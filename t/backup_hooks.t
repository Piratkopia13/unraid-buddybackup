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
my $backups_page  = File::Spec->catfile($plugin_dir, 'Backups.page');

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

my $rc   = slurp($rc_script);
my $php  = slurp($rc_php);
my $page = slurp($backups_page);

# ---------------------------------------------------------------------------
# Static assertions on Backups.page
# ---------------------------------------------------------------------------
subtest 'Backups.page exposes backup hook fields' => sub {
    like($page, qr/name="pre_backup_script"/, 'form has pre_backup_script input');
    like($page, qr/name="post_backup_script"/, 'form has post_backup_script input');
    like($page, qr/name="hook_timeout"/, 'form has hook_timeout input');
    like($page, qr/name="hook_failure_mode"/, 'form has hook_failure_mode input');

    like(
        $page,
        qr/<details\s+class="[^"]*buddybackup-hooks-section[^"]*"/,
        'hooks section is wrapped in collapsible details element'
    );
    like(
        $page,
        qr/<summary\b[^>]*>.*?Advanced:\s*backup hooks.*?<\/summary>/is,
        'hooks section provides a summary element for backup hooks'
    );
    unlike(
        $page,
        qr/<details\s+class="[^"]*buddybackup-hooks-section[^"]*"\s+open/,
        'hooks section defaults to collapsed (no open attribute)'
    );

    like(
        $page,
        qr/mk_option\(\$data\['hook_failure_mode'\] \?\? 'abort', "abort"/,
        'hook failure mode defaults to abort'
    );
    like(
        $page,
        qr/mk_option\(\$data\['hook_failure_mode'\] \?\? 'abort', "warn"/,
        'hook failure mode offers warn'
    );
    like(
        $page,
        qr/function\s+verify_and_submit_backup\b.*?pre_backup_script.*?post_backup_script/s,
        'verify_and_submit_backup validates hook script paths'
    );
    like(
        $page,
        qr/Runs before replication starts\.\s+Script path \(scripts on \/boot\/ run automatically via bash\/interpreter\) or command\./,
        'pre-backup hook field note documents automatic /boot/ interpreter execution'
    );
    like(
        $page,
        qr/Runs after replication completes, on both success and failure\.\s+Script path \(scripts on \/boot\/ run automatically via bash\/interpreter\) or command\./,
        'post-backup hook field note documents automatic /boot/ interpreter execution'
    );
};

# ---------------------------------------------------------------------------
# Static assertions on rc.buddybackup.php
# ---------------------------------------------------------------------------
subtest 'rc.buddybackup.php reads and migrates backup hooks' => sub {
    like($php, qr/load_backup_config_entry\s*\(/, 'defines load_backup_config_entry');
    like(
        $php,
        qr/\$entry\['pre_backup_script'\]\s*=\s*\$entry\['pre_snapshot_script'\]/,
        'load_backup_config_entry falls back to legacy pre_snapshot_script'
    );
    like(
        $php,
        qr/\$entry\['post_backup_script'\]\s*=\s*\$entry\['post_snapshot_script'\]/,
        'load_backup_config_entry falls back to legacy post_snapshot_script'
    );

    like(
        $php,
        qr/unset\s*\(\s*\$[a-zA-Z0-9_]+\['pre_snapshot_script'\]\s*\)/,
        'migrates legacy pre_snapshot_script key on save'
    );
    like(
        $php,
        qr/unset\s*\(\s*\$[a-zA-Z0-9_]+\['post_snapshot_script'\]\s*\)/,
        'migrates legacy post_snapshot_script key on save'
    );
    like(
        $php,
        qr/\$escaped_v\s*=\s*str_replace\('"',\s*'\\"'/s,
        'escapes double quotes during backup config migration'
    );

    like(
        $php,
        qr/build_send_backup_command\s*\(/,
        'defines build_send_backup_command'
    );
};

# ---------------------------------------------------------------------------
# Static assertions on rc.buddybackup
# ---------------------------------------------------------------------------
subtest 'rc.buddybackup defines backup hook lifecycle' => sub {
    like($rc, qr/run_post_backup_hook_once\s*\(\)/, 'defines run_post_backup_hook_once');
    like($rc, qr/head -c 4096/, 'bounds BB_ERROR_MESSAGE to 4096 bytes to avoid kernel E2BIG limit');
    like($rc, qr/export BB_TASK_UID=/, 'exports BB_TASK_UID');
    like($rc, qr/export BB_TASK_TYPE=/, 'exports BB_TASK_TYPE');
    like($rc, qr/export BB_SOURCE_DATASET=/, 'exports BB_SOURCE_DATASET');
    like($rc, qr/export BB_DEST_DATASET=/, 'exports BB_DEST_DATASET');
    like($rc, qr/export BB_STATUS=/, 'exports BB_STATUS');
    like($rc, qr/export BB_EXIT_CODE=/, 'exports BB_EXIT_CODE');
    like($rc, qr/export BB_ERROR_MESSAGE=/, 'exports BB_ERROR_MESSAGE');

    like(
        $rc,
        qr/trap 'run_post_backup_hook_once; cleanup' EXIT INT TERM HUP/,
        'registers run_post_backup_hook_once on EXIT INT TERM HUP traps'
    );
    like(
        $rc,
        qr/load_backup_hooks\s*\(\)/,
        'defines load_backup_hooks helper'
    );
    like(
        $rc,
        qr/pre_backup_script\|pre_snapshot_script/,
        'load_backup_hooks reads both modern and legacy pre-hook keys'
    );
    like(
        $rc,
        qr/post_backup_script\|post_snapshot_script/,
        'load_backup_hooks reads both modern and legacy post-hook keys'
    );
};

# ---------------------------------------------------------------------------
# Behavioral test: PHP backwards compatibility evaluation
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
    skip 'php CLI is required to test PHP config loading behavior', 1 if !$php_available;

    subtest 'PHP config loading backwards compatibility' => sub {
        my $workdir = tempdir(CLEANUP => 1);
        my $test_php = File::Spec->catfile($workdir, 'test_hooks_compat.php');
        my $cfg_file = File::Spec->catfile($workdir, 'backups.cfg');

        open my $cfh, '>', $cfg_file or die "Cannot write $cfg_file: $!";
        print $cfh <<'CFG';
[legacy_task]
enable="yes"
source_dataset="tank/data"
type="local"
destination_dataset="tank/backups"
pre_snapshot_script="/usr/local/bin/legacy-pre.sh"
post_snapshot_script="/usr/local/bin/legacy-post.sh"

[modern_task]
enable="yes"
source_dataset="tank/data"
type="local"
destination_dataset="tank/backups"
pre_backup_script="/usr/local/bin/modern-pre.sh"
post_backup_script="/usr/local/bin/modern-post.sh"

[mixed_task]
enable="yes"
source_dataset="tank/data"
type="local"
destination_dataset="tank/backups"
pre_backup_script="/usr/local/bin/prefer-modern.sh"
pre_snapshot_script="/usr/local/bin/ignored-legacy.sh"
CFG
        close $cfh;

        open my $pfh, '>', $test_php or die "Cannot write $test_php: $!";
        print $pfh <<"PHP";
<?php
\$backups_config_path = '$cfg_file';

function load_backup_config_entry(\$uid, &\$error_message = null) {
    global \$backups_config_path;
    \$backup_cfg = parse_ini_file(\$backups_config_path, true);
    if (!is_array(\$backup_cfg) || !array_key_exists(\$uid, \$backup_cfg)) {
        \$error_message = "Backup with uid '\$uid' does not exist.";
        return null;
    }
    \$entry = \$backup_cfg[\$uid];
    if (!isset(\$entry['pre_backup_script']) && isset(\$entry['pre_snapshot_script'])) {
        \$entry['pre_backup_script'] = \$entry['pre_snapshot_script'];
    }
    if (!isset(\$entry['post_backup_script']) && isset(\$entry['post_snapshot_script'])) {
        \$entry['post_backup_script'] = \$entry['post_snapshot_script'];
    }
    return \$entry;
}

\$legacy = load_backup_config_entry('legacy_task');
\$modern = load_backup_config_entry('modern_task');
\$mixed  = load_backup_config_entry('mixed_task');

echo json_encode(array(
    'legacy' => \$legacy,
    'modern' => \$modern,
    'mixed'  => \$mixed,
));
PHP
        close $pfh;

        my $json = `php "$test_php"`;
        ok($json, 'php script produced output');

        like($json, qr/"pre_backup_script":"\\\/usr\\\/local\\\/bin\\\/legacy-pre\.sh"/, 'legacy pre_snapshot_script loaded as pre_backup_script');
        like($json, qr/"post_backup_script":"\\\/usr\\\/local\\\/bin\\\/legacy-post\.sh"/, 'legacy post_snapshot_script loaded as post_backup_script');
        like($json, qr/"pre_backup_script":"\\\/usr\\\/local\\\/bin\\\/modern-pre\.sh"/, 'modern pre_backup_script loaded directly');
        like($json, qr/"pre_backup_script":"\\\/usr\\\/local\\\/bin\\\/prefer-modern\.sh"/, 'modern key takes precedence over legacy key');
    };

    subtest 'PHP validate_hook_script supports /boot without +x' => sub {
        my $workdir = tempdir(CLEANUP => 1);
        my $boot_mock = File::Spec->catdir($workdir, 'boot', 'config', 'plugins', 'buddybackup', 'hooks');
        make_path($boot_mock);
        my $regular_dir = File::Spec->catdir($workdir, 'regular');
        make_path($regular_dir);

        my $boot_script = File::Spec->catfile($boot_mock, 'test-boot.sh');
        open my $bfh, '>', $boot_script or die "Cannot write $boot_script: $!";
        print $bfh "#!/bin/bash\necho ok\n";
        close $bfh;
        chmod 0600, $boot_script;

        my $reg_exec = File::Spec->catfile($regular_dir, 'exec.sh');
        open my $efh, '>', $reg_exec or die "Cannot write $reg_exec: $!";
        print $efh "#!/bin/bash\necho ok\n";
        close $efh;
        chmod 0755, $reg_exec;

        my $reg_noexec = File::Spec->catfile($regular_dir, 'noexec.sh');
        open my $nfh, '>', $reg_noexec or die "Cannot write $reg_noexec: $!";
        print $nfh "#!/bin/bash\necho ok\n";
        close $nfh;
        chmod 0644, $reg_noexec;

        my $test_php = File::Spec->catfile($workdir, 'test_validate.php');
        my $boot_prefix = File::Spec->catdir($workdir, 'boot');
        open my $pfh, '>', $test_php or die "Cannot write $test_php: $!";
        print $pfh <<"PHP";
<?php
putenv('BUDDYBACKUP_TEST_BOOT_PREFIX=$boot_prefix');
\$_ENV['BUDDYBACKUP_TEST_BOOT_PREFIX'] = '$boot_prefix';

require_once '$rc_php';

\$err = null;
\$r_boot = validate_hook_script('$boot_script', \$err);
\$e_boot = \$err;

\$err = null;
\$r_reg_ok = validate_hook_script('$reg_exec', \$err);
\$e_reg_ok = \$err;

\$err = null;
\$r_reg_bad = validate_hook_script('$reg_noexec', \$err);
\$e_reg_bad = \$err;

echo json_encode(array(
    'boot' => array('result' => \$r_boot, 'error' => \$e_boot),
    'reg_ok' => array('result' => \$r_reg_ok, 'error' => \$e_reg_ok),
    'reg_bad' => array('result' => \$r_reg_bad, 'error' => \$e_reg_bad),
));
PHP
        close $pfh;

        my $out = `php "$test_php"`;
        ok($out, 'validation test produced json');
        like($out, qr/"boot":\{"result":true,"error":null\}/, 'boot script without +x passes validation');
        like($out, qr/"reg_ok":\{"result":true,"error":null\}/, 'regular script with 755 passes validation');
        like($out, qr/"reg_bad":\{"result":false,"error":".*not executable.*"\}/, 'regular script with 644 fails validation');
    };
}

# ---------------------------------------------------------------------------
# Behavioral tests: Bash execution of send_local_backup & send_backup
# ---------------------------------------------------------------------------
subtest 'behavioral: backup lifecycle hooks execution and environment' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);

    my $log_file = File::Spec->catfile($workdir, 'hook_events.log');

    my $write_script = sub {
        my ($path, $body) = @_;
        open my $fh, '>', $path or die "Cannot write $path: $!";
        print $fh $body;
        close $fh;
        chmod 0755, $path;
    };

    # Mock syncoid executable
    my $mock_syncoid = File::Spec->catfile($bin_dir, 'syncoid');
    $write_script->($mock_syncoid, <<'SH');
#!/bin/bash
echo syncoid_ran >> "$HOOK_EVENT_LOG"
exit "${SIMULATED_SYNCOID_EXIT:-0}"
SH

    # Mock hooks
    my $pre_hook = File::Spec->catfile($workdir, 'pre_hook.sh');
    $write_script->($pre_hook, <<'SH');
#!/bin/bash
echo pre_backup_ran >> "$HOOK_EVENT_LOG"
exit "${SIMULATED_PRE_EXIT:-0}"
SH

    my $post_hook = File::Spec->catfile($workdir, 'post_hook.sh');
    $write_script->($post_hook, <<'SH');
#!/bin/bash
echo "post_backup_ran status=${BB_STATUS} exit=${BB_EXIT_CODE} uid=${BB_TASK_UID} type=${BB_TASK_TYPE} src=${BB_SOURCE_DATASET} dst=${BB_DEST_DATASET}" >> "$HOOK_EVENT_LOG"
exit "${SIMULATED_POST_EXIT:-0}"
SH

    # Extract functions from rc.buddybackup (before configuration reading & case dispatch)
    my $functions_src = $rc;
    my $cut = index($functions_src, '# read our configuration.');
    $functions_src = substr($functions_src, 0, $cut) if $cut >= 0;
    my $functions_file = File::Spec->catfile($workdir, 'rc.functions.sh');
    $write_script->($functions_file, $functions_src);

    my $harness = File::Spec->catfile($workdir, 'harness.sh');
    my $harness_body = <<'SH';
#!/bin/bash
set -o pipefail
plugin="buddybackup"
export HOOK_EVENT_LOG
export PATH="$MOCK_BIN_DIR:$PATH"
export syncoid_bin="syncoid"
export username="buddybackup"

source "$FUNCTIONS_FILE"

logger() { :; }
unraid_notify() { :; }
write() { :; }
append_to_buddybackup_log() { :; }
mark_sent_backup() { echo "marked_sent" >> "$HOOK_EVENT_LOG"; }
mark_failed_backup() { echo "marked_failed code=$2" >> "$HOOK_EVENT_LOG"; }
preflight_send_state() { PREFLIGHT_STATUS="ok"; PREFLIGHT_MESSAGE=""; }
zfs_get_property_value() { echo "10G"; }
get_buddy_used_size() { echo "10G"; }
run_remote_ssh() { return 0; }
normalize_remote_target() { return 0; }
is_encrypted() { return 1; }
ensure_managed_known_host() { return 0; }
send_mark_received_backup() { return 0; }
has_mount_privilege_error() { return 1; }

run_and_write_output() {
    local nchan="$1"
    local cmd="$2"
    local out
    out=$(eval "$cmd")
    local ec=$?
    echo "$out"
    return $ec
}

if [[ "$HARNESS_TYPE" == "local" ]]; then
    send_local_backup "tank/data" "no" "tank/backups" "$TASK_UID" "no" "$PRE_HOOK" "$POST_HOOK" "$TIMEOUT" "$MODE"
elif [[ "$HARNESS_TYPE" == "remote" ]]; then
    send_backup "remote" "tank/data" "no" "192.0.2.50" "tank/remote_backups" "$TASK_UID" "user" "22" "no" "$PRE_HOOK" "$POST_HOOK" "$TIMEOUT" "$MODE"
fi
SH
    $write_script->($harness, $harness_body);

    my $run_harness = sub {
        my (%env) = @_;
        local $ENV{HOOK_EVENT_LOG}           = $log_file;
        local $ENV{MOCK_BIN_DIR}             = $bin_dir;
        local $ENV{FUNCTIONS_FILE}           = $functions_file;
        local $ENV{HARNESS_TYPE}             = $env{type} // 'local';
        local $ENV{TASK_UID}                 = $env{uid} // 'test1234';
        local $ENV{PRE_HOOK}                 = $env{pre} // '';
        local $ENV{POST_HOOK}                = $env{post} // '';
        local $ENV{TIMEOUT}                  = $env{timeout} // '30';
        local $ENV{MODE}                     = $env{mode} // 'abort';
        local $ENV{SIMULATED_PRE_EXIT}       = $env{pre_exit} // '0';
        local $ENV{SIMULATED_SYNCOID_EXIT}   = $env{syncoid_exit} // '0';
        local $ENV{SIMULATED_POST_EXIT}      = $env{post_exit} // '0';
        local $ENV{BUDDYBACKUP_TEST_BOOT_PREFIX} = $env{boot_prefix} // '';
        unlink $log_file if -e $log_file;
        my $out = `bash "$harness" 2>&1`;
        my $log = -e $log_file ? slurp($log_file) : '';
        return ($log, $out);
    };

    subtest 'local backup success runs pre, syncoid, post with success context' => sub {
        my ($log, $out) = $run_harness->(
            type => 'local',
            pre  => $pre_hook,
            post => $post_hook,
            uid  => 'uid_local_ok',
        );
        my @lines = grep { length } split /\n/, $log;
        ok(grep({ $_ eq 'pre_backup_ran' } @lines), 'pre backup hook ran');
        ok(grep({ $_ eq 'syncoid_ran' } @lines), 'syncoid replication ran');
        ok(grep({ $_ eq 'marked_sent' } @lines), 'backup was marked sent');
        ok(
            grep({ /post_backup_ran status=success exit=0 uid=uid_local_ok type=local src=tank\/data dst=tank\/backups/ } @lines),
            'post backup hook received success context'
        );
    };

    subtest 'syncoid failure sets failed context for post hook' => sub {
        my ($log, $out) = $run_harness->(
            type         => 'local',
            pre          => $pre_hook,
            post         => $post_hook,
            uid          => 'uid_local_fail',
            syncoid_exit => '2',
        );
        my @lines = grep { length } split /\n/, $log;
        ok(grep({ $_ eq 'pre_backup_ran' } @lines), 'pre backup hook ran');
        ok(grep({ $_ eq 'syncoid_ran' } @lines), 'syncoid replication ran (and failed)');
        ok(grep({ /marked_failed code=2/ } @lines), 'backup failure marked with exit code 2');
        ok(
            grep({ /post_backup_ran status=failed exit=2 uid=uid_local_fail type=local/ } @lines),
            'post backup hook received failed status and exit code 2'
        );
    };

    subtest 'pre-hook failure in abort mode halts replication and runs post hook' => sub {
        my ($log, $out) = $run_harness->(
            type     => 'local',
            pre      => $pre_hook,
            post     => $post_hook,
            uid      => 'uid_abort',
            mode     => 'abort',
            pre_exit => '3',
        );
        my @lines = grep { length } split /\n/, $log;
        ok(grep({ $_ eq 'pre_backup_ran' } @lines), 'pre backup hook ran');
        ok(!grep({ $_ eq 'syncoid_ran' } @lines), 'syncoid replication was skipped');
        ok(grep({ /marked_failed code=3/ } @lines), 'backup marked failed due to pre-hook');
        ok(
            grep({ /post_backup_ran status=failed exit=3 uid=uid_abort type=local/ } @lines),
            'post backup hook ran with failed status and exit code 3'
        );
    };

    subtest 'pre-hook failure in warn mode proceeds with replication' => sub {
        my ($log, $out) = $run_harness->(
            type     => 'local',
            pre      => $pre_hook,
            post     => $post_hook,
            uid      => 'uid_warn',
            mode     => 'warn',
            pre_exit => '3',
        );
        my @lines = grep { length } split /\n/, $log;
        ok(grep({ $_ eq 'pre_backup_ran' } @lines), 'pre backup hook ran');
        ok(grep({ $_ eq 'syncoid_ran' } @lines), 'syncoid replication proceeded in warn mode');
        ok(grep({ $_ eq 'marked_sent' } @lines), 'backup succeeded and marked sent');
        ok(
            grep({ /post_backup_ran status=success exit=0 uid=uid_warn type=local/ } @lines),
            'post backup hook received success context'
        );
    };

    subtest 'remote backup success exports remote task type' => sub {
        my ($log, $out) = $run_harness->(
            type => 'remote',
            pre  => $pre_hook,
            post => $post_hook,
            uid  => 'uid_remote_ok',
        );
        my @lines = grep { length } split /\n/, $log;
        ok(grep({ $_ eq 'pre_backup_ran' } @lines), 'pre backup hook ran');
        ok(grep({ $_ eq 'syncoid_ran' } @lines), 'syncoid replication ran');
        ok(
            grep({ /post_backup_ran status=success exit=0 uid=uid_remote_ok type=remote src=tank\/data dst=tank\/remote_backups/ } @lines),
            'post backup hook received remote context'
        );
    };

    subtest 'direct inline commands and environment variable expansion' => sub {
        my ($log, $out) = $run_harness->(
            type => 'local',
            pre  => 'echo inline_pre >> "$HOOK_EVENT_LOG" && echo inline_pre2 >> "$HOOK_EVENT_LOG"',
            post => 'echo "inline_post status=${BB_STATUS} exit=${BB_EXIT_CODE} uid=${BB_TASK_UID}" >> "$HOOK_EVENT_LOG"',
            uid  => 'uid_inline_cmd',
        );
        my @lines = grep { length } split /\n/, $log;
        ok(grep({ $_ eq 'inline_pre' } @lines), 'first chained inline pre command ran');
        ok(grep({ $_ eq 'inline_pre2' } @lines), 'second chained inline pre command ran');
        ok(grep({ $_ eq 'syncoid_ran' } @lines), 'syncoid replication ran');
        ok(
            grep({ /inline_post status=success exit=0 uid=uid_inline_cmd/ } @lines),
            'inline post command accessed exported environment variables'
        );
    };

    subtest 'hook script on boot storage runs without +x via shebang or bash' => sub {
        my $boot_dir = File::Spec->catdir($workdir, 'boot_hooks');
        make_path($boot_dir);

        # Script with shebang and mode 0600 (not executable, typical of Unraid FAT32)
        my $boot_shebang_hook = File::Spec->catfile($boot_dir, 'boot_shebang.sh');
        open my $bfh, '>', $boot_shebang_hook or die "Cannot write $boot_shebang_hook: $!";
        print $bfh "#!/bin/bash\necho boot_shebang_ran >> \"\$HOOK_EVENT_LOG\"\nexit 0\n";
        close $bfh;
        chmod 0600, $boot_shebang_hook;

        my ($log, $out) = $run_harness->(
            type        => 'local',
            pre         => $boot_shebang_hook,
            post        => $post_hook,
            uid         => 'uid_boot_shebang',
            boot_prefix => $boot_dir,
        );
        my @lines = grep { length } split /\n/, $log;
        ok(grep({ $_ eq 'boot_shebang_ran' } @lines), 'boot hook with shebang ran without +x');
        ok(grep({ $_ eq 'syncoid_ran' } @lines), 'syncoid replication ran');
        ok(grep({ /post_backup_ran status=success/ } @lines), 'post backup hook received success context');

        # Script without shebang and mode 0600
        my $boot_noshebang_hook = File::Spec->catfile($boot_dir, 'boot_noshebang.sh');
        open my $nbh, '>', $boot_noshebang_hook or die "Cannot write $boot_noshebang_hook: $!";
        print $nbh "echo boot_noshebang_ran >> \"\$HOOK_EVENT_LOG\"\nexit 0\n";
        close $nbh;
        chmod 0600, $boot_noshebang_hook;

        ($log, $out) = $run_harness->(
            type        => 'local',
            pre         => $boot_noshebang_hook,
            post        => $post_hook,
            uid         => 'uid_boot_noshebang',
            boot_prefix => $boot_dir,
        );
        @lines = grep { length } split /\n/, $log;
        ok(grep({ $_ eq 'boot_noshebang_ran' } @lines), 'boot hook without shebang ran without +x');
        ok(grep({ $_ eq 'syncoid_ran' } @lines), 'syncoid replication ran');
    };
};

done_testing();
