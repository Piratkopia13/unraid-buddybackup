use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Spec;
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

my $script;
for my $candidate_root (@repo_root_candidates) {
    my $candidate_script = File::Spec->catfile(
        $candidate_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', 'restrict_zfs_send'
    );
    if (-f $candidate_script) {
        $script = $candidate_script;
        last;
    }
}

ok(defined $script && -f $script, 'restrict_zfs_send script exists');

BAIL_OUT('Unable to locate restrict_zfs_send script from test path or current working directory') if !defined $script;

my $script_source = do {
    open my $fh, '<', $script or die "Unable to read $script: $!";
    local $/;
    <$fh>;
};

like(
    $script_source,
    qr!join\(':',\s*grep\s*\{\s*length\s*\}\s*qw\(/usr/local/sbin /usr/sbin /sbin /usr/local/bin /usr/bin /bin\)!s,
    'restrict_zfs_send normalizes PATH to include sbin directories'
);

sub run_restrict {
    my ($command) = @_;

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

sub stderr_regex {
    my (@lines) = @_;
    my $pattern = join('\r?\n', map { quotemeta($_) } @lines);
    return qr/^$pattern\r?\n?$/;
}

sub assert_case {
    my ($label, $command, $expected_lines) = @_;

    my $result = run_restrict($command);
    is($result->{exit_code}, 0, "$label exits cleanly");
    is($result->{stdout}, '', "$label does not write to stdout");
    like($result->{stderr}, stderr_regex(@$expected_lines), "$label logs expected stderr") or diag($result->{stderr});
}

my $dataset = q{'tank0/offsite/tim/cache_domains/Windows 11'};
my $snap1 = q{'tank0/offsite/tim/cache_domains/Windows 11@autosnap_2026-04-27:01:30:48-GMT01:00_daily'};
my $snap2 = q{'tank0/offsite/tim/cache_domains/Windows 11@autosnap_2026-04-23_06:15:01_daily'};

subtest 'blocked commands' => sub {
    my $newline_attack = "echo ok\nls";

    my @cases = (
        {
            label => 'security validation bypass attempt',
            command => q{echo ok && ls},
            expected_lines => ['blocked command: echo ok && ls'],
        },
        {
            label => 'shell chaining after allowed query',
            command => qq{zfs get -H encryption $dataset && id},
            expected_lines => [qq{blocked command: zfs get -H encryption $dataset && id}],
        },
        {
            label => 'unquoted dataset',
            command => q{zfs get -H name tank0/offsite/tim/cache_domains/Windows_11},
            expected_lines => ['blocked command: zfs get -H name tank0/offsite/tim/cache_domains/Windows_11'],
        },
        {
            label => 'double quoted dataset',
            command => q{zfs get -H name "tank0/offsite/tim/cache_domains/Windows 11"},
            expected_lines => ['blocked command: zfs get -H name "tank0/offsite/tim/cache_domains/Windows 11"'],
        },
        {
            label => 'sudo-prefixed command',
            command => qq{sudo zfs get -H name $dataset},
            expected_lines => [qq{blocked command: sudo zfs get -H name $dataset}],
        },
        {
            label => 'disallowed availability probe',
            command => q{command -v busybox},
            expected_lines => ['blocked command: command -v busybox'],
        },
        {
            label => 'property mutation attempt',
            command => qq{zfs set compression=lz4 $dataset},
            expected_lines => [qq{blocked command: zfs set compression=lz4 $dataset}],
        },
        {
            label => 'snapshot creation attempt',
            command => qq{zfs snapshot $snap1},
            expected_lines => [qq{blocked command: zfs snapshot $snap1}],
        },
        {
            label => 'snapshot destroy attempt',
            command => qq{zfs destroy $snap1},
            expected_lines => [qq{blocked command: zfs destroy $snap1}],
        },
        {
            label => 'hold attempt',
            command => qq{zfs hold syncoid_test $snap1},
            expected_lines => [qq{blocked command: zfs hold syncoid_test $snap1}],
        },
        {
            label => 'release attempt',
            command => qq{zfs release syncoid_test $snap1},
            expected_lines => [qq{blocked command: zfs release syncoid_test $snap1}],
        },
        {
            label => 'receive attempt',
            command => qq{zfs receive -F $dataset},
            expected_lines => [qq{blocked command: zfs receive -F $dataset}],
        },
        {
            label => 'receive pipeline attempt',
            command => qq{mbuffer  -q -s 128k -m 16M | zstdmt -dc | zfs receive -F $dataset 2>&1},
            expected_lines => [qq{blocked command: mbuffer  -q -s 128k -m 16M | zstdmt -dc | zfs receive -F $dataset 2>&1}],
        },
        {
            label => 'receive reset attempt',
            command => qq{zfs receive -A $dataset},
            expected_lines => [qq{blocked command: zfs receive -A $dataset}],
        },
        {
            label => 'probe zfs callback attempt',
            command => q{/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs},
            expected_lines => ['blocked command: /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs'],
        },
        {
            label => 'mark received backup callback attempt',
            command => q{/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php mark_received_backup},
            expected_lines => ['blocked command: /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php mark_received_backup'],
        },
        {
            label => 'arbitrary stderr redirection',
            command => qq{zfs get -H name $dataset 2>/tmp/pwned},
            expected_lines => [qq{blocked command: zfs get -H name $dataset 2>/tmp/pwned}],
        },
        {
            label => 'stdout redirection on send',
            command => qq{zfs send -w $snap1 >/tmp/pwned},
            expected_lines => [qq{blocked command: zfs send -w $snap1 >/tmp/pwned}],
        },
        {
            label => 'pipeline to shell',
            command => qq{zfs send -w $snap1 | zstdmt -3 | mbuffer  -q -s 128k -m 16M | sh},
            expected_lines => [qq{blocked command: zfs send -w $snap1 | zstdmt -3 | mbuffer  -q -s 128k -m 16M | sh}],
        },
        {
            label => 'environment prefix attempt',
            command => q{PATH=/tmp:$PATH echo ok},
            expected_lines => ['blocked command: PATH=/tmp:$PATH echo ok'],
        },
        {
            label => 'comment suffix attempt',
            command => q{echo ok # comment},
            expected_lines => ['blocked command: echo ok # comment'],
        },
        {
            label => 'command substitution attempt',
            command => qq{zfs get -H name $dataset \$(id)},
            expected_lines => [qq{blocked command: zfs get -H name $dataset \$(id)}],
        },
        {
            label => 'backtick substitution attempt',
            command => qq{zfs get -H name $dataset `id`},
            expected_lines => [qq{blocked command: zfs get -H name $dataset `id`}],
        },
        {
            label => 'nested quote injection in send',
            command => q{zfs send -w 'ds@snap'"'"'@extra'},
            expected_lines => [q{blocked command: zfs send -w 'ds@snap'"'"'@extra'}],
        },
        {
            label => 'newline injection attempt',
            command => $newline_attack,
            expected_lines => [
                'blocked command: echo ok',
                'ls',
            ],
        },
        {
            label => 'malicious follow-up after allowed send estimate',
            command => qq{zfs send -w -nvP $snap1; zfs destroy $snap2},
            expected_lines => [
                qq{would run command: zfs send -w -nvP $snap1},
                qq{blocked command: zfs destroy $snap2},
            ],
        },
        {
            label => 'malicious follow-up after allowed send pipeline',
            command => qq{zfs send -w $snap1 | zstdmt -3 | mbuffer  -q -s 128k -m 16M; zfs destroy $snap2},
            expected_lines => [
                qq{would run command: zfs send -w $snap1 | zstdmt -3 | mbuffer  -q -s 128k -m 16M},
                qq{blocked command: zfs destroy $snap2},
            ],
        },
        {
            label => 'malicious follow-up after allowed resume estimate',
            command => q{zfs send  -nvP -t 1234567890123456; id},
            expected_lines => [
                'would run command: zfs send  -nvP -t 1234567890123456',
                'blocked command: id',
            ],
        },
        {
            label => 'flag injection after resume token',
            command => q{zfs send -w -nvP -t 1234567890123456 'ds@snap'},
            expected_lines => [q{blocked command: zfs send -w -nvP -t 1234567890123456 'ds@snap'}],
        },
    );

    for my $case (@cases) {
        assert_case($case->{label}, $case->{command}, $case->{expected_lines});
    }
};

subtest 'allowed commands' => sub {
    my @cases = (
        {
            label => 'whitespace-trimmed echo ok probe',
            command => "  echo ok  ",
            expected_lines => ['would run command: echo ok'],
        },
        {
            label => 'echo -n probe',
            command => q{echo -n},
            expected_lines => ['would run command: echo -n'],
        },
        {
            label => 'exit probe',
            command => q{exit},
            expected_lines => ['would run command: exit'],
        },
        {
            label => 'zstdmt availability probe',
            command => q{command -v zstdmt},
            expected_lines => ['would run command: command -v zstdmt'],
        },
        {
            label => 'zstd availability probe',
            command => q{command -v zstd},
            expected_lines => ['would run command: command -v zstd'],
        },
        {
            label => 'mbuffer availability probe',
            command => q{command -v mbuffer},
            expected_lines => ['would run command: command -v mbuffer'],
        },
        {
            label => 'zfs availability probe',
            command => q{command -v zfs},
            expected_lines => ['would run command: command -v zfs'],
        },
        {
            label => 'zfs version probe',
            command => q{zfs version},
            expected_lines => ['would run command: zfs version'],
        },
        {
            label => 'resume feature probe',
            command => q{zpool get -o value -H feature@extensible_dataset 'tank0'},
            expected_lines => [q{would run command: zpool get -o value -H feature@extensible_dataset 'tank0'}],
        },
        {
            label => 'target exists query',
            command => qq{zfs get -H name $dataset},
            expected_lines => [qq{would run command: zfs get -H name $dataset}],
        },
        {
            label => 'dataset type query',
            command => qq{zfs get -H type $dataset},
            expected_lines => [qq{would run command: zfs get -H type $dataset}],
        },
        {
            label => 'encryption property query',
            command => qq{zfs get -H encryption $dataset},
            expected_lines => [qq{would run command: zfs get -H encryption $dataset}],
        },
        {
            label => 'receive token query',
            command => qq{zfs get -H receive_resume_token $dataset},
            expected_lines => [qq{would run command: zfs get -H receive_resume_token $dataset}],
        },
        {
            label => 'used size query',
            command => qq{zfs get -H -o value used $dataset},
            expected_lines => [qq{would run command: zfs get -H -o value used $dataset}],
        },
        {
            label => 'precise used size query',
            command => qq{zfs get -H -p used $dataset},
            expected_lines => [qq{would run command: zfs get -H -p used $dataset}],
        },
        {
            label => 'syncoid sync property query',
            command => qq{zfs get -H syncoid:sync $dataset},
            expected_lines => [qq{would run command: zfs get -H syncoid:sync $dataset}],
        },
        {
            label => 'json used size query',
            command => qq{zfs get -j used $dataset},
            expected_lines => [qq{would run command: zfs get -j used $dataset}],
        },
        {
            label => 'json encryption query',
            command => qq{zfs get -j encryption $dataset},
            expected_lines => [qq{would run command: zfs get -j encryption $dataset}],
        },
        {
            label => 'snapshot metadata query',
            command => qq{zfs get -Hpd 1 -t snapshot guid,creation $dataset},
            expected_lines => [qq{would run command: zfs get -Hpd 1 -t snapshot guid,creation $dataset}],
        },
        {
            label => 'snapshot metadata query with stderr redirect',
            command => qq{zfs get -Hpd 1 -t snapshot guid,creation $dataset 2>/dev/null},
            expected_lines => [qq{would run command: zfs get -Hpd 1 -t snapshot guid,creation $dataset 2>/dev/null}],
        },
        {
            label => 'json snapshot metadata query',
            command => qq{zfs get -j -p -d 1 -t snapshot guid,creation $dataset},
            expected_lines => [qq{would run command: zfs get -j -p -d 1 -t snapshot guid,creation $dataset}],
        },
        {
            label => 'bookmark metadata query',
            command => qq{zfs get -Hpd 1 -t bookmark guid,creation $dataset},
            expected_lines => [qq{would run command: zfs get -Hpd 1 -t bookmark guid,creation $dataset}],
        },
        {
            label => 'fallback metadata query',
            command => qq{zfs get -Hpd 1 type,guid,creation $dataset},
            expected_lines => [qq{would run command: zfs get -Hpd 1 type,guid,creation $dataset}],
        },
        {
            label => 'dataset list query',
            command => qq{zfs list -o name,origin -t filesystem,volume -Hr $dataset},
            expected_lines => [qq{would run command: zfs list -o name,origin -t filesystem,volume -Hr $dataset}],
        },
        {
            label => 'json dataset list query',
            command => qq{zfs list -r -j -o name,origin -t filesystem,volume $dataset},
            expected_lines => [qq{would run command: zfs list -r -j -o name,origin -t filesystem,volume $dataset}],
        },
        {
            label => 'full send size estimate',
            command => qq{zfs send -w -nvP $snap1},
            expected_lines => [qq{would run command: zfs send -w -nvP $snap1}],
        },
        {
            label => 'incremental send size estimate',
            command => qq{zfs send -w -nvP -I $snap1 $snap2},
            expected_lines => [qq{would run command: zfs send -w -nvP -I $snap1 $snap2}],
        },
        {
            label => 'full send pipeline',
            command => qq{zfs send -w $snap1 | zstdmt -3 | mbuffer  -q -s 128k -m 16M},
            expected_lines => [qq{would run command: zfs send -w $snap1 | zstdmt -3 | mbuffer  -q -s 128k -m 16M}],
        },
        {
            label => 'incremental send pipeline',
            command => qq{zfs send -w -I $snap1 $snap2 | zstdmt -3 | mbuffer  -q -s 128k -m 16M},
            expected_lines => [qq{would run command: zfs send -w -I $snap1 $snap2 | zstdmt -3 | mbuffer  -q -s 128k -m 16M}],
        },
        {
            label => 'filtered incremental send pipeline',
            command => qq{zfs send -w -i $snap1 $snap2 | zstdmt -3 | mbuffer  -q -s 128k -m 16M},
            expected_lines => [qq{would run command: zfs send -w -i $snap1 $snap2 | zstdmt -3 | mbuffer  -q -s 128k -m 16M}],
        },
        {
            label => 'bandwidth limited send pipeline',
            command => qq{zfs send -w $snap1 | zstdmt -3 | mbuffer -R 5M -q -s 128k -m 16M},
            expected_lines => [qq{would run command: zfs send -w $snap1 | zstdmt -3 | mbuffer -R 5M -q -s 128k -m 16M}],
        },
        {
            label => 'resume size estimate',
            command => q{zfs send  -nvP -t 1234567890123456},
            expected_lines => ['would run command: zfs send  -nvP -t 1234567890123456'],
        },
        {
            label => 'resume send pipeline',
            command => q{zfs send  -t 1234567890123456 | zstdmt -3 | mbuffer  -q -s 128k -m 16M},
            expected_lines => ['would run command: zfs send  -t 1234567890123456 | zstdmt -3 | mbuffer  -q -s 128k -m 16M'],
        },
        {
            label => 'multiple allowed commands',
            command => q{echo ok; command -v zfs},
            expected_lines => [
                'would run command: echo ok',
                'would run command: command -v zfs',
            ],
        },
    );

    for my $case (@cases) {
        assert_case($case->{label}, $case->{command}, $case->{expected_lines});
    }
};

done_testing();
