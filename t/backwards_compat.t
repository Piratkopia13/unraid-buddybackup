use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Spec;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
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
};

subtest 'older releases still send commands the current allowlist accepts' => sub {
    my $current_script = File::Spec->catfile(
        $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', 'restrict_zfs'
    );

    assert_inventory_allowed(
        'current buddy',
        $current_script,
        receiver_command_inventory(0),
    );
};

done_testing();
