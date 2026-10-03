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
my $backups_page = File::Spec->catfile($plugin_dir, 'Backups.page');

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
# Static assertions on the bash implementation.
# ---------------------------------------------------------------------------
subtest 'rc.buddybackup defines a safe run_hook helper' => sub {
    like($rc, qr/^run_hook\s*\(\)/m, 'defines run_hook()');

    like(
        $rc,
        qr/timeout\s+"\$\{hook_timeout\}"\s+"\$\{hook_path\}"/,
        'runs the hook with an explicit timeout + argv (no eval)'
    );

    my ($run_hook_body) = $rc =~ /^run_hook\s*\(\)\s*\{(.*?)^\}/ms;
    ok(defined $run_hook_body, 'run_hook body is discoverable');
    unlike($run_hook_body // '', qr/\beval\b/, 'run_hook does not use eval');

    like(
        $rc,
        qr/\[\[ ! -x "\$\{hook_path\}" \]\]/,
        'run_hook validates the hook is executable'
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

subtest 'rc.buddybackup registers a one-shot post hook trap' => sub {
    like($rc, qr/^run_post_hook_once\s*\(\)/m, 'defines run_post_hook_once()');

    like($rc, qr/POST_HOOK_DONE/, 'post hook uses a guard so it only runs once');

    like(
        $rc,
        qr/trap 'run_post_hook_once; cleanup' EXIT/,
        'registers the post hook on the EXIT trap (preserving cleanup)'
    );

    my ($post_body) = $rc =~ /^run_post_hook_once\s*\(\)\s*\{(.*?)^\}/ms;
    ok(defined $post_body, 'run_post_hook_once body is discoverable');
    like($post_body // '', qr/\[\[ -n "\$\{POST_HOOK_DONE:-\}" \]\]/, 'guards against repeat execution');

    like(
        $rc,
        qr/run_hook "\$\{POST_HOOK_SCRIPT\}" "\$\{POST_HOOK_TIMEOUT:-30\}" "post-snapshot"/,
        'post hook invokes run_hook with the stored timeout'
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

    like($php, qr/is_executable\(\$resolved\)/, 'requires the hook to be executable');
    like($php, qr/\$perms & 0022/, 'rejects group/world writable hooks');
    like($php, qr/substr\(\$path, 0, 1\) !== '\/'/, 'requires an absolute path');

    foreach my $key (qw(pre_snapshot_script post_snapshot_script hook_timeout hook_failure_mode)) {
        like($php, qr/\$cfg\['$key'\]/, "PHP builder reads $key");
    }
};

subtest 'Backups.page exposes the snapshot hook fields' => sub {
    foreach my $name (qw(pre_snapshot_script post_snapshot_script hook_timeout hook_failure_mode)) {
        like($page, qr/name="$name"/, "Backups.page has a $name field");
    }

    like($page, qr/Advanced: snapshot hooks/, 'form has an advanced hooks section');
    like($page, qr/<details\s+class="[^"]*buddybackup-hooks-section[^"]*"/, 'hooks section is wrapped in collapsible details element');
    like($page, qr/<summary/, 'hooks section provides a summary element');
    unlike($page, qr/<details\s+class="[^"]*buddybackup-hooks-section[^"]*"\s+open/, 'hooks section defaults to collapsed (no open attribute)');
    like($page, qr/mk_option\(\$data\['hook_failure_mode'\] \?\? 'abort', "abort"/, 'failure mode defaults to abort');
    like($page, qr/mk_option\(\$data\['hook_failure_mode'\] \?\? 'abort', "warn"/, 'failure mode offers warn');
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
    write_script($mock_zfs, qq{#!/bin/bash\necho snapshot >> "\$SNAPSHOT_HOOK_TEST_LOG"\nexit 0\n});
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

# Simulate replication without calling exit so the EXIT trap still drives the
# post hook; the send status is controlled by $SIMULATED_SEND_STATUS.
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
        unlink $log_file if -e $log_file;
        my $out = `bash "$harness" 2>&1`;
        my $log = -e $log_file ? slurp($log_file) : '';
        return ($log, $out);
    }

    subtest 'behavioral: pre -> snapshot -> replicate -> post on success' => sub {
        my ($log, $out) = _run_harness( pre => $pre_hook, post => $post_hook, mode => 'abort', send_status => '0' );
        my @lines = grep { length } split /\n/, $log;
        is_deeply( \@lines, [qw(pre snapshot replicate post)], 'execution order is pre, snapshot, replicate, post' );
    };

    subtest 'behavioral: post hook still runs when replication fails' => sub {
        my ($log, $out) = _run_harness( pre => $pre_hook, post => $post_hook, mode => 'abort', send_status => '1' );
        my @lines = grep { length } split /\n/, $log;
        is_deeply( \@lines, [qw(pre snapshot replicate post)], 'post hook runs after a failed replication' );
    };

    subtest 'behavioral: abort mode skips snapshot when pre hook fails' => sub {
        my ($log, $out) = _run_harness( pre => $fail_hook, post => $post_hook, mode => 'abort', send_status => '0' );
        my @lines = grep { length } split /\n/, $log;
        ok(!grep({ $_ eq 'snapshot' } @lines),   'no snapshot is taken when the pre hook fails in abort mode');
        ok(!grep({ $_ eq 'replicate' } @lines),  'replication is skipped when the pre hook fails in abort mode');
        ok(scalar(grep { /^failed:/ } @lines),    'the pre hook failure is recorded as a failed backup');
    };

    subtest 'behavioral: warn mode continues past a failing pre hook' => sub {
        my ($log, $out) = _run_harness( pre => $fail_hook, post => $post_hook, mode => 'warn', send_status => '0' );
        my @lines = grep { length } split /\n/, $log;
        is_deeply( \@lines, [qw(pre snapshot replicate post)], 'warn mode proceeds with snapshot and replication' );
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