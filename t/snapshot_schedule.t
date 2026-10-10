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

my $rc   = slurp($rc_script);
my $php  = slurp($rc_php);
my $page = slurp($snap_page);

# ---------------------------------------------------------------------------
# 1. Static assertions
# ---------------------------------------------------------------------------
subtest 'static assertions on scheduling, cron, and WebGUI code' => sub {
    # 1-minute ticker with --cache-ttl=60
    like($php, qr/\*\s+\*\s+\*\s+\*\s+\*\s+flock\s+-n\s+\/var\/lock\/buddybackup-sanoid-cron/, 'uses 1-minute cron ticker (* * * * *)');
    like($php, qr/--cache-ttl=60/, 'includes --cache-ttl=60 flag');
    unlike($php, qr/\*\/15\s+\*\s+\*\s+\*\s+\*\s+flock.*buddybackup-sanoid-cron/, 'does not retain legacy 15-minute cron ticker');

    # Helpers in PHP
    like($php, qr/normalize_snapshot_time\s*\(/, 'defines normalize_snapshot_time()');
    like($php, qr/daily_hour\s*=/, 'emits daily_hour directive');
    like($php, qr/daily_min\s*=/, 'emits daily_min directive');

    # WebGUI SnapshotSettings.page
    like($page, qr/name=['"]daily_hour['"]/, 'SnapshotSettings.page includes daily_hour dropdown');
    like($page, qr/name=['"]daily_min['"]/, 'SnapshotSettings.page includes daily_min dropdown');
    like($page, qr/name=['"]hook_scope['"]/, 'SnapshotSettings.page includes hook_scope dropdown');
    like($page, qr/Scheduled snapshot time/, 'SnapshotSettings.page uses Scheduled snapshot time label');
    like($page, qr/fa-clock-o/, 'SnapshotSettings.page includes clock icon in header telemetry badge');
    like($page, qr/buddybackup-schedule-summary/, 'SnapshotSettings.page includes live dynamic schedule summary container');
    like($page, qr/format_schedule_time/, 'SnapshotSettings.page defines format_schedule_time JavaScript function');
    like($page, qr/update_schedule_summary/, 'SnapshotSettings.page defines update_schedule_summary JavaScript function');
};

# ---------------------------------------------------------------------------
# 2. Behavioral: PHP normalize_snapshot_time() validation
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
    skip 'php CLI required for behavioral tests', 3 if !$php_available;

    subtest 'behavioral: normalize_snapshot_time() unit tests' => sub {
        my $workdir = tempdir(CLEANUP => 1);
        my $test_php = File::Spec->catfile($workdir, 'test_norm.php');

        open my $fh, '>', $test_php or die "Cannot write $test_php: $!";
        print $fh <<"PHP";
<?php
\$argv = array('test_norm.php', 'noop');
require_once '$rc_php';

\$cases = array(
    array('hour' => '4', 'min' => '0', 'expected' => array('4', '0')),
    array('hour' => '04', 'min' => '05', 'expected' => array('4', '5')),
    array('hour' => '0', 'min' => '0', 'expected' => array('0', '0')),
    array('hour' => '23', 'min' => '59', 'expected' => array('23', '59')),
    array('hour' => '24', 'min' => '0', 'expected' => array('', '')),
    array('hour' => '-1', 'min' => '0', 'expected' => array('', '')),
    array('hour' => '12', 'min' => '60', 'expected' => array('', '')),
    array('hour' => '12', 'min' => '-5', 'expected' => array('', '')),
    array('hour' => '', 'min' => '', 'expected' => array('', '')),
    array('hour' => null, 'min' => null, 'expected' => array('', '')),
    array('hour' => '4', 'min' => '', 'expected' => array('', '')),
    array('hour' => 'abc', 'min' => '30', 'expected' => array('', '')),
);

foreach (\$cases as \$idx => \$c) {
    \$res = normalize_snapshot_time(\$c['hour'], \$c['min']);
    if (\$res !== \$c['expected']) {
        echo "FAIL case \$idx: got " . json_encode(\$res) . ", expected " . json_encode(\$c['expected']) . "\\n";
        exit(1);
    }
}
echo "ALL_NORM_CASES_PASSED\\n";
PHP
        close $fh;

        my $out = `php "$test_php" 2>&1`;
        is($? >> 8, 0, 'normalize_snapshot_time test runner exited with 0');
        like($out, qr/ALL_NORM_CASES_PASSED/, 'all snapshot time normalization cases passed');
    };

    subtest 'behavioral: enable_sanoid_cron() 1-minute ticker generation' => sub {
        my $workdir = tempdir(CLEANUP => 1);
        my $plugin_cfg = File::Spec->catfile($workdir, 'plugin.cfg');
        my $cron_file  = File::Spec->catfile($workdir, 'sanoid.cron');
        my $test_php   = File::Spec->catfile($workdir, 'test_cron.php');

        open my $pfh, '>', $plugin_cfg or die "Cannot write $plugin_cfg: $!";
        print $pfh "UtcTimezone=\"no\"\n";
        close $pfh;

        open my $tfh, '>', $test_php or die "Cannot write $test_php: $!";
        print $tfh <<"PHP";
<?php
\$argv = array('test_cron.php', 'noop');
require_once '$rc_php';

\$sanoid_cron_path = '$cron_file';
\$sanoid_bin = '/usr/local/emhttp/plugins/buddybackup/deps/sanoid';
\$buddybackup_path = '/usr/local/emhttp/plugins/buddybackup';
\$plugin_path = '$workdir';
\$log_script = '/usr/local/emhttp/plugins/buddybackup/scripts/log.sh';
\$plugin_config_path = '$plugin_cfg';

// Run enable_sanoid_cron (suppressing passthru for update_cron)
ob_start();
enable_sanoid_cron();
ob_end_clean();

echo file_get_contents('$cron_file');
PHP
        close $tfh;

        my $generated = `php "$test_php" 2>&1`;
        ok($generated, 'enable_sanoid_cron generated cron file');
        like($generated, qr/^\* \* \* \* \* flock -n \/var\/lock\/buddybackup-sanoid-cron/m, 'cron uses * * * * * ticker');
        like($generated, qr/--cache-ttl=60/, 'invocation includes --cache-ttl=60');
        unlike($generated, qr/\*\/15/, 'cron does NOT contain */15');
    };

    subtest 'behavioral: update_sanoid_conf() daily_hour, daily_min, and hook_scope' => sub {
        my $workdir = tempdir(CLEANUP => 1);
        my $plugin_cfg   = File::Spec->catfile($workdir, 'plugin.cfg');
        my $extra_cfg    = File::Spec->catfile($workdir, 'extra_sanoid.cfg');
        my $incoming_cfg = File::Spec->catfile($workdir, 'buddys.cfg');
        my $sanoid_cfg   = File::Spec->catfile($workdir, 'sanoid.conf');
        my $test_php     = File::Spec->catfile($workdir, 'test_sanoid.php');

        open my $pfh, '>', $plugin_cfg or die "Cannot write $plugin_cfg: $!";
        print $pfh "ReceiveBackups=\"disable\"\n";
        close $pfh;

        open my $efh, '>', $extra_cfg or die "Cannot write $extra_cfg: $!";
        print $efh <<'CFG';
[custom_time]
dataset="tank/appdata"
hourly="0"
daily="7"
daily_hour="4"
daily_min="0"
trigger="no"

[legacy_no_time]
dataset="tank/legacy"
hourly="24"
daily="7"
trigger="no"

[scoped_hooks_daily]
dataset="tank/workload_daily_hooks"
hourly="24"
daily="7"
daily_hour="3"
daily_min="30"
hook_scope="daily"
pre_snapshot_script="/usr/local/bin/freeze.sh"
post_snapshot_script="/usr/local/bin/thaw.sh"
hook_timeout="30"
trigger="no"

[scoped_hooks_all]
dataset="tank/workload_all_hooks"
hourly="24"
daily="7"
hook_scope="all"
pre_snapshot_script="/usr/local/bin/freeze.sh"
post_snapshot_script="/usr/local/bin/thaw.sh"
hook_timeout="30"
trigger="no"

[scoped_chained_daily]
dataset="tank/workload_chained_daily"
daily="7"
daily_hour="5"
daily_min="15"
hook_scope="daily"
post_snapshot_script="/usr/local/bin/thaw.sh"
hook_timeout="30"
trigger="uid_trig_chain"
CFG
        close $efh;

        open my $sfh, '>', $test_php or die "Cannot write $test_php: $!";
        print $sfh <<"PHP";
<?php
\$argv = array('test_sanoid.php', 'noop');
require_once '$rc_php';

\$plugin_config_path = '$plugin_cfg';
\$extra_sanoid_config_path = '$extra_cfg';
\$incoming_config_path = '$incoming_cfg';
\$sanoid_config_path = '$sanoid_cfg';
\$empath = '/usr/local/emhttp/plugins/buddybackup';
\$log_script = '/usr/local/emhttp/plugins/buddybackup/scripts/log.sh';
\$rc = '/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup';

update_sanoid_conf();
echo file_get_contents('$sanoid_cfg');
PHP
        close $sfh;

        my $generated = `php "$test_php" 2>&1`;
        ok($generated, 'php executed and produced sanoid.conf');

        # 1. custom_time (daily_hour = 4, daily_min = 0, weekly_hour = 4, weekly_min = 0)
        my ($custom_sec) = $generated =~ /\[tank\/appdata\](.*?)(?=\n\[|\z)/s;
        ok(defined $custom_sec, 'section [tank/appdata] exists');
        like($custom_sec, qr/daily_hour = 4/, 'custom_time has daily_hour = 4');
        like($custom_sec, qr/daily_min = 0/, 'custom_time has daily_min = 0');
        like($custom_sec, qr/weekly_hour = 4/, 'custom_time syncs weekly_hour = 4');
        like($custom_sec, qr/weekly_min = 0/, 'custom_time syncs weekly_min = 0');
        unlike($custom_sec, qr/hook_scope/, 'hook_scope is not leaked into sanoid.conf');

        # 2. legacy_no_time (omits daily_hour, daily_min, and weekly_hour for automatic Sanoid fallback)
        my ($legacy_sec) = $generated =~ /\[tank\/legacy\](.*?)(?=\n\[|\z)/s;
        ok(defined $legacy_sec, 'section [tank/legacy] exists');
        unlike($legacy_sec, qr/daily_hour/, 'legacy_no_time omits daily_hour');
        unlike($legacy_sec, qr/daily_min/, 'legacy_no_time omits daily_min');
        unlike($legacy_sec, qr/weekly_hour/, 'legacy_no_time omits weekly_hour');

        # 3. scoped_hooks_daily (injected SANOID_TYPES guard for daily scope)
        my ($daily_sec) = $generated =~ /\[tank\/workload_daily_hooks\](.*?)(?=\n\[|\z)/s;
        ok(defined $daily_sec, 'section [tank/workload_daily_hooks] exists');
        like($daily_sec, qr/daily_hour = 3/, 'scoped_hooks_daily has daily_hour = 3');
        like($daily_sec, qr/daily_min = 30/, 'scoped_hooks_daily has daily_min = 30');
        like(
            $daily_sec,
            qr/pre_snapshot_script = \[ -n "\$\{SANOID_TYPES:-\}" \] && \[\[ "\$\{SANOID_TYPES\}" != \*"daily"\* \]\] && exit 0; \/usr\/local\/bin\/freeze\.sh/,
            'pre_snapshot_script has SANOID_TYPES guard for daily scope'
        );
        like(
            $daily_sec,
            qr/post_snapshot_script = \[ -n "\$\{SANOID_TYPES:-\}" \] && \[\[ "\$\{SANOID_TYPES\}" != \*"daily"\* \]\] && exit 0; \/usr\/local\/bin\/thaw\.sh/,
            'post_snapshot_script has SANOID_TYPES guard for daily scope'
        );

        # 4. scoped_hooks_all (no SANOID_TYPES guard when scope is all)
        my ($all_sec) = $generated =~ /\[tank\/workload_all_hooks\](.*?)(?=\n\[|\z)/s;
        ok(defined $all_sec, 'section [tank/workload_all_hooks] exists');
        like($all_sec, qr/pre_snapshot_script = \/usr\/local\/bin\/freeze\.sh/, 'all scope pre-hook has no SANOID_TYPES guard');
        like($all_sec, qr/post_snapshot_script = \/usr\/local\/bin\/thaw\.sh/, 'all scope post-hook has no SANOID_TYPES guard');

        # 5. scoped_chained_daily (passes daily hook_scope to run_snapshot_post_hook_and_trigger)
        my ($chain_sec) = $generated =~ /\[tank\/workload_chained_daily\](.*?)(?=\n\[|\z)/s;
        ok(defined $chain_sec, 'section [tank/workload_chained_daily] exists');
        like(
            $chain_sec,
            qr/post_snapshot_script = \/usr\/local\/emhttp\/plugins\/buddybackup\/scripts\/rc\.buddybackup run_snapshot_post_hook_and_trigger "tank\/workload_chained_daily" "\/usr\/local\/bin\/thaw\.sh" "30" "uid_trig_chain" "daily"/,
            'chained runner receives daily hook_scope parameter'
        );
    };
}

# ---------------------------------------------------------------------------
# 3. Behavioral: run_snapshot_post_hook_and_trigger with hook_scope & SANOID_TYPES
# ---------------------------------------------------------------------------
subtest 'behavioral: run_snapshot_post_hook_and_trigger filters hooks by SANOID_TYPES' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);

    my $log_file = File::Spec->catfile($workdir, 'scope_events.log');

    my $write_script = sub {
        my ($path, $body) = @_;
        open my $fh, '>', $path or die "Cannot write $path: $!";
        print $fh $body;
        close $fh;
        chmod 0755, $path;
    };

    my $thaw_hook = File::Spec->catfile($workdir, 'thaw_hook.sh');
    $write_script->($thaw_hook, <<'SH');
#!/bin/bash
echo "post_thaw_hook_executed" >> "$CHAIN_EVENT_LOG"
exit 0
SH

    my $functions_src = $rc;
    my $cut = index($functions_src, '# read our configuration.');
    $functions_src = substr($functions_src, 0, $cut) if $cut >= 0;
    my $functions_file = File::Spec->catfile($workdir, 'rc.functions.sh');
    $write_script->($functions_file, $functions_src);

    my $mock_empath = File::Spec->catdir($workdir, 'empath');
    my $mock_scripts = File::Spec->catdir($mock_empath, 'scripts');
    make_path($mock_scripts);

    my $mock_php = File::Spec->catfile($mock_scripts, 'rc.buddybackup.php');
    $write_script->($mock_php, <<'SH');
#!/bin/bash
if [[ "$1" == "send_backup" ]]; then
    echo "trigger_dispatched uid=$2" >> "$CHAIN_EVENT_LOG"
fi
exit 0
SH

    my $mock_log = File::Spec->catfile($mock_scripts, 'log.sh');
    $write_script->($mock_log, <<'SH');
#!/bin/bash
cat > /dev/null
SH

    my $harness = File::Spec->catfile($workdir, 'harness.sh');
    my $harness_body = <<'SH';
#!/bin/bash
set -o pipefail
plugin="buddybackup"
export CHAIN_EVENT_LOG
export empath="$MOCK_EMPATH"

source "$FUNCTIONS_FILE"

logger() { :; }
write() { :; }

run_snapshot_post_hook_and_trigger "$DATASET" "$THAW_HOOK" "30" "$TRIGGER_UID" "$HOOK_SCOPE"
ret=$?
echo "RUN_STATUS=$ret"
wait
SH
    $write_script->($harness, $harness_body);

    my $run_harness = sub {
        my (%env) = @_;
        local $ENV{CHAIN_EVENT_LOG} = $log_file;
        local $ENV{MOCK_EMPATH}     = $mock_empath;
        local $ENV{FUNCTIONS_FILE}  = $functions_file;
        local $ENV{DATASET}         = 'tank/appdata';
        local $ENV{THAW_HOOK}       = $thaw_hook;
        local $ENV{TRIGGER_UID}     = 'trig_scope_1';
        local $ENV{HOOK_SCOPE}      = $env{hook_scope} // 'daily';
        local $ENV{SANOID_TYPES}    = $env{sanoid_types} // '';
        unlink $log_file if -e $log_file;
        my $out = `bash "$harness" 2>&1`;
        my $log = -e $log_file ? slurp($log_file) : '';
        return ($log, $out);
    };

    subtest 'when hook_scope is daily and SANOID_TYPES is hourly: skip thaw hook, still dispatch trigger' => sub {
        my ($log, $out) = $run_harness->(hook_scope => 'daily', sanoid_types => 'hourly');
        like($out, qr/RUN_STATUS=0/, 'harness returned 0');
        my @lines = grep { length } split /\n/, $log;
        is(scalar(@lines), 1, 'only 1 event logged (thaw was skipped)');
        is($lines[0], 'trigger_dispatched uid=trig_scope_1', 'trigger backup still dispatched');
    };

    subtest 'when hook_scope is daily and SANOID_TYPES is daily: execute thaw hook and dispatch trigger' => sub {
        my ($log, $out) = $run_harness->(hook_scope => 'daily', sanoid_types => 'daily');
        like($out, qr/RUN_STATUS=0/, 'harness returned 0');
        my @lines = grep { length } split /\n/, $log;
        is(scalar(@lines), 2, 'both thaw and trigger events logged');
        is($lines[0], 'post_thaw_hook_executed', 'thaw hook executed on daily snapshot');
        is($lines[1], 'trigger_dispatched uid=trig_scope_1', 'trigger backup dispatched');
    };

    subtest 'when hook_scope is all and SANOID_TYPES is hourly: execute thaw hook and dispatch trigger' => sub {
        my ($log, $out) = $run_harness->(hook_scope => 'all', sanoid_types => 'hourly');
        like($out, qr/RUN_STATUS=0/, 'harness returned 0');
        my @lines = grep { length } split /\n/, $log;
        is(scalar(@lines), 2, 'both thaw and trigger events logged on hourly snapshot');
        is($lines[0], 'post_thaw_hook_executed', 'thaw hook executed because scope is all');
        is($lines[1], 'trigger_dispatched uid=trig_scope_1', 'trigger backup dispatched');
    };
};

done_testing();
