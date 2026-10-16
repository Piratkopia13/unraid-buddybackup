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
my $rc_script     = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup');
my $rc_php        = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup.php');
my $snap_page     = File::Spec->catfile($plugin_dir, 'SnapshotSettings.page');

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

my $rc  = slurp($rc_script);
my $php = slurp($rc_php);

# ---------------------------------------------------------------------------
# Static assertions on rc.buddybackup.php Sanoid config generation
# ---------------------------------------------------------------------------
subtest 'rc.buddybackup.php generates complete Sanoid hook directives' => sub {
    like($php, qr/update_sanoid_conf\s*\(\)/, 'defines update_sanoid_conf()');

    like(
        $php,
        qr/pre_snapshot_script\s*=\s*\$pre_hook/,
        'writes pre_snapshot_script directive'
    );
    like(
        $php,
        qr/if\s*\(\s*\$hook_failure_mode\s*===\s*'abort'\s*\)\s*\{\s*\$sanoid_conf_content\s*\.=\s*"    no_inconsistent_snapshot = 1\\n";\s*\}/,
        'writes no_inconsistent_snapshot = 1 when failure mode is abort'
    );
    like(
        $php,
        qr/script_timeout\s*=\s*\$hook_timeout/,
        'writes script_timeout directive when hooks are configured'
    );
    like(
        $php,
        qr/force_post_snapshot_script\s*=\s*1/,
        'writes force_post_snapshot_script = 1 to guarantee thaw runs'
    );
    like(
        $php,
        qr/\$rc\s+run_snapshot_post_hook_and_trigger/,
        'uses run_snapshot_post_hook_and_trigger runner when both post_hook and trigger are present'
    );
};

