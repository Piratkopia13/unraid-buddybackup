#!/usr/bin/php
<?php
$verbose = false; // Enable to get more info printed to syslog

$plugin = "buddybackup";
$plugin_path = "/boot/config/plugins/$plugin";
$plugin_config_path = "/boot/config/plugins/$plugin/$plugin.cfg";
$backups_config_path = "$plugin_path/backups.cfg";
$sanoid_config_path = "$plugin_path/sanoid.conf";
$extra_sanoid_config_path = "$plugin_path/snapshots.cfg";
$sanoid_cron_path = "$plugin_path/sanoid.cron";
$tmp_recv_dataset_path = "/tmp/buddybackup-recv-dest";
$incoming_config_path = "$plugin_path/incoming.cfg";

$buddybackup_path = '/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin';
$current_path = getenv('PATH') ?: '';
$normalized_path = $buddybackup_path . ($current_path !== '' ? ":$current_path" : '');
putenv("PATH=$normalized_path");
$_ENV['PATH'] = $normalized_path;
$_SERVER['PATH'] = $normalized_path;

$empath = "/usr/local/emhttp/plugins/buddybackup";
$sanoid_bin = "$empath/deps/sanoid";
$log_script = "$empath/scripts/log.sh";
$rc = $empath."/scripts/rc.buddybackup";
$managed_known_hosts_path = "$plugin_path/buddybackup_known_hosts";

function BB_LOG($msg) {
    global $plugin;
    syslog(LOG_INFO, "$plugin: $msg");
}
function BB_ERR($msg) {
    global $plugin;
    global $log_script;
    syslog(LOG_ERR, "$plugin: ERROR: $msg");
    exec('echo "'.$msg.'" | '.$log_script);
}
function BB_WARN($msg) {
    global $plugin;
    global $log_script;
    syslog(LOG_WARNING, "$plugin: WARN: $msg");
    exec('echo "'.$msg.'" | '.$log_script);
}
function BB_VERBOSE($msg) {
    global $verbose;
    if ($verbose) BB_LOG($msg);
}
function ENSURE_SUCCESS($b) {
    if (!$b) {
        debug_print_backtrace();
        die("Error!");
    }
}

function write_ini($file, $data) {
    $content = "";
    foreach ($data as $key => $value) {
        $content .= "$key=\"$value\"\n";
    }
    ENSURE_SUCCESS(file_put_contents($file, $content)!==false);
}

function file_exists_and_not_empty($file) {
    return file_exists($file) && filesize($file) > 1;
}

function ensure_managed_known_hosts_file() {
    global $managed_known_hosts_path;

    $known_hosts_dir = dirname($managed_known_hosts_path);
    if (!is_dir($known_hosts_dir)) {
        ENSURE_SUCCESS(mkdir($known_hosts_dir, 0700, true) || is_dir($known_hosts_dir));
    }

    ENSURE_SUCCESS(file_put_contents($managed_known_hosts_path, '', FILE_APPEND) !== false);
    @chmod($managed_known_hosts_path, 0600);
}

function is_valid_zfs_dataset_name($dataset) {
    if ($dataset === '' || !is_string($dataset)) {
        return false;
    }

    if (preg_match('/[\x00-\x1F\x7F]/', $dataset)) {
        return false;
    }

    if (strpos($dataset, '@') !== false || strpos($dataset, '#') !== false) {
        return false;
    }

    $parts = explode('/', $dataset);
    if (empty($parts)) {
        return false;
    }

    foreach ($parts as $part) {
        if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9_.: -]*$/', $part)) {
            return false;
        }
    }

    return true;
}

function is_valid_remote_host($host) {
    return preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]*$/', $host) === 1;
}

function normalize_remote_identity($user, $port, &$error_message = null) {
    $user = trim((string)$user);
    $port = trim((string)$port);

    if ($user === '') {
        $user = 'buddybackup';
    }
    if ($port === '') {
        $port = '22';
    }

    if (preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]*$/', $user) !== 1) {
        $error_message = "Invalid remote user name '$user'.";
        return null;
    }

    if (preg_match('/^\d{1,5}$/', $port) !== 1 || (int)$port < 1 || (int)$port > 65535) {
        $error_message = "Invalid remote port '$port'.";
        return null;
    }

    return array('user' => $user, 'port' => $port);
}

