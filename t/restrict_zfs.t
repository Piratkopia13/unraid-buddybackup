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
        $candidate_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', 'restrict_zfs'
    );
    if (-f $candidate_script) {
        $script = $candidate_script;
        last;
    }
}

ok(defined $script && -f $script, 'restrict_zfs script exists');

BAIL_OUT('Unable to locate restrict_zfs script from test path or current working directory') if !defined $script;

my $script_source = do {
    open my $fh, '<', $script or die "Unable to read $script: $!";
    local $/;
    <$fh>;
};

like(
    $script_source,
    qr!join\(':',\s*grep\s*\{\s*length\s*\}\s*qw\(/usr/local/sbin /usr/sbin /sbin /usr/local/bin /usr/bin /bin\)!s,
    'restrict_zfs normalizes PATH to include sbin directories'
);

like(
    $script_source,
    qr/my \$use_sudo = \(-f "\$0\.sudo"\) \? 1 : 0;/,
    'restrict_zfs supports sudo mode via sibling flag file'
);

like(
    $script_source,
    qr/system\('\/usr\/bin\/sudo',\s*'-n',\s*'--',\s*'\/usr\/bin\/bash',\s*'-c',\s*\$command\)/s,
    'restrict_zfs runs validated commands through sudo -n in sudo mode'
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

my $dataset = q{'disk11/backups/tim/cache_domains/Windows 11'};
my $snap1 = q{'disk11/backups/tim/cache_domains/Windows 11@syncoid_Tower_2026-04-27:01:30:48-GMT01:00'};
my $snap2 = q{'disk11/backups/tim/cache_domains/Windows 11@autosnap_2026-04-23_06:15:01_daily'};

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
            label => 'mbuffer availability probe',
            command => q{command -v mbuffer},
            expected_lines => ['would run command: command -v mbuffer'],
        },
        {
            label => 'resume feature probe',
            command => q{zpool get -o value -H feature@extensible_dataset 'disk11'},
            expected_lines => [q{would run command: zpool get -o value -H feature@extensible_dataset 'disk11'}],
        },
        {
            label => 'receive busy check',
            command => q{ps -Ao args=},
            expected_lines => ['would run command: ps -Ao args='],
        },
        {
            label => 'target exists query',
            command => qq{zfs get -H name $dataset},
            expected_lines => [qq{would run command: zfs get -H name $dataset}],
        },
        {
            label => 'target encryption query',
            command => qq{zfs get -H encryption $dataset},
            expected_lines => [qq{would run command: zfs get -H encryption $dataset}],
        },
        {
            label => 'zfs version probe',
            command => q{zfs version},
            expected_lines => ['would run command: zfs version'],
        },
        {
            label => 'zfs version with redirection',
            command => q{zfs version 2>&1},
            expected_lines => ['would run command: zfs version 2>&1'],
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
            label => 'json used size query',
            command => qq{zfs get -j used $dataset},
            expected_lines => [qq{would run command: zfs get -j used $dataset}],
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
            label => 'snapshot metadata query',
            command => qq{zfs get -Hpd 1 -t snapshot guid,creation $dataset},
            expected_lines => [qq{would run command: zfs get -Hpd 1 -t snapshot guid,creation $dataset}],
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
            command => qq{zfs send -w -i $snap1 $snap2 | zstdmt -3 | mbuffer  -q -s 128k -m 16M},
            expected_lines => [qq{would run command: zfs send -w -i $snap1 $snap2 | zstdmt -3 | mbuffer  -q -s 128k -m 16M}],
        },
        {
            label => 'receive pipeline',
            command => qq{mbuffer  -q -s 128k -m 16M | zstdmt -dc | zfs receive -F $dataset 2>&1},
            expected_lines => [qq{would run command: mbuffer  -q -s 128k -m 16M | zstdmt -dc | zfs receive -F $dataset 2>&1}],
        },
        {
            label => 'receive reset',
            command => qq{zfs receive -A $dataset},
            expected_lines => [qq{would run command: zfs receive -A $dataset}],
        },
        {
            label => 'zfs probe callback',
            command => q{/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs},
            expected_lines => ['would run command: /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php probe_zfs'],
        },
        {
            label => 'mark received backup callback',
            command => q{/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php mark_received_backup},
            expected_lines => ['would run command: /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php mark_received_backup'],
        },
        {
            label => 'multiple allowed commands',
            command => q{echo ok; echo -n},
            expected_lines => [
                'would run command: echo ok',
                'would run command: echo -n',
            ],
        },
        {
            label => 'zettarepl wrapped echo ok probe',
            command => q{sh -c 'PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin echo ok 2>&1'},
            expected_lines => ['would run command: echo ok 2>&1'],
        },
        {
            label => 'zettarepl list snapshots query',
            command => qq{sh -c 'PATH=\$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs list -t snapshot -H -o name -s name -d 1 '\\'''disk11/backups/tim/cache_domains/Windows 11'\\''' 2>&1'},
            expected_lines => [qq{would run command: zfs list -t snapshot -H -o name -s name -d 1 'disk11/backups/tim/cache_domains/Windows 11' 2>&1}],
        },
        {
            label => 'zettarepl list dataset tokens query',
            command => qq{sh -c 'PATH=\$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs list -H -o name,origin,receive_resume_token -t filesystem,volume '\\'''disk11/backups/tim/cache_domains/Windows 11'\\''' 2>&1'},
            expected_lines => [qq{would run command: zfs list -H -o name,origin,receive_resume_token -t filesystem,volume 'disk11/backups/tim/cache_domains/Windows 11' 2>&1}],
        },
        {
            label => 'zettarepl get all properties query',
            command => qq{sh -c 'PATH=\$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs get -H -p -o property,value all '\\'''disk11/backups/tim/cache_domains/Windows 11'\\''' 2>&1'},
            expected_lines => [qq{would run command: zfs get -H -p -o property,value all 'disk11/backups/tim/cache_domains/Windows 11' 2>&1}],
        },
        {
            label => 'zettarepl create child dataset',
            command => qq{sh -c 'PATH=\$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs create -u '\\'''disk11/backups/tim/cache_domains/Windows 11/sub'\\''' 2>&1'},
            expected_lines => [qq{would run command: zfs create -u 'disk11/backups/tim/cache_domains/Windows 11/sub' 2>&1}],
        },
        {
            label => 'zettarepl direct receive stream',
            command => qq{sh -c 'PATH=\$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs recv -F -s -u '\\'''disk11/backups/tim/cache_domains/Windows 11'\\''' 2>&1'},
            expected_lines => [qq{would run command: zfs recv -F -s -u 'disk11/backups/tim/cache_domains/Windows 11' 2>&1}],
        },
        {
            label => 'zettarepl receive abort',
            command => qq{sh -c 'PATH=\$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs recv -A '\\'''disk11/backups/tim/cache_domains/Windows 11'\\''' 2>&1'},
            expected_lines => [qq{would run command: zfs recv -A 'disk11/backups/tim/cache_domains/Windows 11' 2>&1}],
        },
        {
            label => 'zettarepl restore send stream',
            command => qq{sh -c 'PATH=\$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs send -w -p -e $snap1 2>&1'},
            expected_lines => [qq{would run command: zfs send -w -p -e $snap1 2>&1}],
        },
        {
            label => 'zettarepl get dataset type query (wrapped with 2>&1)',
            command => qq{sh -c 'PATH=\$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs get -H -p -t filesystem,volume type '\\'''disk11/backups/tim/cache_domains/Windows 11'\\''' 2>&1'},
            expected_lines => [qq{would run command: zfs get -H -p -t filesystem,volume type 'disk11/backups/tim/cache_domains/Windows 11' 2>&1}],
        },
        {
            label => 'unquoted dataset query',
            command => q{zfs get -H name disk11/backups/tim/cache_domains/Windows_11},
            expected_lines => ['would run command: zfs get -H name disk11/backups/tim/cache_domains/Windows_11'],
        },
        {
            label => 'zettarepl get dataset type query',
            command => q{zfs get -H -p -t filesystem,volume type disk1/mamma_offsite_backup/maskinbroderi},
            expected_lines => ['would run command: zfs get -H -p -t filesystem,volume type disk1/mamma_offsite_backup/maskinbroderi'],
        },
        {
            label => 'zettarepl list snapshots query (unquoted)',
            command => q{zfs list -t snapshot -H -o name -s name -r disk1/mamma_offsite_backup/maskinbroderi},
            expected_lines => ['would run command: zfs list -t snapshot -H -o name -s name -r disk1/mamma_offsite_backup/maskinbroderi'],
        },
        {
            label => 'zettarepl list datasets query (unquoted)',
            command => q{zfs list -t filesystem,volume -H -o name -s name -r disk1/mamma_offsite_backup/maskinbroderi},
            expected_lines => ['would run command: zfs list -t filesystem,volume -H -o name -s name -r disk1/mamma_offsite_backup/maskinbroderi'],
        },
        {
            label => 'zettarepl set readonly',
            command => q{zfs set readonly=on disk1/mamma_offsite_backup/maskinbroderi},
            expected_lines => ['would run command: zfs set readonly=on disk1/mamma_offsite_backup/maskinbroderi'],
        },
        {
            label => 'zettarepl inherit readonly',
            command => q{zfs inherit readonly disk1/mamma_offsite_backup/maskinbroderi},
            expected_lines => ['would run command: zfs inherit readonly disk1/mamma_offsite_backup/maskinbroderi'],
        },
        {
            label => 'zettarepl pool encryption query',
            command => q{zfs get -H -p -t filesystem,volume encryption disk1 2>&1},
            expected_lines => ['would run command: zfs get -H -p -t filesystem,volume encryption disk1 2>&1'],
        },
        {
            label => 'zettarepl umount dataset',
            command => q{zfs umount disk1/mamma_offsite_backup/maskinbroderi 2>&1},
            expected_lines => ['would run command: zfs umount disk1/mamma_offsite_backup/maskinbroderi 2>&1'],
        },
        {
            label => 'zettarepl probe recv -x',
            command => q{zfs recv -x 2>&1},
            expected_lines => ['would run command: zfs recv -x 2>&1'],
        },
        {
            label => 'create with safe options',
            command => qq{zfs create -u -p -o canmount=off $dataset},
            expected_lines => [qq{would run command: zfs create -u -p -o canmount=off $dataset}],
        },
        {
            label => 'direct receive with safe readonly=on option',
            command => qq{zfs receive -F -s -o readonly=on $dataset},
            expected_lines => [qq{would run command: zfs receive -F -s -o readonly=on $dataset}],
        },
        {
            label => 'paramiko wrapped single quote query',
            command => qq{sh -c 'PATH=\$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs get -H name '\\'''disk11/backups/tim/cache_domains/Windows 11'\\''' 2>&1'},
            expected_lines => [qq{would run command: zfs get -H name 'disk11/backups/tim/cache_domains/Windows 11' 2>&1}],
        },
    );

    for my $case (@cases) {
        assert_case($case->{label}, $case->{command}, $case->{expected_lines});
    }
};

subtest 'blocked commands' => sub {
    my $newline_attack = "echo ok\nls";

    my @cases = (
        {
            label => 'security validation bypass attempt',
            command => q{echo ok && ls},
            expected_lines => ['blocked command: echo ok && ls'],
        },
        {
            label => 'zfs version with arguments',
            command => q{zfs version extra},
            expected_lines => ['blocked command: zfs version extra'],
        },
        {
            label => 'zfs version chained',
            command => q{zfs version && id},
            expected_lines => ['blocked command: zfs version && id'],
        },
        {
            label => 'unauthorized zfs get property query',
            command => qq{zfs get -H keylocation $dataset},
            expected_lines => [qq{blocked command: zfs get -H keylocation $dataset}],
        },
        {
            label => 'shell chaining after allowed query',
            command => qq{zfs get -H name $dataset && id},
            expected_lines => [qq{blocked command: zfs get -H name $dataset && id}],
        },
        {
            label => 'unquoted dataset with space splits arguments',
            command => q{zfs get -H name disk11/backups/tim/cache_domains/Windows 11},
            expected_lines => ['blocked command: zfs get -H name disk11/backups/tim/cache_domains/Windows 11'],
        },
        {
            label => 'double quoted dataset',
            command => q{zfs get -H name "disk11/backups/tim/cache_domains/Windows 11"},
            expected_lines => ['blocked command: zfs get -H name "disk11/backups/tim/cache_domains/Windows 11"'],
        },
        {
            label => 'sudo-prefixed command',
            command => qq{sudo zfs get -H name $dataset},
            expected_lines => [qq{blocked command: sudo zfs get -H name $dataset}],
        },
        {
            label => 'sudo-prefixed zettarepl query',
            command => q{sudo zfs get -H -p -t filesystem,volume type disk1/mamma_offsite_backup/maskinbroderi},
            expected_lines => ['blocked command: sudo zfs get -H -p -t filesystem,volume type disk1/mamma_offsite_backup/maskinbroderi'],
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
            label => 'arbitrary stderr redirection',
            command => qq{zfs get -H name $dataset 2>/tmp/pwned},
            expected_lines => [qq{blocked command: zfs get -H name $dataset 2>/tmp/pwned}],
        },
        {
            label => 'stdout redirection',
            command => qq{zfs receive -A $dataset >/tmp/pwned},
            expected_lines => [qq{blocked command: zfs receive -A $dataset >/tmp/pwned}],
        },
        {
            label => 'pipeline to shell',
            command => qq{mbuffer  -q -s 128k -m 16M | zstdmt -dc | zfs receive -F $dataset 2>&1 | sh},
            expected_lines => [qq{blocked command: mbuffer  -q -s 128k -m 16M | zstdmt -dc | zfs receive -F $dataset 2>&1 | sh}],
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
            label => 'malicious follow-up after allowed dataset query',
            command => qq{zfs get -H name $dataset; rm -rf /},
            expected_lines => [
                qq{would run command: zfs get -H name $dataset},
                'blocked command: rm -rf /',
            ],
        },
        {
            label => 'zettarepl snapshot destroy attempt',
            command => qq{sh -c 'PATH=\$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs destroy '\\'''disk11/backups/tim/cache_domains/Windows 11\@autosnap_2026-04-23_06:15:01_daily'\\''' 2>&1'},
            expected_lines => [
                qq{blocked command: zfs destroy 'disk11/backups/tim/cache_domains/Windows 11\@autosnap_2026-04-23_06:15:01_daily' 2>&1},
            ],
        },
        {
            label => 'zettarepl chained injection attempt',
            command => q{sh -c 'PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin echo ok; id 2>&1'},
            expected_lines => [
                'would run command: echo ok',
                'blocked command: id 2>&1',
            ],
        },
        {
            label => 'mount attempt is blocked',
            command => q{zfs mount disk1/mamma_offsite_backup/foton},
            expected_lines => ['blocked command: zfs mount disk1/mamma_offsite_backup/foton'],
        },
        {
            label => 'command substitution in zfs create option',
            command => qq{zfs create -o mountpoint="\$(id)" $dataset},
            expected_lines => [qq{blocked command: zfs create -o mountpoint="\$(id)" $dataset}],
        },
        {
            label => 'backtick substitution in zfs create option',
            command => qq{zfs create -o mountpoint="`id`" $dataset},
            expected_lines => [qq{blocked command: zfs create -o mountpoint="`id`" $dataset}],
        },
        {
            label => 'mountpoint modification attempt in zfs create',
            command => qq{zfs create -o mountpoint=/mnt/evil $dataset},
            expected_lines => [qq{blocked command: zfs create -o mountpoint=/mnt/evil $dataset}],
        },
        {
            label => 'setuid enable attempt in zfs create',
            command => qq{zfs create -o setuid=on $dataset},
            expected_lines => [qq{blocked command: zfs create -o setuid=on $dataset}],
        },
        {
            label => 'exec enable attempt in zfs create',
            command => qq{zfs create -o exec=on $dataset},
            expected_lines => [qq{blocked command: zfs create -o exec=on $dataset}],
        },
        {
            label => 'disabling readonly via zfs set is blocked',
            command => qq{zfs set readonly=off $dataset},
            expected_lines => [qq{blocked command: zfs set readonly=off $dataset}],
        },
        {
            label => 'mountpoint modification attempt in zfs receive',
            command => qq{zfs receive -o mountpoint=/mnt/evil $dataset},
            expected_lines => [qq{blocked command: zfs receive -o mountpoint=/mnt/evil $dataset}],
        },
        {
            label => 'setuid enable attempt in zfs receive',
            command => qq{zfs receive -o setuid=on $dataset},
            expected_lines => [qq{blocked command: zfs receive -o setuid=on $dataset}],
        },
        {
            label => 'disabling readonly via zfs receive is blocked',
            command => qq{zfs receive -o readonly=off $dataset},
            expected_lines => [qq{blocked command: zfs receive -o readonly=off $dataset}],
        },
        {
            label => 'unbounded mbuffer memory allocation is blocked',
            command => qq{mbuffer  -q -s 128k -m 999999999M | zstdmt -dc | zfs receive -F $dataset 2>&1},
            expected_lines => [qq{blocked command: mbuffer  -q -s 128k -m 999999999M | zstdmt -dc | zfs receive -F $dataset 2>&1}],
        },
    );

    for my $case (@cases) {
        assert_case($case->{label}, $case->{command}, $case->{expected_lines});
    }
};

sub run_restrict_live {
    my ($command) = @_;

    local %ENV = %ENV;
    $ENV{SSH_ORIGINAL_COMMAND} = $command;

    my $stderr = gensym;
    my $pid = open3(undef, my $stdout, $stderr, $^X, $script);
    my $stdout_text = do { local $/; <$stdout> // '' };
    my $stderr_text = do { local $/; <$stderr> // '' };
    waitpid($pid, 0);

    return {
        exit_code => $? >> 8,
        stdout => $stdout_text,
        stderr => $stderr_text,
    };
}

subtest 'exit code propagation' => sub {
    my $res_ok = run_restrict_live('echo ok');
    is($res_ok->{exit_code}, 0, 'successful command exits 0');
    is($res_ok->{stdout}, "ok\n", 'successful command writes to stdout');

    my $res_fail = run_restrict_live('exit 42');
    is($res_fail->{exit_code}, 42, 'command exit status 42 propagated');

    my $res_blocked = run_restrict_live('id');
    is($res_blocked->{exit_code}, 1, 'blocked command exits 1');

    my $res_zfs_nonexistent = run_restrict_live(
        q{sh -c 'PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin zfs get -H -p -t filesystem,volume type nonexistent/test/dataset 2>&1'}
    );
    isnt($res_zfs_nonexistent->{exit_code}, 0, 'querying non-existent dataset exits non-zero');
    like($res_zfs_nonexistent->{stdout}, qr/(?:dataset does not exist|zfs: command not found)/, 'error output is redirected to stdout via 2>&1');
    is($res_zfs_nonexistent->{stderr}, '', 'stderr is empty when 2>&1 is used');
};

done_testing();