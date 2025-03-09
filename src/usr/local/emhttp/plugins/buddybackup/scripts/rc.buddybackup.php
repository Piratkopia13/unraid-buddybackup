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

$empath = "/usr/local/emhttp/plugins/buddybackup";
$sanoid_bin = "$empath/deps/sanoid";
$log_script = "$empath/scripts/log.sh";
$rc = $empath."/scripts/rc.buddybackup";

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

// update() runs on system boot, on plugin install/update, and when backup settings are changed.
function update() {
    global $rc;
    global $plugin_config_path;
    global $extra_sanoid_config_path;
    global $tmp_recv_dataset_path;
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

    // Write buddy's receive destination dataset to tmp file 
    // so it can be accessed by user buddybackup executing mark_received_backup
    file_put_contents($tmp_recv_dataset_path, $plugin_cfg["ReceiveDestinationDataset"]);

    update_sanoid_conf();
    $receive_backups_enabled = $plugin_cfg["ReceiveBackups"] == "enable";
    if ($receive_backups_enabled || file_exists_and_not_empty($extra_sanoid_config_path)) {
        enable_sanoid_cron();
    } else {
        disable_sanoid_cron();
    }

    if ($receive_backups_enabled) {
        passthru($rc.' enable_backups_from_buddy');
    } else {
        passthru($rc.' disable_backups_from_buddy');
    }
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
    global $empath;
    global $log_script;
    $plugin_cfg = parse_ini_file($plugin_config_path, false);
    $receive_backups_enabled = $plugin_cfg["ReceiveBackups"] == "enable";

    $sanoid_conf_content = "";
    if ($receive_backups_enabled) {
        // save retention for buddy's backups to sanoid conf
        $sanoid_conf_content .= "[".$plugin_cfg["ReceiveDestinationDataset"]."]\n";
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
            if ($receive_backups_enabled && !empty($plugin_cfg["ReceiveDestinationDataset"]) && str_starts_with($dataset, $plugin_cfg["ReceiveDestinationDataset"])) {
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
    global $plugin_path;
    global $log_script;
    global $plugin_config_path;
    $plugin_cfg = parse_ini_file($plugin_config_path, false);
    if (file_exists($sanoid_cron_path)) {
        ENSURE_SUCCESS(unlink($sanoid_cron_path));
    }
    $tz = ($plugin_cfg["UtcTimezone"] == "yes") ? "TZ=UTC" : "";
    $cron_content = "# Generated cron settings for plugin buddybackup\n";
    $cron_content .= "*/15 * * * * flock -n /var/lock/buddybackup-sanoid-cron -c \"$tz $sanoid_bin --configdir=\"$plugin_path\" --cron\" 2>&1 | $log_script\n";
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
    $known_hosts_path = "/root/.ssh/known_hosts";
    ENSURE_SUCCESS(file_put_contents($known_hosts_path, "# buddybackup start\n", FILE_APPEND)!==false);

    foreach ($backup_cfg as $uid => $cfg) {
        // append target as known host. This gets rid of strange hostfile_replace_entries/update_known_hosts errors during remote ssh commands
        // This is done as long as a destination host is set regardless if backups are enabled or not since we still need to eg. run get_available_snapshots
        if ($key = shell_exec("ssh-keyscan -H \"".$cfg["destination_host"]."\"")) {
            ENSURE_SUCCESS(file_put_contents($known_hosts_path, $key, FILE_APPEND)!==false);
        }

        $is_local = $cfg['type'] == "local";
        $any_empty = false;
        foreach ($cfg as $key => $value) {
            if (empty($value)) {
                if ($is_local && $key == "destination_host") continue;

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
    ENSURE_SUCCESS(file_put_contents($known_hosts_path, "# buddybackup end\n", FILE_APPEND)!==false);

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
    global $rc;
    global $plugin_path;
    global $backups_config_path;
    $backup_cfg = parse_ini_file($backups_config_path, true);
    $uid = $argv[2];
    if (!array_key_exists($uid, $backup_cfg)) {
        echo "UID '$uid' does not exist";
        return;
    }
    $cfg = $backup_cfg[$uid];

    BB_LOG("restore_snapshot ".$uid);

    if ($cfg["type"] == "remote") {
        $cmd = $rc.' restore_snapshot remote "'.$cfg["destination_host"].'" "'.$argv[3].'" "'.$argv[4].'" "'.$argv[5].'" "'.$argv[6].'" "'.$argv[7].'"';
        BB_LOG("remote cmd ".$cmd);
        start_long_running_task_echo_pid($cmd);
    } else if ($cfg["type"] == "local") {
        $cmd = $rc.' restore_snapshot local "'.$argv[3].'" "'.$argv[4].'" "'.$argv[5].'" "'.$argv[6].'" "'.$argv[7].'"';
        BB_LOG("local cmd ".$cmd);
        start_long_running_task_echo_pid($cmd);
    } else {
        BB_ERR("Unknown backup type: ".$cfg["type"]);
    }
}

function get_available_snapshots($uid) {
    global $rc;
    global $plugin_path;
    global $backups_config_path;
    $backup_cfg = parse_ini_file($backups_config_path, true);
    if (!array_key_exists($uid, $backup_cfg)) {
        echo "UID '$uid' does not exist";
        return;
    }
    $cfg = $backup_cfg[$uid];
    if ($cfg["type"] == "remote") {
        passthru($rc.' get_available_snapshots remote "'.$cfg["destination_host"].'" "'.$cfg["destination_dataset"].'"');
    } else {
        passthru($rc.' get_available_snapshots local "'.$cfg["destination_dataset"].'"');
    }
}

// Write tmp file with timestamp and size of destination dataset. Used in Unraid dashboard.
function mark_received_backup() {
    global $tmp_recv_dataset_path;
    $dataset = file_get_contents($tmp_recv_dataset_path);
    $dest_size = exec("zfs get -H -o value used \"".$dataset."\"");
    $file = "/tmp/buddybackup-buddy";
    $info = "last_ran=".time()."\ndest_size=$dest_size";
    file_put_contents($file, $info);
}

function send_backup($uid, $echo_pid_arg) {
    BB_LOG("Sending backup $uid");
    global $rc;
    global $plugin_path;
    global $backups_config_path;
    $backup_cfg = parse_ini_file($backups_config_path, true);
    if (!array_key_exists($uid, $backup_cfg)) {
        BB_ERR("Could not startup backup with uid '$uid' since it does not exist");
        return;
    }
    $echo_pid = (!empty($echo_pid_arg) && $echo_pid_arg == "echopid");
    $cfg = $backup_cfg[$uid];
    $result_code = null;
    if ($cfg['type'] == "local") {
        $cmd = $rc.' send_local_backup "'.$cfg["source_dataset"].'" "'.$cfg["recursive"].'" "'.$cfg["destination_dataset"].'" "'.$uid.'"';
        if ($echo_pid) {
            start_long_running_task_echo_pid($cmd);
        } else {
            passthru($cmd, $result_code);
        }
    } else {
        $cmd = $rc.' send_backup "'.$cfg["source_dataset"].'" "'.$cfg["recursive"].'" "'.$cfg["destination_host"].'" "'.$cfg["destination_dataset"].'" "'.$uid.'"';
        if ($echo_pid) {
            start_long_running_task_echo_pid($cmd);
        } else {
            passthru($cmd, $result_code);
        }
    }
    if (!$echo_pid) {
        BB_VERBOSE("backup result: $result_code");
    }
}

switch ($argv[1]) {
    case 'update':
        update();
        break;
    case 'send_backup':
        send_backup($argv[2], $argv[3]);
        break;
    case 'test_connection':
        passthru($rc.' '.$argv[1].' '.$argv[2]);
        break;
    case 'get_available_snapshots':
        get_available_snapshots($argv[2]);
        break;
    case 'mark_received_backup':
        mark_received_backup();
        break;
    case 'restore_snapshot':
        restore_snapshot($argv);
        break;
    case 'uninstall':
        passthru($rc.' uninstall');
        break;
    
    default:
        echo "usage ".$argv[0]." update|send_backup|get_available_snapshots|mark_received_backup|restore_snapshot";
        break;
}
?>