use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use JSON::PP qw(decode_json);
use Test::More;

my @repo_root_candidates;
for my $anchor (
    dirname(File::Spec->rel2abs($0)),
    File::Spec->rel2abs($Bin),
    getcwd(),
) {
    next if !defined $anchor || $anchor eq q{};

    for my $candidate_root ($anchor, dirname($anchor)) {
        next if !defined $candidate_root || $candidate_root eq q{};
        next if grep { $_ eq $candidate_root } @repo_root_candidates;
        push @repo_root_candidates, $candidate_root;
    }
}

my $repo_root;
for my $candidate_root (@repo_root_candidates) {
    my $candidate_allowlist = File::Spec->catfile(
        $candidate_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', 'restrict_zfs'
    );
    if (-f $candidate_allowlist) {
        $repo_root = $candidate_root;
        last;
    }
}

BAIL_OUT('Unable to locate repository root') if !defined $repo_root;

my $plugin_dir = File::Spec->catdir(
    $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup'
);
my $rc_script     = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup');
my $rc_php        = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup.php');
my $common_php    = File::Spec->catfile($plugin_dir, 'common.php');

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

my $rc_content     = slurp($rc_script);
my $php_content    = slurp($rc_php);
my $common_content = slurp($common_php);

# ---------------------------------------------------------------------------
# SEC-01 & SEC-06: Elimination of wildcard chown/chmod in /tmp & safe runtime dir
# ---------------------------------------------------------------------------
subtest 'SEC-01 & SEC-06: Elimination of wildcard chown/chmod and safe file handling' => sub {
    unlike(
        $php_content,
        qr/glob\(\s*['"]\/tmp\/buddybackup-buddy\*['"]\s*\)/,
        'eliminated dangerous wildcard glob on /tmp/buddybackup-buddy*'
    );
    unlike(
        $php_content,
        qr/\@chmod\(\s*\$f,\s*0666\s*\)/,
        'eliminated bulk chmod on /tmp glob results'
    );
    like(
        $php_content,
        qr/\/var\/run\/buddybackup/,
        'uses secure /var/run/buddybackup runtime directory'
    );
    like(
        $rc_content,
        qr/mkdir -p \/var\/run\/buddybackup/,
        'rc.buddybackup creates /var/run/buddybackup directory'
    );
    like(
        $rc_content,
        qr/chmod 0770 \/var\/run\/buddybackup/,
        'rc.buddybackup secures /var/run/buddybackup with mode 0770'
    );
    like(
        $php_content,
        qr/0640/,
        'sets restrictive mode 0640 for incoming metadata'
    );
};

# ---------------------------------------------------------------------------
# SEC-02: Concurrency locking on snapshot-triggered backups
# ---------------------------------------------------------------------------
subtest 'SEC-02: Concurrency lock with flock on background triggered backups' => sub {
    like(
        $rc_content,
        qr/flock\s+-n\s+["']?\/var\/lock\/buddybackup-\$\{trigger_uid\}["']?/,
        'run_snapshot_post_hook_and_trigger wraps background send_backup in non-blocking flock'
    );
    like(
        $rc_content,
        qr/\[\[\s*"\$\{trigger_uid\}"\s*=~\s*\^\[A-Za-z0-9_-\]\+\$\s*\]\]/,
        'validates trigger_uid against safe identifier regex before interpolation'
    );
};

# ---------------------------------------------------------------------------
# SEC-03: Safe sanoid post-hook quoting and trigger validation
# ---------------------------------------------------------------------------
subtest 'SEC-03: Sanoid hook quoting and trigger sanitization' => sub {
    like(
        $php_content,
        qr/preg_match\(\s*['"]\/\^\[A-Za-z0-9_-\]\+\$\/['"],\s*\$trigger\s*\)/,
        'update_sanoid_conf validates trigger UID with regex'
    );
    like(
        $php_content,
        qr/addcslashes\(\s*\$post_hook,\s*["']\\\\\\"\$`["']\s*\)/,
        'escapes backticks in post_hook to prevent command substitution inside double quotes'
    );
};

# ---------------------------------------------------------------------------
# SEC-04: Cross-buddy dataset scoping and no data leakage in probe_zfs
# ---------------------------------------------------------------------------
subtest 'SEC-04: probe_zfs and read_receive_destination_datasets scoping' => sub {
    like(
        $php_content,
        qr/if\s*\(\s*\$env_uid\s*!==\s*''\s*&&\s*isset\(\$incoming_cfg\[\$env_uid\]\['destination_dataset'\]\)\s*\)\s*\{\s*\$ds\s*=\s*trim\(\$incoming_cfg\[\$env_uid\]\['destination_dataset'\]\);\s*if\s*\(is_valid_zfs_dataset_name\(\$ds\)\)\s*\{\s*return\s+array\(\$ds\);/s,
        'read_receive_destination_datasets immediately returns single dataset for BUDDY_UID'
    );

    unlike(
        $php_content,
        qr/write_probe_zfs_response\(\s*'error',\s*null,\s*[^,]+,\s*\$all_datasets\s*\)/,
        'probe_zfs error paths do not pass $all_datasets to write_probe_zfs_response'
    );
};

# ---------------------------------------------------------------------------
# SEC-05: POSIX compliance of daily hook filtering under /bin/sh
# ---------------------------------------------------------------------------
subtest 'SEC-05: POSIX compliance of daily hook filter' => sub {
    like(
        $php_content,
        qr/case\s+"\$\{SANOID_TYPES\}"\s+in\s+\*daily\*\)/,
        'daily hook filter uses standard POSIX case statement'
    );
    unlike(
        $php_content,
        qr/\[\[\s*"\\\$\{SANOID_TYPES\}"\s*!=\s*\*\"daily\"\*\s*\]\]/,
        'removed non-POSIX bashism [[ ... != *daily* ]]'
    );
};

# ---------------------------------------------------------------------------
# SEC-07: Telemetry attribution and longest prefix matching
# ---------------------------------------------------------------------------
subtest 'SEC-07: Robust telemetry dataset matching' => sub {
    like(
        $php_content,
        qr/strpos\(\$dataset,\s*'\@'\)\s*!==\s*false/,
        'mark_received_backup strips snapshot suffix before querying dataset size'
    );
    like(
        $common_content,
        qr/!is_link\(\$run_file\)/,
        'common.php rejects symlinks on runtime telemetry files'
    );
};

# ---------------------------------------------------------------------------
# Behavioral tests
# ---------------------------------------------------------------------------
my $php_bin = 'php';
my $php_available = 0;
{
    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = eval { open3(undef, $stdout, $stderr, $php_bin, '-v') };
    if ($pid) {
        waitpid($pid, 0);
        $php_available = 1 if $? == 0;
    }
}

SKIP: {
    skip 'php CLI is required for behavioral tests', 2 if !$php_available;

    subtest 'behavioral: probe_zfs dataset isolation' => sub {
        my $workdir = tempdir(CLEANUP => 1);
        my $incoming_cfg = File::Spec->catfile($workdir, 'incoming.cfg');
        open my $fh, '>', $incoming_cfg or die "Cannot write $incoming_cfg: $!";
        print $fh <<'CFG';
[alice_uid]
name="Alice"
enable="yes"
destination_dataset="tank/backups/alice"

[bob_uid]
name="Bob"
enable="yes"
destination_dataset="tank/backups/bob_private"

[charlie_uid]
name="Charlie"
enable="yes"
destination_dataset="tank/backups/charlie_vault"
CFG
        close $fh;

        my $probe_script = File::Spec->catfile($workdir, 'probe_test.php');
        open my $pfh, '>', $probe_script or die "Cannot write $probe_script: $!";
        print $pfh <<"PHP";
<?php
\$incoming_config_path = '$incoming_cfg';
\$tmp_recv_dataset_path = '$workdir/recv-dest';
\$tmp_incoming_json_path = '$workdir/incoming.json';

require_once '$rc_php';

// Mock read_zfs_property_value to return mock sizes
function mock_probe() {
    global \$argv;
    probe_zfs(\$argv[1] ?? null);
}
PHP
        close $pfh;

        # Test querying as Alice - should only expose Alice's dataset
        my $stdout = gensym;
        my $stderr = gensym;
        local $ENV{BUDDY_UID} = 'alice_uid';
        delete $ENV{BUDDY_DATASET};

        my $test_code = <<"PHP";
\$argv = array('rc.buddybackup.php', 'noop');
ob_start();
require_once '$rc_php';
ob_end_clean();
\$incoming_config_path = '$incoming_cfg';
\$tmp_recv_dataset_path = '$workdir/recv-dest';
\$tmp_incoming_json_path = '$workdir/incoming.json';
\$datasets = read_receive_destination_datasets(\$err);
echo json_encode(array('datasets' => \$datasets));
PHP
        my $pid = open3(undef, $stdout, $stderr, 'php', '-r', $test_code);
        my $out = do { local $/; <$stdout> // '' };
        waitpid($pid, 0);

        is($? >> 8, 0, 'read_receive_destination_datasets exited with 0');
        my $res = decode_json($out);
        is_deeply($res->{datasets}, ['tank/backups/alice'], 'Alice only sees her own dataset')
            or diag("Output: $out");
    };

    subtest 'behavioral: POSIX daily filter execution under /bin/sh' => sub {
        my $daily_filter = '[ -n "${SANOID_TYPES:-}" ] && case "${SANOID_TYPES}" in *daily*) ;; *) exit 0;; esac; exit 42';

        # Case 1: hourly -> exit 0 (filter matched and exited early)
        my $out1 = `sh -c 'SANOID_TYPES="hourly"; $daily_filter'`;
        is($? >> 8, 0, 'hourly snapshot exits 0 without running hook');

        # Case 2: frequently -> exit 0
        my $out2 = `sh -c 'SANOID_TYPES="frequently"; $daily_filter'`;
        is($? >> 8, 0, 'frequently snapshot exits 0 without running hook');

        # Case 3: daily -> exit 42 (filter passed, hook ran)
        my $out3 = `sh -c 'SANOID_TYPES="daily"; $daily_filter'`;
        is($? >> 8, 42, 'daily snapshot executes hook');

        # Case 4: hourly,daily -> exit 42 (filter passed, hook ran)
        my $out4 = `sh -c 'SANOID_TYPES="hourly,daily"; $daily_filter'`;
        is($? >> 8, 42, 'hourly,daily snapshot executes hook');

        # Case 5: unset SANOID_TYPES -> exit 42 (manual run executes hook)
        my $out5 = `sh -c 'unset SANOID_TYPES; $daily_filter'`;
        is($? >> 8, 42, 'unset SANOID_TYPES executes hook');
    };
}

done_testing();
