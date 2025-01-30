<?php
    $plugin = "buddybackup";
    $docroot = $docroot ?? $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
    require_once $docroot."/plugins/dynamix/include/Helpers.php";

    $cfg = parse_plugin_cfg($plugin, true);
    $rc_name = "rc.{$plugin}";
    $rc_script = "/plugins/{$plugin}/scripts/{$rc_name}";

    $snapshot_cfg_file = "/boot/config/plugins/$plugin/snapshots.cfg";
    $snapshot_cfg = my_parse_ini_file($snapshot_cfg_file, true);

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
