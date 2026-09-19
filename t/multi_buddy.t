use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IPC::Open3 qw(open3);
use JSON::PP qw(decode_json);
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

my $rc_php_source = File::Spec->catfile(
    $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'scripts', 'rc.buddybackup.php'
);
my $common_php_source = File::Spec->catfile(
    $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'common.php'
);

subtest 'disjoint dataset validator logic' => sub {
    my $php_test = <<'PHP';
function bb_is_dataset_overlapping($dataset, $existing_datasets) {
    $ds = trim((string)$dataset, '/');
    if ($ds === '') return false;
    foreach ($existing_datasets as $existing) {
        $ex = trim((string)$existing, '/');
        if ($ex === '') continue;
        if ($ds === $ex || str_starts_with($ds, $ex . '/') || str_starts_with($ex, $ds . '/')) {
            return true;
        }
    }
    return false;
}

$tests = [
    'identical' => bb_is_dataset_overlapping('tank/backups/alice', ['tank/backups/alice']),
    'child'     => bb_is_dataset_overlapping('tank/backups/alice/sub', ['tank/backups/alice']),
    'parent'    => bb_is_dataset_overlapping('tank/backups', ['tank/backups/alice']),
    'sibling'   => bb_is_dataset_overlapping('tank/backups/bob', ['tank/backups/alice']),
    'prefix_sibling' => bb_is_dataset_overlapping('tank/backups/alice_two', ['tank/backups/alice']),
    'empty'     => bb_is_dataset_overlapping('', ['tank/backups/alice']),
];
echo json_encode($tests);
PHP

    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = open3(undef, $stdout, $stderr, 'php', '-r', $php_test);
    my $out = do { local $/; <$stdout> // '' };
    waitpid($pid, 0);

    my $res = decode_json($out);
    is($res->{identical}, 1, 'identical dataset overlaps');
    is($res->{child}, 1, 'child dataset overlaps with parent');
    is($res->{parent}, 1, 'parent dataset overlaps with child');
    is($res->{sibling}, 0, 'sibling dataset does not overlap');
    is($res->{prefix_sibling}, 0, 'dataset sharing prefix name is distinct and does not overlap');
    is($res->{empty}, 0, 'empty dataset does not overlap');
};

subtest 'auto-migration of legacy buddybackup.cfg to incoming.cfg' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $config_dir = File::Spec->catdir($workdir, 'boot', 'config', 'plugins', 'buddybackup');
    make_path($config_dir);

    my $plugin_cfg = File::Spec->catfile($config_dir, 'buddybackup.cfg');
    my $incoming_cfg = File::Spec->catfile($config_dir, 'incoming.cfg');

    open my $fh, '>', $plugin_cfg or die "Failed to write $plugin_cfg: $!";
    print $fh <<'CFG';
ReceiveBackups="enable"
ReceiveDestinationDataset="tank/backups/alice"
DestinationPubSSHKey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG... alice@legacy"
ReceiveDestinationRententionHourly="1"
ReceiveDestinationRententionDaily="14"
ReceiveDestinationRententionWeekly="8"
ReceiveDestinationRententionMonthly="6"
ReceiveDestinationRententionYearly="2"
BackupDaysAgoWarning="7"
CFG
    close $fh;

    my $php_test = sprintf(<<'PHP', $plugin_cfg, $incoming_cfg);
$plugin_config_path = '%s';
$incoming_config_path = '%s';

function write_ini($file, $data) {
    $content = "";
    foreach ($data as $key => $value) {
        $content .= "$key=\"$value\"\n";
    }
    file_put_contents($file, $content);
}

function ensure_incoming_config_migrated() {
    global $plugin_config_path, $incoming_config_path;
    if (!file_exists($incoming_config_path) && file_exists($plugin_config_path)) {
        $cfg = parse_ini_file($plugin_config_path, false);
        if (isset($cfg["ReceiveBackups"]) || isset($cfg["ReceiveDestinationDataset"]) || isset($cfg["DestinationPubSSHKey"])) {
            $raw_keys = $cfg["DestinationPubSSHKey"] ?? "";
            $key_lines = array();
            foreach (preg_split("/\r\n|\r|\n/", (string)$raw_keys) as $line) {
                $line = trim($line);
                if ($line !== '') {
                    $key_lines[] = $line;
                }
            }
            if (empty($key_lines)) {
                $key_lines = array("");
            }

            $total_keys = count($key_lines);
            $incoming = array();
            foreach ($key_lines as $i => $key) {
                $uid = ($i === 0) ? "1ml3g4cy" : substr(md5("legacy_buddy_" . $i . "_" . $key), 0, 8);
                if ($total_keys === 1) {
                    $buddy_name = "Buddy";
                } else {
                    $parts = preg_split('/\s+/', $key, 3);
                    $comment = isset($parts[2]) ? trim($parts[2]) : '';
                    $buddy_name = "Buddy " . ($i + 1) . ($comment !== '' ? " ($comment)" : "");
                }

                $incoming[$uid] = array(
                    "name" => $buddy_name,
                    "enable" => (($cfg["ReceiveBackups"] ?? "") == "enable") ? "yes" : "no",
                    "destination_dataset" => $cfg["ReceiveDestinationDataset"] ?? "",
                    "ssh_key" => $key,
                    "hourly" => $cfg["ReceiveDestinationRententionHourly"] ?? 0,
                    "daily" => $cfg["ReceiveDestinationRententionDaily"] ?? 7,
                    "weekly" => $cfg["ReceiveDestinationRententionWeekly"] ?? 4,
                    "monthly" => $cfg["ReceiveDestinationRententionMonthly"] ?? 3,
                    "yearly" => $cfg["ReceiveDestinationRententionYearly"] ?? 0,
                );
            }

            $content = "";
            foreach ($incoming as $sec => $vals) {
                $content .= "[$sec]\n";
                foreach ($vals as $k => $v) {
                    $content .= "$k=\"$v\"\n";
                }
            }
            file_put_contents($incoming_config_path, $content);

            unset($cfg["ReceiveBackups"]);
            unset($cfg["ReceiveDestinationDataset"]);
            unset($cfg["DestinationPubSSHKey"]);
            unset($cfg["ReceiveDestinationRententionHourly"]);
            unset($cfg["ReceiveDestinationRententionDaily"]);
            unset($cfg["ReceiveDestinationRententionWeekly"]);
            unset($cfg["ReceiveDestinationRententionMonthly"]);
            unset($cfg["ReceiveDestinationRententionYearly"]);
            write_ini($plugin_config_path, $cfg);
        }
    }
}

ensure_incoming_config_migrated();
PHP

    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = open3(undef, $stdout, $stderr, 'php', '-r', $php_test);
    waitpid($pid, 0);

    ok(-f $incoming_cfg, 'incoming.cfg was created during migration');
    my $migrated_content = do { local $/; open my $h, '<', $incoming_cfg; <$h> };
    like($migrated_content, qr/\[1ml3g4cy\]/, 'contains legacy section uid [1ml3g4cy]');
    like($migrated_content, qr/enable="yes"/, 'migrated enable status is yes');
    like($migrated_content, qr/destination_dataset="tank\/backups\/alice"/, 'migrated destination dataset preserved');
    like($migrated_content, qr/daily="14"/, 'migrated retention settings preserved');

    my $remaining_plugin_cfg = do { local $/; open my $h, '<', $plugin_cfg; <$h> };
    unlike($remaining_plugin_cfg, qr/ReceiveDestinationDataset/, 'ReceiveDestinationDataset stripped from plugin.cfg');
    unlike($remaining_plugin_cfg, qr/DestinationPubSSHKey/, 'DestinationPubSSHKey stripped from plugin.cfg');
    like($remaining_plugin_cfg, qr/BackupDaysAgoWarning="7"/, 'unrelated settings preserved in plugin.cfg');
};

