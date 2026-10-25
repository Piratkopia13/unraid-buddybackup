use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
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

my $content = slurp($rc_script);

sub extract_bash_function {
    my ($text, $func_name) = @_;
    if ($text =~ /(^$func_name\(\)\s*\{.*?\n\})/ms) {
        return $1;
    }
    die "Could not extract function $func_name";
}

my $setup_buddy_user_code = extract_bash_function($content, 'setup_buddy_user');
my $disable_backups_code  = extract_bash_function($content, 'disable_backups_from_buddy');

subtest 'static analysis: self-healing receiver user and group setup' => sub {
    # 1. Verify self-healing group logic
    like($content, qr/getent group "\$\{username\}"/, "Checks for existing group in getent");
    like($content, qr/groupadd.*"\$\{username\}"/, "Adds group if missing");
    like($content, qr/groupadd -g "\$\{user_gid\}" "\$\{username\}"/, "Attempts to add group with matching user_gid");

    # 2. Verify user repair logic
    like($content, qr/usermod -g "\$\{username\}" "\$\{username\}"/, "Ensures primary group is set");
    like($content, qr/usermod -d "\/home\/\$\{username\}" -s \/bin\/bash "\$\{username\}"/, "Restores home directory and bash shell");
    like($content, qr/usermod -p "\$\{repair_pwd\}" "\$\{username\}"/, "Sets unguessable password hash to clear shadow lock");
    like($content, qr/usermod -U "\$\{username\}"/, "Unlocks account");

    # 3. Verify directory permissions and ownership
    like($content, qr/chmod 700 "\/home\/\$\{username\}" "\/home\/\$\{username\}\/\.ssh"/, "Secures home directory and .ssh mode to 700");
    like($content, qr/chown -R "\$\{username\}:\$\{username\}" "\/home\/\$\{username\}\/"/, "Correctly chowns home directory recursively");

    # 4. Verify clean group deletion on disable_backups_from_buddy
    like($content, qr/groupdel "\$\{username\}"/, "Deletes group in disable_backups_from_buddy");
};

subtest 'behavioral simulation: post-reboot repair when user exists but group and home are missing' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);

    my $log_file = File::Spec->catfile($workdir, 'commands.log');
    open my $init_log, '>', $log_file or die $!;
    close $init_log;

    my $write_script = sub {
        my ($path, $body) = @_;
        open my $fh, '>', $path or die "Cannot write $path: $!";
        print $fh $body;
        close $fh;
        chmod 0755, $path;
    };

    # Mock shadow and coreutils
    $write_script->(File::Spec->catfile($bin_dir, 'useradd'), <<"SH");
#!/bin/bash
echo "useradd \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'usermod'), <<"SH");
#!/bin/bash
echo "usermod \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'groupadd'), <<"SH");
#!/bin/bash
echo "groupadd \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'groupdel'), <<"SH");
#!/bin/bash
echo "groupdel \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'id'), <<"SH");
#!/bin/bash
echo "id \$@" >> "$log_file"
if [[ "\$1" == "-g" ]]; then
    echo "1003"
    exit 0
fi
# Simulated user buddybackup already exists
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'getent'), <<"SH");
#!/bin/bash
echo "getent \$@" >> "$log_file"
# group buddybackup missing, GID 1003 missing
exit 1
SH

    $write_script->(File::Spec->catfile($bin_dir, 'mkdir'), <<"SH");
#!/bin/bash
echo "mkdir \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'chmod'), <<"SH");
#!/bin/bash
echo "chmod \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'chown'), <<"SH");
#!/bin/bash
echo "chown \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'touch'), <<"SH");
#!/bin/bash
echo "touch \$@" >> "$log_file"
exit 0
SH

    my $test_runner = File::Spec->catfile($workdir, 'run_test.sh');
    $write_script->($test_runner, <<"SH");
#!/bin/bash
set -e
export PATH="$bin_dir:\$PATH"
username="buddybackup"
sshd_config="$workdir/sshd_config"