function resolve_remote_identity_from_cfg($cfg, $prefix, &$error_message = null) {
    return normalize_remote_identity($cfg[$prefix.'_user'] ?? '', $cfg[$prefix.'_port'] ?? '', $error_message);
}

function read_receive_destination_dataset(&$error_message = null) {
    global $tmp_recv_dataset_path, $incoming_config_path;

    // Check environment variable BUDDY_DATASET (set by restrict_zfs for current SSH connection)
    $env_dataset = getenv('BUDDY_DATASET') ?: ($_ENV['BUDDY_DATASET'] ?? '');
    if ($env_dataset !== '') {
        $first = trim(explode(',', $env_dataset)[0]);
        if (is_valid_zfs_dataset_name($first)) {
            return $first;
        }
    }

    // Check incoming.cfg
    if (file_exists($incoming_config_path)) {
        $incoming_cfg = parse_ini_file($incoming_config_path, true);
        if (is_array($incoming_cfg)) {
            $env_uid = getenv('BUDDY_UID') ?: ($_ENV['BUDDY_UID'] ?? '');
            if ($env_uid !== '' && isset($incoming_cfg[$env_uid]['destination_dataset'])) {
                $ds = trim($incoming_cfg[$env_uid]['destination_dataset']);
                if (is_valid_zfs_dataset_name($ds)) {
                    return $ds;
                }
            }
            foreach ($incoming_cfg as $uid => $buddy) {
                if (($buddy['enable'] ?? '') === 'yes' && !empty($buddy['destination_dataset'])) {
                    $ds = trim($buddy['destination_dataset']);
                    if (is_valid_zfs_dataset_name($ds)) {
                        return $ds;
                    }
                }
            }
        }
    }

    if (!file_exists($tmp_recv_dataset_path)) {
        $error_message = 'Buddy receive destination dataset is not configured.';
        return null;
    }

    $dataset = trim((string)file_get_contents($tmp_recv_dataset_path));
    if ($dataset === '') {
        $error_message = 'Buddy receive destination dataset is not configured.';
        return null;
    }

    if (!is_valid_zfs_dataset_name($dataset)) {
        $error_message = 'Buddy receive destination dataset is invalid.';
        return null;
    }

    return $dataset;
}

function read_zfs_property_value($dataset, $property, &$error_message = null) {
    $output = array();
    $result_code = 0;

    exec("zfs get -j " . escapeshellarg($property) . " " . escapeshellarg($dataset) . " 2>&1", $output, $result_code);
    if ($result_code !== 0) {
        $error_message = implode("\n", $output);
        return null;
    }

    $decoded = json_decode(implode("\n", $output), true);
    $value = $decoded['datasets'][$dataset]['properties'][$property]['value'] ?? null;
    if (!is_string($value)) {
        $error_message = "Invalid JSON output from zfs get for dataset '$dataset' and property '$property'.";
        return null;
    }

    return $value;
}

function write_probe_zfs_response($status, $dataset = null, $message = null) {
    $response = array('status' => $status);

    if ($dataset !== null) {
        $response['dataset'] = $dataset;
    }

    if ($message !== null) {
        $response['message'] = $message;
    }

    echo json_encode($response, JSON_UNESCAPED_SLASHES);
}

function write_json_response($response) {
    echo json_encode($response, JSON_UNESCAPED_SLASHES);
}

function build_shell_command($parts) {
    return implode(' ', array_map(function($part) {
        return escapeshellarg((string)$part);
    }, $parts));
}

function load_backup_config_entry($uid, &$error_message = null) {
    global $backups_config_path;

    $backup_cfg = parse_ini_file($backups_config_path, true);
    if (!is_array($backup_cfg) || !array_key_exists($uid, $backup_cfg)) {
        $error_message = "Backup with uid '$uid' does not exist.";
        return null;
    }

    return $backup_cfg[$uid];
}

function run_task_command($cmd, $echo_pid) {
    $result_code = null;

    if ($echo_pid) {
        start_long_running_task_echo_pid($cmd);
        return null;
    }

    passthru($cmd, $result_code);
    return $result_code;
}