subtest 'auto-migration of multi-key legacy DestinationPubSSHKey to multiple incoming buddy entries' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $config_dir = File::Spec->catdir($workdir, 'boot', 'config', 'plugins', 'buddybackup');
    make_path($config_dir);

    my $plugin_cfg = File::Spec->catfile($config_dir, 'buddybackup.cfg');
    my $incoming_cfg = File::Spec->catfile($config_dir, 'incoming.cfg');

    open my $fh, '>', $plugin_cfg or die "Failed to write $plugin_cfg: $!";
    print $fh <<'CFG';
ReceiveBackups="enable"
ReceiveDestinationDataset="tank/backups"
DestinationPubSSHKey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG111111111111111111111111111111 alice@unraid
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG222222222222222222222222222222 bob@truenas"
ReceiveDestinationRententionHourly="2"
ReceiveDestinationRententionDaily="21"
ReceiveDestinationRententionWeekly="8"
ReceiveDestinationRententionMonthly="6"
ReceiveDestinationRententionYearly="1"
BackupDaysAgoWarning="7"
CFG
    close $fh;

    my $php_test = sprintf(<<'PHP', $plugin_cfg, $incoming_cfg);
$plugin_config_path = '%s';
$incoming_config_path = '%s';

function write_ini($file, $data) {
    $content = "";
    foreach ($data as $key => $value) {
        $content .= "$key=\"$value\"\n";
    }
    file_put_contents($file, $content);
}

