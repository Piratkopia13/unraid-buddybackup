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

my $plugin_dir = File::Spec->catdir($repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup');
my $rc_script = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup');
my $rc_php = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup.php');

ok(-f $rc_script, 'rc.buddybackup exists');
ok(-f $rc_php, 'rc.buddybackup.php exists');

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

sub write_script {
    my ($path, $body) = @_;
    open my $fh, '>:raw', $path or die "Cannot write $path: $!";
    print $fh $body;
    close $fh;
    chmod 0755, $path;
}

sub extract_bash_function {
    my ($text, $func_name) = @_;
    if ($text =~ /(^$func_name\(\)\s*\{.*?\n\})/ms) {
        return $1;
    }
    die "Could not extract bash function $func_name";
}

sub extract_php_function {
    my ($text, $func_name) = @_;
    if ($text =~ /(^function\s+$func_name\([^)]*\)\s*\{.*?\n\})/ms) {
        return $1;
    }
    die "Could not extract PHP function $func_name";
}

my $rc_sh_content = slurp($rc_script);
my $rc_php_content = slurp($rc_php);

my $php_scan_code = extract_php_function($rc_php_content, 'scan_remote_known_hosts');
my $bash_ensure_code = extract_bash_function($rc_sh_content, 'ensure_managed_known_hosts_file');
my $bash_remove_code = extract_bash_function($rc_sh_content, 'remove_managed_known_host');
my $bash_append_code = extract_bash_function($rc_sh_content, 'append_managed_known_host');

# Fixture key lines. Order below is the expected LC_ALL=C/C sort order.
my $banner = "# peer.example:22 SSH-2.0-OpenSSH_10.2\n";
my $rsa_line = 'peer.example ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC-test-rsa';
my $ed25519_line = 'peer.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN-test-ed25519';
my $ecdsa_line = 'peer.example ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY-test-ecdsa';
my @sorted_key_lines = ($ecdsa_line, $ed25519_line, $rsa_line);
my $complete_scan = $banner . $rsa_line . "\n" . $ed25519_line . "\n" . $ecdsa_line . "\n";