function build_send_backup_command($cfg, $uid, &$error_message = null) {
    global $rc;

    if ($cfg['type'] == 'local') {
        return build_shell_command(array(
            $rc,
            'send_local_backup',
            $cfg['source_dataset'],
            $cfg['recursive'],
            $cfg['destination_dataset'],
            $uid,
        ));
    }

    if ($cfg['type'] == 'remote') {
        return build_shell_command(array(
            $rc,
            'send_backup',
            'remote',
            $cfg['source_dataset'],
            $cfg['recursive'],
            $cfg['destination_host'],
            $cfg['destination_dataset'],
            $uid,
        ));
    }

    if ($cfg['type'] == 'remote_generic') {
        $identity = resolve_remote_identity_from_cfg($cfg, 'destination', $error_message);
        if ($identity === null) {
            return null;
        }
        return build_shell_command(array(
            $rc,
            'send_backup',
            'remote_generic',
            $cfg['source_dataset'],
            $cfg['recursive'],
            $cfg['destination_host'],
            $cfg['destination_dataset'],
            $uid,
            $identity['user'],
            $identity['port'],
        ));
    }

    $error_message = "Unknown backup type: ".($cfg['type'] ?? '');
    return null;
}

function build_create_snapshot_and_send_command($cfg, $uid, &$error_message = null) {
    global $rc;

    $parts = array(
        $rc,
        'create_snapshot_and_send',
        $cfg['type'],
        $cfg['source_dataset'],
        $cfg['recursive'],
        $cfg['destination_host'] ?? '',
        $cfg['destination_dataset'],
        $uid,
    );

    if ($cfg['type'] == 'remote_generic') {
        $identity = resolve_remote_identity_from_cfg($cfg, 'destination', $error_message);
        if ($identity === null) {
            return null;
        }
        $parts[] = $identity['user'];
        $parts[] = $identity['port'];
    }

    return build_shell_command($parts);
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

function sync_incoming_buddies() {
    global $rc, $incoming_config_path, $empath, $tmp_recv_dataset_path;

    ensure_incoming_config_migrated();

    if (!file_exists($incoming_config_path)) {
        return;
    }

    $incoming_cfg = parse_ini_file($incoming_config_path, true);
    if (!is_array($incoming_cfg)) {
        return;
    }

    $enabled_buddies = array();
    foreach ($incoming_cfg as $uid => $buddy) {
        if (($buddy['enable'] ?? '') === 'yes' && !empty($buddy['destination_dataset'])) {
            $enabled_buddies[$uid] = $buddy;
        }
    }

    if (empty($enabled_buddies)) {
        passthru($rc . ' disable_backups_from_buddy');
        if (file_exists($tmp_recv_dataset_path)) {
            @unlink($tmp_recv_dataset_path);
        }
        return;
    }

    passthru($rc . ' setup_buddy_user');

    $authorized_keys = "";
    $first_dataset = null;

    foreach ($enabled_buddies as $uid => $buddy) {
        $dataset = trim($buddy['destination_dataset']);
        if (!is_valid_zfs_dataset_name($dataset)) {
            BB_ERR("Invalid destination dataset '$dataset' for buddy UID '$uid'");
            continue;
        }

        if ($first_dataset === null) {
            $first_dataset = $dataset;
        }

        if (strpos($dataset, '/') === false) {
            BB_LOG("Destination parent dataset '$dataset' is a pool root; mountpoint=none and readonly=on skipped to avoid unmounting pool root.");
        }

        passthru(build_shell_command(array($rc, 'allow_buddy_dataset', $dataset)));

        $raw_key = trim($buddy['ssh_key'] ?? '');
        if ($raw_key === '') continue;

        $first_line = strtok($raw_key, "\r\n");
        $trimmed_key = trim($first_line ?: '');
        if ($trimmed_key === '') continue;

        $cmd_line = "$empath/deps/restrict_zfs --dataset " . escapeshellarg($dataset) . " --uid " . escapeshellarg($uid);
        $authorized_keys .= 'restrict,command="' . str_replace('"', '\"', $cmd_line) . '" ' . $trimmed_key . "\n";
    }

    $auth_keys_path = "/home/buddybackup/.ssh/authorized_keys";
    if (is_dir("/home/buddybackup/.ssh")) {
        file_put_contents($auth_keys_path, $authorized_keys);
        @chmod($auth_keys_path, 0644);
        @chown($auth_keys_path, 'buddybackup');
        @chgrp($auth_keys_path, 'buddybackup');
    }

    if ($first_dataset !== null) {
        file_put_contents($tmp_recv_dataset_path, $first_dataset);
    }

    if (file_exists("/tmp/buddybackup-buddy")) {
        @unlink("/tmp/buddybackup-buddy");
    }
}

// update() runs on system boot, on plugin install/update, and when backup settings are changed.
function update() {
    global $rc;
    global $plugin_config_path;
    global $extra_sanoid_config_path;
    global $incoming_config_path;
    global $tmp_recv_dataset_path;

    ensure_incoming_config_migrated();

    $plugin_cfg = parse_ini_file($plugin_config_path, false);
    // Set config defaults
    {
        $any_changed = false;
        $set_default = function($key, $default) use (&$any_changed, &$plugin_cfg) {
            if (!array_key_exists($key, $plugin_cfg)) {
                $plugin_cfg[$key] = $default;
                $any_changed = true;
                BB_VERBOSE("Added key '$key' with default value '$default' to cfg.");
            }
        };
        $set_default("BackupDaysAgoWarning", "7");
        $set_default("BackupDaysAgoCritical", "30");
        $set_default("BuddysBackupDaysAgoWarning", "7");
        $set_default("BuddysBackupDaysAgoCritical", "30");
        $set_default("UtcTimezone", "no");
        $set_default("AllowUnencryptedRemoteBackups", "no");

        if ($any_changed) {
            write_ini($plugin_config_path, $plugin_cfg);
        }
    }

    passthru($rc.' update');    
    update_backups_from_config();

    update_sanoid_conf();

    $any_buddy_enabled = false;
    if (file_exists($incoming_config_path)) {
        $incoming_cfg = parse_ini_file($incoming_config_path, true);
        if (is_array($incoming_cfg)) {
            foreach ($incoming_cfg as $buddy) {
                if (($buddy['enable'] ?? '') === 'yes') {
                    $any_buddy_enabled = true;
                    break;
                }
            }
        }
    } else if (($plugin_cfg["ReceiveBackups"] ?? '') == "enable") {
        $any_buddy_enabled = true;
    }

    if ($any_buddy_enabled || file_exists_and_not_empty($extra_sanoid_config_path)) {
        enable_sanoid_cron();
    } else {
        disable_sanoid_cron();
    }

    sync_incoming_buddies();
}

function disable_sanoid_cron() {
    global $sanoid_cron_path;
    if (file_exists($sanoid_cron_path)) {
        ENSURE_SUCCESS(unlink($sanoid_cron_path));
    }
    passthru("/usr/local/sbin/update_cron");
}

function update_sanoid_conf() {
    global $plugin_config_path;
    global $sanoid_config_path;
    global $extra_sanoid_config_path;
    global $incoming_config_path;
    global $empath;
    global $log_script;

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
                    if (in_array($dataset, $buddy_datasets)) {
                        continue;
                    }
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
    } else if (($plugin_cfg["ReceiveBackups"] ?? '') == "enable" && !empty($plugin_cfg["ReceiveDestinationDataset"])) {
        $dataset = $plugin_cfg["ReceiveDestinationDataset"];
        $buddy_datasets[] = $dataset;
        $sanoid_conf_content .= "[$dataset]\n";
        $sanoid_conf_content .= "    hourly = ".$plugin_cfg["ReceiveDestinationRententionHourly"]."\n";
        $sanoid_conf_content .= "    daily = ".$plugin_cfg["ReceiveDestinationRententionDaily"]."\n";
        $sanoid_conf_content .= "    weekly = ".$plugin_cfg["ReceiveDestinationRententionWeekly"]."\n";
        $sanoid_conf_content .= "    monthly = ".$plugin_cfg["ReceiveDestinationRententionMonthly"]."\n";
        $sanoid_conf_content .= "    yearly = ".$plugin_cfg["ReceiveDestinationRententionYearly"]."\n";
        $sanoid_conf_content .= "    autosnap = no\n";
        $sanoid_conf_content .= "    autoprune = yes\n";
        $sanoid_conf_content .= "    recursive = yes\n";
    }
    
    // save manual entries from "snapshot creation and pruning" section in settings
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
                BB_ERR("Buddy's destination dataset '$dataset' also specified in 'Snapshot creation and pruning' section. Remove it from there!");
                continue;
            }
            $sanoid_conf_content .= "[$dataset]\n";
            foreach ($section as $key => $value) {
                if ($key == "dataset") continue;
                if ($key == "trigger") {
                    if (empty($value) || $value == "no") continue;
                    $cmd = "$empath/scripts/rc.buddybackup.php send_backup \"$value\" 2>&1 | $log_script";
                    $sanoid_conf_content .= "    post_snapshot_script = $cmd\n";
                    continue;
                }

                $sanoid_conf_content .= "    $key = $value\n";
            }
        }
    }

    ENSURE_SUCCESS(file_put_contents($sanoid_config_path, $sanoid_conf_content)!==false);
}