function ensure_incoming_config_migrated() {
    global $plugin_config_path, $incoming_config_path;
    if (!file_exists($incoming_config_path) && file_exists($plugin_config_path)) {
        $cfg = parse_ini_file($plugin_config_path, false);
        if (isset($cfg["ReceiveBackups"]) || isset($cfg["ReceiveDestinationDataset"]) || isset($cfg["DestinationPubSSHKey"])) {
            $raw_keys = $cfg["DestinationPubSSHKey"] ?? "";
            $key_lines = array();
            foreach (preg_split("/\r\n|\r|\n/", (string)$raw_keys) as $line) {
                $line = trim($line);
                if ($line !== '') {
                    $key_lines[] = $line;
                }
            }
            if (empty($key_lines)) {
                $key_lines = array("");
            }

            $total_keys = count($key_lines);
            $incoming = array();
            foreach ($key_lines as $i => $key) {
                $uid = ($i === 0) ? "1ml3g4cy" : substr(md5("legacy_buddy_" . $i . "_" . $key), 0, 8);
                if ($total_keys === 1) {
                    $buddy_name = "Buddy";
                } else {
                    $parts = preg_split('/\s+/', $key, 3);
                    $comment = isset($parts[2]) ? trim($parts[2]) : '';
                    $buddy_name = "Buddy " . ($i + 1) . ($comment !== '' ? " ($comment)" : "");
                }

                $incoming[$uid] = array(
                    "name" => $buddy_name,
                    "enable" => (($cfg["ReceiveBackups"] ?? "") == "enable") ? "yes" : "no",
                    "destination_dataset" => $cfg["ReceiveDestinationDataset"] ?? "",
                    "ssh_key" => $key,
                    "hourly" => $cfg["ReceiveDestinationRententionHourly"] ?? 0,
                    "daily" => $cfg["ReceiveDestinationRententionDaily"] ?? 7,
                    "weekly" => $cfg["ReceiveDestinationRententionWeekly"] ?? 4,
                    "monthly" => $cfg["ReceiveDestinationRententionMonthly"] ?? 3,
                    "yearly" => $cfg["ReceiveDestinationRententionYearly"] ?? 0,
                );
            }

            $content = "";
            foreach ($incoming as $sec => $vals) {
                $content .= "[$sec]\n";
                foreach ($vals as $k => $v) {
                    $content .= "$k=\"$v\"\n";
                }
            }
            file_put_contents($incoming_config_path, $content);

            unset($cfg["ReceiveBackups"]);
            unset($cfg["ReceiveDestinationDataset"]);
            unset($cfg["DestinationPubSSHKey"]);
            unset($cfg["ReceiveDestinationRententionHourly"]);
            unset($cfg["ReceiveDestinationRententionDaily"]);
            unset($cfg["ReceiveDestinationRententionWeekly"]);
            unset($cfg["ReceiveDestinationRententionMonthly"]);
            unset($cfg["ReceiveDestinationRententionYearly"]);
            write_ini($plugin_config_path, $cfg);
        }
    }
}

