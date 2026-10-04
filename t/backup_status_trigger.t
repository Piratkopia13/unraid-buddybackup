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
my $backups_page = File::Spec->catfile($plugin_dir, 'Backups.page');

# Static guard: the trigger comparison must cast both sides to string so that
# all-digit uids (which parse_ini_file returns as int section keys) still match
# the string trigger values (regression for issue #34).
subtest 'Backups.page compares snapshot trigger with string casts' => sub {
    open my $fh, '<', $backups_page
        or die "Cannot open $backups_page: $!";
    my $page = do { local $/; <$fh> };
    close $fh;

    like(
        $page,
        qr/\(string\)\s*\(\$snap\['trigger'\]\s*\?\?\s*''\)\s*===\s*\(string\)\$uid/,
        'trigger comparison casts both snapshot trigger and backup uid to string'
    );
};

# php may be absent in the CI container; skip the behavioral part cleanly.
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
    skip 'php CLI is required to evaluate backup status rendering', 1
        if !$php_available;

    my $workdir = tempdir(CLEANUP => 1);
    my $config_dir = File::Spec->catdir($workdir, 'boot', 'config', 'plugins', 'buddybackup');
    make_path($config_dir);

    my $backups_cfg = File::Spec->catfile($config_dir, 'backups.cfg');
    my $snapshots_cfg = File::Spec->catfile($config_dir, 'snapshots.cfg');

    # A non-numeric uid and an all-digit uid; the latter becomes an int section
    # key under parse_ini_file and previously rendered as "Disabled".
    open my $b_fh, '>', $backups_cfg or die "Failed to write $backups_cfg: $!";
    print $b_fh <<'CFG';
[aa4ed6a1]
enable="no"
source_dataset="tank/data/appdata"
type="local"
destination_dataset="tank/backups/appdata"
backup_cron=""

[81370285]
enable="no"
source_dataset="tank/data/media"
type="local"
destination_dataset="tank/backups/media"
backup_cron=""
CFG
    close $b_fh;

    # Both backups are disabled and driven purely by an external snapshot trigger.
    open my $s_fh, '>', $snapshots_cfg or die "Failed to write $snapshots_cfg: $!";
    print $s_fh <<'CFG';
[snap_one]
dataset="tank/data/appdata"
trigger="aa4ed6a1"
autosnap="no"

[snap_two]
dataset="tank/data/media"
trigger="81370285"
autosnap="no"
CFG
    close $s_fh;

    # Faithful reproduction of the trigger-detection block in Backups.page
    # followed by the status-text selection for the "disabled + triggered" case.
    my $php_test = sprintf(<<'PHP', $backups_cfg, $snapshots_cfg);
$backups_cfg_path = '%s';
$snapshots_cfg_path = '%s';

$backups_cfg = parse_ini_file($backups_cfg_path, true);
$snapshot_cfg = parse_ini_file($snapshots_cfg_path, true);

$statuses = array();
foreach ($backups_cfg as $uid => $data) {
    $triggering_snapshots = array();
    if (!empty($snapshot_cfg) && is_array($snapshot_cfg)) {
        foreach ($snapshot_cfg as $snap_uid => $snap) {
            if ((string)($snap['trigger'] ?? '') === (string)$uid) {
                $triggering_snapshots[] = $snap['dataset'] ?? 'snapshot';
            }
        }
    }
    $is_triggered = !empty($triggering_snapshots);
    $is_enabled = ($data['enable'] ?? '') === 'yes';

    if (!$is_enabled && !$is_triggered) {
        $status_text = 'Disabled';
    } else if (!$is_enabled && $is_triggered) {
        $status_text = 'Triggered by snapshot';
    } else {
        $status_text = 'Enabled';
    }

    $statuses[(string)$uid] = array(
        'triggered' => $is_triggered,
        'status_text' => $status_text,
    );
}

echo json_encode($statuses);
PHP

    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = open3(undef, $stdout, $stderr, $php_bin, '-r', $php_test);
    my $out = do { local $/; <$stdout> // '' };
    waitpid($pid, 0);

    require JSON::PP;
    my $statuses = JSON::PP::decode_json($out || '{}');

    ok(exists $statuses->{'aa4ed6a1'}, 'non-numeric uid rendered');
    ok(exists $statuses->{'81370285'}, 'all-digit uid rendered');

    is(
        $statuses->{'aa4ed6a1'}{triggered}, 1,
        'non-numeric uid is detected as snapshot-triggered'
    );
    is(
        $statuses->{'aa4ed6a1'}{status_text}, 'Triggered by snapshot',
        'non-numeric uid shows "Triggered by snapshot"'
    );

    is(
        $statuses->{'81370285'}{triggered}, 1,
        'all-digit uid is detected as snapshot-triggered (regression #34)'
    );
    is(
        $statuses->{'81370285'}{status_text}, 'Triggered by snapshot',
        'all-digit uid shows "Triggered by snapshot" (regression #34)'
    );
}

done_testing();