cat << 'EOF' > "\$sshd_config"
AllowUsers buddybackup
Match User buddybackup
EOF

$setup_buddy_user_code

setup_buddy_user
SH

    my $out = `bash "$test_runner" 2>&1`;
    my $exit_code = $? >> 8;
    is($exit_code, 0, "setup_buddy_user executed successfully: $out");

    my $log_content = slurp($log_file);
    unlike($log_content, qr/^useradd/m, "useradd was NOT called because user already exists");
    like($log_content, qr/^groupadd -g 1003 buddybackup/m, "groupadd with matching GID 1003 was called");
    like($log_content, qr/^usermod -g buddybackup buddybackup/m, "usermod set primary group to buddybackup");
    like($log_content, qr/^usermod -d \/home\/buddybackup -s \/bin\/bash buddybackup/m, "usermod restored home to /home/buddybackup and shell to /bin/bash");
    like($log_content, qr/^usermod -p \S+ buddybackup/m, "usermod set random password to ensure account is not locked in shadow");
    like($log_content, qr/^usermod -U buddybackup/m, "usermod unlocked buddybackup account");
    like($log_content, qr/^chmod 700 \/home\/buddybackup \/home\/buddybackup\/\.ssh/m, "chmod 700 secured home and .ssh directory");
    like($log_content, qr/^chown -R buddybackup:buddybackup \/home\/buddybackup\//m, "chown -R set recursive ownership to buddybackup:buddybackup");
};

subtest 'behavioral simulation: GID collision fallback when GID is taken' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);

    my $log_file = File::Spec->catfile($workdir, 'commands.log');
    open my $init_log, '>', $log_file or die $!;
    close $init_log;

    my $write_script = sub {
        my ($path, $body) = @_;
        open my $fh, '>', $path or die "Cannot write $path: $!";
        print $fh $body;
        close $fh;
        chmod 0755, $path;
    };

    $write_script->(File::Spec->catfile($bin_dir, 'useradd'), "exit 0\n");
    $write_script->(File::Spec->catfile($bin_dir, 'usermod'), "exit 0\n");
    $write_script->(File::Spec->catfile($bin_dir, 'mkdir'), "exit 0\n");
    $write_script->(File::Spec->catfile($bin_dir, 'chmod'), "exit 0\n");
    $write_script->(File::Spec->catfile($bin_dir, 'chown'), "exit 0\n");
    $write_script->(File::Spec->catfile($bin_dir, 'touch'), "exit 0\n");

    $write_script->(File::Spec->catfile($bin_dir, 'groupadd'), <<"SH");
#!/bin/bash
echo "groupadd \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'id'), <<"SH");
#!/bin/bash
if [[ "\$1" == "-g" ]]; then
    echo "1003"
    exit 0
fi
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'getent'), <<"SH");
#!/bin/bash
# group buddybackup does NOT exist (exit 1)
# BUT group 1003 DOES exist (taken by something else, exit 0)
if [[ "\$2" == "buddybackup" ]]; then
    exit 1
fi
if [[ "\$2" == "1003" ]]; then
    exit 0
fi
exit 1
SH

    my $test_runner = File::Spec->catfile($workdir, 'run_test.sh');
    $write_script->($test_runner, <<"SH");
#!/bin/bash
set -e
export PATH="$bin_dir:\$PATH"
username="buddybackup"
sshd_config="$workdir/sshd_config"

cat << 'EOF' > "\$sshd_config"
AllowUsers buddybackup
Match User buddybackup
EOF

$setup_buddy_user_code

setup_buddy_user
SH

    my $out = `bash "$test_runner" 2>&1`;
    is($? >> 8, 0, "setup_buddy_user executed successfully when GID 1003 is taken: $out");

    my $log_content = slurp($log_file);
    like($log_content, qr/^groupadd buddybackup/m, "fallback groupadd without -g was called when GID was already taken");
    unlike($log_content, qr/^groupadd -g 1003 buddybackup/m, "groupadd -g 1003 was skipped");
};

