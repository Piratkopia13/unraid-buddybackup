use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Copy qw(copy);
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

sub deps_file {
    my ($name) = @_;
    return File::Spec->catfile(
        $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', $name
    );
}

sub install_allowlist {
    my ($dir, $name) = @_;

    my $script = File::Spec->catfile($dir, $name);
    copy(deps_file($name), $script) or die "Unable to copy $name: $!";
    return $script;
}

sub write_scope {
    my ($dir, $name, $content) = @_;

    my $scope_file = File::Spec->catfile($dir, "$name.datasets");
    open my $fh, '>', $scope_file or die "Unable to write $scope_file: $!";
    print $fh $content;
    close $fh;
    return $scope_file;
}

sub run_restrict {
    my ($script, $command, @cli_args) = @_;

    local %ENV = %ENV;
    $ENV{SSH_ORIGINAL_COMMAND} = $command;

    my $stderr = gensym;
    my $pid = open3(undef, my $stdout, $stderr, $^X, $script, '--dry-run', '--log=stderr', @cli_args);
    my $stdout_text = do { local $/; <$stdout> // '' };
    my $stderr_text = do { local $/; <$stderr> // '' };
    waitpid($pid, 0);

    return {
        exit_code => $? >> 8,
        stdout => $stdout_text,
        stderr => $stderr_text,
    };
}

sub assert_allowed {
    my ($label, $script, $command, @cli_args) = @_;

    my $result = run_restrict($script, $command, @cli_args);
    is($result->{exit_code}, 0, "$label exits cleanly");
    is($result->{stdout}, '', "$label does not write to stdout");
    like(
        $result->{stderr},
        qr/^\Qwould run command: $command\E\r?\n?$/,
        "$label allows: $command",
    ) or diag($result->{stderr});
}

sub assert_blocked {
    my ($label, $script, $command, @cli_args) = @_;

    my $result = run_restrict($script, $command, @cli_args);
    is($result->{exit_code}, 0, "$label exits cleanly");
    is($result->{stdout}, '', "$label does not write to stdout");
    like(
        $result->{stderr},
        qr/^\Qblocked command: $command\E\r?\n?$/,
        "$label blocks: $command",
    ) or diag($result->{stderr});
}

subtest 'receiver allowlist is narrowed to the configured dataset tree' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $script = install_allowlist($dir, 'restrict_zfs');
    write_scope($dir, 'restrict_zfs', "stuff/various\n");

    my $in = q{'stuff/various'};
    my $in_child = q{'stuff/various/child'};
    my $out = q{'stuff/other'};
    my $sibling = q{'stuff/various2'};
    my $in_snap = q{'stuff/various@autosnap_2026-04-27:01:30:48-GMT01:00_daily'};
    my $out_snap = q{'stuff/other@autosnap_2026-04-27:01:30:48-GMT01:00_daily'};

    assert_allowed('in-scope dataset query', $script, "zfs get -H name $in");
    assert_allowed('in-scope child dataset query', $script, "zfs get -H name $in_child");
    assert_allowed('in-scope dataset encryption query', $script, "zfs get -H encryption $in");
    assert_allowed('in-scope child dataset encryption query', $script, "zfs get -H encryption $in_child");
    assert_blocked('out-of-scope dataset query', $script, "zfs get -H name $out");
    assert_blocked('out-of-scope dataset encryption query', $script, "zfs get -H encryption $out");
    assert_blocked('sibling dataset name sharing the scope prefix', $script, "zfs get -H name $sibling");
    assert_allowed('in-scope snapshot metadata query', $script, "zfs get -Hpd 1 -t snapshot guid,creation $in");
    assert_blocked('out-of-scope snapshot metadata query', $script, "zfs get -Hpd 1 -t snapshot guid,creation $out");
    assert_allowed('in-scope receive pipeline', $script, "mbuffer  -q -s 128k -m 16M | zstdmt -dc | zfs receive -F $in 2>&1");
    assert_blocked('out-of-scope receive pipeline', $script, "mbuffer  -q -s 128k -m 16M | zstdmt -dc | zfs receive -F $out 2>&1");
    assert_allowed('in-scope direct receive', $script, "zfs receive -F -s $in");
    assert_blocked('out-of-scope direct receive', $script, "zfs receive -F -s $out");
    assert_allowed('in-scope create', $script, "zfs create -u $in_child");
    assert_blocked('out-of-scope create', $script, "zfs create -u $out");
    assert_allowed('in-scope receive reset', $script, "zfs receive -A $in");
    assert_blocked('out-of-scope receive reset', $script, "zfs receive -A $out");
    assert_allowed('in-scope restore send estimate', $script, "zfs send -w -nvP $in_snap");
    assert_blocked('out-of-scope restore send estimate', $script, "zfs send -w -nvP $out_snap");
    assert_allowed('in-scope restore send', $script, "zfs send -w $in_snap | zstdmt -3 | mbuffer  -q -s 128k -m 16M");
    assert_blocked('out-of-scope restore send', $script, "zfs send -w $out_snap | zstdmt -3 | mbuffer  -q -s 128k -m 16M");
    assert_allowed('in-scope dataset list', $script, "zfs list -o name,origin -t filesystem,volume -Hr $in");
    assert_blocked('out-of-scope dataset list', $script, "zfs list -o name,origin -t filesystem,volume -Hr $out");
    assert_allowed('pool-level query for the scope pool', $script, "zpool get -o value -H feature\@extensible_dataset 'stuff'");
    assert_blocked('pool-level query for another pool', $script, "zpool get -o value -H feature\@extensible_dataset 'otherpool'");
    assert_allowed('pool encryption query for the scope pool', $script, "zfs get -H -p -t filesystem,volume encryption 'stuff' 2>&1");
    assert_allowed('unquoted pool encryption query for the scope pool', $script, "zfs get -H -p -t filesystem,volume encryption stuff 2>&1");
    assert_blocked('pool encryption query for another pool', $script, "zfs get -H -p -t filesystem,volume encryption 'otherpool' 2>&1");
    assert_allowed('in-scope dataset umount', $script, "zfs umount $in 2>&1");
    assert_allowed('in-scope child umount', $script, "zfs umount $in_child 2>&1");
    assert_blocked('out-of-scope dataset umount', $script, "zfs umount $out 2>&1");
    assert_allowed('capability probe recv -x is allowed', $script, "zfs recv -x 2>&1");
    assert_blocked('zfs mount is blocked even for in-scope dataset', $script, "zfs mount $in");
    assert_allowed('in-scope delegation probe', $script, "zfs allow $in");
    assert_blocked('out-of-scope delegation probe', $script, "zfs allow $out");
    assert_allowed('scope-independent callback stays usable', $script, '/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs');
    assert_allowed('scope-independent process probe stays usable', $script, 'ps -Ao args=');
    assert_allowed('scope-independent zfs version probe stays usable', $script, 'zfs version');
};

subtest 'missing scope file keeps the historical unscoped patterns' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $script = install_allowlist($dir, 'restrict_zfs');

    assert_allowed('any dataset query works without a scope file', $script, "zfs get -H name 'stuff/other'");
    assert_allowed('any pool query works without a scope file', $script, "zpool get -o value -H feature\@extensible_dataset 'otherpool'");
};

