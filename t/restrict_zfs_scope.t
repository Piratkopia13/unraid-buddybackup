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
        stdout => $stdout_text,
        stderr => $stderr_text,
    };
}

sub assert_allowed {
    my ($label, $script, $command) = @_;

    my $result = run_restrict($script, $command);
    is($result->{exit_code}, 0, "$label exits cleanly");
    is($result->{stdout}, '', "$label does not write to stdout");
    like(
        $result->{stderr},
        qr/^\Qwould run command: $command\E\r?\n?$/,
        "$label allows: $command",
    ) or diag($result->{stderr});
}

sub assert_blocked {
    my ($label, $script, $command) = @_;

    my $result = run_restrict($script, $command);
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
    assert_blocked('out-of-scope dataset query', $script, "zfs get -H name $out");
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
    assert_allowed('in-scope delegation probe', $script, "zfs allow $in");
    assert_blocked('out-of-scope delegation probe', $script, "zfs allow $out");
    assert_allowed('scope-independent callback stays usable', $script, '/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs');
    assert_allowed('scope-independent process probe stays usable', $script, 'ps -Ao args=');
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

done_testing();
