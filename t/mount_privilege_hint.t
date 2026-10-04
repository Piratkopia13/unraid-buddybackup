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
my $rc_script = File::Spec->catfile($plugin_dir, 'scripts', 'rc.buddybackup');
my $restrict_zfs = File::Spec->catfile($plugin_dir, 'deps', 'restrict_zfs');

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

my $rc = slurp($rc_script);
my $allowlist = slurp($restrict_zfs);

# Static guard: the detector helper and the user hint must be present so that a
# mount privilege failure during receive produces actionable guidance.
subtest 'rc.buddybackup carries the mount privilege detector and hint' => sub {
    like(
        $rc,
        qr/has_mount_privilege_error\s*\(\)/,
        'defines has_mount_privilege_error() helper'
    );

    like(
        $rc,
        qr/grep -q 'cannot mount'/,
        'detector matches the "cannot mount" failure text'
    );

    like(
        $rc,
        qr/grep -q 'Insufficient privileges'/,
        'detector matches the "Insufficient privileges" failure text'
    );

    like(
        $rc,
        qr/Hint: the received dataset could not be mounted on the target\./,
        'send failure output carries the user-facing mount hint'
    );

    like(
        $rc,
        qr/use a destination sub-dataset created with .+?mountpoint=none.+? so received backups inherit it/,
        'mount hint recommends a mountpoint=none destination sub-dataset'
    );

    like(
        $rc,
        qr/is a pool\/disk root; received child datasets inherit a real mountpoint/,
        'pool-root destination emits a warning about inherited mountpoints'
    );

    like(
        $rc,
        qr/has_mount_privilege_error "\$\{result\}"/,
        'send failure branch consults the detector before notifying'
    );
};

# Guard against the auto-mount temptation: the restricted allowlist must never
# permit `zfs mount` for the buddybackup user.
subtest 'restrict_zfs allowlist does not permit zfs mount' => sub {
    my $mount_lines = grep { /\bmount\b/ && /\bzfs\b/ } split /\n/, $allowlist;
    is($mount_lines, 0, 'no zfs mount command added to the restricted allowlist');

    unlike(
        $allowlist,
        qr/^\s*zfs\s+mount\b/m,
        'allowlist contains no bare "zfs mount" entry'
    );
};

done_testing();