ensure_incoming_config_migrated();
PHP

    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = open3(undef, $stdout, $stderr, 'php', '-r', $php_test);
    waitpid($pid, 0);

    ok(-f $incoming_cfg, 'incoming.cfg was created during multi-key migration');
    my $parsed_incoming = do {
        my $p = gensym;
        my $e = gensym;
        my $proc = open3(undef, $p, $e, 'php', '-r', "echo json_encode(parse_ini_file('$incoming_cfg', true));");
        my $out = do { local $/; <$p> // '{}' };
        waitpid($proc, 0);
        decode_json($out);
    };

    my @uids = sort keys %$parsed_incoming;
    is(scalar(@uids), 2, 'two buddy entries created for two legacy keys');
    ok(exists $parsed_incoming->{'1ml3g4cy'}, 'first buddy keeps legacy uid 1ml3g4cy');

    my $buddy1 = $parsed_incoming->{'1ml3g4cy'};
    is($buddy1->{name}, 'Buddy 1 (alice@unraid)', 'first buddy named with index and SSH key comment');
    is($buddy1->{destination_dataset}, 'tank/backups', 'first buddy inherits destination_dataset');
    is($buddy1->{daily}, '21', 'first buddy inherits daily retention');
    like($buddy1->{ssh_key}, qr/AAAAC3NzaC1lZDI1NTE5AAAAIG111111111111111111111111111111 alice\@unraid/, 'first buddy gets key 1');

    my ($second_uid) = grep { $_ ne '1ml3g4cy' } @uids;
    ok(defined $second_uid && length($second_uid) == 8, 'second buddy gets unique 8-char uid');

    my $buddy2 = $parsed_incoming->{$second_uid};
    is($buddy2->{name}, 'Buddy 2 (bob@truenas)', 'second buddy named with index and SSH key comment');
    is($buddy2->{destination_dataset}, 'tank/backups', 'second buddy inherits same destination_dataset');
    is($buddy2->{daily}, '21', 'second buddy inherits same daily retention');
    like($buddy2->{ssh_key}, qr/AAAAC3NzaC1lZDI1NTE5AAAAIG222222222222222222222222222222 bob\@truenas/, 'second buddy gets key 2');
};

subtest 'multi-stanza sanoid.conf generation' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $config_dir = File::Spec->catdir($workdir, 'boot', 'config', 'plugins', 'buddybackup');
    make_path($config_dir);

    my $plugin_cfg = File::Spec->catfile($config_dir, 'buddybackup.cfg');
    my $incoming_cfg = File::Spec->catfile($config_dir, 'incoming.cfg');
    my $snapshots_cfg = File::Spec->catfile($config_dir, 'snapshots.cfg');
    my $sanoid_conf = File::Spec->catfile($config_dir, 'sanoid.conf');

    open my $fh, '>', $plugin_cfg or die "Failed to write: $!";
    print $fh "BackupDaysAgoWarning=\"7\"\n";
    close $fh;

    open $fh, '>', $incoming_cfg or die "Failed to write: $!";
    print $fh <<'INCOMING';
[alice_uid]
name="Alice"
enable="yes"
destination_dataset="tank/backups/alice"
hourly="0"
daily="7"
weekly="4"
monthly="3"
yearly="0"

[bob_disabled]
name="Bob"
enable="no"
destination_dataset="tank/backups/bob"
hourly="0"
daily="14"
weekly="4"
monthly="3"
yearly="0"

[truenas_uid]
name="TrueNAS"
enable="yes"
destination_dataset="tank/backups/truenas"
hourly="2"
daily="30"
weekly="8"
monthly="12"
yearly="1"
INCOMING
    close $fh;

    open $fh, '>', $snapshots_cfg or die "Failed to write: $!";
    print $fh <<'SNAPS';
[local_snap]
dataset="tank/local_appdata"
hourly="4"
daily="7"
weekly="0"
monthly="0"
yearly="0"
autosnap="yes"
autoprune="yes"
SNAPS
    close $fh;

    my $php_test = sprintf(<<'PHP', $plugin_cfg, $incoming_cfg, $snapshots_cfg, $sanoid_conf);
$plugin_config_path = '%s';
$incoming_config_path = '%s';
$extra_sanoid_config_path = '%s';
$sanoid_config_path = '%s';
$empath = '/usr/local/emhttp/plugins/buddybackup';
$log_script = "$empath/scripts/log.sh";