function enable_sanoid_cron() {
    global $sanoid_cron_path;
    global $sanoid_bin;
    global $buddybackup_path;
    global $plugin_path;
    global $log_script;
    global $plugin_config_path;
    $plugin_cfg = parse_ini_file($plugin_config_path, false);
    if (file_exists($sanoid_cron_path)) {
        ENSURE_SUCCESS(unlink($sanoid_cron_path));
    }
    $tz = ($plugin_cfg["UtcTimezone"] == "yes") ? "TZ=UTC" : "";
    $command_env = "PATH=$buddybackup_path" . ($tz !== "" ? " $tz" : "");
    $cron_content = "# Generated cron settings for plugin buddybackup\n";
    $cron_content .= "*/15 * * * * flock -n /var/lock/buddybackup-sanoid-cron -c \"$command_env $sanoid_bin --configdir=\"$plugin_path\" --cron\" 2>&1 | $log_script\n";
    ENSURE_SUCCESS(file_put_contents($sanoid_cron_path, $cron_content)!==false);
    BB_VERBOSE("Created $sanoid_cron_path");
    passthru("/usr/local/sbin/update_cron");
}

function add_backup_cron_file($uid, $cfg) {
    global $plugin_path;
    global $empath;
    global $log_script;

    $cron_content = "# Generated cron settings for plugin buddybackup\n";
    $cron_content .= $cfg["backup_cron"] . " flock -n \"/var/lock/buddybackup-$uid\" -c \"$empath/scripts/rc.buddybackup.php send_backup $uid\" 2>&1 | $log_script\n";
    ENSURE_SUCCESS(file_put_contents("$plugin_path/backup-$uid.cron", $cron_content)!==false);
    BB_VERBOSE("Created $plugin_path/backup-$uid.cron");
}

