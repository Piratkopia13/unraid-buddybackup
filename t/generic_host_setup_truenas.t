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

subtest 'TrueNAS SCALE allowlist location' => sub {
    like($setup_source, qr/ALLOWLIST_DIR="\/usr\/local\/sbin"/, 'generic hosts keep the /usr/local/sbin default');
    like($setup_source, qr/truenas_allowlist_dir\(\)/, 'TrueNAS allowlist dir derivation present');
    like($setup_source, qr/\$\{mp\}\/\.buddybackup/, 'TrueNAS allowlist dir is a hidden .buddybackup dir on the pool mountpoint');
    like($setup_source, qr/"\/mnt\/\$\{pool\}"/, 'TrueNAS fallback uses the canonical /mnt/<pool> mountpoint');
    like($setup_source, qr/ALLOWLIST_PATH_RE/, 'allowlist path charset validation present');
    like($setup_source, qr/allowlist-dir must be an absolute path/, 'allowlist dir validation message present');
    like($setup_source, qr/--allowlist-dir requires a non-empty value/, 'empty --allowlist-dir value rejected');
    like($setup_source, qr/mounts its root filesystem read-only/, 'TrueNAS read-only root filesystem guidance present');
    like($setup_source, qr/--allowlist-dir \/mnt\/<pool>\/\.buddybackup/, 'TrueNAS guidance suggests a data pool location');
};

subtest 'allowlist is untouchable by the SSH user' => sub {
    like($setup_source, qr/must be owned by root so \$\{USER_NAME\} cannot replace/, 'pre-existing user-owned allowlist dir is refused, not claimed');
    like($setup_source, qr/user_path_test -w "\$\{ALLOWLIST_DIR\}"/, 'setup refuses a user-writable allowlist dir');
    like($setup_source, qr/user_path_test -w "\$\{allowlist_parent\}"/, 'setup refuses a user-writable allowlist parent');
    like($setup_source, qr/user_path_test\(\)/, 'user-level path checks run as the restricted user');
    like($setup_source, qr/runuser -u "\$USER_NAME" -- test/, 'user path checks use runuser');
    like($setup_source, qr/chown 0:0 "\$\{ALLOWLIST_DIR\}"/, 'freshly created allowlist dir is chowned to root');
    like($setup_source, qr/chmod 755 "\$\{ALLOWLIST_DIR\}"/, 'allowlist dir is world traversable for the SSH user');
    like($setup_source, qr/chown 0:0 "\$\{ALLOWLIST_PATH\}"/, 'installed allowlist file is root-owned');
    like($setup_source, qr/stat -c %u "\$\{ALLOWLIST_PATH\}"/, 'verify checks allowlist root ownership');
    like($setup_source, qr/allowlist script is root-owned and not writable by \$\{USER_NAME\}/, 'verify asserts the allowlist is not user-writable');
    like($setup_source, qr/allowlist script is executable by \$\{USER_NAME\}/, 'verify asserts the SSH user can execute the allowlist');
    like($setup_source, qr/allowlist location is writable by \$\{USER_NAME\}/, 'verify detects later user-writable allowlist locations');
};

subtest 'override flag plumbing' => sub {
    like($setup_source, qr/--allowlist-dir PATH/, 'usage documents --allowlist-dir');
    like($setup_source, qr/ALLOWLIST_DIR_ARG/, 'allowlist dir override is parsed');
    like($setup_source, qr/--role\|--user\|--dataset\|--pubkey\|--port\|--sudo-mode\|--allowlist-dir\)/, 'override value is presence-checked like the other options');
    like($setup_source, qr/if \[ -n "\$ALLOWLIST_DIR_ARG" \]; then/, 'override takes precedence over the defaults');
};

subtest 'TrueNAS operator guidance' => sub {
    like($setup_source, qr/The forced-command allowlist lives at \$\{ALLOWLIST_PATH\}/, 'reminders point at the installed allowlist location');
    like($setup_source, qr/Deleting or moving it breaks SSH/, 'reminders warn against removing the allowlist');
};

done_testing();
