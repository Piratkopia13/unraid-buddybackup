use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
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
my $rc_script = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup');
my $rc_php    = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup.php');
my $snap_page = File::Spec->catfile($plugin_dir, 'SnapshotSettings.page');

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

my $rc         = slurp($rc_script);
my $php        = slurp($rc_php);
my $page_html  = slurp($snap_page);

# ---------------------------------------------------------------------------
# Test 1: Static assertions on rc.buddybackup
# ---------------------------------------------------------------------------
subtest 'rc.buddybackup defines ensure_child_datasets_have_snapshots and wires it into replication' => sub {
    like(
        $rc,
        qr/ensure_child_datasets_have_snapshots\s*\(\)/,
        'defines ensure_child_datasets_have_snapshots()'
    );

    like(
        $rc,
        qr/comm\s+-23/,
        'uses comm -23 to compute missing datasets without per-item subshell overhead'
    );

    like(
        $rc,
        qr/zfs\s+snapshot\s+"(?:\$\{snap_name\}|\$snap_name)"/,
        'invokes zfs snapshot on datasets lacking snapshots'
    );

    like(
        $rc,
        qr/send_backup\s*\(\)\s*\{[\s\S]*?ensure_child_datasets_have_snapshots "\$\{source_dataset\}" "\$\{nchan\}"/,
        'send_backup calls ensure_child_datasets_have_snapshots before replication'
    );

    like(
        $rc,
        qr/send_local_backup\s*\(\)\s*\{[\s\S]*?ensure_child_datasets_have_snapshots "\$\{source_dataset\}" "\$\{nchan\}"/,
        'send_local_backup calls ensure_child_datasets_have_snapshots before replication'
    );

    like(
        $rc,
        qr/if\s*\[\[\s*"\$\{recursive\}"\s*==\s*"yes"\s*\|\|\s*"\$\{recursive\}"\s*==\s*"zfs"\s*\]\]/,
        'supports both "yes" and "zfs" recursion modes'
    );
};

# ---------------------------------------------------------------------------
# Test 2: Static assertions on rc.buddybackup.php and SnapshotSettings.page
# ---------------------------------------------------------------------------
subtest 'rc.buddybackup.php and SnapshotSettings.page configure atomic ZFS recursion' => sub {
    like(
        $php,
        qr/\$key\s*===\s*'recursive'/,
        'update_sanoid_conf checks for recursive key'
    );

    like(
        $php,
        qr/\(\$value\s*===\s*'yes'\s*\|\|\s*\$value\s*===\s*'zfs'\)\s*\?\s*'zfs'\s*:\s*'no'/,
        'update_sanoid_conf maps "yes" and "zfs" to atomic "zfs" mode in sanoid.conf'
    );

    like(
        $page_html,
        qr/Yes \(All child datasets\)/,
        'SnapshotSettings.page exposes "Yes (All child datasets)" label'
    );

    like(
        $page_html,
        qr/in_array\(\$data\['recursive'\]\s*\?\?\s*'',\s*\['yes',\s*'zfs'\],\s*true\)/,
        'SnapshotSettings.page card header recognizes both yes and zfs as recursive'
    );
};

# ---------------------------------------------------------------------------
# Test 3: Upstream external vendor dependencies remain untouched (AGENTS.md)
# ---------------------------------------------------------------------------
subtest 'external vendor dependencies policy compliance' => sub {
    my $sanoid_bin = File::Spec->catfile($plugin_dir, 'deps', 'sanoid');
    my $syncoid_bin = File::Spec->catfile($plugin_dir, 'deps', 'syncoid');

    ok(-f $sanoid_bin, 'sanoid binary exists');
    ok(-f $syncoid_bin, 'syncoid binary exists');

    # Verify no uncommitted changes in upstream vendor dependency directory
    my $git_status = `git status --porcelain "$plugin_dir/deps/sanoid" "$plugin_dir/deps/syncoid"`;
    is($git_status, '', 'upstream vendor dependencies deps/sanoid and deps/syncoid have zero modifications');
};

# ---------------------------------------------------------------------------
# Test 4: Behavioral test: ensure_child_datasets_have_snapshots detects and snapshots missing datasets
# ---------------------------------------------------------------------------
subtest 'behavioral: ensure_child_datasets_have_snapshots creates baseline snapshot for child with 0 snapshots' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);

    my $log_file = File::Spec->catfile($workdir, 'zfs_calls.log');

    my $write_script = sub {
        my ($path, $body) = @_;
        open my $fh, '>', $path or die "Cannot write $path: $!";
        print $fh $body;
        close $fh;
        chmod 0755, $path;
    };

    # Mock zfs executable
    my $mock_zfs = File::Spec->catfile($bin_dir, 'zfs');
    $write_script->($mock_zfs, <<"SH");
#!/bin/bash
echo "zfs \$*" >> "$log_file"

if [[ "\$1" == "list" && "\$*" == *"-t filesystem,volume -r tank/appdata"* ]]; then
    printf 'tank/appdata\\ntank/appdata/container1\\ntank/appdata/container2\\n'
    exit 0
fi

if [[ "\$1" == "list" && "\$*" == *"-t snapshot -r tank/appdata"* ]]; then
    printf 'tank/appdata\@autosnap_2026-10-10_01:00:00_daily\\ntank/appdata/container1\@autosnap_2026-10-10_01:00:00_daily\\n'
    exit 0
fi

if [[ "\$1" == "snapshot" ]]; then
    echo "snapshot_created \$2" >> "$log_file"
    exit 0
fi

exit 0
SH

    # Extract functions from rc.buddybackup (before configuration reading & case dispatch)
    my $functions_src = $rc;
    my $cut = index($functions_src, '# read our configuration.');
    $functions_src = substr($functions_src, 0, $cut) if $cut >= 0;
    my $functions_file = File::Spec->catfile($workdir, 'rc.functions.sh');
    $write_script->($functions_file, $functions_src);

    my $harness = File::Spec->catfile($workdir, 'test_ensure.sh');
    $write_script->($harness, <<"SH");
#!/bin/bash
set -o pipefail
plugin="buddybackup"
export PATH="$bin_dir:\$PATH"
export UtcTimezone="yes"

source "$functions_file"

logger() { :; }
write() { echo "WRITE: \$*" >> "$log_file"; }

ensure_child_datasets_have_snapshots "tank/appdata" "send"
SH

    my $out = `bash "$harness" 2>&1`;
    ok(-f $log_file, 'harness executed and generated log');

    my $log_content = slurp($log_file);

    # container2 should be snapshotted
    like(
        $log_content,
        qr/snapshot_created tank\/appdata\/container2\@autosnap_[0-9_\-:]+_daily/,
        'baseline snapshot created specifically for child dataset container2'
    );

    # container1 and tank/appdata already had snapshots, so they must NOT be snapshotted
    unlike(
        $log_content,
        qr/snapshot_created tank\/appdata\/container1\@/,
        'container1 was not touched because it already has snapshots'
    );
    unlike(
        $log_content,
        qr/snapshot_created tank\/appdata\@/,
        'parent dataset tank/appdata was not touched because it already has snapshots'
    );

    # write message streamed to user
    like(
        $log_content,
        qr/WRITE:.*Child dataset 'tank\/appdata\/container2' has no snapshots\. Creating initial baseline snapshot/,
        'logged informational notice to nchan / UI'
    );
};