function update_backups_from_config() {
    BB_LOG("Updating backup cronjobs");
    global $managed_known_hosts_path;
    global $plugin_path;
    global $backups_config_path;
    global $rc;
    $backup_cfg = parse_ini_file($backups_config_path, true);

    // Remove all backup cron files from $plugin_path
    $files = scandir($plugin_path);
    foreach($files as $file) {
        if(preg_match("/^backup-\w{8}.cron$/", $file) && !is_dir("$plugin_path/$file")) {
            ENSURE_SUCCESS(unlink("$plugin_path/$file"));
            BB_VERBOSE("Deleted $plugin_path/$file");
        }
    }

    // Remove all buddybackup entries in known_hosts file
    passthru($rc.' clear_known_hosts');
    ensure_managed_known_hosts_file();
    $known_hosts_path = $managed_known_hosts_path;
    $known_hosts_content = "# buddybackup start\n";

    $destination_hosts = [];
    foreach ($backup_cfg as $uid => $cfg) {
        $type = $cfg['type'] ?? '';
        $is_local = $type == "local";
        $destination_host = trim((string)($cfg['destination_host'] ?? ''));

        // append targets as known hosts. This gets rid of strange hostfile_replace_entries/update_known_hosts errors during remote ssh commands
        // This is done as long as a host is set regardless if backups are enabled or not since we still need to eg. run get_available_snapshots
        if (!$is_local && $destination_host !== '') {
            $port = '22';
            if ($type == 'remote_generic') {
                $identity = resolve_remote_identity_from_cfg($cfg, 'destination');
                if ($identity !== null) {
                    $port = $identity['port'];
                }
            }
            $destination_hosts[$destination_host.'|'.$port] = array('host' => $destination_host, 'port' => $port);
        }

        $allow_empty = array();
        if ($is_local) {
            $allow_empty = array('destination_host');
        } else if ($type == 'remote_generic') {
            $allow_empty = array('destination_user', 'destination_port');
        }

        $any_empty = false;
        foreach ($cfg as $key => $value) {
            if (empty($value)) {
                if (in_array($key, $allow_empty, true)) continue;

                $any_empty = true;
                BB_VERBOSE("Skipped backup uid $uid because of empty field $key");
                break;
            }
        }
        if ($cfg["enable"] != "yes" || $any_empty) {
            BB_VERBOSE("Skipped backup uid $uid");
            continue;
        }

        add_backup_cron_file($uid, $cfg);
    }

    $destination_host_keys = array_keys($destination_hosts);
    sort($destination_host_keys, SORT_STRING);

    foreach ($destination_host_keys as $destination_host_key) {
        $entry = $destination_hosts[$destination_host_key];
        $command = 'ssh-keyscan';
        if ($entry['port'] != '22') {
            $command .= ' -p '.escapeshellarg($entry['port']);
        }
        $command .= ' '.escapeshellarg($entry['host']).' 2>/dev/null';
        if ($key = shell_exec($command)) {
            $known_hosts_content .= rtrim($key, "\r\n") . "\n";
        }
    }

    $known_hosts_content .= "# buddybackup end\n";
    ENSURE_SUCCESS(file_put_contents($known_hosts_path, $known_hosts_content, LOCK_EX)!==false);
    @chmod($known_hosts_path, 0600);

    passthru("/usr/local/sbin/update_cron");
}