subtest 'empty or comment-only scope file denies dataset-scoped commands' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $script = install_allowlist($dir, 'restrict_zfs');

    write_scope($dir, 'restrict_zfs', '');
    assert_blocked('dataset query denied by empty scope', $script, "zfs get -H name 'stuff/various'");
    assert_blocked('pool query denied by empty scope', $script, "zpool get -o value -H feature\@extensible_dataset 'stuff'");
    assert_allowed('scope-independent probe still works with empty scope', $script, 'echo ok');

    write_scope($dir, 'restrict_zfs', "# nothing configured yet\n\n");
    assert_blocked('dataset query denied by comment-only scope', $script, "zfs get -H name 'stuff/various'");
    assert_allowed('scope-independent probe still works with comment-only scope', $script, 'ps -Ao args=');
};

subtest 'scope file with multiple datasets, spaces and CRLF endings' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $script = install_allowlist($dir, 'restrict_zfs');
    write_scope($dir, 'restrict_zfs', "stuff/various\r\ntank pool/with space\r\n");

    my $spaced = q{'tank pool/with space'};
    my $spaced_child = q{'tank pool/with space/child'};
    my $other = q{'tank pool/other'};

    assert_allowed('spaced dataset query', $script, "zfs get -H name $spaced");
    assert_allowed('spaced dataset child query', $script, "zfs get -H name $spaced_child");
    assert_allowed('first dataset still in scope', $script, "zfs get -H name 'stuff/various'");
    assert_blocked('sibling of spaced dataset blocked', $script, "zfs get -H name $other");
    assert_allowed('spaced pool-level query', $script, "zpool get -o value -H feature\@extensible_dataset 'tank pool'");
    assert_allowed('first pool-level query', $script, "zpool get -o value -H feature\@extensible_dataset 'stuff'");
    assert_blocked('unrelated pool blocked', $script, "zpool get -o value -H feature\@extensible_dataset 'thirdpool'");
};

