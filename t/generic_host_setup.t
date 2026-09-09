use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Spec;
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

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $content = <$fh>;
    $content =~ s/\n\z//;
    return $content;
}

my $setup_script;
my $repo_root;
for my $candidate_root (@repo_root_candidates) {
    my $candidate_script = File::Spec->catfile(
        $candidate_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', 'generic_host_setup.sh'
    );
    if (-f $candidate_script) {
        $setup_script = $candidate_script;
        $repo_root = $candidate_root;
        last;
    }
}

ok(defined $setup_script && -f $setup_script, 'generic_host_setup.sh exists');

BAIL_OUT('Unable to locate generic_host_setup.sh from test path or current working directory') if !defined $setup_script;

my $setup_source = do {
    open my $fh, '<', $setup_script or die "Unable to read $setup_script: $!";
    local $/;
    <$fh>;
};

sub extract_heredoc {
    my ($source, $marker, $test_label) = @_;

    my $match = $source =~ m/<<'$marker'\n(.*?)\n$marker\n/s;
    ok($match, "$test_label heredoc block present") or return undef;
    return $1;
}

subtest 'embedded allowlist copies match deps' => sub {
    my $restrict_zfs_heredoc = extract_heredoc($setup_source, 'BUDDYBACKUP_RESTRICT_ZFS_EOF', 'receiver allowlist');
    my $restrict_zfs_send_heredoc = extract_heredoc($setup_source, 'BUDDYBACKUP_RESTRICT_ZFS_SEND_EOF', 'sender allowlist');

    plan skip_all => 'heredoc blocks not found' if !defined $restrict_zfs_heredoc || !defined $restrict_zfs_send_heredoc;

    my $restrict_zfs_path = File::Spec->catfile(
        $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', 'restrict_zfs'
    );
    my $restrict_zfs_send_path = File::Spec->catfile(
        $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', 'restrict_zfs_send'
    );

    is($restrict_zfs_heredoc, read_file($restrict_zfs_path), 'receiver allowlist heredoc is byte-identical to deps/restrict_zfs');
    is($restrict_zfs_send_heredoc, read_file($restrict_zfs_send_path), 'sender allowlist heredoc is byte-identical to deps/restrict_zfs_send');
};

subtest 'setup script structure' => sub {
    like($setup_source, qr/Usage: generic_host_setup\.sh/, 'usage text present');
    like($setup_source, qr/--role receiver\|sender/, 'usage documents role values');
    like($setup_source, qr/--sudo-mode auto\|yes\|no/, 'usage documents sudo-mode values');
    like($setup_source, qr/--verify/, 'usage documents verify mode');
    like($setup_source, qr/DRY_RUN=1/, 'dry-run support present');

    like($setup_source, qr/restrict,command="%s" %s\\n/, 'forced-command authorized_keys line format present');
    like($setup_source, qr/mountpoint=none/, 'receiver mountpoint=none handling present');
    like($setup_source, qr/send:raw/, 'send:raw delegation attempt present');
    like($setup_source, qr/visudo -cf/, 'sudoers validated with visudo before install');
    like($setup_source, qr/sshd_bin" -t/, 'sshd config validated before reload');
    like($setup_source, qr/Allowed sudo commands with no password/, 'TrueNAS SCALE sudo UI instructions present');
    like($setup_source, qr/Auxiliary Parameters/, 'TrueNAS SCALE sshd Auxiliary Parameters instructions present');
    like($setup_source, qr/rewrites authorized_keys and removes the/, 'TrueNAS authorized_keys rewrite caveat documented');
    like($setup_source, qr/\$\{ALLOWLIST_PATH\}\.sudo/, 'sudo mode flag file managed next to allowlist');
    like($setup_source, qr/NOPASSWD: \/usr\/bin\/bash -c \*/, 'coarse sudo grant matches allowlist execution mode');
    like($setup_source, qr/runuser -u "\$USER_NAME" --/, 'user-level checks use runuser');
    like($setup_source, qr/grep -qi truenas \/etc\/version/, 'TrueNAS SCALE detection present');
};

done_testing();
