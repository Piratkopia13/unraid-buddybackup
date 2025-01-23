<?php
    $plugin = "buddybackup";
    
    function get_buddy_snapshots() {
        if ($json = shell_exec("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup get_buddy_snapshots")) {
            echo $json;
        } else {
            echo '{"status": "failed", "error": "Failed to retrieve buddy\'s snapshots"}';
        }
    }

    switch ($_POST["cmd"]) {
        case 'get_log':
            echo file_get_contents("/var/log/buddybackup.log");
            break;
        case 'get_buddy_snapshots':
            get_buddy_snapshots();
            break;
        
        default:
            break;
    }
?>