sub run_command_capture {
    my (@command) = @_;
    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = eval { open3(undef, $stdout, $stderr, @command) };
    if (!$pid) {
        return (255, '', "failed to start command: $@");
    }
    my $out = do { local $/; <$stdout> // '' };
    my $err = do { local $/; <$stderr> // '' };
    waitpid($pid, 0);
    return ($? >> 8, $out, $err);
}

sub detect_php {
    my ($exit_code, $out) = run_command_capture('php', '-r', 'echo PHP_OS_FAMILY;');
    return (0, '') if $exit_code != 0;
    $out =~ s/\s+//g;
    return (1, $out eq 'Windows' ? 'Windows' : 'POSIX');
}

sub write_ssh_keyscan_mock {
    my ($bin_dir) = @_;
    my $path = File::Spec->catfile($bin_dir, 'ssh-keyscan');
    write_script($path, <<'SH');
#!/bin/bash
count=0
if [[ -f "$MOCK_COUNT" ]]; then
    count=$(cat "$MOCK_COUNT")
fi
count=$((count + 1))
echo "$count" > "$MOCK_COUNT"
printf 'call %s:' "$count" >> "$MOCK_SCAN_LOG"
printf ' %s' "$@" >> "$MOCK_SCAN_LOG"
printf '\n' >> "$MOCK_SCAN_LOG"

scenario_dir="$MOCK_DIR/$MOCK_SCENARIO"
file="$scenario_dir/scan-$count.txt"
if [[ ! -f "$file" ]]; then
    file=$(ls "$scenario_dir"/scan-*.txt 2>/dev/null | sort -V | tail -n 1)
fi
if [[ -n "$file" && -f "$file" ]]; then
    cat "$file"
fi
exit 0
SH
    return $path;
}

sub write_ssh_keygen_mock {
    my ($bin_dir) = @_;
    my $path = File::Spec->catfile($bin_dir, 'ssh-keygen');
    write_script($path, <<'SH');
#!/bin/bash
printf 'ssh-keygen' >> "$MOCK_KEYGEN_LOG"
printf ' %s' "$@" >> "$MOCK_KEYGEN_LOG"
printf '\n' >> "$MOCK_KEYGEN_LOG"
exit 0
SH
    return $path;
}

sub write_scan_scenario {
    my ($mock_dir, $name, $scans) = @_;
    my $dir = File::Spec->catdir($mock_dir, $name);
    make_path($dir);
    my $index = 0;
    for my $scan (@$scans) {
        $index++;
        my $path = File::Spec->catfile($dir, "scan-$index.txt");
        open my $fh, '>:raw', $path or die "Cannot write $path: $!";
        print $fh $scan;
        close $fh;
    }
    return $dir;
}

sub reset_scenario_state {
    my ($count_file, $scan_log, $keygen_log, $mock_dir, $scenario) = @_;
    for my $file ($count_file, $scan_log, $keygen_log) {
        open my $fh, '>:raw', $file or die "Cannot initialize $file: $!";
        close $fh;
    }
    $ENV{MOCK_COUNT} = $count_file;
    $ENV{MOCK_SCAN_LOG} = $scan_log;
    $ENV{MOCK_KEYGEN_LOG} = $keygen_log;
    $ENV{MOCK_DIR} = $mock_dir;
    $ENV{MOCK_SCENARIO} = $scenario;
}

sub call_count {
    my ($count_file) = @_;
    return 0 if !-f $count_file;
    my $value = slurp($count_file);
    return 0 if $value !~ /\d/;
    return $value + 0;
}

sub write_php_runner {
    my ($path) = @_;
    my $php = "<?php\nerror_reporting(E_ALL & ~E_NOTICE);\n"
        . $php_scan_code . "\n"
        . '$result = scan_remote_known_hosts($argv[1], $argv[2]);' . "\n"
        . 'if ($result === null) {' . "\n"
        . '    echo "NULL\n";' . "\n"
        . '} else {' . "\n"
        . '    echo $result . "\n";' . "\n"
        . '}' . "\n";
    write_script($path, $php);
    return $path;
}

sub write_bash_runner {
    my ($path) = @_;
    my $template = <<'SH';
#!/bin/bash
set -u

export PATH="$MOCK_BIN:$PATH"

plugin_path="$WORKDIR/plugin"
ssh_known_hosts_path="$plugin_path/buddybackup_known_hosts"
legacy_root_known_hosts_path="$WORKDIR/legacy_known_hosts"
mkdir -p "$plugin_path"
touch "$ssh_known_hosts_path"

__ENSURE_CODE__

__REMOVE_CODE__

__APPEND_CODE__

TEST_HOST="${TEST_HOST:-peer.example}"
TEST_PORT="${TEST_PORT:-22}"

: > "$ssh_known_hosts_path"

if append_managed_known_host "$TEST_HOST" "$TEST_PORT"; then
    echo "append=ok"
else
    echo "append=failed"
fi

cat "$ssh_known_hosts_path"
SH
    $template =~ s/__ENSURE_CODE__/$bash_ensure_code/;
    $template =~ s/__REMOVE_CODE__/$bash_remove_code/;
    $template =~ s/__APPEND_CODE__/$bash_append_code/;
    write_script($path, $template);
    return $path;
}

subtest 'static analysis: known_hosts scans merge partial results' => sub {
    like($rc_php_content, qr/\$scanned_keys = scan_remote_known_hosts\(\$entry\['host'\], \$entry\['port'\]\);/,
        'PHP update persists merged scan output via the resilient helper');
    unlike($rc_php_content, qr/\$command = 'ssh-keyscan';/,
        'PHP update no longer builds a bare single-shot ssh-keyscan command');
    like($php_scan_code, qr/for \(\$attempt = 0; \$attempt < \d+; \$attempt\+\+\)/,
        'PHP helper bounds the number of scan attempts');
    like($php_scan_code, qr/\$standard_types = \['ssh-ed25519', 'ecdsa-sha2-nistp256', 'ssh-rsa'\]/,
        'PHP helper defines the common host key types');
    like($php_scan_code, qr/\$standard_types_found >= count\(\$standard_types\)/,
        'PHP helper keeps scanning until every common host key type was seen');
    like($php_scan_code, qr/\$empty_scans >= 2/,
        'PHP helper stops retrying once the peer is consistently unreachable');
    like($php_scan_code, qr/str_starts_with\(\$line, '#'\)/,
        'PHP helper ignores ssh-keyscan banner comments');
    like($php_scan_code, qr/sort\(\$keys, SORT_STRING\)/,
        'PHP helper sorts key lines for stable output');

    like($bash_append_code, qr/for attempt in [\d\s]+; do/,
        'bash append bounds the number of scan attempts');
    like($bash_append_code, qr/ssh-keyscan -T \d+/,
        'bash append sets a scan timeout');
    like($bash_append_code, qr/grep -q 'ssh-ed25519' &&[\s\S]*grep -q 'ecdsa-sha2-nistp256' &&[\s\S]*grep -q 'ssh-rsa'/,
        'bash append keeps scanning until every common host key type was seen');
    like($bash_append_code, qr/empty_scans/,
        'bash append stops retrying once the peer is consistently unreachable');
    like($bash_append_code, qr/LC_ALL=C sort/,
        'bash append sorts key lines for stable output');
};

subtest 'behavioral: PHP helper merges partial ssh-keyscan results' => sub {
    my ($php_found, $php_family) = detect_php();
    plan skip_all => 'php CLI is required for the PHP behavioral test' if !$php_found;
    plan skip_all => 'PHP behavioral test requires a POSIX shell for the ssh-keyscan mock' if $php_family eq 'Windows';

    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);
    write_ssh_keyscan_mock($bin_dir);
    my $mock_dir = File::Spec->catdir($workdir, 'mock');
    make_path($mock_dir);
    my $runner = write_php_runner(File::Spec->catfile($workdir, 'run_scan.php'));
    my $count_file = File::Spec->catfile($workdir, 'count');
    my $scan_log = File::Spec->catfile($workdir, 'scan.log');
    my $keygen_log = File::Spec->catfile($workdir, 'keygen.log');

    my $saved_path = $ENV{PATH};
    $ENV{PATH} = $bin_dir . ':' . ($saved_path // '');

    write_scan_scenario($mock_dir, 'php-partial', [
        $banner . $rsa_line . "\n",
        $banner . $rsa_line . "\n" . $ed25519_line . "\n",
        $banner . $rsa_line . "\n" . $ed25519_line . "\n" . $ecdsa_line . "\n",
        $complete_scan,
    ]);
    reset_scenario_state($count_file, $scan_log, $keygen_log, $mock_dir, 'php-partial');
    my ($exit_code, $out, $err) = run_command_capture('php', $runner, 'peer.example', '22');
    is($exit_code, 0, "PHP scan helper exits cleanly (stderr: $err)");
    is_deeply([grep { /\S/ } split /\r?\n/, $out], [@sorted_key_lines],
        'successive partial scans are merged into the complete key set');
    is(call_count($count_file), 3, 'scan loop runs until every common key type was seen');
    like(slurp($scan_log), qr/^call 1: -T 5 peer\.example$/m,
        'scan uses a timeout and omits -p for the default port');

    write_scan_scenario($mock_dir, 'php-stable', [$complete_scan, $complete_scan]);
    reset_scenario_state($count_file, $scan_log, $keygen_log, $mock_dir, 'php-stable');
    ($exit_code, $out, $err) = run_command_capture('php', $runner, 'peer.example', '22');
    is($exit_code, 0, "PHP scan helper exits cleanly for stable scans (stderr: $err)");
    is_deeply([grep { /\S/ } split /\r?\n/, $out], [@sorted_key_lines],
        'stable scans return the complete key set');
    is(call_count($count_file), 1, 'a complete first scan stops immediately');

    write_scan_scenario($mock_dir, 'php-dedup', [$complete_scan . $rsa_line . "\n", $complete_scan]);
    reset_scenario_state($count_file, $scan_log, $keygen_log, $mock_dir, 'php-dedup');
    ($exit_code, $out, $err) = run_command_capture('php', $runner, 'peer.example', '22');
    is($exit_code, 0, "PHP scan helper exits cleanly for duplicate keys (stderr: $err)");
    is_deeply([grep { /\S/ } split /\r?\n/, $out], [@sorted_key_lines],
        'duplicate key material is deduplicated');

    write_scan_scenario($mock_dir, 'php-empty', ['', '', '', '']);
    reset_scenario_state($count_file, $scan_log, $keygen_log, $mock_dir, 'php-empty');
    ($exit_code, $out, $err) = run_command_capture('php', $runner, 'peer.example', '22');
    is($exit_code, 0, "PHP scan helper exits cleanly when scans fail (stderr: $err)");
    is($out, "NULL\n", 'empty scans report no keys instead of persisting garbage');
    is(call_count($count_file), 2, 'consistently unreachable peers stop after two scans');

    write_scan_scenario($mock_dir, 'php-port', [$complete_scan, $complete_scan]);
    reset_scenario_state($count_file, $scan_log, $keygen_log, $mock_dir, 'php-port');
    ($exit_code, $out, $err) = run_command_capture('php', $runner, 'peer.example', '2222');
    is($exit_code, 0, "PHP scan helper exits cleanly for a custom port (stderr: $err)");
    like(slurp($scan_log), qr/^call 1: -T 5 -p 2222 peer\.example$/m,
        'non-default ports are passed to ssh-keyscan');

    $ENV{PATH} = $saved_path;
};

subtest 'behavioral: bash append merges partial ssh-keyscan results' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);
    write_ssh_keyscan_mock($bin_dir);
    write_ssh_keygen_mock($bin_dir);
    my $mock_dir = File::Spec->catdir($workdir, 'mock');
    make_path($mock_dir);
    my $runner = write_bash_runner(File::Spec->catfile($workdir, 'run_append.sh'));
    my $known_hosts_path = File::Spec->catfile($workdir, 'plugin', 'buddybackup_known_hosts');
    my $count_file = File::Spec->catfile($workdir, 'count');
    my $scan_log = File::Spec->catfile($workdir, 'scan.log');
    my $keygen_log = File::Spec->catfile($workdir, 'keygen.log');

    $ENV{MOCK_BIN} = $bin_dir;
    $ENV{WORKDIR} = $workdir;

    write_scan_scenario($mock_dir, 'bash-partial', [
        $banner . $rsa_line . "\n",
        $banner . $rsa_line . "\n" . $ed25519_line . "\n",
        $banner . $rsa_line . "\n" . $ed25519_line . "\n" . $ecdsa_line . "\n",
        $complete_scan,
    ]);
    reset_scenario_state($count_file, $scan_log, $keygen_log, $mock_dir, 'bash-partial');
    my ($exit_code, $out, $err) = run_command_capture('bash', $runner);
    is($exit_code, 0, "bash append exits cleanly (stderr: $err)");
    like($out, qr/^append=ok$/m, 'bash append reports success after merging partial scans');
    is_deeply([grep { /\S/ } split /\r?\n/, slurp($known_hosts_path)], [@sorted_key_lines],
        'bash append persists the merged complete key set in sorted order');
    is(call_count($count_file), 3, 'bash scan loop runs until every common key type was seen');
    like(slurp($keygen_log), qr/^ssh-keygen -R peer\.example -f /m,
        'bash append removes stale host entries before rescanning');

    write_scan_scenario($mock_dir, 'bash-partial-repeat', [
        $banner . $rsa_line . "\n",
        $banner . $rsa_line . "\n",
        $banner . $rsa_line . "\n",
    ]);
    reset_scenario_state($count_file, $scan_log, $keygen_log, $mock_dir, 'bash-partial-repeat');
    ($exit_code, $out, $err) = run_command_capture('bash', $runner);
    is($exit_code, 0, "bash append exits cleanly for repeated partial scans (stderr: $err)");
    like($out, qr/^append=ok$/m, 'bash append still persists the keys it has');
    is_deeply([grep { /\S/ } split /\r?\n/, slurp($known_hosts_path)], [$rsa_line],
        'repeated partial scans keep the keys they found');
    is(call_count($count_file), 5, 'bash scan loop always uses its attempt budget for partial scans');

    write_scan_scenario($mock_dir, 'bash-empty', ['', '', '', '']);
    reset_scenario_state($count_file, $scan_log, $keygen_log, $mock_dir, 'bash-empty');
    ($exit_code, $out, $err) = run_command_capture('bash', $runner);
    is($exit_code, 0, "bash append exits cleanly when scans fail (stderr: $err)");
    like($out, qr/^append=failed$/m, 'bash append reports failure when no keys were found');
    is(slurp($known_hosts_path), '', 'bash append does not persist an empty scan result');
    is(call_count($count_file), 2, 'bash scan loop stops retrying once the peer is unreachable');
};

done_testing();
