<?php
    $plugin = "buddybackup";
    $docroot = $docroot ?? $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
    require_once $docroot."/plugins/".$plugin."/common.php";
    
    function get_buddy_snapshots() {
        if ($json = shell_exec("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup get_buddy_snapshots")) {
            echo $json;
        } else {
            echo '{"status": "failed", "error": "Failed to retrieve buddy\'s snapshots"}';
        }
    }

    function remove_sanoid_section($section) {
        global $snapshot_cfg;
        global $snapshot_cfg_file;

        unset($snapshot_cfg[$section]);
        $new_content = '';
        foreach ($snapshot_cfg as $section => $section_content) {
            $section_content = array_map(function($value, $key) {
                return "$key=$value";
            }, array_values($section_content), array_keys($section_content));
            $section_content = implode("\n", $section_content);
            $new_content .= "[$section]\n$section_content\n";
        }
        file_put_contents($snapshot_cfg_file, $new_content);
        echo shell_exec("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup update_sanoid_conf");
    }

    switch ($_POST["cmd"]) {
        case 'get_log':
            echo file_get_contents("/var/log/buddybackup.log");
            break;
        case 'get_buddy_snapshots':
            get_buddy_snapshots();
            break;
        case 'remove_sanoid_section':
            remove_sanoid_section($_POST["section"]);
            break;
        
        default:
            break;
    }
?>