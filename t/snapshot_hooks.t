use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
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
my $rc_script    = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup');
my $rc_php       = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup.php');
my $snap_page_file = File::Spec->catfile($plugin_dir, 'SnapshotSettings.page');

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

my $rc   = slurp($rc_script);
my $php  = slurp($rc_php);
my $snap_page = slurp($snap_page_file);

# ---------------------------------------------------------------------------
# Static assertions on the bash implementation.
# ---------------------------------------------------------------------------
subtest 'rc.buddybackup defines a safe run_hook helper' => sub {
    like($rc, qr/^run_hook\s*\(\)/m, 'defines run_hook()');

    like(
        $rc,
        qr/timeout\s+"\$\{hook_timeout\}"\s+bash\s+-c\s+"\$\{(?:hook_cmd|exec_cmd)\}"/,
        'runs the hook with an explicit timeout via bash -c'
    );

    my ($run_hook_body) = $rc =~ /^run_hook\s*\(\)\s*\{(.*?)^\}/ms;
    ok(defined $run_hook_body, 'run_hook body is discoverable');
    unlike($run_hook_body // '', qr/\beval\b/, 'run_hook does not use eval');

    like(
        $rc,
        qr/\[\[ ! -x "\$\{(?:hook_cmd|hook_target)\}" \]\]/,
        'run_hook validates standalone scripts are executable'
    );
};

subtest 'rc.buddybackup orders the pre hook before zfs snapshot' => sub {
    like(
        $rc,
        qr/run_hook "\$\{pre_hook\}" "\$\{hook_timeout\}" "pre-snapshot"/,
        'pre-snapshot hook is invoked with the configured timeout'
    );

    my $pre_pos      = index($rc, 'run_hook "${pre_hook}" "${hook_timeout}" "pre-snapshot"');
    my $snapshot_pos = index($rc, 'if ! snapshot_output=$("${snapshot_cmd[@]}" 2>&1); then');
    ok($pre_pos >= 0, 'pre hook call site found');
    ok($snapshot_pos >= 0, 'snapshot invocation site found');
    ok(
        $pre_pos >= 0 && $snapshot_pos >= 0 && $pre_pos < $snapshot_pos,
        'pre hook appears before the snapshot command in the script'
    );
};

subtest 'rc.buddybackup guarantees post-snapshot thaw' => sub {
    like($rc, qr/run_snapshot_post_hook_once/, 'defines run_snapshot_post_hook_once');

    like(
        $rc,
        qr/trap 'run_snapshot_post_hook_once; cleanup' EXIT/,
        'registers the snapshot thaw hook on the EXIT trap during snapshotting'
    );

    like(
        $rc,
        qr/run_snapshot_post_hook_once\s*\n\s*trap cleanup EXIT/,
        'runs thaw immediately after zfs snapshot and restores cleanup trap before replication'
    );
};

subtest 'rc.buddybackup honors hook_failure_mode' => sub {
    like($rc, qr/hook_failure_mode/, 'reads hook_failure_mode');
    like(
        $rc,
        qr/\[\[ "\$\{hook_failure_mode\}" == "abort" \]\]/,
        'abort mode aborts the backup on a failing pre hook'
    );
    like(
        $rc,
        qr/Continuing because hook_failure_mode=warn/,
        'warn mode logs and continues'
    );
};

subtest 'rc.buddybackup dispatch forwards hook arguments' => sub {
    like(
        $rc,
        qr/\(\s*'create_snapshot_and_send'\s*\)\s*\n\s*create_snapshot_and_send .*"\$\{11:-\}" "\$\{12:-\}" "\$\{13:-30\}" "\$\{14:-abort\}"/,
        'case dispatch passes pre/post/timeout/mode positionally'
    );
};

# ---------------------------------------------------------------------------
# Static assertions on the PHP builder / validator.
# ---------------------------------------------------------------------------
subtest 'rc.buddybackup.php validates and forwards hook settings' => sub {
    like($php, qr/function validate_hook_script\s*\(/, 'defines validate_hook_script()');

    like($php, qr/is_executable\(\$resolved\)/, 'requires script files to be executable');
    like($php, qr/\$perms & 0022/, 'rejects group/world writable script files');
    like($php, qr/strpos\(\$path,\s*"\\0"\)/, 'guards against null characters');

    foreach my $key (qw(pre_snapshot_script post_snapshot_script hook_timeout hook_failure_mode)) {
        like($php, qr/\$section\['$key'\]|\$data\['$key'\]|\$cfg\['$key'\]/, "PHP reads $key");
    }
};

subtest 'SnapshotSettings.page exposes the snapshot hook fields' => sub {
    foreach my $name (qw(pre_snapshot_script post_snapshot_script hook_timeout hook_failure_mode)) {
        like($snap_page, qr/name="$name"/, "SnapshotSettings.page has a $name field");
    }

    like($snap_page, qr/Advanced:\s*snapshot hooks/, 'form has an advanced snapshot hooks section');
    like($snap_page, qr/<details\s+class="[^"]*buddybackup-hooks-section[^"]*"/, 'hooks section is wrapped in collapsible details element');
    like($snap_page, qr/<summary/, 'hooks section provides a summary element');
    unlike($snap_page, qr/<details\s+class="[^"]*buddybackup-hooks-section[^"]*"\s+open/, 'hooks section defaults to collapsed (no open attribute)');
    like($snap_page, qr/mk_option\(\$data\['hook_failure_mode'\] \?\? 'abort', "abort"/, 'failure mode defaults to abort');
    like($snap_page, qr/mk_option\(\$data\['hook_failure_mode'\] \?\? 'abort', "warn"/, 'failure mode offers warn');
};

# ---------------------------------------------------------------------------
# Behavioral test: exercise the function bodies with mocked zfs + hooks.
# ---------------------------------------------------------------------------
my $bash_available = 0;
{
    my $probe = `command -v bash 2>/dev/null`;
    $bash_available = 1 if defined $probe && $probe =~ /\S/;
}

SKIP: {
    skip 'bash is required to exercise hook ordering', 1 if !$bash_available;

    my $workdir   = tempdir(CLEANUP => 1);
    my $hooks_dir = File::Spec->catdir($workdir, 'hooks');
    my $bin_dir   = File::Spec->catdir($workdir, 'bin');
    make_path($hooks_dir, $bin_dir);

    my $log_file = File::Spec->catfile($workdir, 'order.log');

    my $pre_hook  = File::Spec->catfile($hooks_dir, 'pre.sh');
    my $post_hook = File::Spec->catfile($hooks_dir, 'post.sh');
    my $fail_hook = File::Spec->catfile($hooks_dir, 'fail.sh');

    write_hook($pre_hook, 'pre');
    write_hook($post_hook, 'post');
    write_hook($fail_hook, 'pre', 1);

    # Mock zfs so the snapshot step is observable and never touches the host.
    my $mock_zfs = File::Spec->catfile($bin_dir, 'zfs');
    write_script($mock_zfs, qq{#!/bin/bash
if [[ "\$SIMULATED_SNAP_FAIL" == "1" ]]; then
    echo "snapshot failed" >&2
    exit 1
fi
echo snapshot >> "\$SNAPSHOT_HOOK_TEST_LOG"
exit 0
});
    chmod 0755, $mock_zfs;

    # Source the functions from a copy of rc.buddybackup with the trailing
    # config-source + case dispatch stripped, so the dispatch never runs.
    my $functions_src = $rc;
    my $cut = index($functions_src, '# read our configuration.');
    $functions_src = substr($functions_src, 0, $cut) if $cut >= 0;
    my $functions_file = File::Spec->catfile($workdir, 'rc.functions.sh');
    write_script($functions_file, $functions_src);

    my $harness = File::Spec->catfile($workdir, 'harness.sh');
    my $harness_body = <<'SH';
#!/bin/bash
set -o pipefail

plugin="buddybackup"
export SNAPSHOT_HOOK_TEST_LOG
export PATH="$MOCK_BIN_DIR:$PATH"

source "$FUNCTIONS_FILE"

logger() { :; }
unraid_notify() { :; }
mark_failed_backup() { echo "failed:$3" >> "$SNAPSHOT_HOOK_TEST_LOG"; }
preflight_send_state() { PREFLIGHT_STATUS="ok"; PREFLIGHT_MESSAGE=""; }
manual_snapshot_name() { echo 'tank/data@manual-test'; }
mark_sent_backup() { :; }

send_local_backup() {
    echo replicate >> "$SNAPSHOT_HOOK_TEST_LOG"
    return "$SIMULATED_SEND_STATUS"
}
send_backup() {
    echo replicate >> "$SNAPSHOT_HOOK_TEST_LOG"
    return "$SIMULATED_SEND_STATUS"
}

create_snapshot_and_send local tank/data yes '' tank/backups testuid '' '' no "$PRE_HOOK" "$POST_HOOK" "$HOOK_TIMEOUT" "$HOOK_MODE"
SH
    write_script($harness, $harness_body);
    chmod 0755, $harness;

    sub _run_harness {
        my (%env) = @_;
        local $ENV{SNAPSHOT_HOOK_TEST_LOG} = $log_file;
        local $ENV{MOCK_BIN_DIR}          = $bin_dir;
        local $ENV{FUNCTIONS_FILE}        = $functions_file;
        local $ENV{PRE_HOOK}              = $env{pre} // '';
        local $ENV{POST_HOOK}             = $env{post} // '';
        local $ENV{HOOK_TIMEOUT}          = $env{timeout} // '30';
        local $ENV{HOOK_MODE}             = $env{mode} // 'abort';
        local $ENV{SIMULATED_SEND_STATUS} = $env{send_status} // '0';
        local $ENV{SIMULATED_SNAP_FAIL}   = $env{snap_fail} // '0';
        unlink $log_file if -e $log_file;
        my $out = `bash "$harness" 2>&1`;
        my $log = -e $log_file ? slurp($log_file) : '';
        return ($log, $out);
    }

    subtest 'behavioral: pre -> snapshot -> post -> replicate on success' => sub {
        my ($log, $out) = _run_harness( pre => $pre_hook, post => $post_hook, mode => 'abort', send_status => '0' );
        my @lines = grep { length } split /\n/, $log;
        is_deeply( \@lines, [qw(pre snapshot post replicate)], 'execution order is pre, snapshot, post, replicate (immediate thaw)' );
    };

    subtest 'behavioral: post hook still runs when snapshot creation fails' => sub {
        my ($log, $out) = _run_harness( pre => $pre_hook, post => $post_hook, mode => 'abort', snap_fail => '1' );
        my @lines = grep { length } split /\n/, $log;
        ok(grep({ $_ eq 'pre' } @lines), 'pre hook ran');
        ok(grep({ $_ eq 'post' } @lines), 'post thaw hook ran immediately despite snapshot failure');
        ok(!grep({ $_ eq 'replicate' } @lines), 'replication was skipped due to snapshot failure');
        ok(scalar(grep { /^failed:/ } @lines), 'snapshot failure was recorded');
    };

    subtest 'behavioral: abort mode skips snapshot when pre hook fails' => sub {
        my ($log, $out) = _run_harness( pre => $fail_hook, post => $post_hook, mode => 'abort', send_status => '0' );
        my @lines = grep { length } split /\n/, $log;
        ok(!grep({ $_ eq 'snapshot' } @lines),   'no snapshot is taken when the pre hook fails in abort mode');
        ok(!grep({ $_ eq 'replicate' } @lines),  'replication is skipped when the pre hook fails in abort mode');
        ok(grep({ $_ eq 'post' } @lines),        'post thaw hook still ran to thaw workloads when pre hook aborted');
        ok(scalar(grep { /^failed:/ } @lines),    'the pre hook failure is recorded as a failed backup');
    };

    subtest 'behavioral: warn mode continues past a failing pre hook' => sub {
        my ($log, $out) = _run_harness( pre => $fail_hook, post => $post_hook, mode => 'warn', send_status => '0' );
        my @lines = grep { length } split /\n/, $log;
        is_deeply( \@lines, [qw(pre snapshot post replicate)], 'warn mode proceeds with snapshot, post thaw, and replication' );
    };

    subtest 'behavioral: direct command and chained commands run as hooks' => sub {
        my $cmd_pre = 'echo cmd_pre >> "$SNAPSHOT_HOOK_TEST_LOG" && echo cmd_pre2 >> "$SNAPSHOT_HOOK_TEST_LOG"';
        my $cmd_post = 'echo cmd_post >> "$SNAPSHOT_HOOK_TEST_LOG"';
        my ($log, $out) = _run_harness( pre => $cmd_pre, post => $cmd_post, mode => 'abort', send_status => '0' );
        my @lines = grep { length } split /\n/, $log;
        is_deeply( \@lines, [qw(cmd_pre cmd_pre2 snapshot cmd_post replicate)], 'chained pre command and direct post command ran in order' );
    };

    subtest 'behavioral: single-quoted and double-quoted hook scripts execute cleanly' => sub {
        my $quoted_pre_single = "'$pre_hook'";
        my $quoted_post_double = "\"$post_hook\"";
        my ($log, $out) = _run_harness( pre => $quoted_pre_single, post => $quoted_post_double, mode => 'abort', send_status => '0' );
        my @lines = grep { length } split /\n/, $log;
        is_deeply( \@lines, [qw(pre snapshot post replicate)], 'quoted pre and post hook paths are unquoted and executed' );
    };
};

sub write_hook {
    my ($path, $tag, $fail) = @_;
    my $exit = $fail ? 1 : 0;
    my $body = qq{#!/bin/bash\necho $tag >> "\$SNAPSHOT_HOOK_TEST_LOG"\nexit $exit\n};
    write_script($path, $body);
    chmod 0755, $path;
}

sub write_script {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print $fh $content;
    close $fh;
}

done_testing();