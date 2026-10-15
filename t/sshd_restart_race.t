use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
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

ok(-f $rc_script, "rc.buddybackup exists");

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

sub write_script {
    my ($path, $body) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print $fh $body;
    close $fh;
    chmod 0755, $path;
}

sub extract_bash_function {
    my ($text, $func_name) = @_;
    if ($text =~ /(^$func_name\(\)\s*\{.*?\n\})/ms) {
        return $1;
    }
    die "Could not extract function $func_name";
}

my $content = slurp($rc_script);

my $setup_buddy_user_code = extract_bash_function($content, 'setup_buddy_user');
my $disable_backups_code  = extract_bash_function($content, 'disable_backups_from_buddy');
my $reload_sshd_code      = extract_bash_function($content, 'reload_sshd');
my $sshd_is_running_code  = extract_bash_function($content, 'sshd_is_running');

subtest 'static analysis: restarting sshd must not race OpenSSH pid file handling' => sub {
    like($sshd_is_running_code, qr/\bpgrep\b|\bpidof\b/, 'liveness helper inspects the process table');
    like($reload_sshd_code, qr/sshd_is_running/, 'reload_sshd consults the liveness helper');

    my ($fallback) = $reload_sshd_code =~ /if sshd_is_running; then\s+return 0\s+fi(.*)/s;
    like($fallback // q{}, qr{/usr/sbin/sshd}, 'manual sshd start only runs after the liveness check passed');
    unlike($reload_sshd_code, qr/\bkill -0\b/, 'does not use the pid file to test liveness (races the unlink)');
    unlike($content, qr/\bkill -0\b/, 'no remaining pid-file liveness checks anywhere in rc.buddybackup');
};

subtest 'static analysis: sshd_config edits restart sshd only on actual change' => sub {
    unlike($content, qr/\brestart_sshd\b/, 'no unconditional restart flag remains');
    like($setup_buddy_user_code, qr/sshd_config_checksum_before/, 'setup_buddy_user remembers the config before editing');
    like($setup_buddy_user_code, qr/md5sum/, 'setup_buddy_user compares the config after editing');
    like($setup_buddy_user_code, qr/reload_sshd/, 'setup_buddy_user restarts via the shared helper');
    like($disable_backups_code, qr/sshd_config_checksum_before/, 'disable_backups_from_buddy remembers the config before editing');
    like($disable_backups_code, qr/md5sum/, 'disable_backups_from_buddy compares the config after editing');
    like($setup_buddy_user_code, qr/Match\[\[:space:\]\]\+User/, 'Match User detection tolerates whitespace variants');
};

my $mocks = sub {
    my ($workdir, $bin_dir, $log_file) = @_;

    for my $tool (qw(useradd usermod groupadd groupdel userdel mkdir chmod chown touch)) {
        write_script(File::Spec->catfile($bin_dir, $tool), "#!/bin/bash\nexit 0\n");
    }

    write_script(File::Spec->catfile($bin_dir, 'rm'), "#!/bin/bash\nexit 0\n");
    write_script(File::Spec->catfile($bin_dir, 'zfs'), "#!/bin/bash\nexit 0\n");

    write_script(File::Spec->catfile($bin_dir, 'id'), <<'SH');
#!/bin/bash
# Report the buddybackup user/group as existing so user/group repair is skipped
exit 0
SH

    write_script(File::Spec->catfile($bin_dir, 'getent'), <<'SH');
#!/bin/bash
exit 0
SH
};

sub build_runner {
    my ($workdir, $bin_dir, $log_file, $code, $call) = @_;
    my $test_runner = File::Spec->catfile($workdir, 'run_test.sh');
    write_script($test_runner, <<"SH");
#!/bin/bash
set -e
export PATH="$bin_dir:\$PATH"
username="buddybackup"
sshd_config="$workdir/sshd_config"

# Helper functions referenced by the extracted code
zfs_json_dataset_names() { echo ""; }

$code

# Stub the restart helper so the test records it without touching real sshd
reload_sshd() { echo "reload_sshd \$@" >> "$log_file"; }

$call
SH
    return $test_runner;
}

subtest 'no AllowUsers line: config is untouched and sshd is NOT restarted' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);
    my $log_file = File::Spec->catfile($workdir, 'calls.log');
    write_script($log_file, "");

    my $sshd_config = File::Spec->catfile($workdir, 'sshd_config');
    open my $fh, '>', $sshd_config or die $!;
    print $fh <<'CONF';