function start_long_running_task_echo_pid($cmd) {
    $descriptorspec = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w']
    ];
    $proc = proc_open($cmd, $descriptorspec, $pipes);
    $proc_details = proc_get_status($proc);
    $pid = $proc_details['pid'];
    echo $pid;
}

function restore_snapshot($argv) {
    // uid is passed as first argument. Convert it to destination hostname if type is remote, otherwise passthrough all other args to rc.buddybackup
    $uid = $argv[2];
    $error_message = null;
    $cfg = load_backup_config_entry($uid, $error_message);
    if ($cfg === null) {
        echo $error_message;
        return;
    }

    BB_LOG("restore_snapshot ".$uid);

    if ($cfg["type"] == "remote") {
        $cmd = build_shell_command(array(
            $GLOBALS['rc'],
            'restore_snapshot',
            'remote',
            $cfg['destination_host'],
            $argv[3],
            $argv[4],
            $argv[5],
            $argv[6],
            $argv[7],
        ));
        BB_LOG("remote cmd ".$cmd);
        start_long_running_task_echo_pid($cmd);
    } else if ($cfg["type"] == "remote_generic") {
        $identity = resolve_remote_identity_from_cfg($cfg, 'destination', $error_message);
        if ($identity === null) {
            echo $error_message;
            return;
        }
        $cmd = build_shell_command(array(
            $GLOBALS['rc'],
            'restore_snapshot',
            'remote_generic',
            $cfg['destination_host'],
            $argv[3],
            $argv[4],
            $argv[5],
            $argv[6],
            $argv[7],
            $identity['user'],
            $identity['port'],
        ));
        BB_LOG("remote_generic cmd ".$cmd);
        start_long_running_task_echo_pid($cmd);
    } else if ($cfg["type"] == "local") {
        $cmd = build_shell_command(array(
            $GLOBALS['rc'],
            'restore_snapshot',
            'local',
            $argv[3],
            $argv[4],
            $argv[5],
            $argv[6],
            $argv[7],
        ));
        BB_LOG("local cmd ".$cmd);
        start_long_running_task_echo_pid($cmd);
    } else {
        BB_ERR("Unknown backup type: ".$cfg["type"]);
    }
}

