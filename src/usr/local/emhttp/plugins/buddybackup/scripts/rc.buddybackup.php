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
$run_dir = "/var/run/buddybackup";
$tmp_recv_dataset_path = "$run_dir/recv-dest";
$tmp_incoming_json_path = "$run_dir/incoming.json";
$incoming_config_path = "$plugin_path/incoming.cfg";

function ensure_runtime_dir() {
    global $run_dir;
    if (!is_dir($run_dir)) {
        @mkdir($run_dir, 0770, true);
    }
    if (is_dir($run_dir)) {
        if (function_exists('posix_getuid') && posix_getuid() === 0) {
            @chown($run_dir, 'root');
            @chgrp($run_dir, 'buddybackup');
            @chmod($run_dir, 0770);
        }
    }
}

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

function validate_hook_script($path, &$error_message = null) {
    $path = trim((string)$path);

    // An empty value simply means "no hook configured".
    if ($path === '') {
        return true;
    }

    if (strpos($path, "\0") !== false) {
        $error_message = "Hook command cannot contain null characters.";
        return false;
    }

    // Guard against relative script file paths (e.g. "my_hook.sh" or "./my_hook.sh")
    if (preg_match('/^\.?[a-zA-Z0-9_\-]+\.sh$/', $path)) {
        $error_message = "Script files must be specified with an absolute path starting with / (e.g. /boot/config/plugins/buddybackup/hooks/$path).";
        return false;
    }

    // If it looks like a single absolute file path (starts with / and has no whitespace or shell operators)
    if (substr($path, 0, 1) === '/' && !preg_match('/[\s;&|]/', $path)) {
        $resolved = realpath($path);
        if ($resolved === false || !is_file($resolved)) {
            $error_message = "Hook script '$path' does not exist or is not a regular file.";
            return false;
        }

        $test_prefix = getenv('BUDDYBACKUP_TEST_BOOT_PREFIX');
        $is_boot = (substr($resolved, 0, 6) === '/boot/' || ($test_prefix !== false && $test_prefix !== '' && substr($resolved, 0, strlen($test_prefix)) === $test_prefix));
        if ($is_boot) {
            if (!is_readable($resolved)) {
                $error_message = "Hook script '$path' is not readable.";
                return false;
            }
        } else {
            if (!is_executable($resolved)) {
                $error_message = "Hook script '$path' is not executable.";
                return false;
            }

            $perms = fileperms($resolved);
            if ($perms !== false && ($perms & 0022) !== 0) {
                $error_message = "Hook script '$path' must not be group- or world-writable.";
                return false;
            }
        }
    }

    return true;
}

function format_sanoid_hook_command($hook) {
    $hook = trim((string)$hook);
    if ($hook === '') {
        return '';
    }

    if (preg_match('/^([\'"]?)(\/[^\s;&|]+)\1$/', $hook, $matches)) {
        $path = $matches[2];
        $resolved = realpath($path);
        if ($resolved === false) {
            $resolved = $path;
        }

        $test_prefix = getenv('BUDDYBACKUP_TEST_BOOT_PREFIX') ?: ($_ENV['BUDDYBACKUP_TEST_BOOT_PREFIX'] ?? '');
        $is_boot = (
            substr($resolved, 0, 6) === '/boot/' ||
            substr($path, 0, 6) === '/boot/' ||
            ($test_prefix !== '' && (
                substr($resolved, 0, strlen($test_prefix)) === $test_prefix ||
                substr($path, 0, strlen($test_prefix)) === $test_prefix
            ))
        );

        if ($is_boot) {
            $interpreter = 'bash';
            $target_file = is_file($resolved) ? $resolved : (is_file($path) ? $path : null);
            if ($target_file !== null && is_readable($target_file)) {
                $fh = @fopen($target_file, 'r');
                if ($fh) {
                    $first_line = fgets($fh);
                    fclose($fh);
                    if ($first_line !== false) {
                        $first_line = trim($first_line, "\r\n");
                        if (preg_match('/^#!\s*(\/.+)$/', $first_line, $m)) {
                            $interpreter = trim($m[1]);
                        }
                    }
                }
            }
            $escaped_path = "'" . str_replace("'", "'\\''", $path) . "'";
            return "$interpreter $escaped_path";
        }
    }

    return $hook;
}

function normalize_hook_timeout($value) {
    $value = trim((string)$value);
    if ($value === '' || !ctype_digit($value) || (int)$value < 1) {
        return '30';
    }
    return (string)(int)$value;
}

function normalize_hook_failure_mode($value) {
    return ((string)$value === 'warn') ? 'warn' : 'abort';
}