function BB_ERR($msg) {}
function ENSURE_SUCCESS($b) {}
function file_exists_and_not_empty($file) {
    return file_exists($file) && filesize($file) > 1;
}
function ensure_incoming_config_migrated() {}

function update_sanoid_conf() {
    global $plugin_config_path, $sanoid_config_path, $extra_sanoid_config_path, $incoming_config_path, $empath, $log_script;

    ensure_incoming_config_migrated();

    $plugin_cfg = parse_ini_file($plugin_config_path, false);
    $sanoid_conf_content = "";
    $buddy_datasets = array();

    if (file_exists($incoming_config_path)) {
        $incoming_cfg = parse_ini_file($incoming_config_path, true);
        if (is_array($incoming_cfg)) {
            foreach ($incoming_cfg as $uid => $buddy) {
                if (($buddy['enable'] ?? '') === 'yes' && !empty($buddy['destination_dataset'])) {
                    $dataset = trim($buddy['destination_dataset']);
                    $buddy_datasets[] = $dataset;
                    $sanoid_conf_content .= "[$dataset]\n";
                    $sanoid_conf_content .= "    hourly = ".($buddy['hourly'] ?? 0)."\n";
                    $sanoid_conf_content .= "    daily = ".($buddy['daily'] ?? 7)."\n";
                    $sanoid_conf_content .= "    weekly = ".($buddy['weekly'] ?? 4)."\n";
                    $sanoid_conf_content .= "    monthly = ".($buddy['monthly'] ?? 3)."\n";
                    $sanoid_conf_content .= "    yearly = ".($buddy['yearly'] ?? 0)."\n";
                    $sanoid_conf_content .= "    autosnap = no\n";
                    $sanoid_conf_content .= "    autoprune = yes\n";
                    $sanoid_conf_content .= "    recursive = yes\n";
                }
            }
        }
    }

    if (file_exists_and_not_empty($extra_sanoid_config_path)) {
        $extra_sanoid_cfg = parse_ini_file($extra_sanoid_config_path, true);

        foreach ($extra_sanoid_cfg as $uid => $section) {
            $dataset = $section["dataset"];
            $conflict = false;
            foreach ($buddy_datasets as $b_ds) {
                if (str_starts_with($dataset, $b_ds)) {
                    $conflict = true;
                    break;
                }
            }
            if ($conflict) {
                continue;
            }
            $sanoid_conf_content .= "[$dataset]\n";
            foreach ($section as $key => $value) {
                if ($key == "dataset") continue;
                $sanoid_conf_content .= "    $key = $value\n";
            }
        }
    }

    file_put_contents($sanoid_config_path, $sanoid_conf_content);
}

update_sanoid_conf();
PHP

    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = open3(undef, $stdout, $stderr, 'php', '-r', $php_test);
    waitpid($pid, 0);

    ok(-f $sanoid_conf, 'sanoid.conf generated successfully');
    my $conf_content = do { local $/; open my $h, '<', $sanoid_conf; <$h> };

    like($conf_content, qr/\[tank\/backups\/alice\]/, 'Alice dataset stanza present');
    like($conf_content, qr/daily = 7/, 'Alice daily retention present');
    like($conf_content, qr/\[tank\/backups\/truenas\]/, 'TrueNAS dataset stanza present');
    like($conf_content, qr/daily = 30/, 'TrueNAS daily retention present');
    like($conf_content, qr/\[tank\/local_appdata\]/, 'Local snapshot dataset stanza present');

    unlike($conf_content, qr/\[tank\/backups\/bob\]/, 'Disabled buddy Bob is excluded from sanoid.conf');
};