subtest 'behavioral simulation: fresh install creates user, group, and permissions' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);

    my $log_file = File::Spec->catfile($workdir, 'commands.log');
    open my $init_log, '>', $log_file or die $!;
    close $init_log;

    my $write_script = sub {
        my ($path, $body) = @_;
        open my $fh, '>', $path or die "Cannot write $path: $!";
        print $fh $body;
        close $fh;
        chmod 0755, $path;
    };

    $write_script->(File::Spec->catfile($bin_dir, 'useradd'), <<"SH");
#!/bin/bash
echo "useradd \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'usermod'), <<"SH");
#!/bin/bash
echo "usermod \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'groupadd'), <<"SH");
#!/bin/bash
echo "groupadd \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'id'), <<"SH");
#!/bin/bash
# User does NOT exist yet
exit 1
SH

    $write_script->(File::Spec->catfile($bin_dir, 'getent'), <<"SH");
#!/bin/bash
exit 1
SH

    $write_script->(File::Spec->catfile($bin_dir, 'mkdir'), "exit 0\n");
    $write_script->(File::Spec->catfile($bin_dir, 'chmod'), "exit 0\n");
    $write_script->(File::Spec->catfile($bin_dir, 'chown'), "exit 0\n");
    $write_script->(File::Spec->catfile($bin_dir, 'touch'), "exit 0\n");

    my $test_runner = File::Spec->catfile($workdir, 'run_test.sh');
    $write_script->($test_runner, <<"SH");
#!/bin/bash
set -e
export PATH="$bin_dir:\$PATH"
username="buddybackup"
sshd_config="$workdir/sshd_config"

cat << 'EOF' > "\$sshd_config"
AllowUsers buddybackup
Match User buddybackup
EOF

$setup_buddy_user_code

setup_buddy_user
SH

    my $out = `bash "$test_runner" 2>&1`;
    is($? >> 8, 0, "setup_buddy_user executed successfully for fresh install: $out");

    my $log_content = slurp($log_file);
    like($log_content, qr/^useradd -m -s \/bin\/bash -p \S+ buddybackup/m, "useradd creates user with home and bash");
};

subtest 'behavioral simulation: disable_backups_from_buddy cleans up user and group' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $bin_dir = File::Spec->catdir($workdir, 'bin');
    make_path($bin_dir);

    my $log_file = File::Spec->catfile($workdir, 'commands.log');
    open my $init_log, '>', $log_file or die $!;
    close $init_log;

    my $write_script = sub {
        my ($path, $body) = @_;
        open my $fh, '>', $path or die "Cannot write $path: $!";
        print $fh $body;
        close $fh;
        chmod 0755, $path;
    };

    $write_script->(File::Spec->catfile($bin_dir, 'userdel'), <<"SH");
#!/bin/bash
echo "userdel \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'groupdel'), <<"SH");
#!/bin/bash
echo "groupdel \$@" >> "$log_file"
exit 0
SH

    $write_script->(File::Spec->catfile($bin_dir, 'rm'), "exit 0\n");
    $write_script->(File::Spec->catfile($bin_dir, 'mkdir'), "exit 0\n");
    $write_script->(File::Spec->catfile($bin_dir, 'zfs'), "exit 0\n");

    my $test_runner = File::Spec->catfile($workdir, 'run_test.sh');
    $write_script->($test_runner, <<"SH");
#!/bin/bash
set -e
export PATH="$bin_dir:\$PATH"
username="buddybackup"
sshd_config="$workdir/sshd_config"
touch "\$sshd_config"

# Helper function referenced in disable_backups_from_buddy
zfs_json_dataset_names() { echo ""; }

$disable_backups_code

disable_backups_from_buddy
SH

    my $out = `bash "$test_runner" 2>&1`;
    is($? >> 8, 0, "disable_backups_from_buddy executed successfully: $out");

    my $log_content = slurp($log_file);
    like($log_content, qr/^userdel buddybackup/m, "userdel buddybackup was called");
    like($log_content, qr/^groupdel buddybackup/m, "groupdel buddybackup was called");
};

done_testing();