# limetech - we need to allow root
PermitRootLogin yes
Match User buddybackup
    PasswordAuthentication no
CONF
    close $fh;

    my $before = slurp($sshd_config);

    $mocks->($workdir, $bin_dir, $log_file);
    my $runner = build_runner($workdir, $bin_dir, $log_file, $setup_buddy_user_code, 'setup_buddy_user');

    my $out = `bash "$runner" 2>&1`;
    is($? >> 8, 0, "setup_buddy_user executed successfully: $out");
    is(slurp($sshd_config), $before, 'sshd_config is byte-identical when there is no AllowUsers line');
    is(slurp($log_file), '', 'no sshd restart attempted when nothing changed');
};

subtest 'outdated AllowUsers and missing Match block: edits are applied and reloaded once' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);
    my $log_file = File::Spec->catfile($workdir, 'calls.log');
    write_script($log_file, "");

    my $sshd_config = File::Spec->catfile($workdir, 'sshd_config');
    open my $fh, '>', $sshd_config or die $!;
    print $fh <<'CONF';
AllowUsers root
PermitRootLogin yes
CONF
    close $fh;

    $mocks->($workdir, $bin_dir, $log_file);
    my $runner = build_runner($workdir, $bin_dir, $log_file, $setup_buddy_user_code, 'setup_buddy_user');

    my $out = `bash "$runner" 2>&1`;
    is($? >> 8, 0, "setup_buddy_user executed successfully: $out");

    my $after = slurp($sshd_config);
    like($after, qr/^AllowUsers root buddybackup$/m, 'buddybackup was appended to AllowUsers');
    like($after, qr/^Match User buddybackup$/m, 'Match User block was appended');

    my $calls = slurp($log_file);
    is(scalar(my @reloads = ($calls =~ /^reload_sshd/mg)), 1, 'sshd restarted exactly once');
};

subtest 'indented Match block is detected and not duplicated' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);
    my $log_file = File::Spec->catfile($workdir, 'calls.log');
    write_script($log_file, "");

    my $sshd_config = File::Spec->catfile($workdir, 'sshd_config');
    open my $fh, '>', $sshd_config or die $!;
    print $fh <<'CONF';
AllowUsers root buddybackup
  Match User buddybackup
    PasswordAuthentication no
CONF
    close $fh;

    my $before = slurp($sshd_config);

    $mocks->($workdir, $bin_dir, $log_file);
    my $runner = build_runner($workdir, $bin_dir, $log_file, $setup_buddy_user_code, 'setup_buddy_user');

    my $out = `bash "$runner" 2>&1`;
    is($? >> 8, 0, "setup_buddy_user executed successfully: $out");
    is(slurp($sshd_config), $before, 'indented Match User block is recognized as present');
    is(slurp($log_file), '', 'no sshd restart attempted when nothing changed');
};

subtest 'disable_backups_from_buddy removes entries and reloads exactly once' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);
    my $log_file = File::Spec->catfile($workdir, 'calls.log');
    write_script($log_file, "");

    my $sshd_config = File::Spec->catfile($workdir, 'sshd_config');
    open my $fh, '>', $sshd_config or die $!;
    print $fh <<'CONF';
AllowUsers root buddybackup
PermitRootLogin yes
Match User buddybackup
    PasswordAuthentication no
Match Group root
AllowTcpForwarding yes
CONF
    close $fh;

    $mocks->($workdir, $bin_dir, $log_file);
    my $runner = build_runner($workdir, $bin_dir, $log_file, $disable_backups_code, 'disable_backups_from_buddy');

    my $out = `bash "$runner" 2>&1`;
    is($? >> 8, 0, "disable_backups_from_buddy executed successfully: $out");

    my $after = slurp($sshd_config);
    like($after, qr/^AllowUsers root$/m, 'buddybackup was removed from AllowUsers');
    like($after, qr/^Match Group root$/m, 'unrelated Match Group block kept');
    unlike($after, qr/buddybackup/, 'no buddybackup entries left');

    my $calls = slurp($log_file);
    is(scalar(my @reloads = ($calls =~ /^reload_sshd/mg)), 1, 'sshd restarted exactly once');
};

done_testing();
