<?php
    $plugin = "buddybackup";
    $docroot = $docroot ?? $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
    require_once $docroot."/plugins/dynamix/include/Helpers.php";

    $cfg = parse_plugin_cfg($plugin, true);
    $rc_name = "rc.{$plugin}";
    $rc_script = "/plugins/{$plugin}/scripts/{$rc_name}";

    $plugin_cfg_file = "/boot/config/plugins/$plugin/$plugin.cfg";
    $snapshot_cfg_file = "/boot/config/plugins/$plugin/snapshots.cfg";
    $backup_cfg_file = "/boot/config/plugins/$plugin/backups.cfg";

    function overwrite_ini($config, $file) {
        $content = "";
        foreach ($config as $key => $value) {
            $content .= "$key=\"$value\"\n";
        }
        return file_put_contents($file, $content) !== false;
    }
    function add_to_ini($config, $section, $file) {
        $content = "[$section]\n";
        foreach ($config as $key => $value) {
            $content .= "$key=\"$value\"\n";
        }
        // Append content to file
        return file_put_contents($file, $content, FILE_APPEND) !== false;
    }

    // backup cfg used to be a single one and live in $cfg. Move it over to $snapshot_cfg if it still exists
    // LEGACY - to be removed
    if ($cfg["BackupToBuddy"]) {
        $backup = array();
        $backup["enable"] = ($cfg["BackupToBuddy"] == "enable") ? "yes" : "no"; unset($cfg["BackupToBuddy"]);
        $backup["destination_host"] = $cfg["DestinationHost"]; unset($cfg["DestinationHost"]);
        $backup["source_dataset"] = $cfg["SourceDataset"]; unset($cfg["SourceDataset"]);
        $backup["destination_dataset"] = $cfg["SendDestinationDataset"]; unset($cfg["SendDestinationDataset"]);
        $backup["backup_cron"] = $cfg["BackupCron"]; unset($cfg["BackupCron"]);
        $backup["recursive"] = $cfg["BackupRecursive"]; unset($cfg["BackupRecursive"]);

        // Update ini files
        add_to_ini($backup, "1ml3g4cy", $backup_cfg_file);
        overwrite_ini($cfg, $plugin_cfg_file);
    }

    $snapshot_cfg = my_parse_ini_file($snapshot_cfg_file, true);
    $backup_cfg = my_parse_ini_file($backup_cfg_file, true);

    function datasets($selected, $only_encrypted = true) {
        $datasets = mk_option($selected, "", "Select from list", "disabled");
        $raw_datasets = array();
        if (exec("zfs list -rH -o name,encryption", $raw_datasets)) {
            foreach ($raw_datasets as $set) {
                $parts = preg_split('/\s+/', $set);
                if ($parts[1] != "off" || !$only_encrypted) {
                    $datasets .= mk_option($selected, $parts[0], $parts[0]);
                } else {
                    $datasets .= mk_option($selected, $parts[0], "{$parts[0]} (not encrypted)", "disabled");
                }
            }
        } else {
            $datasets = mk_option(null, "", "failed to list datasets", "disabled");
        }
        return $datasets;
    }
?>

<!-- ReceiveBackups="enable" -->
<!-- ReceiveDestinationRententionHourly="0" -->
<!-- ReceiveDestinationRententionDaily="7" -->
<!-- ReceiveDestinationRententionWeekly="4" -->
<!-- ReceiveDestinationRententionMonthly="3" -->
<!-- ReceiveDestinationRententionYearly="0" -->
<!-- DestinationPubSSHKey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHRHUnG8/Qp4b0zJiWjR1tezUkDVLzsc21EUguCcEQRk root@Prism " -->
<!-- ReceiveDestinationDataset="disk1/prism_offsite_backup" -->