<?php
    $plugin = "buddybackup";
    $docroot = $docroot ?? $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
    require_once $docroot."/plugins/dynamix/include/Helpers.php";

    $buddybackup_path = '/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin';
    $current_path = getenv('PATH') ?: '';
    $normalized_path = $buddybackup_path . ($current_path !== '' ? ":$current_path" : '');
    putenv("PATH=$normalized_path");
    $_ENV['PATH'] = $normalized_path;
    $_SERVER['PATH'] = $normalized_path;

    $cfg = parse_plugin_cfg($plugin, true);
    $rc_name = "rc.$plugin.php";
    $rc_script = "/plugins/$plugin/scripts/$rc_name";

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
        $backup["type"] = "remote";

        // Update ini files
        add_to_ini($backup, "1ml3g4cy", $backup_cfg_file);
        overwrite_ini($cfg, $plugin_cfg_file);
    }

    $snapshot_cfg = my_parse_ini_file($snapshot_cfg_file, true);
    $backup_cfg = my_parse_ini_file($backup_cfg_file, true);

    function datasets($selected, $only_encrypted = true) {
        $datasets = mk_option($selected, "", "Select from list", "disabled");
            $raw_datasets = array();
            $result_code = 0;
            exec("zfs list -j -o name,encryption 2>&1", $raw_datasets, $result_code);
            if ($result_code === 0) {
                $decoded = json_decode(implode("\n", $raw_datasets), true);
                if (is_array($decoded) && isset($decoded["datasets"]) && is_array($decoded["datasets"])) {
                    foreach ($decoded["datasets"] as $dataset_name => $dataset_info) {
                        $encryption = $dataset_info["properties"]["encryption"]["value"] ?? null;
                        if (!is_string($dataset_name) || $dataset_name === '' || !is_string($encryption)) {
                            continue;
                        }

                        if ($encryption != "off") {
                            $datasets .= mk_option($selected, $dataset_name, $dataset_name);
                        } else {
                            if ($only_encrypted) {
                                if ($dataset_name === $selected) {
                                    $datasets .= mk_option($selected, $dataset_name, "$dataset_name (not encrypted)");
                                } else {
                                    $datasets .= mk_option($selected, $dataset_name, "$dataset_name (not encrypted)", "disabled");
                                }
                            } else {
                                $datasets .= mk_option($selected, $dataset_name, "$dataset_name (not encrypted)");
                            }
                        }
                }
                } else {
                    $datasets = mk_option(null, "", "failed to parse datasets", "disabled");
            }
        } else {
            $datasets = mk_option(null, "", "failed to list datasets", "disabled");
        }
        return $datasets;
    }

    function backups($selected) {
        global $backup_cfg;
        $backups = "";
        foreach ($backup_cfg as $uid => $backup) {
            $destination = ($backup["type"] == "local") ? "localhost" : $backup["destination_host"];
            $backups .= mk_option($selected, $uid, $backup["source_dataset"]." -> ".$destination."@".$backup["destination_dataset"]);
        }
        return $backups;
    }
?>