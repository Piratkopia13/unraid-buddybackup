use strict;
use warnings;

# Regression tests for two issues reported on the Unraid forum (2026.10.18):
#
# 1. Scheduled backup cron jobs were silently never created when optional
#    fields (pre_backup_script, post_backup_script, destination_user, ...) were
#    saved as empty strings by the WebGUI. update_backups_from_config() treated
#    any empty field as "incomplete entry" and skipped the backup.
#
# 2. run_hook() captured the full hook output and emitted it only after the
#    hook finished, so log.sh stamped every line of e.g. a post-snapshot hook
#    with the same (completion) timestamp.

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

my $repo_root;
for my $anchor (dirname(File::Spec->rel2abs($0)), File::Spec->rel2abs($Bin), getcwd()) {
    next if !defined $anchor || $anchor eq q{};
    for my $candidate ($anchor, dirname($anchor)) {
        if (-f File::Spec->catfile($candidate, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'scripts', 'rc.buddybackup')) {
            $repo_root = $candidate;
            last;
        }
    }
    last if defined $repo_root;
}
BAIL_OUT('Unable to locate repository root') if !defined $repo_root;

my $plugin_dir = File::Spec->catdir($repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup');
my $rc_script  = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup');
my $rc_php     = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup.php');
my $log_sh     = File::Spec->catfile($plugin_dir, 'scripts', 'log.sh');

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

sub spew {
    my ($path, $content, $mode) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print $fh $content;
    close $fh;
    chmod $mode, $path if defined $mode;
}

my $php_available = 0;
{
    my ($out, $err) = (gensym, gensym);
    my $pid = eval { open3(undef, $out, $err, 'php', '-v') };
    if ($pid) {
        waitpid($pid, 0);
        $php_available = 1 if $? == 0;
    }
}

# ---------------------------------------------------------------------------
# Static guard: the fragile "every field must be non-empty" check must not return
# ---------------------------------------------------------------------------
subtest 'update_backups_from_config validates required fields only' => sub {
    my $php = slurp($rc_php);
    my ($body) = $php =~ /^function update_backups_from_config\s*\(\)\s*\{(.*?)^\}/ms;
    ok(defined $body, 'update_backups_from_config body is discoverable');
    like($body // '', qr/backup_cfg_missing_required_field\s*\(/, 'uses backup_cfg_missing_required_field()');
    unlike($body // '', qr/\$allow_empty/, 'no longer uses an allow_empty list of optional fields');
    unlike($body // '', qr/foreach\s*\(\s*\$cfg\s+as\s+\$key\s*=>\s*\$value\s*\)/, 'does not reject entries for arbitrary empty fields');
};

SKIP: {
    skip 'php CLI is required for backup scheduling behavior tests', 2 if !$php_available;

    subtest 'backup_cfg_missing_required_field()' => sub {
        my $workdir = tempdir(CLEANUP => 1);
        my $runner = File::Spec->catfile($workdir, 'required.php');
        spew($runner, <<"PHP");
<?php
require_once '$rc_php';
\$base_local = array(
    'enable' => 'yes', 'type' => 'local', 'source_dataset' => 'tank/data', 'recursive' => 'no',
    'destination_host' => '', 'destination_dataset' => 'tank/backup', 'backup_cron' => '0 4 * * *',
    'pre_backup_script' => '', 'post_backup_script' => '', 'hook_timeout' => '', 'hook_failure_mode' => '',
);
\$base_remote = array_merge(\$base_local, array('type' => 'remote', 'destination_host' => '10.0.0.2', 'destination_user' => '', 'destination_port' => ''));
\$base_generic = array_merge(\$base_local, array('type' => 'remote_generic', 'destination_host' => '10.0.0.3', 'destination_user' => '', 'destination_port' => ''));
\$cases = array(
    'local_blank_optional'   => \$base_local,
    'remote_blank_optional'  => \$base_remote,
    'generic_blank_optional' => \$base_generic,
    'zero_values'            => array_merge(\$base_local, array('hook_timeout' => '0', 'skip_parent' => '0')),
    'missing_source'         => array_merge(\$base_local, array('source_dataset' => '')),
    'missing_dest'           => array_merge(\$base_local, array('destination_dataset' => '  ')),
    'missing_cron'           => array_merge(\$base_local, array('backup_cron' => '')),
    'missing_type'           => array_merge(\$base_local, array('type' => '')),
    'remote_missing_host'    => array_merge(\$base_remote, array('destination_host' => '')),
    'generic_missing_host'   => array_merge(\$base_generic, array('destination_host' => '')),
    'local_absent_optional'  => array('type' => 'local', 'source_dataset' => 'a', 'destination_dataset' => 'b', 'backup_cron' => '* * * * *'),
);
\$result = array();
foreach (\$cases as \$name => \$cfg) {
    \$result[\$name] = backup_cfg_missing_required_field(\$cfg);
}
echo "\\nJSON:" . json_encode(\$result) . "\\n";
PHP
        my $out = `php "$runner" 2>&1`;
        my ($json) = $out =~ /^JSON:(.*)$/m;
        ok(defined $json, 'runner produced JSON') or diag($out);
        $json //= '';
        like($json, qr/"local_blank_optional":null/,   'local backup with blank hooks is schedulable');
        like($json, qr/"remote_blank_optional":null/,  'buddy remote backup with blank user/port/hooks is schedulable');
        like($json, qr/"generic_blank_optional":null/, 'generic remote backup with blank user/port/hooks is schedulable');
        like($json, qr/"zero_values":null/,            '"0" values in optional fields do not block scheduling');
        like($json, qr/"local_absent_optional":null/,  'entries from older versions without optional keys are schedulable');
        like($json, qr/"missing_source":"source_dataset"/,     'blank source_dataset is rejected');
        like($json, qr/"missing_dest":"destination_dataset"/,  'whitespace-only destination_dataset is rejected');
        like($json, qr/"missing_cron":"backup_cron"/,          'blank backup_cron is rejected');
        like($json, qr/"missing_type":"type"/,                 'blank type is rejected');
        like($json, qr/"remote_missing_host":"destination_host"/,  'buddy remote without host is rejected');
        like($json, qr/"generic_missing_host":"destination_host"/, 'generic remote without host is rejected');
    };

    subtest 'update_backups_from_config() writes cron files for WebGUI-saved backups with blank hooks' => sub {
        my $workdir = tempdir(CLEANUP => 1);
        my $plugin_path = File::Spec->catdir($workdir, 'plugin');
        make_path($plugin_path);
        my $cfg_file = File::Spec->catfile($plugin_path, 'backups.cfg');

        # Exactly what Backups.page writes when the optional hook fields are left blank.
        spew($cfg_file, <<'CFG');
[aaaa1111]
enable="yes"
type="local"
source_dataset="tank/appdata"
recursive="yes"
skip_parent="no"
destination_host=""
destination_dataset="backup/appdata"
backup_cron="0 4 * * *"
pre_backup_script=""
post_backup_script=""
hook_timeout="300"
hook_failure_mode="abort"

[bbbb2222]
enable="yes"
type="local"
source_dataset="tank/media"
recursive="no"
destination_host=""
destination_dataset="backup/media"
backup_cron="30 5 * * 1"
pre_backup_script="/boot/config/plugins/buddybackup/hooks/pre.sh"
post_backup_script=""

[cccc3333]
enable="no"
type="local"
source_dataset="tank/off"
recursive="no"
destination_host=""
destination_dataset="backup/off"
backup_cron="0 1 * * *"

[dddd4444]
enable="yes"
type="local"
source_dataset="tank/broken"
recursive="no"
destination_host=""
destination_dataset=""
backup_cron="0 2 * * *"
CFG

        # A stale cron file from a previous run must be removed and regenerated.
        spew(File::Spec->catfile($plugin_path, 'backup-zzzz9999.cron'), "stale\n");

        my $runner = File::Spec->catfile($workdir, 'update.php');
        spew($runner, <<"PHP");
<?php
require_once '$rc_php';
\$plugin_path = '$plugin_path';
\$backups_config_path = '$cfg_file';
\$managed_known_hosts_path = '$plugin_path/buddybackup_known_hosts';
\$rc = 'true';
\$log_script = 'cat >/dev/null';
update_backups_from_config();
echo "\\nDONE\\n";
PHP
        my $out = `php "$runner" 2>&1`;
        like($out, qr/^DONE$/m, 'update_backups_from_config completed') or diag($out);

        my $cron_a = File::Spec->catfile($plugin_path, 'backup-aaaa1111.cron');
        my $cron_b = File::Spec->catfile($plugin_path, 'backup-bbbb2222.cron');
        ok(-f $cron_a, 'cron file created for backup with both hooks blank');
        ok(-f $cron_b, 'cron file created for backup with only one hook set');
        ok(!-e File::Spec->catfile($plugin_path, 'backup-cccc3333.cron'), 'no cron file for disabled backup');
        ok(!-e File::Spec->catfile($plugin_path, 'backup-dddd4444.cron'), 'no cron file for backup missing a required field');
        ok(!-e File::Spec->catfile($plugin_path, 'backup-zzzz9999.cron'), 'stale cron file removed');

        if (-f $cron_a) {
            like(slurp($cron_a), qr/^0 4 \* \* \* flock -n "\/var\/lock\/buddybackup-aaaa1111" .*send_backup aaaa1111/m, 'cron entry uses configured schedule and uid');
        }
        if (-f $cron_b) {
            like(slurp($cron_b), qr/^30 5 \* \* 1 flock .*send_backup bbbb2222/m, 'second cron entry uses its own schedule');
        }
    };
}

# ---------------------------------------------------------------------------
# run_hook output is streamed line by line (per-line log timestamps)
# ---------------------------------------------------------------------------
subtest 'run_hook streams hook output as it is produced' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $rc = slurp($rc_script);
    my $cut = index($rc, '# read our configuration.');
    $rc = substr($rc, 0, $cut) if $cut >= 0;
    my $functions_file = File::Spec->catfile($workdir, 'rc.functions.sh');
    spew($functions_file, $rc, 0755);

    my $hook = File::Spec->catfile($workdir, 'slow_hook.sh');
    spew($hook, <<'SH', 0755);
#!/bin/bash
echo "step one"
sleep 2
echo "step two"
printf 'no trailing newline'
exit 7
SH

    my $timeout_hook = File::Spec->catfile($workdir, 'hang_hook.sh');
    spew($timeout_hook, <<'SH', 0755);
#!/bin/bash
echo "before hang"
sleep 30
echo "never printed"
SH

    my $log_file = File::Spec->catfile($workdir, 'buddybackup.log');
    my $nchan_file = File::Spec->catfile($workdir, 'nchan.log');
    my $harness = File::Spec->catfile($workdir, 'harness.sh');
    spew($harness, <<'SH', 0755);
#!/bin/bash
set -o pipefail
plugin="buddybackup"
source "$FUNCTIONS_FILE"
logger() { :; }
nchan_publish() { [[ -n "$1" ]] || return 0; shift; printf '%s\n--\n' "$@" >> "$NCHAN_FILE"; }
run_hook "$HOOK" "$HOOK_TIMEOUT" "post-snapshot" "snapshot"
echo "status=$?"
SH

    my $run = sub {
        my ($hook_cmd, $timeout) = @_;
        unlink $log_file, $nchan_file;
        local $ENV{FUNCTIONS_FILE} = $functions_file;
        local $ENV{HOOK} = $hook_cmd;
        local $ENV{HOOK_TIMEOUT} = $timeout;
        local $ENV{NCHAN_FILE} = $nchan_file;
        local $ENV{LOGFILE} = $log_file;
        system('bash', '-c', 'bash "$0" 2>&1 | bash "$1"', $harness, $log_sh);
        return (-e $log_file ? slurp($log_file) : '', -e $nchan_file ? slurp($nchan_file) : '');
    };

    my ($log, $nchan) = $run->($hook, 30);
    my %ts;
    for my $line (split /\n/, $log) {
        $ts{$2} = $1 if $line =~ /^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d): (.*)$/;
    }
    ok(exists $ts{'step one'}, 'first hook line logged') or diag($log);
    ok(exists $ts{'step two'}, 'second hook line logged');
    ok(exists $ts{'no trailing newline'}, 'final line without trailing newline is not lost');
    isnt($ts{'step one'} // '', $ts{'step two'} // '', 'lines emitted 2s apart get different log timestamps');
    ok(exists $ts{'status=7'}, 'hook exit status is propagated through the output pipeline');
    is($nchan, "Running post-snapshot hook (timeout 30s)..\n--\nstep one\nstep two\nno trailing newline\n--\n",
        'nchan receives the start message and the complete hook output as one message');

    ($log) = $run->($timeout_hook, 1);
    like($log, qr/: before hang$/m, 'output produced before a timeout is still logged');
    unlike($log, qr/never printed/, 'hook is killed at its timeout');
    like($log, qr/: status=124$/m, 'timeout exit status 124 is propagated');
};

# ---------------------------------------------------------------------------
# Log file creation after boot & manual WebGUI backup logging (echopid mode)
# ---------------------------------------------------------------------------
subtest 'log.sh and manual WebGUI backups create and populate missing buddybackup.log' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $log_file = File::Spec->catfile($workdir, 'buddybackup.log');

    # 1. log.sh creates the log file even when stdin is empty (e.g. quiet sanoid cron right after boot)
    unlink $log_file;
    ok(!-e $log_file, 'precondition: log file does not exist after reboot');
    {
        local $ENV{LOGFILE} = $log_file;
        system('bash', '-c', 'bash "$0" </dev/null', $log_sh);
    }
    ok(-f $log_file, 'log.sh creates missing log file even when zero lines are received');
    is(slurp($log_file), '', 'newly touched log file is empty');

    # 2. write() with BUDDYBACKUP_DIRECT_LOG=1 (set by start_long_running_task_echo_pid)
    #    creates and appends to missing log file, while cron mode (unset) only echoes to stdout
    unlink $log_file;
    my $rc = slurp($rc_script);
    my $cut = index($rc, '# read our configuration.');
    $rc = substr($rc, 0, $cut) if $cut >= 0;
    my $functions_file = File::Spec->catfile($workdir, 'rc.functions.sh');
    spew($functions_file, $rc, 0755);

    my $mock_empath = File::Spec->catdir($workdir, 'empath');
    make_path(File::Spec->catdir($mock_empath, 'scripts'));
    spew(File::Spec->catfile($mock_empath, 'scripts', 'log.sh'), slurp($log_sh), 0755);

    my $write_harness = File::Spec->catfile($workdir, 'write_harness.sh');
    spew($write_harness, <<'SH', 0755);
#!/bin/bash
plugin="buddybackup"
empath="$MOCK_EMPATH"
source "$FUNCTIONS_FILE"
nchan_publish() { :; }
write "send" $'\nSuccessfully synced backup to buddy!'
write "send" "[[rc.buddybackup finished]]"
SH

    {
        local $ENV{LOGFILE} = $log_file;
        local $ENV{MOCK_EMPATH} = $mock_empath;
        local $ENV{FUNCTIONS_FILE} = $functions_file;
        local $ENV{BUDDYBACKUP_DIRECT_LOG} = '1';
        system('bash', $write_harness);
    }
    ok(-f $log_file, 'BUDDYBACKUP_DIRECT_LOG=1 creates missing log file on manual backup');
    my $manual_log = -f $log_file ? slurp($log_file) : '';
    like($manual_log, qr/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d: Successfully synced backup to buddy!$/m,
        'manual backup completion message is timestamped and written to buddybackup.log');

    # 3. Verify cron mode (BUDDYBACKUP_DIRECT_LOG unset) does not write directly inside write()
    unlink $log_file;
    {
        local $ENV{LOGFILE} = $log_file;
        local $ENV{MOCK_EMPATH} = $mock_empath;
        local $ENV{FUNCTIONS_FILE} = $functions_file;
        delete $ENV{BUDDYBACKUP_DIRECT_LOG};
        system('bash', '-c', 'bash "$0" >/dev/null', $write_harness);
    }
    ok(!-e $log_file, 'cron mode (BUDDYBACKUP_DIRECT_LOG unset) leaves logging to the outer cron pipeline without duplicating');

    SKIP: {
        skip 'php CLI is required for start_long_running_task_echo_pid and ensure_log_file tests', 5 if !$php_available;

        unlink $log_file;
        my $php_runner = File::Spec->catfile($workdir, 'manual_task.php');
        spew($php_runner, <<"PHP");
<?php
putenv('LOGFILE=$log_file');
\$_ENV['LOGFILE'] = '$log_file';
require_once '$rc_php';
\$log_file_path = '$log_file';
ensure_log_file();
echo "\\nTOUCHED=" . (file_exists('$log_file') ? '1' : '0') . "\\n";
unlink('$log_file');
clearstatcache();
ob_start();
start_long_running_task_echo_pid('MOCK_EMPATH=' . escapeshellarg('$mock_empath') . ' FUNCTIONS_FILE=' . escapeshellarg('$functions_file') . ' LOGFILE=' . escapeshellarg('$log_file') . ' bash ' . escapeshellarg('$write_harness'));
\$pid = trim(ob_get_clean());
echo "PID=\$pid\\n";
for (\$i = 0; \$i < 30; \$i++) {
    clearstatcache(true, '$log_file');
    if (file_exists('$log_file') && filesize('$log_file') > 0) {
        break;
    }
    usleep(50000);
}
PHP
        my $out = `php "$php_runner" 2>&1`;
        like($out, qr/^TOUCHED=1$/m, 'ensure_log_file() creates missing buddybackup.log') or diag($out);
        like($out, qr/^PID=\d+$/m, 'start_long_running_task_echo_pid() echoes numeric child PID') or diag($out);
        ok(-f $log_file, 'start_long_running_task_echo_pid() creates and populates buddybackup.log');
        my $task_log = -f $log_file ? slurp($log_file) : '';
        like($task_log, qr/Successfully synced backup to buddy!/,
            'task launched via start_long_running_task_echo_pid() logs output to buddybackup.log');

        # Verify api.php get_log safe behavior when log file does not exist yet
        my $api_php = slurp(File::Spec->catfile($plugin_dir, 'api.php'));
        like($api_php, qr/is_file\(\$log_file\)\s*&&\s*is_readable\(\$log_file\)/,
            'api.php guards file_get_contents on missing log file');
    }
};

done_testing();
