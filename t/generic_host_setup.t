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

    plan skip_all => 'heredoc block not found' if !defined $restrict_zfs_heredoc;

    my $restrict_zfs_path = File::Spec->catfile(
        $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', 'restrict_zfs'
    );

    is($restrict_zfs_heredoc, read_file($restrict_zfs_path), 'receiver allowlist heredoc is byte-identical to deps/restrict_zfs');
};

subtest 'setup script structure' => sub {
    like($setup_source, qr/Usage: generic_host_setup\.sh/, 'usage text present');
    like($setup_source, qr/--role\)/, 'accepts role receiver option');
    like($setup_source, qr/--sudo-mode auto\|yes\|no/, 'usage documents sudo-mode values');
    like($setup_source, qr/--verify/, 'usage documents verify mode');
    like($setup_source, qr/DRY_RUN=1/, 'dry-run support present');

    like($setup_source, qr/restrict,command="%s" %s\\n/, 'forced-command authorized_keys line format present');
    like($setup_source, qr/mountpoint=none/, 'receiver mountpoint=none handling present');
    like($setup_source, qr/readonly=on/, 'receiver readonly=on handling present');
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

subtest 'setup script safety properties' => sub {
    like($setup_source, qr/set -o nounset/, 'nounset enabled');
    like($setup_source, qr/Option \$1 requires a value/, 'option values are presence-checked (no infinite loop on a missing value)');
    like($setup_source, qr/wc -l\)" -gt 0/, 'pubkey containing any newline is rejected (authorized_keys injection guard)');
    like($setup_source, qr/resolves to UID 0/, 'root/UID-0 user is refused (SSH lockout guard)');
    like($setup_source, qr/currently MOUNTED/, 'mountpoint=none is never forced onto a mounted dataset');
    like($setup_source, qr/zfs unallow -u "\$USER_NAME" "send"/, 'stale plain send grant is removed when send:raw is available');
    like($setup_source, qr/mktemp "\/etc\/sudoers\.d\/\.buddybackup-/, 'sudoers entry is installed atomically from a dot-skipped temp file');
    like($setup_source, qr/mktemp "\$\{ssh_dir\}\/\.authorized_keys\.XXXXXX"/, 'authorized_keys is replaced atomically');
    like($setup_source, qr/mktemp "\$\{dropin_dir\}\/\.buddybackup-\$\{USER_NAME\}\.XXXXXX"/, 'sshd drop-in is installed atomically from a dotfile temp');
    like($setup_source, qr/drop-in removed again/, 'sshd drop-in is rolled back when config validation fails');
    like($setup_source, qr/remove_sudoers/, 'leftover sudoers entry is removed when sudo mode is disabled');
    like($setup_source, qr/ERRORS is deliberately not reset/, 'verify() preserves setup errors');
    like($setup_source, qr/sudo mode requested \(--sudo-mode yes\) but flag missing/, 'verify() detects a missing sudo flag for explicit sudo mode');
};

subtest 'dataset scope file management' => sub {
    like($setup_source, qr/printf '%s\\n' "\$\{scope_ds\}"/, 'scope file writer emits one plain dataset name per line');
    like($setup_source, qr/one configured dataset per line/, 'scope file documents its plain-name format');
    like($setup_source, qr/never contain quotes, commas or indentation/, 'scope file writer warns the format must stay plain names');
    like($setup_source, qr/filter_scope_file "\$f"/, 'revoke mode rewrites scope files with the plain-name filter');
    like($setup_source, qr/tab-separated or quoted rewrite would silently drop/, 'scope filter documents why the state-file filter must not be used');
    like($setup_source, qr/filter_scope_file\(\)/, 'scope filter function is defined');
    like($setup_source, qr/\.buddybackup-scope\.XXXXXX/, 'scope file is rewritten atomically from a dotfile temp');
    like($setup_source, qr/compare them byte-exactly/, 'verify() compares the scope file byte-exactly against the configured datasets');
    like($setup_source, qr/dataset scope file at \$\{scope_file\} does not match/, 'verify() detects a scope file that drifted from the configured datasets');
    like($setup_source, qr/dataset scope file at \$\{scope_file\} is empty/, 'verify() detects an empty scope file (which would deny everything)');
    like($setup_source, qr/buddybackup-\$\{USER_NAME\}-restrict_zfs\.datasets/, 'revoke mode filters the receiver allowlist scope file');
    like($setup_source, qr/ALLOWLIST_PATH="\$\{ALLOWLIST_DIR\}\/buddybackup-\$\{USER_NAME\}-restrict_zfs"/, 'receiver allowlist path is per-user');
    like($setup_source, qr/remove_buddybackup_files/, 'clean removes allowlist and state files');
};

done_testing();
