use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Spec;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
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

my $git_available = 0;
{
    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = open3(undef, $stdout, $stderr, 'git', '-C', $repo_root, 'rev-parse', '--is-inside-work-tree');
    my $output = do { local $/; <$stdout> // '' };
    waitpid($pid, 0);
    $git_available = 1 if $? == 0 && $output =~ /true/;
}

plan skip_all => 'git history required to extract previous release allowlists' if !$git_available;

my $allowlist_relpath = 'src/usr/local/emhttp/plugins/buddybackup/deps/restrict_zfs';

sub extract_allowlist {
    my ($tag, $workdir) = @_;

    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = open3(undef, $stdout, $stderr, 'git', '-C', $repo_root, 'show', "$tag:$allowlist_relpath");
    my $content = do { local $/; <$stdout> // '' };
    waitpid($pid, 0);
    return undef if $? != 0;

    my $path = File::Spec->catfile($workdir, "restrict_zfs_$tag");
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print $fh $content;
    close $fh;
    return $path;
}

sub run_restrict {
    my ($script, $command) = @_;

    local %ENV = %ENV;
    $ENV{SSH_ORIGINAL_COMMAND} = $command;

    my $stderr = gensym;
    my $pid = open3(undef, my $stdout, $stderr, $^X, $script, '--dry-run', '--log=stderr');
    my $stdout_text = do { local $/; <$stdout> // '' };
    my $stderr_text = do { local $/; <$stderr> // '' };
    waitpid($pid, 0);

    return {
        exit_code => $? >> 8,
        stderr => $stderr_text,
    };
}

my $dataset = q{'disk11/backups/tim'};
my $snap1 = q{'disk11/backups/tim@autosnap_2026-04-27:01:30:48-GMT01:00_daily'};
my $snap2 = q{'disk11/backups/tim@autosnap_2026-04-23_06:15:01_daily'};
my $spaced_dataset = q{'disk11/backups/tim/cache_domains/Windows 11'};

sub receiver_command_inventory {
    my ($with_spaced_datasets) = @_;

    my @commands = (
        'echo ok',
        'echo -n',
        'exit',
        'command -v zstdmt',
        'command -v mbuffer',
        q{zpool get -o value -H feature@extensible_dataset 'disk11'},
        'ps -Ao args=',
        qq{zfs get -H name $dataset},
        qq{zfs get -H receive_resume_token $dataset},
        qq{zfs get -H -o value used $dataset},
        qq{zfs get -H -p used $dataset},
        qq{zfs get -H syncoid:sync $dataset},
        qq{zfs get -Hpd 1 -t snapshot guid,creation $dataset 2>/dev/null},
        qq{zfs get -Hpd 1 type,guid,creation $dataset},
        qq{zfs list -o name,origin -t filesystem,volume -Hr $dataset},
        qq{mbuffer  -q -s 128k -m 16M | zstdmt -dc | zfs receive -F $dataset 2>&1},
        qq{zfs receive -A $dataset},
        qq{zfs send -w -nvP $snap1},
        qq{zfs send -w -nvP -I $snap1 $snap2},
        qq{zfs send -w $snap1 | zstdmt -3 | mbuffer  -q -s 128k -m 16M},
        qq{zfs send -w -i $snap1 $snap2 | zstdmt -3 | mbuffer  -q -s 128k -m 16M},
        '/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php mark_received_backup',
    );

    if ($with_spaced_datasets) {
        push @commands,
            qq{zfs get -j used $spaced_dataset},
            qq{zfs get -j -p -d 1 -t snapshot guid,creation $spaced_dataset},
            qq{zfs list -r -j -o name,origin -t filesystem,volume $spaced_dataset},
            '/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs';
    }

    return @commands;
}

sub assert_inventory_allowed {
    my ($label, $script, @commands) = @_;

    for my $command (@commands) {
        my $result = run_restrict($script, $command);
        like(
            $result->{stderr},
            qr/^\Qwould run command: $command\E\r?\n?$/,
            "$label accepts: $command",
        ) or diag($result->{stderr});
    }
}

subtest 'current receiver command surface accepted by previously released allowlists' => sub {
    my $workdir = tempdir(CLEANUP => 1);

    my $blocked_cmd = qq{/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php mark_received_backup $dataset};

    my $older_release_script = extract_allowlist('2025.09.13', $workdir);
    if (!defined $older_release_script) {
        plan skip_all => 'tag 2025.09.13 not available in this checkout';
        return;
    }
    assert_inventory_allowed(
        '2025.09.13 buddy',
        $older_release_script,
        receiver_command_inventory(0),
    );

    # Verify that older release strictly rejects the parameterized mark_received_backup command,
    # ensuring we test why the unparameterized fallback is required.
    my $blocked_res = run_restrict($older_release_script, $blocked_cmd);
    like(
        $blocked_res->{stderr},
        qr/^\Qblocked command: $blocked_cmd\E\r?\n?$/,
        '2025.09.13 buddy blocks parameterized mark_received_backup (necessitating fallback)',
    );

    my $previous_release_script = extract_allowlist('2026.05.29', $workdir);
    if (!defined $previous_release_script) {
        plan skip_all => 'tag 2026.05.29 not available in this checkout';
        return;
    }
    assert_inventory_allowed(
        '2026.05.29 buddy',
        $previous_release_script,
        receiver_command_inventory(1),
    );

    my $blocked_prev_res = run_restrict($previous_release_script, $blocked_cmd);
    like(
        $blocked_prev_res->{stderr},
        qr/^\Qblocked command: $blocked_cmd\E\r?\n?$/,
        '2026.05.29 buddy blocks parameterized mark_received_backup (necessitating fallback)',
    );

    my $blocked_probe_cmd = qq{/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs $dataset};
    my $blocked_probe_res = run_restrict($previous_release_script, $blocked_probe_cmd);
    like(
        $blocked_probe_res->{stderr},
        qr/^\Qblocked command: $blocked_probe_cmd\E\r?\n?$/,
        '2026.05.29 buddy blocks parameterized probe_zfs (necessitating fallback)',
    );
};

subtest 'older releases still send commands the current allowlist accepts' => sub {
    my $current_script = File::Spec->catfile(
        $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', 'restrict_zfs'
    );

    assert_inventory_allowed(
        'current buddy',
        $current_script,
        receiver_command_inventory(0),
        qq{/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php mark_received_backup $dataset},
        qq{/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs $dataset},
    );
};

subtest 'send_mark_received_backup fallback logic' => sub {
    my $rc_path = File::Spec->catfile(
        $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'scripts', 'rc.buddybackup'
    );
    ok(-f $rc_path, 'rc.buddybackup exists');

    open my $rc_fh, '<', $rc_path or die "Cannot open $rc_path: $!";
    my $rc_content = do { local $/; <$rc_fh> };
    close $rc_fh;

    my ($fn_code) = $rc_content =~ m{(send_mark_received_backup\(\)\s*\{.*?\n\})}s;
    ok(defined $fn_code, 'send_mark_received_backup function extracted from rc.buddybackup');

    my $bash_test = <<'BASH_PRE';
set -e
calls_file=$(mktemp)
trap 'rm -f "$calls_file"' EXIT

fail_param=0
fail_base=0

shell_single_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

run_remote_ssh() {
    local host="$1"
    local cmd="$2"
    echo "$cmd" >> "$calls_file"
    if [[ "$cmd" == *" mark_received_backup '"* ]]; then
        if [[ $fail_param -eq 1 ]]; then
            return 1
        fi
    elif [[ "$cmd" == *" mark_received_backup" ]]; then
        if [[ $fail_base -eq 1 ]]; then
            return 1
        fi
    fi
    return 0
}

write() {
    echo "WRITE: $2"
}
BASH_PRE

    $bash_test .= "\n" . $fn_code . "\n";
    $bash_test .= <<'BASH_POST';

# Test 1: Modern receiver (parameterized succeeds on first try)
: > "$calls_file"
fail_param=0
fail_base=0
send_mark_received_backup "buddy.example" "tank/backup/dest" "buddyuser" "22"
readarray -t calls < "$calls_file"
[[ ${#calls[@]} -eq 1 ]] || { echo "Test 1 failed: expected 1 call, got ${#calls[@]}"; exit 1; }
[[ "${calls[0]}" == *"/rc.buddybackup.php mark_received_backup 'tank/backup/dest'" ]] || { echo "Test 1 cmd mismatch: ${calls[0]}"; exit 1; }

# Test 2: Legacy receiver (parameterized rejected, fallback without dataset succeeds)
: > "$calls_file"
fail_param=1
fail_base=0
out=$(send_mark_received_backup "buddy.example" "tank/backup/dest" "buddyuser" "22")
readarray -t calls < "$calls_file"
[[ ${#calls[@]} -eq 2 ]] || { echo "Test 2 failed: expected 2 calls, got ${#calls[@]}"; exit 2; }
[[ "${calls[0]}" == *"/rc.buddybackup.php mark_received_backup 'tank/backup/dest'" ]] || { echo "Test 2 call 0 mismatch: ${calls[0]}"; exit 2; }
[[ "${calls[1]}" == *"/rc.buddybackup.php mark_received_backup" ]] || { echo "Test 2 call 1 mismatch: ${calls[1]}"; exit 2; }
[[ -z "$out" ]] || { echo "Test 2 unexpected error output: $out"; exit 2; }

# Test 3: Total connection failure (both calls fail -> writes failure message)
: > "$calls_file"
fail_param=1
fail_base=1
out=$(send_mark_received_backup "buddy.example" "tank/backup/dest" "buddyuser" "22")
readarray -t calls < "$calls_file"
[[ ${#calls[@]} -eq 2 ]] || { echo "Test 3 failed: expected 2 calls, got ${#calls[@]}"; exit 3; }
[[ "$out" == *"Failed to send mark_received_backup to buddy"* ]] || { echo "Test 3 expected failure log, got: $out"; exit 3; }

# Test 4: Empty destination dataset (only 1 call made)
: > "$calls_file"
fail_param=0
fail_base=0
send_mark_received_backup "buddy.example" "" "buddyuser" "22"
readarray -t calls < "$calls_file"
[[ ${#calls[@]} -eq 1 ]] || { echo "Test 4 failed: expected 1 call, got ${#calls[@]}"; exit 4; }
[[ "${calls[0]}" == *"/rc.buddybackup.php mark_received_backup" ]] || { echo "Test 4 cmd mismatch: ${calls[0]}"; exit 4; }

echo "ALL_BASH_TESTS_PASSED"
BASH_POST

    my $stdin;
    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = open3($stdin, $stdout, $stderr, 'bash', '-s');
    binmode($stdin, ':raw');
    print $stdin $bash_test;
    close $stdin;

    my $out = do { local $/; <$stdout> // '' };
    my $err = do { local $/; <$stderr> // '' };
    waitpid($pid, 0);

    is($? >> 8, 0, 'send_mark_received_backup fallback test exited with 0') or diag("stderr: $err\nstdout: $out");
    like($out, qr/ALL_BASH_TESTS_PASSED/, 'all fallback test scenarios passed');
};

subtest 'test_connection probe fallback logic' => sub {
    my $bash_test = <<'BASH';
set -e
calls_file=$(mktemp)
trap 'rm -f "$calls_file"' EXIT

fail_param=0
fail_base=0

shell_single_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

run_remote_ssh() {
    local host="$1"
    local cmd="$2"
    echo "$cmd" >> "$calls_file"
    if [[ "$cmd" == *" probe_zfs '"* ]]; then
        if [[ $fail_param -eq 1 ]]; then
            return 1
        fi
        echo '{"status":"ok","dataset":"cache/domains/MintCinnamon","datasets":["cache/appdata","cache/domains/MintCinnamon"]}'
        return 0
    elif [[ "$cmd" == *" probe_zfs" ]]; then
        if [[ $fail_base -eq 1 ]]; then
            return 1
        fi
        echo '{"status":"ok","dataset":"cache/appdata"}'
        return 0
    fi
    return 1
}

run_probe_with_fallback() {
    local host="$1"
    local destination_dataset="$2"

    local zfs_probe_cmd="/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs"
    if [[ -n "${destination_dataset}" ]]; then
        zfs_probe_cmd="/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs $(shell_single_quote "${destination_dataset}")"
    fi
    local zfs_probe_result
    zfs_probe_result=$(run_remote_ssh "${host}" "${zfs_probe_cmd}" 2>&1)
    local zfs_probe_status=$?

    if [[ -n "${destination_dataset}" ]] && [[ $zfs_probe_status -ne 0 ]]; then
        local fallback_probe_cmd="/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs"
        local fallback_probe_result
        fallback_probe_result=$(run_remote_ssh "${host}" "${fallback_probe_cmd}" 2>&1)
        local fallback_probe_status=$?
        if [[ $fallback_probe_status -eq 0 ]] && [[ "${fallback_probe_result}" == \{* ]]; then
            zfs_probe_cmd="${fallback_probe_cmd}"
            zfs_probe_result="${fallback_probe_result}"
            zfs_probe_status=0
        fi
    fi

    echo "${zfs_probe_result}"
    return $zfs_probe_status
}

# Test 1: Modern receiver (parameterized probe succeeds on first try)
: > "$calls_file"
fail_param=0
fail_base=0
res=$(run_probe_with_fallback "buddy.example" "cache/domains/MintCinnamon")
readarray -t calls < "$calls_file"
[[ ${#calls[@]} -eq 1 ]] || { echo "Test 1 failed: expected 1 call, got ${#calls[@]}"; exit 1; }
[[ "${calls[0]}" == *"/rc.buddybackup.php probe_zfs 'cache/domains/MintCinnamon'" ]] || { echo "Test 1 cmd mismatch: ${calls[0]}"; exit 1; }
[[ "$res" == *"MintCinnamon"* ]] || { echo "Test 1 res mismatch: $res"; exit 1; }

# Test 2: Legacy receiver (parameterized probe blocked, fallback succeeds)
: > "$calls_file"
fail_param=1
fail_base=0
res=$(run_probe_with_fallback "buddy.example" "cache/domains/MintCinnamon")
readarray -t calls < "$calls_file"
[[ ${#calls[@]} -eq 2 ]] || { echo "Test 2 failed: expected 2 calls, got ${#calls[@]}"; exit 2; }
[[ "${calls[0]}" == *"/rc.buddybackup.php probe_zfs 'cache/domains/MintCinnamon'" ]] || { echo "Test 2 call 0 mismatch: ${calls[0]}"; exit 2; }
[[ "${calls[1]}" == *"/rc.buddybackup.php probe_zfs" ]] || { echo "Test 2 call 1 mismatch: ${calls[1]}"; exit 2; }
[[ "$res" == *'"dataset":"cache/appdata"'* ]] || { echo "Test 2 res mismatch: $res"; exit 2; }

# Test 3: Unparameterized probe when destination_dataset is empty
: > "$calls_file"
fail_param=0
fail_base=0
res=$(run_probe_with_fallback "buddy.example" "")
readarray -t calls < "$calls_file"
[[ ${#calls[@]} -eq 1 ]] || { echo "Test 3 failed: expected 1 call, got ${#calls[@]}"; exit 3; }
[[ "${calls[0]}" == *"/rc.buddybackup.php probe_zfs" ]] || { echo "Test 3 cmd mismatch: ${calls[0]}"; exit 3; }

echo "ALL_PROBE_FALLBACK_TESTS_PASSED"
BASH

    my $stdin;
    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = open3($stdin, $stdout, $stderr, 'bash', '-s');
    binmode($stdin, ':raw');
    print $stdin $bash_test;
    close $stdin;

    my $out = do { local $/; <$stdout> // '' };
    my $err = do { local $/; <$stderr> // '' };
    waitpid($pid, 0);

    is($? >> 8, 0, 'test_connection probe fallback test exited with 0') or diag("stderr: $err\nstdout: $out");
    like($out, qr/ALL_PROBE_FALLBACK_TESTS_PASSED/, 'all probe fallback test scenarios passed');
};

# ---------------------------------------------------------------------------
# Backward compatibility: legacy snapshots.cfg without time directives
# ---------------------------------------------------------------------------
subtest 'legacy snapshots.cfg and 15-minute cron upgrade compatibility' => sub {
    my $rc_php = File::Spec->catfile(
        $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'scripts', 'rc.buddybackup.php'
    );
    plan skip_all => 'rc.buddybackup.php not found' if !-f $rc_php;

    my $workdir = tempdir(CLEANUP => 1);
    my $plugin_cfg = File::Spec->catfile($workdir, 'plugin.cfg');
    my $extra_cfg  = File::Spec->catfile($workdir, 'extra_sanoid.cfg');
    my $incoming_cfg = File::Spec->catfile($workdir, 'buddys.cfg');
    my $sanoid_cfg = File::Spec->catfile($workdir, 'sanoid.conf');
    my $cron_file  = File::Spec->catfile($workdir, 'sanoid.cron');
    my $test_php   = File::Spec->catfile($workdir, 'test_compat.php');

    # 1. Plugin cfg
    open my $pfh, '>', $plugin_cfg or die "Cannot write $plugin_cfg: $!";
    print $pfh "ReceiveBackups=\"disable\"\nUtcTimezone=\"no\"\n";
    close $pfh;

    # 2. Legacy extra_sanoid.cfg (snapshots.cfg) without any time or scope keys
    open my $efh, '>', $extra_cfg or die "Cannot write $extra_cfg: $!";
    print $efh <<'CFG';
[legacy_snap_task]
dataset="tank/legacy_appdata"
autosnap="yes"
autoprune="yes"
hourly="24"
daily="7"
weekly="4"
monthly="3"
yearly="0"
recursive="yes"
trigger="no"
CFG
    close $efh;

    # 3. Simulate existing legacy 15-minute sanoid.cron file from previous version
    open my $cfh, '>', $cron_file or die "Cannot write $cron_file: $!";
    print $cfh "*/15 * * * * flock -n /var/lock/buddybackup-sanoid-cron -c \"PATH=/usr/local/emhttp/plugins/buddybackup /usr/local/emhttp/plugins/buddybackup/deps/sanoid --configdir=/boot/config/plugins/buddybackup --cron\" 2>&1 | /usr/local/emhttp/plugins/buddybackup/scripts/log.sh\n";
    close $cfh;

    # 4. PHP test script executing update_sanoid_conf() and enable_sanoid_cron()
    open my $tfh, '>', $test_php or die "Cannot write $test_php: $!";
    print $tfh <<"PHP";
<?php
\$argv = array('test_compat.php', 'noop');
require_once '$rc_php';

\$plugin_config_path = '$plugin_cfg';
\$extra_sanoid_config_path = '$extra_cfg';
\$incoming_config_path = '$incoming_cfg';
\$sanoid_config_path = '$sanoid_cfg';
\$sanoid_cron_path = '$cron_file';
\$sanoid_bin = '/usr/local/emhttp/plugins/buddybackup/deps/sanoid';
\$buddybackup_path = '/usr/local/emhttp/plugins/buddybackup';
\$plugin_path = '$workdir';
\$log_script = '/usr/local/emhttp/plugins/buddybackup/scripts/log.sh';
\$rc = '/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup';

update_sanoid_conf();

ob_start();
enable_sanoid_cron();
ob_end_clean();

echo "SANOID_CONF_START\\n";
echo file_get_contents('$sanoid_cfg');
echo "SANOID_CONF_END\\n";
echo "SANOID_CRON_START\\n";
echo file_get_contents('$cron_file');
echo "SANOID_CRON_END\\n";
PHP
    close $tfh;

    my $out = `php "$test_php" 2>&1`;
    is($? >> 8, 0, 'php compat runner exited cleanly');

    my ($conf) = $out =~ /SANOID_CONF_START\n(.*?)\nSANOID_CONF_END/s;
    ok(defined $conf, 'sanoid.conf generated from legacy config');
    like($conf, qr/\[tank\/legacy_appdata\]/, 'legacy section generated');
    like($conf, qr/hourly = 24/, 'hourly retention preserved');
    like($conf, qr/daily = 7/, 'daily retention preserved');
    like($conf, qr/recursive = zfs/, 'recursive mode normalized to zfs');
    unlike($conf, qr/daily_hour/, 'daily_hour cleanly omitted for default fallback');
    unlike($conf, qr/daily_min/, 'daily_min cleanly omitted for default fallback');
    unlike($conf, qr/hook_scope/, 'hook_scope not present');

    my ($cron) = $out =~ /SANOID_CRON_START\n(.*?)\nSANOID_CRON_END/s;
    ok(defined $cron, 'sanoid.cron upgraded successfully');
    like($cron, qr/^\* \* \* \* \* flock -n \/var\/lock\/buddybackup-sanoid-cron/m, 'upgraded to 1-minute ticker');
    like($cron, qr/--cache-ttl=60/, 'includes --cache-ttl=60 in upgraded cron');
    unlike($cron, qr/\*\/15/, 'legacy */15 ticker was removed');
};

done_testing();