# ---------------------------------------------------------------------------
# Test 5: Behavioral test: PHP update_sanoid_conf() outputs recursive = zfs
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
    skip 'php CLI is required to test update_sanoid_conf() behavior', 1 if !$php_available;

    subtest 'behavioral: update_sanoid_conf() generates recursive = zfs for recursive snapshot tasks' => sub {
        my $workdir = tempdir(CLEANUP => 1);
        my $plugin_cfg = File::Spec->catfile($workdir, 'plugin.cfg');
        my $extra_cfg  = File::Spec->catfile($workdir, 'extra_sanoid.cfg');
        my $incoming_cfg = File::Spec->catfile($workdir, 'buddys.cfg');
        my $sanoid_out = File::Spec->catfile($workdir, 'sanoid.conf');

        open my $pcfg_fh, '>', $plugin_cfg or die "Cannot write $plugin_cfg: $!";
        print $pcfg_fh "ReceiveBackups=\"disable\"\n";
        close $pcfg_fh;

        open my $ecfg_fh, '>', $extra_cfg or die "Cannot write $extra_cfg: $!";
        print $ecfg_fh <<"INI";
[task_rec_yes]
dataset = "tank/appdata"
recursive = "yes"
autosnap = "yes"
autoprune = "yes"
hourly = "24"
daily = "7"
weekly = "4"
monthly = "3"
yearly = "0"

[task_rec_zfs]
dataset = "tank/vms"
recursive = "zfs"
autosnap = "yes"
autoprune = "yes"
hourly = "12"
daily = "5"
weekly = "0"
monthly = "0"
yearly = "0"

[task_non_rec]
dataset = "tank/photos"
recursive = "no"
autosnap = "yes"
autoprune = "yes"
hourly = "4"
daily = "2"
weekly = "0"
monthly = "0"
yearly = "0"
INI
        close $ecfg_fh;

        my $test_php = File::Spec->catfile($workdir, 'run_update_sanoid.php');
        open my $tfh, '>', $test_php or die "Cannot write $test_php: $!";
        print $tfh <<"PHP";
<?php
\$argv = array('run_update_sanoid.php', 'noop');
require_once '$rc_php';

\$plugin_config_path = '$plugin_cfg';
\$extra_sanoid_config_path = '$extra_cfg';
\$incoming_config_path = '$incoming_cfg';
\$sanoid_config_path = '$sanoid_out';
\$empath = '/usr/local/emhttp/plugins/buddybackup';
\$log_script = '/usr/local/emhttp/plugins/buddybackup/scripts/log.sh';
\$rc = '/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup';

update_sanoid_conf();
echo "SUCCESS";
PHP
        close $tfh;

        my $stdout = gensym;
        my $stderr = gensym;
        my $pid = open3(undef, $stdout, $stderr, $php_bin, $test_php);
        waitpid($pid, 0);
        my $php_exit = $? >> 8;
        my $out = do { local $/; <$stdout> } // '';
        my $err = do { local $/; <$stderr> } // '';

        is($php_exit, 0, 'php executed update_sanoid_conf() successfully');
        like($out, qr/SUCCESS/, 'output confirmed SUCCESS');
        ok(-f $sanoid_out, 'sanoid.conf file created');

        my $conf = slurp($sanoid_out);

        # Verify task_rec_yes got translated to recursive = zfs
        like(
            $conf,
            qr/\[tank\/appdata\][^\[]*?recursive = zfs/s,
            'task with recursive = yes is written as recursive = zfs in sanoid.conf'
        );

        # Verify task_rec_zfs is preserved as recursive = zfs
        like(
            $conf,
            qr/\[tank\/vms\][^\[]*?recursive = zfs/s,
            'task with recursive = zfs is written as recursive = zfs in sanoid.conf'
        );

        # Verify non-recursive task is written as recursive = no
        like(
            $conf,
            qr/\[tank\/photos\][^\[]*?recursive = no/s,
            'task with recursive = no is written as recursive = no in sanoid.conf'
        );
    };
}

done_testing();