subtest 'invalid scope lines are skipped; valid ones still apply' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $script = install_allowlist($dir, 'restrict_zfs');
    write_scope(
        $dir,
        'restrict_zfs',
        "# comment\nstuff/various\n    indented\n'quoted'\nds; rm -rf /\n../evil\nds\@snap\n\n",
    );

    assert_allowed('valid line still scopes its dataset', $script, "zfs get -H name 'stuff/various'");
    assert_blocked('dataset outside the valid lines is blocked', $script, "zfs get -H name 'stuff/other'");

    write_scope($dir, 'restrict_zfs', "    indented\n'quoted'\nds; rm -rf /\n../evil\n");
    assert_blocked('junk-only scope file denies dataset commands', $script, "zfs get -H name 'stuff/various'");
};

subtest 'CLI --dataset argument narrows scope and enforces cross-buddy isolation' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $script = install_allowlist($dir, 'restrict_zfs');
    my @alice_cli = ('--dataset', 'tank/backups/alice', '--uid', 'alice_123');

    my $alice_in = q{'tank/backups/alice'};
    my $alice_child = q{'tank/backups/alice/appdata'};
    my $alice_snap = q{'tank/backups/alice@autosnap_2026-04-27:01:30:48-GMT01:00_daily'};
    my $truenas = q{'tank/backups/truenas'};
    my $truenas_child = q{'tank/backups/truenas/system'};
    my $truenas_snap = q{'tank/backups/truenas@autosnap_2026-04-27:01:30:48-GMT01:00_daily'};
    my $alice_sibling = q{'tank/backups/alice_two'};

    # In-scope for Alice (quoted)
    assert_allowed('in-scope dataset query', $script, "zfs get -H name $alice_in", @alice_cli);
    assert_allowed('in-scope child query', $script, "zfs get -H name $alice_child", @alice_cli);
    assert_allowed('in-scope receive', $script, "zfs receive -F -s $alice_in", @alice_cli);
    assert_allowed('in-scope restore send', $script, "zfs send -w $alice_snap | zstdmt -3 | mbuffer  -q -s 128k -m 16M", @alice_cli);

    # In-scope for Alice (unquoted, e.g. TrueNAS / zettarepl)
    assert_allowed('in-scope unquoted dataset query', $script, "zfs get -H name tank/backups/alice", @alice_cli);
    assert_allowed('in-scope unquoted child query', $script, "zfs get -H name tank/backups/alice/appdata", @alice_cli);
    assert_allowed('in-scope unquoted zettarepl property query', $script, "zfs get -H -p -t filesystem,volume type tank/backups/alice/appdata", @alice_cli);
    assert_allowed('in-scope unquoted snapshot list', $script, "zfs list -t snapshot -H -o name -s name -r tank/backups/alice", @alice_cli);
    assert_allowed('in-scope unquoted dataset list', $script, "zfs list -t filesystem,volume -H -o name -s name -r tank/backups/alice", @alice_cli);
    assert_allowed('in-scope pool encryption query', $script, "zfs get -H -p -t filesystem,volume encryption tank 2>&1", @alice_cli);
    assert_allowed('in-scope unmount', $script, "zfs umount tank/backups/alice/appdata 2>&1", @alice_cli);
    assert_allowed('recv capability probe', $script, "zfs recv -x 2>&1", @alice_cli);

    # Cross-buddy attacks (Alice trying to access TrueNAS) - MUST BE BLOCKED
    assert_blocked('cross-buddy dataset query blocked', $script, "zfs get -H name $truenas", @alice_cli);
    assert_blocked('cross-buddy child query blocked', $script, "zfs get -H name $truenas_child", @alice_cli);
    assert_blocked('cross-buddy receive blocked', $script, "zfs receive -F -s $truenas", @alice_cli);
    assert_blocked('cross-buddy create blocked', $script, "zfs create -u $truenas_child", @alice_cli);
    assert_blocked('cross-buddy restore send blocked', $script, "zfs send -w $truenas_snap | zstdmt -3 | mbuffer  -q -s 128k -m 16M", @alice_cli);
    assert_blocked('cross-buddy snapshot list blocked', $script, "zfs list -t snapshot -H -o name $truenas", @alice_cli);
    assert_blocked('sibling dataset prefix blocked', $script, "zfs get -H name $alice_sibling", @alice_cli);
    assert_blocked('cross-buddy unquoted dataset query blocked', $script, "zfs get -H name tank/backups/truenas", @alice_cli);
    assert_blocked('cross-buddy unquoted property query blocked', $script, "zfs get -H -p -t filesystem,volume type tank/backups/truenas", @alice_cli);
    assert_blocked('cross-buddy unmount blocked', $script, "zfs umount tank/backups/truenas 2>&1", @alice_cli);
    assert_blocked('unquoted sibling dataset prefix blocked', $script, "zfs get -H name tank/backups/alice_two", @alice_cli);
    assert_blocked('cross-buddy mount blocked', $script, "zfs mount tank/backups/alice", @alice_cli);
    assert_blocked('disallowed pool encryption query blocked', $script, "zfs get -H -p -t filesystem,volume encryption otherpool 2>&1", @alice_cli);
};