function normalize_snapshot_time($hour, $min) {
    if ($hour === null || $hour === '' || $min === null || $min === '') {
        return array('', '');
    }
    $hour_str = trim((string)$hour);
    $min_str = trim((string)$min);
    if (!ctype_digit($hour_str) || !ctype_digit($min_str)) {
        return array('', '');
    }
    $h = (int)$hour_str;
    $m = (int)$min_str;
    if ($h < 0 || $h > 23 || $m < 0 || $m > 59) {
        return array('', '');
    }
    return array((string)$h, (string)$m);
}

function read_receive_destination_datasets(&$error_message = null) {
    global $tmp_recv_dataset_path, $incoming_config_path, $tmp_incoming_json_path;

    $datasets = array();

    // Check environment variable BUDDY_DATASET (set by restrict_zfs for current SSH connection)
    $env_dataset = getenv('BUDDY_DATASET') ?: ($_ENV['BUDDY_DATASET'] ?? '');
    if ($env_dataset !== '') {
        foreach (explode(',', $env_dataset) as $part) {
            $ds = trim($part);
            if (is_valid_zfs_dataset_name($ds) && !in_array($ds, $datasets, true)) {
                $datasets[] = $ds;
            }
        }
        if (!empty($datasets)) {
            return $datasets;
        }
    }

    // Check incoming.cfg or /var/run/buddybackup/incoming.json (or fallback /tmp/buddybackup-incoming.json)
    $incoming_cfg = null;
    if (file_exists($incoming_config_path) && is_readable($incoming_config_path)) {
        $incoming_cfg = parse_ini_file($incoming_config_path, true);
    } else if (file_exists($tmp_incoming_json_path) && is_readable($tmp_incoming_json_path) && !is_link($tmp_incoming_json_path)) {
        $incoming_cfg = json_decode(file_get_contents($tmp_incoming_json_path), true);
    } else if (file_exists("/tmp/buddybackup-incoming.json") && is_readable("/tmp/buddybackup-incoming.json") && !is_link("/tmp/buddybackup-incoming.json")) {
        $incoming_cfg = json_decode(file_get_contents("/tmp/buddybackup-incoming.json"), true);
    }
    if (is_array($incoming_cfg)) {
        $env_uid = getenv('BUDDY_UID') ?: ($_ENV['BUDDY_UID'] ?? '');
        if ($env_uid !== '' && isset($incoming_cfg[$env_uid]['destination_dataset'])) {
            $ds = trim($incoming_cfg[$env_uid]['destination_dataset']);
            if (is_valid_zfs_dataset_name($ds)) {
                return array($ds);
            }
        }
        foreach ($incoming_cfg as $uid => $buddy) {
            if (($buddy['enable'] ?? '') === 'yes' && !empty($buddy['destination_dataset'])) {
                $ds = trim($buddy['destination_dataset']);
                if (is_valid_zfs_dataset_name($ds) && !in_array($ds, $datasets, true)) {
                    $datasets[] = $ds;
                }
            }
        }
        if (!empty($datasets)) {
            return $datasets;
        }
    }

    if (file_exists($tmp_recv_dataset_path) && !is_link($tmp_recv_dataset_path)) {
        $dataset = trim((string)file_get_contents($tmp_recv_dataset_path));
        if ($dataset !== '' && is_valid_zfs_dataset_name($dataset)) {
            return array($dataset);
        }
    } else if (file_exists("/tmp/buddybackup-recv-dest") && !is_link("/tmp/buddybackup-recv-dest")) {
        $dataset = trim((string)file_get_contents("/tmp/buddybackup-recv-dest"));
        if ($dataset !== '' && is_valid_zfs_dataset_name($dataset)) {
            return array($dataset);
        }
    }

    $error_message = 'Buddy receive destination dataset is not configured.';
    return array();
}