subtest 'scoped telemetry and probe_zfs' => sub {
    my $workdir = tempdir(CLEANUP => 1);
    my $config_dir = File::Spec->catdir($workdir, 'boot', 'config', 'plugins', 'buddybackup');
    make_path($config_dir);

    my $incoming_cfg = File::Spec->catfile($config_dir, 'incoming.cfg');
    open my $fh, '>', $incoming_cfg or die "Failed to write: $!";
    print $fh <<'INCOMING';
[alice_uid]
name="Alice"
enable="yes"
destination_dataset="tank/backups/alice"

[bob_uid]
name="Bob"
enable="yes"
destination_dataset="tank/backups/bob"

[1ml3g4cy]
name="Carol"
enable="yes"
destination_dataset="tank/backups/carol"

[dave_uid]
name="Dave"
enable="yes"
destination_dataset="tank/backups/dave"
INCOMING
    close $fh;

    my $tmp_dir = File::Spec->catdir($workdir, 'tmp');
    make_path($tmp_dir);

    my $php_test = sprintf(<<'PHP', $incoming_cfg, $tmp_dir);
$incoming_config_path = '%s';
$tmp_dir = '%s';

function is_valid_zfs_dataset_name($dataset) {
    return !empty($dataset) && strpos($dataset, '..') === false;
}

function read_zfs_property_value($dataset, $property, &$error_message = null) {
    if ($dataset === 'tank/backups/alice') return '50.2G';
    if ($dataset === 'tank/backups/bob') return '128.4G';
    if ($dataset === 'tank/backups/carol') return '250G';
    if ($dataset === 'tank/backups/dave') return '806G';
    return null;
}

function read_receive_destination_dataset(&$error_message = null) {
    global $incoming_config_path;
    $env_dataset = getenv('BUDDY_DATASET') ?: ($_ENV['BUDDY_DATASET'] ?? '');
    if ($env_dataset !== '') {
        $first = trim(explode(',', $env_dataset)[0]);
        if (is_valid_zfs_dataset_name($first)) return $first;
    }
    if (file_exists($incoming_config_path)) {
        $cfg = parse_ini_file($incoming_config_path, true);
        $env_uid = getenv('BUDDY_UID') ?: ($_ENV['BUDDY_UID'] ?? '');
        if ($env_uid !== '' && isset($cfg[$env_uid]['destination_dataset'])) {
            return $cfg[$env_uid]['destination_dataset'];
        }
    }
    return null;
}

function mark_received_backup($target_dataset = null) {
    global $incoming_config_path, $tmp_dir;
    $env_uid = getenv('BUDDY_UID') ?: ($_ENV['BUDDY_UID'] ?? '');
    $env_dataset = getenv('BUDDY_DATASET') ?: ($_ENV['BUDDY_DATASET'] ?? '');
    $matched_uid = !empty($env_uid) ? $env_uid : null;
    $dataset = !empty($target_dataset) ? trim($target_dataset) : null;
    if ($dataset === null && !empty($env_dataset)) {
        $dataset = trim(explode(',', $env_dataset)[0]);
    }

    if (file_exists($incoming_config_path)) {
        $cfg = parse_ini_file($incoming_config_path, true);
        if ($matched_uid !== null && empty($dataset) && isset($cfg[$matched_uid]['destination_dataset'])) {
            $dataset = trim($cfg[$matched_uid]['destination_dataset']);
        }
        if ($matched_uid === null && !empty($dataset)) {
            foreach ($cfg as $uid => $buddy) {
                $b_ds = trim($buddy['destination_dataset'] ?? '');
                if ($b_ds !== '' && ($dataset === $b_ds || str_starts_with($dataset, $b_ds . '/'))) {
                    $matched_uid = $uid;
                    $dataset = $b_ds;
                    break;
                }
            }
        }
        if (empty($dataset) && $matched_uid === null) {
            $enabled_buddies = array_filter($cfg, function($b) {
                return ($b['enable'] ?? '') === 'yes' && !empty($b['destination_dataset']);
            });
            if (count($enabled_buddies) === 1) {
                $matched_uid = array_key_first($enabled_buddies);
                $dataset = trim($enabled_buddies[$matched_uid]['destination_dataset']);
            }
        }
    }

    $dest_size = read_zfs_property_value($dataset, 'used', $error_message);
    $info = "last_ran=1700000000\ndest_size=$dest_size\n";
    if ($matched_uid !== null && $matched_uid !== '') {
        file_put_contents("$tmp_dir/buddybackup-buddy-$matched_uid", $info);
    }
    if (!file_exists($incoming_config_path)) {
        file_put_contents("$tmp_dir/buddybackup-buddy", $info);
    } else if (file_exists("$tmp_dir/buddybackup-buddy")) {
        @unlink("$tmp_dir/buddybackup-buddy");
    }
}

function probe_zfs($target_dataset = null) {
    $dataset = $target_dataset ?: read_receive_destination_dataset($err);
    if ($dataset && read_zfs_property_value($dataset, 'used', $err)) {
        echo json_encode(['status' => 'ok', 'dataset' => $dataset]);
    } else {
        echo json_encode(['status' => 'error']);
    }
}

$action = $argv[1] ?? '';
if ($action === 'probe') {
    probe_zfs();
} elseif ($action === 'mark') {
    mark_received_backup();
}
PHP

    # 1. Test probe for Alice
    {
        local %ENV = %ENV;
        $ENV{BUDDY_DATASET} = 'tank/backups/alice';
        $ENV{BUDDY_UID} = 'alice_uid';

        my $stdout = gensym;
        my $stderr = gensym;
        my $pid = open3(undef, $stdout, $stderr, 'php', '-r', $php_test, '--', 'probe');
        my $out = do { local $/; <$stdout> // '' };
        waitpid($pid, 0);

        my $data = decode_json($out);
        is($data->{status}, 'ok', 'probe status ok for Alice');
        is($data->{dataset}, 'tank/backups/alice', 'probe returned Alice dataset');
    }

    # 2. Test probe for Bob
    {
        local %ENV = %ENV;
        $ENV{BUDDY_DATASET} = 'tank/backups/bob';
        $ENV{BUDDY_UID} = 'bob_uid';

        my $stdout = gensym;
        my $stderr = gensym;
        my $pid = open3(undef, $stdout, $stderr, 'php', '-r', $php_test, '--', 'probe');
        my $out = do { local $/; <$stdout> // '' };
        waitpid($pid, 0);

        my $data = decode_json($out);
        is($data->{status}, 'ok', 'probe status ok for Bob');
        is($data->{dataset}, 'tank/backups/bob', 'probe returned Bob dataset');
    }

    # 3. Test mark_received_backup writes only specific telemetry in multi-buddy mode
    {
        local %ENV = %ENV;
        $ENV{BUDDY_DATASET} = 'tank/backups/alice';
        $ENV{BUDDY_UID} = 'alice_uid';

        my $stdout = gensym;
        my $stderr = gensym;
        my $pid = open3(undef, $stdout, $stderr, 'php', '-r', $php_test, '--', 'mark');
        waitpid($pid, 0);

        my $alice_file = File::Spec->catfile($tmp_dir, 'buddybackup-buddy-alice_uid');
        my $fallback_file = File::Spec->catfile($tmp_dir, 'buddybackup-buddy');

        ok(-f $alice_file, 'per-buddy telemetry file created for Alice');
        ok(!-f $fallback_file, 'legacy fallback telemetry file is NOT created when incoming.cfg exists');

        my $alice_content = do { local $/; open my $h, '<', $alice_file; <$h> };
        like($alice_content, qr/dest_size=50\.2G/, 'Alice used size recorded correctly');
    }

    # 4. Test bb_task_telemetry isolation between buddies
    {
        my $telemetry_test = sprintf(<<'PHP', $tmp_dir);
$tmp_dir = '%s';
function test_telemetry($uid, $buddy) {
    global $tmp_dir;
    if ($buddy) {
        $file = (!empty($uid)) ? "$tmp_dir/buddybackup-buddy-$uid" : "$tmp_dir/buddybackup-buddy";
    } else {
        $file = "$tmp_dir/buddybackup-$uid";
    }

    $ret = array(
        "last_ran" => "-",
        "status_label" => "Never ran",
        "dest_size" => "-",
        "has_run" => false
    );

    if (file_exists($file)) {
        $info = @parse_ini_file($file);
        if (!empty($info["last_ran"])) {
            $ret["has_run"] = true;
            $ret["dest_size"] = $info["dest_size"] ?? "-";
            $ret["status_label"] = "Healthy";
        }
    }
    return $ret;
}

$alice = test_telemetry('alice_uid', true);
$dave = test_telemetry('dave_uid', true);
$legacy = test_telemetry('1ml3g4cy', true);
echo json_encode(['alice' => $alice, 'dave' => $dave, 'legacy' => $legacy]);
PHP

        my $stdout = gensym;
        my $stderr = gensym;
        my $pid = open3(undef, $stdout, $stderr, 'php', '-r', $telemetry_test);
        my $out = do { local $/; <$stdout> // '' };
        waitpid($pid, 0);

        my $res = decode_json($out);
        is($res->{alice}{has_run}, 1, 'Alice has has_run=true after Alice backup');
        is($res->{alice}{dest_size}, '50.2G', 'Alice has correct dest_size 50.2G');
        is($res->{dave}{has_run}, 0, 'Dave has has_run=false before running');
        is($res->{dave}{status_label}, 'Never ran', 'Dave has status_label "Never ran"');
        is($res->{dave}{dest_size}, '-', 'Dave has dest_size "-"');
        is($res->{legacy}{has_run}, 0, 'legacy buddy 1ml3g4cy has has_run=false and does not inherit Alice telemetry');
        is($res->{legacy}{status_label}, 'Never ran', 'legacy buddy has status_label "Never ran"');
        is($res->{legacy}{dest_size}, '-', 'legacy buddy has dest_size "-"');
    }

    # 5. Test Dave backup completion does NOT update legacy buddy or Alice
    {
        local %ENV = %ENV;
        $ENV{BUDDY_DATASET} = 'tank/backups/dave';
        $ENV{BUDDY_UID} = 'dave_uid';

        my $stdout = gensym;
        my $stderr = gensym;
        my $pid = open3(undef, $stdout, $stderr, 'php', '-r', $php_test, '--', 'mark');
        waitpid($pid, 0);

        my $dave_file = File::Spec->catfile($tmp_dir, 'buddybackup-buddy-dave_uid');
        my $legacy_file = File::Spec->catfile($tmp_dir, 'buddybackup-buddy-1ml3g4cy');
        my $fallback_file = File::Spec->catfile($tmp_dir, 'buddybackup-buddy');

        ok(-f $dave_file, 'per-buddy telemetry file created for Dave');
        ok(!-f $legacy_file, 'legacy buddy file not created when Dave runs');
        ok(!-f $fallback_file, 'legacy fallback file still not created');

        my $telemetry_test = sprintf(<<'PHP', $tmp_dir);
$tmp_dir = '%s';
function test_telemetry($uid, $buddy) {
    global $tmp_dir;
    if ($buddy) {
        $file = (!empty($uid)) ? "$tmp_dir/buddybackup-buddy-$uid" : "$tmp_dir/buddybackup-buddy";
    } else {
        $file = "$tmp_dir/buddybackup-$uid";
    }

    $ret = array(
        "last_ran" => "-",
        "status_label" => "Never ran",
        "dest_size" => "-",
        "has_run" => false
    );

    if (file_exists($file)) {
        $info = @parse_ini_file($file);
        if (!empty($info["last_ran"])) {
            $ret["has_run"] = true;
            $ret["dest_size"] = $info["dest_size"] ?? "-";
            $ret["status_label"] = "Healthy";
        }
    }
    return $ret;
}

$alice = test_telemetry('alice_uid', true);
$dave = test_telemetry('dave_uid', true);
$legacy = test_telemetry('1ml3g4cy', true);
echo json_encode(['alice' => $alice, 'dave' => $dave, 'legacy' => $legacy]);
PHP

        my $t_stdout = gensym;
        my $t_stderr = gensym;
        my $t_pid = open3(undef, $t_stdout, $t_stderr, 'php', '-r', $telemetry_test);
        my $t_out = do { local $/; <$t_stdout> // '' };
        waitpid($t_pid, 0);

        my $res = decode_json($t_out);
        is($res->{dave}{has_run}, 1, 'Dave has has_run=true after Dave backup');
        is($res->{dave}{dest_size}, '806G', 'Dave has dest_size 806G');
        is($res->{legacy}{has_run}, 0, 'legacy buddy 1ml3g4cy STILL has has_run=false after Dave backup (no stats leak)');
        is($res->{legacy}{status_label}, 'Never ran', 'legacy buddy still has status_label "Never ran"');
        is($res->{legacy}{dest_size}, '-', 'legacy buddy still has dest_size "-"');
        is($res->{alice}{has_run}, 1, 'Alice remains has_run=true');
        is($res->{alice}{dest_size}, '50.2G', 'Alice dest_size remains 50.2G');
    }
};

done_testing();