function preflight_send_backup($uid) {
    global $rc;

    $error_message = null;
    $cfg = load_backup_config_entry($uid, $error_message);
    if ($cfg === null) {
        write_json_response(array('status' => 'error', 'message' => $error_message));
        return;
    }

    $cmd = build_shell_command(array($rc, 'preflight_send_backup', $cfg['type'], $cfg['source_dataset']));
    passthru($cmd);
}

function get_available_snapshots($uid) {
    global $rc;
    $error_message = null;
    $cfg = load_backup_config_entry($uid, $error_message);
    if ($cfg === null) {
        echo $error_message;
        return;
    }
    if ($cfg["type"] == "remote") {
        passthru(build_shell_command(array(
            $rc,
            'get_available_snapshots',
            'remote',
            $cfg["destination_host"],
            $cfg["destination_dataset"],
        )));
    } else if ($cfg["type"] == "remote_generic") {
        $identity = resolve_remote_identity_from_cfg($cfg, 'destination', $error_message);
        if ($identity === null) {
            echo $error_message;
            return;
        }
        passthru(build_shell_command(array(
            $rc,
            'get_available_snapshots',
            'remote_generic',
            $cfg["destination_host"],
            $cfg["destination_dataset"],
            $identity['user'],
            $identity['port'],
        )));
    } else if ($cfg["type"] == "local") {
        passthru(build_shell_command(array(
            $rc,
            'get_available_snapshots',
            'local',
            $cfg["destination_dataset"],
        )));
    } else {
        echo "Unknown backup type: ".($cfg["type"] ?? '');
    }
}

// Write tmp file with timestamp and size of destination dataset. Used in Unraid dashboard.
function mark_received_backup($target_dataset = null) {
    global $incoming_config_path, $tmp_recv_dataset_path;

    $env_uid = getenv('BUDDY_UID') ?: ($_ENV['BUDDY_UID'] ?? '');
    $env_dataset = getenv('BUDDY_DATASET') ?: ($_ENV['BUDDY_DATASET'] ?? '');

    $matched_uid = !empty($env_uid) ? $env_uid : null;
    $dataset = !empty($target_dataset) ? trim($target_dataset) : null;

    if ($dataset === null && !empty($env_dataset)) {
        $dataset = trim(explode(',', $env_dataset)[0]);
    }

    if (file_exists($incoming_config_path)) {
        $incoming_cfg = parse_ini_file($incoming_config_path, true);
        if (is_array($incoming_cfg)) {
            if ($matched_uid !== null && empty($dataset) && isset($incoming_cfg[$matched_uid]['destination_dataset'])) {
                $dataset = trim($incoming_cfg[$matched_uid]['destination_dataset']);
            }
            if ($matched_uid === null && !empty($dataset)) {
                foreach ($incoming_cfg as $uid => $buddy) {
                    $b_ds = trim($buddy['destination_dataset'] ?? '');
                    if ($b_ds !== '' && ($dataset === $b_ds || str_starts_with($dataset, $b_ds . '/'))) {
                        $matched_uid = $uid;
                        $dataset = $b_ds;
                        break;
                    }
                }
            }
            if (empty($dataset) && $matched_uid === null) {
                $enabled_buddies = array_filter($incoming_cfg, function($b) {
                    return ($b['enable'] ?? '') === 'yes' && !empty($b['destination_dataset']);
                });
                if (count($enabled_buddies) === 1) {
                    $matched_uid = array_key_first($enabled_buddies);
                    $dataset = trim($enabled_buddies[$matched_uid]['destination_dataset']);
                }
            }
        }
    }

    if (empty($dataset)) {
        $error_message = null;
        $dataset = read_receive_destination_dataset($error_message);
    }

    if ($dataset === null || !is_valid_zfs_dataset_name($dataset)) {
        BB_ERR("Failed to determine destination dataset for mark_received_backup");
        return;
    }

    $error_message = null;
    $dest_size = read_zfs_property_value($dataset, 'used', $error_message);
    if ($dest_size === null) {
        BB_ERR("Failed to get used size for buddy receive destination dataset '$dataset': $error_message");
        return;
    }

    $info = "last_ran=".time()."\ndest_size=$dest_size";
    if ($matched_uid !== null && $matched_uid !== '') {
        file_put_contents("/tmp/buddybackup-buddy-$matched_uid", $info);
    }
    if (!file_exists($incoming_config_path)) {
        file_put_contents("/tmp/buddybackup-buddy", $info);
    } else if (file_exists("/tmp/buddybackup-buddy")) {
        @unlink("/tmp/buddybackup-buddy");
    }
}