subtest 'unified post-receive hook triggers on successful receive' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $script = install_allowlist($dir, 'restrict_zfs');
    my $mock_php = File::Spec->catfile($dir, 'mock_rc.sh');
    my $hook_log = File::Spec->catfile($dir, 'hook.log');

    # Create mock script that records calls to $hook_log
    open my $fh, '>', $mock_php or die $!;
    print $fh "#!/bin/sh\necho \"call:\$* ds:\$BUDDY_DATASET uid:\$BUDDY_UID\" >> \"$hook_log\"\n";
    close $fh;
    chmod 0755, $mock_php;

    # Create a mock bin directory with no-op bash commands (zfs, mbuffer, zstdmt) that exit 0
    my $mock_bin = File::Spec->catdir($dir, 'bin');
    make_path($mock_bin);
    for my $tool ('zfs', 'mbuffer', 'zstdmt') {
        my $tool_path = File::Spec->catfile($mock_bin, $tool);
        open my $tfh, '>', $tool_path or die $!;
        print $tfh "#!/bin/sh\nexit 0\n";
        close $tfh;
        chmod 0755, $tool_path;
    }

    local %ENV = %ENV;
    $ENV{PATH} = "$mock_bin:$ENV{PATH}";
    $ENV{BUDDYBACKUP_RC_PHP} = $mock_php;

    my $exec_restrict = sub {
        my ($cmd, @args) = @_;
        local $ENV{SSH_ORIGINAL_COMMAND} = $cmd;
        my $pid = open3(undef, my $out, my $err, $^X, $script, '--log=none', @args);
        waitpid($pid, 0);
        return $? >> 8;
    };

    # 1. Non-receive command: echo ok (allowed, exits 0, but NOT a zfs receive)
    {
        my $res = $exec_restrict->("echo ok", '--dataset', 'tank/backups/alice', '--uid', 'alice_123');
        is($res, 0, 'echo ok ran cleanly');
        ok(!-f $hook_log, 'echo ok did NOT trigger post-receive hook');
    }

    # 2. Receive command: zfs receive (allowed, exits 0 -> hook MUST trigger)
    {
        my $res = $exec_restrict->("zfs receive -F 'tank/backups/alice'", '--dataset', 'tank/backups/alice', '--uid', 'alice_123');
        is($res, 0, 'zfs receive ran cleanly');
        ok(-f $hook_log, 'zfs receive triggered post-receive hook');
        open my $lfh, '<', $hook_log or die $!;
        my $content = do { local $/; <$lfh> };
        close $lfh;
        like($content, qr/call:mark_received_backup ds:tank\/backups\/alice uid:alice_123/, 'hook received expected args and environment');
        unlink $hook_log;
    }

    # 3. Receive abort command: zfs receive -A (allowed, but aborting -> hook must NOT trigger)
    {
        my $res = $exec_restrict->("zfs receive -A 'tank/backups/alice'", '--dataset', 'tank/backups/alice', '--uid', 'alice_123');
        is($res, 0, 'zfs receive -A ran cleanly');
        ok(!-f $hook_log, 'zfs receive -A did NOT trigger post-receive hook');
    }
};

done_testing();