function read_receive_destination_dataset(&$error_message = null, $target_dataset = null) {
    $all_datasets = read_receive_destination_datasets($error_message);
    if (empty($all_datasets)) {
        return null;
    }

    if (!empty($target_dataset)) {
        $target = trim($target_dataset);
        foreach ($all_datasets as $ds) {
            if ($target === $ds || str_starts_with($target, $ds . '/')) {
                return $ds;
            }
        }
        $error_message = "Target dataset '$target' is not in the allowed destination datasets.";
        return null;
    }

    return $all_datasets[0];
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

function write_probe_zfs_response($status, $dataset = null, $message = null, $datasets = null) {
    $response = array('status' => $status);

    if ($dataset !== null) {
        $response['dataset'] = $dataset;
    }

    if ($datasets !== null && is_array($datasets)) {
        $response['datasets'] = array_values($datasets);
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

function get_snapshot_hooks_for_dataset($dataset) {
    global $extra_sanoid_config_path;
    if (!file_exists($extra_sanoid_config_path)) {
        return array('pre' => '', 'post' => '', 'timeout' => '30', 'mode' => 'abort');
    }
    $cfg = parse_ini_file($extra_sanoid_config_path, true);
    if (!is_array($cfg)) {
        return array('pre' => '', 'post' => '', 'timeout' => '30', 'mode' => 'abort');
    }
    foreach ($cfg as $sec => $data) {
        if (($data['dataset'] ?? '') === $dataset) {
            return array(
                'pre' => trim((string)($data['pre_snapshot_script'] ?? '')),
                'post' => trim((string)($data['post_snapshot_script'] ?? '')),
                'timeout' => normalize_hook_timeout($data['hook_timeout'] ?? ''),
                'mode' => normalize_hook_failure_mode($data['hook_failure_mode'] ?? ''),
            );
        }
    }
    return array('pre' => '', 'post' => '', 'timeout' => '30', 'mode' => 'abort');
}

function load_backup_config_entry($uid, &$error_message = null) {
    global $backups_config_path;

    $backup_cfg = parse_ini_file($backups_config_path, true);
    if (!is_array($backup_cfg) || !array_key_exists($uid, $backup_cfg)) {
        $error_message = "Backup with uid '$uid' does not exist.";
        return null;
    }

    $entry = $backup_cfg[$uid];
    if (!isset($entry['pre_backup_script']) && isset($entry['pre_snapshot_script'])) {
        $entry['pre_backup_script'] = $entry['pre_snapshot_script'];
    }
    if (!isset($entry['post_backup_script']) && isset($entry['post_snapshot_script'])) {
        $entry['post_backup_script'] = $entry['post_snapshot_script'];
    }
    return $entry;
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

    $skip_parent = (($cfg['skip_parent'] ?? 'no') === 'yes' && ($cfg['recursive'] ?? '') === 'yes') ? 'yes' : 'no';

    $pre_hook = trim((string)($cfg['pre_backup_script'] ?? $cfg['pre_snapshot_script'] ?? ''));
    $post_hook = trim((string)($cfg['post_backup_script'] ?? $cfg['post_snapshot_script'] ?? ''));
    if ($pre_hook !== '' && !validate_hook_script($pre_hook, $error_message)) {
        return null;
    }
    if ($post_hook !== '' && !validate_hook_script($post_hook, $error_message)) {
        return null;
    }
    $hook_timeout = normalize_hook_timeout($cfg['hook_timeout'] ?? '');
    $hook_failure_mode = normalize_hook_failure_mode($cfg['hook_failure_mode'] ?? '');

    if ($cfg['type'] == 'local') {
        return build_shell_command(array(
            $rc,
            'send_local_backup',
            $cfg['source_dataset'],
            $cfg['recursive'],
            $cfg['destination_dataset'],
            $uid,
            $skip_parent,
            $pre_hook,
            $post_hook,
            $hook_timeout,
            $hook_failure_mode,
        ));
    }

    if ($cfg['type'] == 'remote') {
        $identity = normalize_remote_identity('buddybackup', $cfg['destination_port'] ?? '', $error_message);
        if ($identity === null) {
            return null;
        }
        return build_shell_command(array(
            $rc,
            'send_backup',
            'remote',
            $cfg['source_dataset'],
            $cfg['recursive'],
            $cfg['destination_host'],
            $cfg['destination_dataset'],
            $uid,
            '',
            $identity['port'],
            $skip_parent,
            $pre_hook,
            $post_hook,
            $hook_timeout,
            $hook_failure_mode,
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
            $skip_parent,
            $pre_hook,
            $post_hook,
            $hook_timeout,
            $hook_failure_mode,
        ));
    }

    $error_message = "Unknown backup type: ".($cfg['type'] ?? '');
    return null;
}

function build_create_snapshot_and_send_command($cfg, $uid, &$error_message = null) {
    global $rc;

    $skip_parent = (($cfg['skip_parent'] ?? 'no') === 'yes' && ($cfg['recursive'] ?? '') === 'yes') ? 'yes' : 'no';
    $remote_user = '';
    $remote_port = '';
    if ($cfg['type'] == 'remote') {
        $identity = normalize_remote_identity('buddybackup', $cfg['destination_port'] ?? '', $error_message);
        if ($identity === null) {
            return null;
        }
        $remote_port = $identity['port'];
    } else if ($cfg['type'] == 'remote_generic') {
        $identity = resolve_remote_identity_from_cfg($cfg, 'destination', $error_message);
        if ($identity === null) {
            return null;
        }
        $remote_user = $identity['user'];
        $remote_port = $identity['port'];
    }

    // Check snapshots.cfg for the source dataset's snapshot hooks
    $snap_hooks = get_snapshot_hooks_for_dataset($cfg['source_dataset'] ?? '');
    $pre_hook = $snap_hooks['pre'];
    $post_hook = $snap_hooks['post'];
    $hook_timeout = $snap_hooks['timeout'];
    $hook_failure_mode = $snap_hooks['mode'];

    // Fall back to legacy keys on the backup task if not configured in snapshots.cfg
    if ($pre_hook === '' && !empty($cfg['pre_snapshot_script'])) {
        $pre_hook = trim((string)$cfg['pre_snapshot_script']);
    }
    if ($post_hook === '' && !empty($cfg['post_snapshot_script'])) {
        $post_hook = trim((string)$cfg['post_snapshot_script']);
    }
    if (!empty($cfg['hook_timeout'])) {
        $hook_timeout = normalize_hook_timeout($cfg['hook_timeout']);
    }
    if (!empty($cfg['hook_failure_mode'])) {
        $hook_failure_mode = normalize_hook_failure_mode($cfg['hook_failure_mode']);
    }

    if ($pre_hook !== '' && !validate_hook_script($pre_hook, $error_message)) {
        return null;
    }
    if ($post_hook !== '' && !validate_hook_script($post_hook, $error_message)) {
        return null;
    }

    $parts = array(
        $rc,
        'create_snapshot_and_send',
        $cfg['type'],
        $cfg['source_dataset'],
        $cfg['recursive'],
        $cfg['destination_host'] ?? '',
        $cfg['destination_dataset'],
        $uid,
        $remote_user,
        $remote_port,
        $skip_parent,
        $pre_hook,
        $post_hook,
        $hook_timeout,
        $hook_failure_mode,
    );

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
                    "immutable" => "yes",
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
    global $rc, $incoming_config_path, $empath, $tmp_recv_dataset_path, $tmp_incoming_json_path;

    ensure_runtime_dir();

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
        if (file_exists($tmp_incoming_json_path)) {
            @unlink($tmp_incoming_json_path);
        }
        if (file_exists("/tmp/buddybackup-recv-dest")) {
            @unlink("/tmp/buddybackup-recv-dest");
        }
        if (file_exists("/tmp/buddybackup-incoming.json")) {
            @unlink("/tmp/buddybackup-incoming.json");
        }
        return;
    }

    passthru($rc . ' setup_buddy_user');

    $first_dataset = null;
    $key_groups = array();

    foreach ($enabled_buddies as $uid => $buddy) {
        $dataset = trim($buddy['destination_dataset']);
        if (!is_valid_zfs_dataset_name($dataset)) {
            BB_ERR("Invalid destination dataset '$dataset' for buddy UID '$uid'");
            continue;
        }

        if ($first_dataset === null) {
            $first_dataset = $dataset;
        }

        $immutable = (($buddy['immutable'] ?? 'yes') === 'no') ? 'no' : 'yes';

        if (strpos($dataset, '/') === false) {
            BB_LOG("Destination parent dataset '$dataset' is a pool root; mountpoint=none and readonly=on skipped to avoid unmounting pool root.");
        }

        passthru(build_shell_command(array($rc, 'allow_buddy_dataset', $dataset, $immutable)), $allow_rc);
        if ($allow_rc !== 0) {
            if ($immutable === 'yes') {
                BB_WARN("Failed to lock dataset '$dataset' for buddy UID '$uid' (filesystem may be in use).");
            } else {
                BB_WARN("Failed to mount or configure dataset '$dataset' for buddy UID '$uid'.");
            }
        }

        $raw_key = trim($buddy['ssh_key'] ?? '');
        if ($raw_key === '') continue;

        $first_line = strtok($raw_key, "\r\n");
        $trimmed_key = trim($first_line ?: '');
        if ($trimmed_key === '') continue;

        if (!isset($key_groups[$trimmed_key])) {
            $key_groups[$trimmed_key] = array(
                'uids' => array(),
                'datasets' => array(),
            );
        }
        $key_groups[$trimmed_key]['uids'][] = $uid;
        if (!in_array($dataset, $key_groups[$trimmed_key]['datasets'], true)) {
            $key_groups[$trimmed_key]['datasets'][] = $dataset;
        }
    }

    $authorized_keys = "";
    foreach ($key_groups as $trimmed_key => $group) {
        $primary_uid = $group['uids'][0];
        $dataset_flags = "";
        foreach ($group['datasets'] as $ds) {
            $dataset_flags .= " --dataset " . escapeshellarg($ds);
        }
        $cmd_line = "$empath/deps/restrict_zfs" . $dataset_flags . " --uid " . escapeshellarg($primary_uid);
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
        if (is_link($tmp_recv_dataset_path)) {
            @unlink($tmp_recv_dataset_path);
        }
        file_put_contents($tmp_recv_dataset_path, $first_dataset);
        @chmod($tmp_recv_dataset_path, 0640);
        if (function_exists('posix_getuid') && posix_getuid() === 0) {
            @chown($tmp_recv_dataset_path, 'root');
            @chgrp($tmp_recv_dataset_path, 'buddybackup');
        }
    }

    $incoming_map = array();
    foreach ($enabled_buddies as $uid => $buddy) {
        $incoming_map[$uid] = array(
            'name' => $buddy['name'] ?? 'Buddy',
            'enable' => $buddy['enable'] ?? 'yes',
            'destination_dataset' => trim($buddy['destination_dataset']),
        );
    }
    if (is_link($tmp_incoming_json_path)) {
        @unlink($tmp_incoming_json_path);
    }
    file_put_contents($tmp_incoming_json_path, json_encode($incoming_map, JSON_PRETTY_PRINT));
    @chmod($tmp_incoming_json_path, 0640);
    if (function_exists('posix_getuid') && posix_getuid() === 0) {
        @chown($tmp_incoming_json_path, 'root');
        @chgrp($tmp_incoming_json_path, 'buddybackup');
    }

    if (file_exists("/tmp/buddybackup-buddy") && !is_link("/tmp/buddybackup-buddy")) {
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
    global $rc;

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

            $pre_hook = str_replace(array("\r", "\n"), '', trim((string)($section['pre_snapshot_script'] ?? '')));
            $post_hook = str_replace(array("\r", "\n"), '', trim((string)($section['post_snapshot_script'] ?? '')));
            $hook_timeout = normalize_hook_timeout($section['hook_timeout'] ?? '');
            $hook_failure_mode = normalize_hook_failure_mode($section['hook_failure_mode'] ?? '');
            $hook_scope = trim((string)($section['hook_scope'] ?? ''));
            $trigger = trim((string)($section['trigger'] ?? ''));
            if ($trigger === 'no' || !preg_match('/^[A-Za-z0-9_-]+$/', $trigger)) {
                $trigger = '';
            }

            foreach ($section as $key => $value) {
                if (in_array($key, array('dataset', 'trigger', 'pre_snapshot_script', 'post_snapshot_script', 'hook_timeout', 'hook_failure_mode', 'hook_scope', 'daily_hour', 'daily_min', 'weekly_hour', 'weekly_min', 'monthly_hour', 'monthly_min', 'yearly_hour', 'yearly_min'), true)) {
                    continue;
                }
                if ($key === 'recursive') {
                    $recursive_mode = ($value === 'yes' || $value === 'zfs') ? 'zfs' : 'no';
                    $sanoid_conf_content .= "    recursive = $recursive_mode\n";
                    continue;
                }
                $sanoid_conf_content .= "    $key = $value\n";
            }

            list($daily_hour, $daily_min) = normalize_snapshot_time($section['daily_hour'] ?? '', $section['daily_min'] ?? '');
            if ($daily_hour !== '' && $daily_min !== '') {
                $sanoid_conf_content .= "    daily_hour = $daily_hour\n";
                $sanoid_conf_content .= "    daily_min = $daily_min\n";
                $sanoid_conf_content .= "    weekly_hour = $daily_hour\n";
                $sanoid_conf_content .= "    weekly_min = $daily_min\n";
                $sanoid_conf_content .= "    monthly_hour = $daily_hour\n";
                $sanoid_conf_content .= "    monthly_min = $daily_min\n";
                $sanoid_conf_content .= "    yearly_hour = $daily_hour\n";
                $sanoid_conf_content .= "    yearly_min = $daily_min\n";
            }

            $daily_filter = '[ -n "${SANOID_TYPES:-}" ] && case "${SANOID_TYPES}" in *daily*) ;; *) exit 0;; esac; ';

            if ($pre_hook !== '') {
                $pre_hook = format_sanoid_hook_command($pre_hook);
                if ($hook_scope === 'daily') {
                    $pre_hook = $daily_filter . $pre_hook;
                }
                $sanoid_conf_content .= "    pre_snapshot_script = $pre_hook\n";
                if ($hook_failure_mode === 'abort') {
                    $sanoid_conf_content .= "    no_inconsistent_snapshot = 1\n";
                }
            }

            if ($pre_hook !== '' || $post_hook !== '') {
                $sanoid_conf_content .= "    script_timeout = $hook_timeout\n";
            }

            if ($post_hook !== '' && $trigger !== '') {
                $sanoid_conf_content .= "    force_post_snapshot_script = 1\n";
                $escaped_post_hook = addcslashes($post_hook, "\\\"$`");
                $post_cmd = "$rc run_snapshot_post_hook_and_trigger \"$dataset\" \"$escaped_post_hook\" \"$hook_timeout\" \"$trigger\"";
                if ($hook_scope === 'daily') {
                    $post_cmd .= " \"daily\"";
                }
                $sanoid_conf_content .= "    post_snapshot_script = $post_cmd\n";
            } else if ($post_hook !== '') {
                $sanoid_conf_content .= "    force_post_snapshot_script = 1\n";
                $post_hook = format_sanoid_hook_command($post_hook);
                if ($hook_scope === 'daily') {
                    $post_hook = $daily_filter . $post_hook;
                }
                $sanoid_conf_content .= "    post_snapshot_script = $post_hook\n";
            } else if ($trigger !== '') {
                $post_cmd = "$rc run_snapshot_post_hook_and_trigger \"$dataset\" \"\" \"30\" \"$trigger\"";
                $sanoid_conf_content .= "    post_snapshot_script = $post_cmd\n";
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
    global $rc;
    $plugin_cfg = parse_ini_file($plugin_config_path, false);
    if (file_exists($sanoid_cron_path)) {
        ENSURE_SUCCESS(unlink($sanoid_cron_path));
    }
    $tz = ($plugin_cfg["UtcTimezone"] == "yes") ? "TZ=UTC" : "";
    $command_env = "PATH=$buddybackup_path" . ($tz !== "" ? " $tz" : "");
    $cron_content = "# Generated cron settings for plugin buddybackup\n";
    $cron_content .= "* * * * * flock -n /var/lock/buddybackup-sanoid-cron -c \"$command_env $rc run_sanoid_cron --cache-ttl=60 --configdir=\"$plugin_path\" --cron\" 2>&1 | $log_script\n";
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

function scan_remote_known_hosts($host, $port) {
    $command = 'ssh-keyscan -T 5';
    if ((string)$port !== '' && (string)$port !== '22') {
        $command .= ' -p '.escapeshellarg($port);
    }
    $command .= ' '.escapeshellarg($host).' 2>/dev/null';

    $keys = [];
    $key_types = [];
    $standard_types = ['ssh-ed25519', 'ecdsa-sha2-nistp256', 'ssh-rsa'];
    $standard_types_found = 0;
    $empty_scans = 0;
    // ssh-keyscan can return only a subset of the offered host key types while
    // the peer is busy. Scan a few times and merge the results (deduplicated by
    // key material), so a partial scan cannot replace a complete known_hosts
    // entry and break host key verification later. Stop early once every
    // common key type has been seen, or once the peer is consistently
    // unreachable.
    for ($attempt = 0; $attempt < 5; $attempt++) {
        $scan = shell_exec($command);
        if (!is_string($scan) || trim($scan) === '') {
            $empty_scans++;
            if ($empty_scans >= 2) {
                break;
            }
            continue;
        }
        $empty_scans = 0;

        foreach (preg_split('/\r?\n/', $scan) as $line) {
            $line = trim($line);
            if ($line === '' || str_starts_with($line, '#')) {
                continue;
            }
            $parts = preg_split('/\s+/', $line);
            if (!is_array($parts) || count($parts) < 3) {
                continue;
            }
            $material = $parts[1].' '.$parts[2];
            if (!isset($keys[$material])) {
                $keys[$material] = $line;
            }
            $key_type = $parts[1];
            if (!isset($key_types[$key_type])) {
                $key_types[$key_type] = true;
                if (in_array($key_type, $standard_types, true)) {
                    $standard_types_found++;
                }
            }
        }

        if ($standard_types_found >= count($standard_types)) {
            break;
        }
    }

    if (empty($keys)) {
        return null;
    }

    sort($keys, SORT_STRING);
    return implode("\n", $keys);
}

// Returns the name of the first required field that is missing or blank in a
// backups.cfg entry, or null when the entry has everything needed to be scheduled.
// Only required fields are checked: optional fields (hooks, hook settings,
// destination user/port, flags added by newer versions) may legitimately be
// saved as empty strings and must never prevent a backup from being scheduled.
function backup_cfg_missing_required_field($cfg) {
    if (!is_array($cfg)) {
        return 'type';
    }
    $required = array('type', 'source_dataset', 'destination_dataset', 'backup_cron');
    $type = trim((string)($cfg['type'] ?? ''));
    if ($type === 'remote' || $type === 'remote_generic') {
        $required[] = 'destination_host';
    }
    foreach ($required as $key) {
        if (trim((string)($cfg[$key] ?? '')) === '') {
            return $key;
        }
    }
    return null;
}

function update_backups_from_config() {
    BB_LOG("Updating backup cronjobs");
    global $managed_known_hosts_path;
    global $plugin_path;
    global $backups_config_path;
    global $rc;
    $backup_cfg = parse_ini_file($backups_config_path, true);

    if (is_array($backup_cfg)) {
        $migrated = false;
        foreach ($backup_cfg as $u => &$c) {
            if (isset($c['pre_snapshot_script']) || isset($c['post_snapshot_script'])) {
                if (!isset($c['pre_backup_script']) && isset($c['pre_snapshot_script'])) {
                    $c['pre_backup_script'] = $c['pre_snapshot_script'];
                }
                if (!isset($c['post_backup_script']) && isset($c['post_snapshot_script'])) {
                    $c['post_backup_script'] = $c['post_snapshot_script'];
                }
                unset($c['pre_snapshot_script']);
                unset($c['post_snapshot_script']);
                $migrated = true;
            }
        }
        unset($c);
        if ($migrated) {
            $content = "";
            foreach ($backup_cfg as $sec => $vals) {
                $content .= "[$sec]\n";
                foreach ($vals as $k => $v) {
                    $escaped_v = str_replace('"', '\"', (string)$v);
                    $content .= "$k=\"$escaped_v\"\n";
                }
            }
            ENSURE_SUCCESS(file_put_contents($backups_config_path, $content) !== false);
        }
    }

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
            } else if ($type == 'remote') {
                $identity = normalize_remote_identity('buddybackup', $cfg['destination_port'] ?? '');
                if ($identity !== null) {
                    $port = $identity['port'];
                }
            }
            $destination_hosts[$destination_host.'|'.$port] = array('host' => $destination_host, 'port' => $port);
        }

        if (($cfg["enable"] ?? '') != "yes") {
            BB_VERBOSE("Skipped backup uid $uid because it is disabled");
            continue;
        }
        $missing_field = backup_cfg_missing_required_field($cfg);
        if ($missing_field !== null) {
            // BB_WARN passes its message through a shell; only log a sanitized uid.
            $safe_uid = preg_replace('/[^A-Za-z0-9_-]/', '?', (string)$uid);
            BB_WARN("Not scheduling backup uid $safe_uid because required field '$missing_field' is empty");
            continue;
        }

        add_backup_cron_file($uid, $cfg);
    }

    $destination_host_keys = array_keys($destination_hosts);
    sort($destination_host_keys, SORT_STRING);

    foreach ($destination_host_keys as $destination_host_key) {
        $entry = $destination_hosts[$destination_host_key];
        $scanned_keys = scan_remote_known_hosts($entry['host'], $entry['port']);
        if ($scanned_keys !== null) {
            $known_hosts_content .= $scanned_keys . "\n";
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
        $identity = normalize_remote_identity('buddybackup', $cfg['destination_port'] ?? '', $error_message);
        if ($identity === null) {
            echo $error_message;
            return;
        }
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
            $identity['user'],
            $identity['port'],
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
        $identity = normalize_remote_identity('buddybackup', $cfg['destination_port'] ?? '', $error_message);
        if ($identity === null) {
            echo $error_message;
            return;
        }
        passthru(build_shell_command(array(
            $rc,
            'get_available_snapshots',
            'remote',
            $cfg["destination_host"],
            $cfg["destination_dataset"],
            $identity['user'],
            $identity['port'],
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

// Write runtime telemetry file with timestamp and size of destination dataset. Used in Unraid dashboard.
function mark_received_backup($target_dataset = null) {
    global $incoming_config_path, $tmp_recv_dataset_path, $tmp_incoming_json_path, $run_dir;

    ensure_runtime_dir();

    $env_uid = getenv('BUDDY_UID') ?: ($_ENV['BUDDY_UID'] ?? '');
    $env_dataset = getenv('BUDDY_DATASET') ?: ($_ENV['BUDDY_DATASET'] ?? '');

    $matched_uids = array();
    $dataset = !empty($target_dataset) ? trim($target_dataset) : null;

    if ($dataset === null && !empty($env_dataset)) {
        $dataset = trim(explode(',', $env_dataset)[0]);
    }

    $incoming_cfg = null;
    $has_incoming_config = false;
    if (file_exists($incoming_config_path) && is_readable($incoming_config_path)) {
        $incoming_cfg = parse_ini_file($incoming_config_path, true);
        $has_incoming_config = true;
    } else if (file_exists($tmp_incoming_json_path) && is_readable($tmp_incoming_json_path) && !is_link($tmp_incoming_json_path)) {
        $incoming_cfg = json_decode(file_get_contents($tmp_incoming_json_path), true);
        $has_incoming_config = true;
    } else if (file_exists("/tmp/buddybackup-incoming.json") && is_readable("/tmp/buddybackup-incoming.json") && !is_link("/tmp/buddybackup-incoming.json")) {
        $incoming_cfg = json_decode(file_get_contents("/tmp/buddybackup-incoming.json"), true);
        $has_incoming_config = true;
    }

    if (is_array($incoming_cfg)) {
        // Prioritize matching dataset against incoming entries
        if (!empty($dataset)) {
            // 1. Exact match
            foreach ($incoming_cfg as $uid => $buddy) {
                $b_ds = trim($buddy['destination_dataset'] ?? '');
                if ($b_ds !== '' && $dataset === $b_ds) {
                    $matched_uids[] = $uid;
                }
            }
            // 2. Longest prefix match if no exact match
            if (empty($matched_uids)) {
                $best_prefix_len = -1;
                $prefix_matches = array();
                foreach ($incoming_cfg as $uid => $buddy) {
                    $b_ds = trim($buddy['destination_dataset'] ?? '');
                    if ($b_ds !== '' && str_starts_with($dataset, $b_ds . '/')) {
                        $len = strlen($b_ds);
                        if ($len > $best_prefix_len) {
                            $best_prefix_len = $len;
                            $prefix_matches = array($uid);
                        } else if ($len === $best_prefix_len) {
                            $prefix_matches[] = $uid;
                        }
                    }
                }
                $matched_uids = $prefix_matches;
            }
            if (!empty($matched_uids)) {
                $primary = $matched_uids[0];
                $dataset = trim($incoming_cfg[$primary]['destination_dataset'] ?? $dataset);
            }
        }

        // Fall back to environment UID if no dataset match
        if (empty($matched_uids) && !empty($env_uid) && isset($incoming_cfg[$env_uid])) {
            $matched_uids[] = $env_uid;
            if (empty($dataset) && isset($incoming_cfg[$env_uid]['destination_dataset'])) {
                $dataset = trim($incoming_cfg[$env_uid]['destination_dataset']);
            }
        }

        // Fallback for single enabled buddy
        if (empty($dataset) && empty($matched_uids)) {
            $enabled_buddies = array_filter($incoming_cfg, function($b) {
                return ($b['enable'] ?? '') === 'yes' && !empty($b['destination_dataset']);
            });
            if (count($enabled_buddies) === 1) {
                $matched_uids[] = array_key_first($enabled_buddies);
                $dataset = trim($enabled_buddies[$matched_uids[0]]['destination_dataset']);
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

    // Strip snapshot suffix if present before querying used property
    if (strpos($dataset, '@') !== false) {
        $dataset = explode('@', $dataset)[0];
    }

    $error_message = null;
    $dest_size = read_zfs_property_value($dataset, 'used', $error_message);
    if ($dest_size === null) {
        BB_ERR("Failed to get used size for buddy receive destination dataset '$dataset': $error_message");
        return;
    }

    $info = "last_ran=".time()."\ndest_size=$dest_size";
    if (!empty($matched_uids)) {
        foreach ($matched_uids as $matched_uid) {
            if ($matched_uid !== '') {
                $buddy_file = "$run_dir/buddy-$matched_uid";
                if (is_link($buddy_file)) {
                    @unlink($buddy_file);
                }
                file_put_contents($buddy_file, $info);
                @chmod($buddy_file, 0660);
            }
        }
    }
    if (!$has_incoming_config) {
        $fallback_file = "$run_dir/buddy";
        if (is_link($fallback_file)) {
            @unlink($fallback_file);
        }
        file_put_contents($fallback_file, $info);
        @chmod($fallback_file, 0660);
    } else if (file_exists("$run_dir/buddy")) {
        @unlink("$run_dir/buddy");
    }
    if (file_exists("/tmp/buddybackup-buddy") && !is_link("/tmp/buddybackup-buddy")) {
        @unlink("/tmp/buddybackup-buddy");
    }
}

function probe_zfs($target_dataset = null) {
    $error_message = null;
    $all_datasets = read_receive_destination_datasets($error_message);
    if (empty($all_datasets)) {
        write_probe_zfs_response('error', null, $error_message);
        exit(1);
    }

    if (!empty($target_dataset)) {
        $target = trim($target_dataset);
        $matched_ds = null;
        foreach ($all_datasets as $ds) {
            if ($target === $ds || str_starts_with($target, $ds . '/')) {
                $matched_ds = $ds;
                break;
            }
        }
        if ($matched_ds === null) {
            write_probe_zfs_response('error', null, "Target dataset '$target' is not within the receiver's configured datasets.");
            exit(1);
        }

        $probe_ds = $target;
        if (read_zfs_property_value($probe_ds, 'used', $error_message) === null) {
            if ($probe_ds !== $matched_ds && read_zfs_property_value($matched_ds, 'used', $error_message) !== null) {
                $probe_ds = $matched_ds;
            } else {
                write_probe_zfs_response('error', null, $error_message);
                exit(1);
            }
        }

        write_probe_zfs_response('ok', $target, null, $all_datasets);
        return;
    }

    $first_dataset = $all_datasets[0];
    if (read_zfs_property_value($first_dataset, 'used', $error_message) !== null) {
        write_probe_zfs_response('ok', $first_dataset, null, $all_datasets);
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

switch ($argv[1] ?? '') {
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
            $identity = normalize_remote_identity('buddybackup', $port, $error_message);
            if ($identity === null) {
                echo $error_message;
                break;
            }
            passthru(build_shell_command(array(
                $rc,
                'test_connection',
                $argv[2] ?? '',
                $argv[3] ?? '',
                $identity['port'],
            )));
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