function probe_zfs($target_dataset = null) {
    $error_message = null;
    $dataset = $target_dataset;
    if (empty($dataset)) {
        $dataset = read_receive_destination_dataset($error_message);
    }
    if ($dataset === null) {
        write_probe_zfs_response('error', null, $error_message);
        exit(1);
    }

    if (read_zfs_property_value($dataset, 'used', $error_message) !== null) {
        write_probe_zfs_response('ok', $dataset, null);
        return;
    }

    write_probe_zfs_response('error', null, $error_message);
    exit(1);
}

function send_backup($uid, $echo_pid_arg) {
    BB_LOG("Sending backup $uid");
    $error_message = null;
    $cfg = load_backup_config_entry($uid, $error_message);
    if ($cfg === null) {
        BB_ERR("Could not startup backup with uid '$uid' since it does not exist");
        return;
    }

    $echo_pid = (!empty($echo_pid_arg) && $echo_pid_arg == "echopid");
    $cmd = build_send_backup_command($cfg, $uid, $error_message);
    if ($cmd === null) {
        BB_ERR("Could not startup backup with uid '$uid': ".$error_message);
        return;
    }
    $result_code = run_task_command($cmd, $echo_pid);

    if (!$echo_pid) {
        BB_VERBOSE("backup result: $result_code");
    }
}

function create_snapshot_and_send($uid, $echo_pid_arg) {
    BB_LOG("Creating snapshot and sending backup $uid");

    $error_message = null;
    $cfg = load_backup_config_entry($uid, $error_message);
    if ($cfg === null) {
        BB_ERR("Could not start create_snapshot_and_send for uid '$uid' since it does not exist");
        return;
    }

    $echo_pid = (!empty($echo_pid_arg) && $echo_pid_arg == 'echopid');
    $cmd = build_create_snapshot_and_send_command($cfg, $uid, $error_message);
    if ($cmd === null) {
        BB_ERR("Could not start create_snapshot_and_send for uid '$uid': ".$error_message);
        return;
    }
    $result_code = run_task_command($cmd, $echo_pid);

    if (!$echo_pid) {
        BB_VERBOSE("create_snapshot_and_send result: $result_code");
    }
}

switch ($argv[1]) {
    case 'update':
        update();
        break;
    case 'preflight_send_backup':
        preflight_send_backup($argv[2]);
        break;
    case 'send_backup':
        send_backup($argv[2], $argv[3]);
        break;
    case 'create_snapshot_and_send':
        create_snapshot_and_send($argv[2], $argv[3]);
        break;
    case 'test_connection':
        $type = $argv[4] ?? 'remote';
        $user = $argv[5] ?? '';
        $port = $argv[6] ?? '';
        if ($type == 'remote_generic') {
            $identity = normalize_remote_identity($user, $port, $error_message);
            if ($identity === null) {
                echo $error_message;
                break;
            }
            passthru(build_shell_command(array(
                $rc,
                'test_generic_connection',
                $argv[2] ?? '',
                $identity['user'],
                $identity['port'],
                $argv[3] ?? '',
                'push',
            )));
        } else {
            $host = escapeshellarg($argv[2] ?? '');
            $destination_dataset = escapeshellarg($argv[3] ?? '');
            passthru($rc.' test_connection '.$host.' '.$destination_dataset);
        }
        break;
    case 'get_available_snapshots':
        get_available_snapshots($argv[2]);
        break;
    case 'probe_zfs':
        probe_zfs($argv[2] ?? null);
        break;
    case 'mark_received_backup':
        mark_received_backup($argv[2] ?? null);
        break;
    case 'restore_snapshot':
        restore_snapshot($argv);
        break;
    case 'uninstall':
        passthru($rc.' uninstall');
        break;
    
    default:
        echo "usage ".$argv[0]." update|preflight_send_backup|send_backup|create_snapshot_and_send|test_connection|get_available_snapshots|probe_zfs|mark_received_backup|restore_snapshot";
        break;
}
?>