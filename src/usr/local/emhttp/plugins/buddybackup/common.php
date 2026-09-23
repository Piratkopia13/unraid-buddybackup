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
    $incoming_cfg_file = "/boot/config/plugins/$plugin/incoming.cfg";

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
    if (!empty($cfg["BackupToBuddy"])) {
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

    // incoming buddy cfg used to be a single set of keys in $cfg. Move it over to $incoming_cfg if it still exists
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
        foreach ($key_lines as $i => $key) {
            $uid = ($i === 0) ? "1ml3g4cy" : substr(md5("legacy_buddy_" . $i . "_" . $key), 0, 8);
            if ($total_keys === 1) {
                $buddy_name = "Buddy";
            } else {
                $parts = preg_split('/\s+/', $key, 3);
                $comment = isset($parts[2]) ? trim($parts[2]) : '';
                $buddy_name = "Buddy " . ($i + 1) . ($comment !== '' ? " ($comment)" : "");
            }

            $incoming = array();
            $incoming["name"] = $buddy_name;
            $incoming["enable"] = (($cfg["ReceiveBackups"] ?? "") == "enable") ? "yes" : "no";
            $incoming["destination_dataset"] = $cfg["ReceiveDestinationDataset"] ?? "";
            $incoming["ssh_key"] = $key;
            $incoming["hourly"] = $cfg["ReceiveDestinationRententionHourly"] ?? 0;
            $incoming["daily"] = $cfg["ReceiveDestinationRententionDaily"] ?? 7;
            $incoming["weekly"] = $cfg["ReceiveDestinationRententionWeekly"] ?? 4;
            $incoming["monthly"] = $cfg["ReceiveDestinationRententionMonthly"] ?? 3;
            $incoming["yearly"] = $cfg["ReceiveDestinationRententionYearly"] ?? 0;

            add_to_ini($incoming, $uid, $incoming_cfg_file);
        }

        unset($cfg["ReceiveBackups"]);
        unset($cfg["ReceiveDestinationDataset"]);
        unset($cfg["DestinationPubSSHKey"]);
        unset($cfg["ReceiveDestinationRententionHourly"]);
        unset($cfg["ReceiveDestinationRententionDaily"]);
        unset($cfg["ReceiveDestinationRententionWeekly"]);
        unset($cfg["ReceiveDestinationRententionMonthly"]);
        unset($cfg["ReceiveDestinationRententionYearly"]);

        overwrite_ini($cfg, $plugin_cfg_file);
    }

    $snapshot_cfg = my_parse_ini_file($snapshot_cfg_file, true);
    $backup_cfg = my_parse_ini_file($backup_cfg_file, true);
    $incoming_cfg = my_parse_ini_file($incoming_cfg_file, true);
    if (!empty($incoming_cfg) && file_exists("/tmp/buddybackup-buddy")) {
        @unlink("/tmp/buddybackup-buddy");
    }

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
            $type = $backup["type"] ?? "";
            if ($type == "local") {
                $destination = "localhost";
            } else {
                $destination = $backup["destination_host"] ?? "";
            }
            $backups .= mk_option($selected, $uid, $backup["source_dataset"]." -> ".$destination."@".$backup["destination_dataset"]);
        }
        return $backups;
    }

    function bb_task_telemetry($uid, $buddy = false, $custom_cfg = null) {
        global $cfg;
        $active_cfg = $custom_cfg;
        if ($active_cfg === null) {
            if (isset($cfg) && is_array($cfg)) {
                $active_cfg = $cfg;
            } else {
                $cfg_file = "/boot/config/plugins/buddybackup/buddybackup.cfg";
                $active_cfg = file_exists($cfg_file) ? @parse_ini_file($cfg_file) : array();
            }
        }

        if ($buddy) {
            $file = (!empty($uid)) ? "/tmp/buddybackup-buddy-$uid" : "/tmp/buddybackup-buddy";
        } else {
            $file = "/tmp/buddybackup-$uid";
        }

        $ret = array(
            "last_ran" => "-",
            "last_ran_class" => "grey-text",
            "compact_last_ran" => "-",
            "status_label" => "Never ran",
            "status_class" => "grey-text",
            "dest_size" => "-",
            "has_run" => false,
            "raw_timestamp" => 0,
            "last_status" => "never_ran",
            "last_error_time" => 0,
            "last_error_code" => 0,
            "last_error_message" => "",
            "days_overdue" => 0
        );

        if (file_exists($file)) {
            $info = @parse_ini_file($file);
            if (isset($info["last_status"])) {
                $ret["last_status"] = $info["last_status"];
            } else if (!empty($info["last_ran"])) {
                $ret["last_status"] = "success";
            }
            if (!empty($info["last_error_time"])) {
                $ret["last_error_time"] = (int)$info["last_error_time"];
            }
            if (isset($info["last_error_code"])) {
                $ret["last_error_code"] = (int)$info["last_error_code"];
            }
            if (!empty($info["last_error_message"])) {
                $ret["last_error_message"] = $info["last_error_message"];
            }

            if (!empty($info["last_ran"])) {
                $last_ran = (int)$info["last_ran"];
                $ret["raw_timestamp"] = $last_ran;
                $ret["has_run"] = true;
                $ret["last_ran"] = function_exists("my_time") ? my_time($last_ran) : date("Y-m-d H:i", $last_ran);
                $ret["compact_last_ran"] = bb_format_dashboard_time($last_ran);
                $current_time = time();

                $warn_days = ($buddy) ? ($active_cfg["BuddysBackupDaysAgoWarning"] ?? 7) : ($active_cfg["BackupDaysAgoWarning"] ?? 7);
                $crit_days = ($buddy) ? ($active_cfg["BuddysBackupDaysAgoCritical"] ?? 30) : ($active_cfg["BackupDaysAgoCritical"] ?? 30);

                $warn_sec = (int)$warn_days * 24 * 60 * 60;
                $crit_sec = (int)$crit_days * 24 * 60 * 60;

                $diff_sec = $current_time - $last_ran;
                $ret["days_overdue"] = max(0, (int)floor($diff_sec / 86400));

                if (!empty($crit_sec) && $diff_sec > $crit_sec) {
                    $ret["last_ran_class"] = "red-text";
                    $ret["status_label"] = "Alert";
                    $ret["status_class"] = "red-text";
                } else if (!empty($warn_sec) && $diff_sec > $warn_sec) {
                    $ret["last_ran_class"] = "orange-text";
                    $ret["status_label"] = "Warning";
                    $ret["status_class"] = "orange-text";
                } else {
                    $ret["last_ran_class"] = "green-text";
                    $ret["status_label"] = "Healthy";
                    $ret["status_class"] = "green-text";
                }
            }

            if ($ret["last_status"] === "failed") {
                $ret["status_label"] = "Failed";
                $ret["status_class"] = "red-text";
            }

            if (!empty($info["dest_size"])) {
                $ret["dest_size"] = $info["dest_size"];
            }
        }
        return $ret;
    }

    function bb_format_dashboard_time($timestamp) {
        if (empty($timestamp) || !is_numeric($timestamp)) return "-";
        $now = time();
        $diff = $now - (int)$timestamp;
        $today_start = strtotime("today", $now);
        $yesterday_start = strtotime("yesterday", $now);

        if ($timestamp >= $today_start) {
            return (function_exists("_") ? _("Today") : "Today") . ", " . date("H:i", $timestamp);
        } else if ($timestamp >= $yesterday_start) {
            return (function_exists("_") ? _("Yesterday") : "Yesterday") . ", " . date("H:i", $timestamp);
        } else if ($diff < 7 * 86400) {
            return date("D, H:i", $timestamp);
        } else {
            return date("Y-m-d H:i", $timestamp);
        }
    }
?>