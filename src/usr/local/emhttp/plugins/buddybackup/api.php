<?php
    $plugin = "buddybackup";
    $docroot = $docroot ?? $_SERVER['DOCUMENT_ROOT'] ?: '/usr/local/emhttp';
    require_once $docroot."/plugins/".$plugin."/common.php";

    function remove_ini_section($current_content, $section_to_remove, $file) {
        unset($current_content[$section_to_remove]);
        $new_content = '';
        foreach ($current_content as $section => $section_content) {
            $section_content = array_map(function($value, $key) {
                return "$key=\"$value\"";
            }, array_values($section_content), array_keys($section_content));
            $section_content = implode("\n", $section_content);
            $new_content .= "[$section]\n$section_content\n";
        }
        file_put_contents($file, $new_content);
    }
    function remove_sanoid_section($section) {
        global $snapshot_cfg;
        global $snapshot_cfg_file;
        remove_ini_section($snapshot_cfg, $section, $snapshot_cfg_file);
        echo shell_exec("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update");
    }
    function remove_backup_section($section) {
        global $backup_cfg;
        global $backup_cfg_file;
        remove_ini_section($backup_cfg, $section, $backup_cfg_file);
        echo shell_exec("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update");
    }

    function get_top_level_pids($filter) {
        $ret = array();
        $output = array();
        exec('pgrep -f "'.$filter.'"', $output);
        foreach ($output as $pid) {
            $ppid = shell_exec("ps -o ppid= ".$pid);
            if ($ppid == "1") {
                array_push($ret, $pid);
            }
        }
        return $ret;
    }
    function get_running_backups_pids() {
        return get_top_level_pids("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup send*_backup");
    }
    function get_running_restore_pids() {
        return get_top_level_pids("/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup restore_snapshot");
    }

    function kill_running_backups() {
        $pids = get_running_backups_pids();
        foreach ($pids as $pid) {
            exec("kill ".$pid);
        }
        exec("echo 'User aborted ".count($pids)." running backup operation(s)' | /usr/local/emhttp/plugins/buddybackup/scripts/log.sh");
    }
    function kill_running_restores() {
        $pids = get_running_restore_pids();
        foreach ($pids as $pid) {
            exec("kill ".$pid);
        }
        exec("echo 'User aborted ".count($pids)." running restore operation(s)' | /usr/local/emhttp/plugins/buddybackup/scripts/log.sh");
    }
    function count_running_backups() {
        echo count(get_running_backups_pids());
    }
    function count_running_restores() {
        echo count(get_running_restore_pids());
    }

    switch ($_POST["cmd"]) {
        case 'get_log':
            echo file_get_contents("/var/log/buddybackup.log");
            break;
        case 'remove_sanoid_section':
            remove_sanoid_section($_POST["section"]);
            break;
        case 'remove_backup_section':
            remove_backup_section($_POST["section"]);
            break;
        case 'kill_running_backups':
            kill_running_backups();
            break;
        case 'kill_running_restores':
            kill_running_restores();
            break;
        case 'count_running_backups':
            count_running_backups();
            break;
        case 'count_running_restores':
            count_running_restores();
            break;
        
        default:
            break;
    }
?>