# ---------------------------------------------------------------------------
# Static assertions on rc.buddybackup helper and dispatch
# ---------------------------------------------------------------------------
subtest 'rc.buddybackup defines chained runner helper' => sub {
    like(
        $rc,
        qr/run_snapshot_post_hook_and_trigger\s*\(\)/,
        'defines run_snapshot_post_hook_and_trigger()'
    );
    like(
        $rc,
        qr/run_hook\s+"\$\{post_hook\}"/,
        'chained helper executes post-snapshot thaw hook first'
    );
    like(
        $rc,
        qr/rc\.buddybackup\.php"\s+send_backup\s+"\$\{trigger_uid\}"/,
        'chained helper dispatches send_backup for trigger task'
    );
    like(
        $rc,
        qr/\(?['"]?run_snapshot_post_hook_and_trigger['"]?\)?/,
        'case dispatch routes run_snapshot_post_hook_and_trigger command'
    );
};

# ---------------------------------------------------------------------------
# Behavioral test: PHP update_sanoid_conf() permutations
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

    subtest 'behavioral: update_sanoid_conf() config generation across permutations' => sub {
        my $workdir = tempdir(CLEANUP => 1);
        my $plugin_cfg = File::Spec->catfile($workdir, 'plugin.cfg');
        my $extra_cfg  = File::Spec->catfile($workdir, 'extra_sanoid.cfg');
        my $incoming_cfg = File::Spec->catfile($workdir, 'buddys.cfg');
        my $sanoid_cfg = File::Spec->catfile($workdir, 'sanoid.conf');
        my $test_php   = File::Spec->catfile($workdir, 'test_sanoid.php');

        open my $pfh, '>', $plugin_cfg or die "Cannot write $plugin_cfg: $!";
        print $pfh "ReceiveBackups=\"disable\"\n";
        close $pfh;

        open my $efh, '>', $extra_cfg or die "Cannot write $extra_cfg: $!";
        print $efh <<'CFG';
[snap_abort]
dataset="tank/workload_abort"
pre_snapshot_script="/usr/local/bin/freeze.sh"
post_snapshot_script="/usr/local/bin/thaw.sh"
hook_timeout="15"
hook_failure_mode="abort"
trigger="no"

[snap_warn]
dataset="tank/workload_warn"
pre_snapshot_script="/usr/local/bin/freeze.sh"
hook_timeout="25"
hook_failure_mode="warn"
trigger="no"

[snap_post_only]
dataset="tank/workload_post_only"
post_snapshot_script="/usr/local/bin/thaw.sh"
hook_timeout="35"
trigger="no"

[snap_trigger_only]
dataset="tank/workload_trigger_only"
trigger="uid_trig_99"

[snap_chained]
dataset="tank/workload_chained"
post_snapshot_script="/usr/local/bin/thaw.sh"
hook_timeout="45"
trigger="uid_trig_100"
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

        # Permutation 1: snap_abort (pre + post + timeout 15 + abort)
        my ($abort_sec) = $generated =~ /\[tank\/workload_abort\](.*?)(?=\n\[|\z)/s;
        ok(defined $abort_sec, 'section [tank/workload_abort] exists');
        like($abort_sec, qr/pre_snapshot_script = \/usr\/local\/bin\/freeze\.sh/, 'abort sec has pre_snapshot_script');
        like($abort_sec, qr/no_inconsistent_snapshot = 1/, 'abort sec has no_inconsistent_snapshot = 1');
        like($abort_sec, qr/force_post_snapshot_script = 1/, 'abort sec has force_post_snapshot_script = 1');
        like($abort_sec, qr/post_snapshot_script = \/usr\/local\/bin\/thaw\.sh/, 'abort sec has post_snapshot_script');
        like($abort_sec, qr/script_timeout = 15/, 'abort sec has script_timeout = 15');

        # Permutation 2: snap_warn (pre only + timeout 25 + warn)
        my ($warn_sec) = $generated =~ /\[tank\/workload_warn\](.*?)(?=\n\[|\z)/s;
        ok(defined $warn_sec, 'section [tank/workload_warn] exists');
        like($warn_sec, qr/pre_snapshot_script = \/usr\/local\/bin\/freeze\.sh/, 'warn sec has pre_snapshot_script');
        unlike($warn_sec, qr/no_inconsistent_snapshot/, 'warn sec does NOT have no_inconsistent_snapshot');
        unlike($warn_sec, qr/post_snapshot_script/, 'warn sec does NOT have post_snapshot_script');
        like($warn_sec, qr/script_timeout = 25/, 'warn sec has script_timeout = 25');

        # Permutation 3: snap_post_only (post only + timeout 35)
        my ($post_sec) = $generated =~ /\[tank\/workload_post_only\](.*?)(?=\n\[|\z)/s;
        ok(defined $post_sec, 'section [tank/workload_post_only] exists');
        unlike($post_sec, qr/pre_snapshot_script/, 'post only sec does NOT have pre_snapshot_script');
        like($post_sec, qr/force_post_snapshot_script = 1/, 'post only sec has force_post_snapshot_script = 1');
        like($post_sec, qr/post_snapshot_script = \/usr\/local\/bin\/thaw\.sh/, 'post only sec has post_snapshot_script');
        like($post_sec, qr/script_timeout = 35/, 'post only sec has script_timeout = 35');

        # Permutation 4: snap_trigger_only (trigger only, no hooks)
        my ($trig_sec) = $generated =~ /\[tank\/workload_trigger_only\](.*?)(?=\n\[|\z)/s;
        ok(defined $trig_sec, 'section [tank/workload_trigger_only] exists');
        like(
            $trig_sec,
            qr/post_snapshot_script = \/usr\/local\/emhttp\/plugins\/buddybackup\/scripts\/rc\.buddybackup run_snapshot_post_hook_and_trigger "tank\/workload_trigger_only" "" "30" "uid_trig_99"/,
            'trigger only sec dispatches asynchronously via run_snapshot_post_hook_and_trigger'
        );
        unlike($trig_sec, qr/force_post_snapshot_script/, 'trigger only sec does NOT have force_post_snapshot_script');
        unlike($trig_sec, qr/script_timeout/, 'trigger only sec does NOT set script_timeout');

        # Permutation 5: snap_chained (post hook + trigger -> chained runner)
        my ($chain_sec) = $generated =~ /\[tank\/workload_chained\](.*?)(?=\n\[|\z)/s;
        ok(defined $chain_sec, 'section [tank/workload_chained] exists');
        like($chain_sec, qr/force_post_snapshot_script = 1/, 'chained sec has force_post_snapshot_script = 1');
        like($chain_sec, qr/script_timeout = 45/, 'chained sec has script_timeout = 45');
        like(
            $chain_sec,
            qr/post_snapshot_script = \/usr\/local\/emhttp\/plugins\/buddybackup\/scripts\/rc\.buddybackup run_snapshot_post_hook_and_trigger "tank\/workload_chained" "\/usr\/local\/bin\/thaw\.sh" "45" "uid_trig_100"/,
            'chained sec sets post_snapshot_script to run_snapshot_post_hook_and_trigger helper'
        );
    };
}

# ---------------------------------------------------------------------------
# Behavioral test: Bash execution of run_snapshot_post_hook_and_trigger
# ---------------------------------------------------------------------------
subtest 'behavioral: run_snapshot_post_hook_and_trigger executes thaw before trigger' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);

    my $log_file = File::Spec->catfile($workdir, 'chain_events.log');

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
exit "${SIMULATED_THAW_EXIT:-0}"
SH

    # Extract functions from rc.buddybackup (before configuration reading & case dispatch)
    my $functions_src = $rc;
    my $cut = index($functions_src, '# read our configuration.');
    $functions_src = substr($functions_src, 0, $cut) if $cut >= 0;
    my $functions_file = File::Spec->catfile($workdir, 'rc.functions.sh');
    $write_script->($functions_file, $functions_src);

    # Create mock empath/scripts directory for rc.buddybackup.php and log.sh
    my $mock_empath = File::Spec->catdir($workdir, 'empath');
    my $mock_scripts = File::Spec->catdir($mock_empath, 'scripts');
    make_path($mock_scripts);

    my $mock_php = File::Spec->catfile($mock_scripts, 'rc.buddybackup.php');
    $write_script->($mock_php, <<'SH');
#!/bin/bash
if [[ "$1" == "send_backup" ]]; then
    if [[ -n "${SIMULATED_BACKUP_DELAY:-}" && "${SIMULATED_BACKUP_DELAY}" -gt 0 ]]; then
        sleep "${SIMULATED_BACKUP_DELAY}"
    fi
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

t_start=$(date +%s)
run_snapshot_post_hook_and_trigger "$DATASET" "$THAW_HOOK" "30" "$TRIGGER_UID"
ret=$?
t_returned=$(date +%s)
duration=$(( t_returned - t_start ))
echo "DISPATCH_DURATION=$duration"
echo "RUN_STATUS=$ret"
wait
SH
    $write_script->($harness, $harness_body);

    my $run_harness = sub {
        my (%env) = @_;
        local $ENV{CHAIN_EVENT_LOG}         = $log_file;
        local $ENV{MOCK_EMPATH}             = $mock_empath;
        local $ENV{FUNCTIONS_FILE}          = $functions_file;
        local $ENV{DATASET}                 = $env{dataset} // 'tank/appdata';
        local $ENV{THAW_HOOK}               = $thaw_hook;
        local $ENV{TRIGGER_UID}             = $env{trigger} // 'trig_abc123';
        local $ENV{SIMULATED_THAW_EXIT}     = $env{thaw_exit} // '0';
        local $ENV{SIMULATED_BACKUP_DELAY}  = $env{backup_delay} // '0';
        unlink $log_file if -e $log_file;
        my $out = `bash "$harness" 2>&1`;
        my $log = -e $log_file ? slurp($log_file) : '';
        return ($log, $out);
    };

    subtest 'successful thaw executes first then dispatches trigger' => sub {
        my ($log, $out) = $run_harness->(thaw_exit => 0);
        my @lines = grep { length } split /\n/, $log;
        is(scalar(@lines), 2, 'two events logged');
        is($lines[0], 'post_thaw_hook_executed', 'thaw hook executed first');
        is($lines[1], 'trigger_dispatched uid=trig_abc123', 'trigger backup dispatched second');
    };

    subtest 'failing thaw logs warning but still dispatches trigger' => sub {
        my ($log, $out) = $run_harness->(thaw_exit => 1);
        my @lines = grep { length } split /\n/, $log;
        is(scalar(@lines), 2, 'two events logged even on thaw failure');
        is($lines[0], 'post_thaw_hook_executed', 'thaw hook executed first');
        is($lines[1], 'trigger_dispatched uid=trig_abc123', 'trigger backup dispatched second to avoid deadlock');
    };

    subtest 'trigger dispatches asynchronously in background without blocking' => sub {
        my ($log, $out) = $run_harness->(thaw_exit => 0, backup_delay => 2);
        like($out, qr/RUN_STATUS=0/, 'run_snapshot_post_hook_and_trigger returned 0');
        like($out, qr/DISPATCH_DURATION=[01]/, 'run_snapshot_post_hook_and_trigger detached trigger without blocking caller');
        my @lines = grep { length } split /\n/, $log;
        is(scalar(@lines), 2, 'two events logged after background replication completed');
        is($lines[0], 'post_thaw_hook_executed', 'thaw hook executed first');
        is($lines[1], 'trigger_dispatched uid=trig_abc123', 'trigger backup completed in background');
    };
};

done_testing();
