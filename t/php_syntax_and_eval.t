use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname basename);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

my @repo_root_candidates;
for my $anchor (
    dirname(File::Spec->rel2abs($0)),
    File::Spec->rel2abs($Bin),
    getcwd(),
) {
    next if !defined $anchor || $anchor eq q{};

    for my $candidate_root ($anchor, dirname($anchor)) {
        next if !defined $candidate_root || $candidate_root eq q{};
        next if grep { $_ eq $candidate_root } @repo_root_candidates;
        push @repo_root_candidates, $candidate_root;
    }
}

my $repo_root;
for my $candidate_root (@repo_root_candidates) {
    my $candidate_allowlist = File::Spec->catfile(
        $candidate_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup', 'deps', 'restrict_zfs'
    );
    if (-f $candidate_allowlist) {
        $repo_root = $candidate_root;
        last;
    }
}

BAIL_OUT("Unable to locate repository root") if !defined $repo_root;

my $plugin_dir = File::Spec->catdir($repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup');

# Check if php is available
my $php_bin = "php";
my $php_available = 0;
{
    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = eval { open3(undef, $stdout, $stderr, $php_bin, "-v") };
    if ($pid) {
        waitpid($pid, 0);
        $php_available = 1 if $? == 0;
    }
}

plan skip_all => "php CLI is required to test PHP syntax and template evaluation" if !$php_available;

# Setup mock emhttp environment with dynamix Helpers.php and plugin symlink
my $mock_emhttp = tempdir(CLEANUP => 1);
my $dynamix_include = File::Spec->catdir($mock_emhttp, 'plugins', 'dynamix', 'include');
make_path($dynamix_include);
my $helpers_php = File::Spec->catfile($dynamix_include, 'Helpers.php');
open my $hfh, '>', $helpers_php or die "Cannot create mock Helpers.php: $!";
print $hfh "<?php\n// Mock Dynamix Helpers.php\n";
close $hfh;

# Symlink buddybackup plugin dir into mock emhttp docroot
my $mock_bb_plugin = File::Spec->catdir($mock_emhttp, 'plugins', 'buddybackup');
symlink($plugin_dir, $mock_bb_plugin) or die "Cannot symlink plugin dir into mock emhttp: $!";

my @php_and_page_files;
find(
    sub {
        return unless -f $_;
        return unless $_ =~ /\.(?:php|page)$/;
        push @php_and_page_files, $File::Find::name;
    },
    $plugin_dir
);

@php_and_page_files = sort @php_and_page_files;

subtest "php -l syntax lint on all plugin PHP and .page files" => sub {
    for my $file (@php_and_page_files) {
        my $relpath = File::Spec->abs2rel($file, $repo_root);
        my $stdout = gensym;
        my $stderr = gensym;
        my $pid = open3(undef, $stdout, $stderr, $php_bin, "-l", $file);
        my $out = do { local $/; <$stdout> // "" };
        my $err = do { local $/; <$stderr> // "" };
        waitpid($pid, 0);
        my $exit_code = $? >> 8;

        is($exit_code, 0, "$relpath has valid PHP syntax")
            or diag("Output: $out\nError: $err");
    }
};

subtest "verify BuddysBackupSettings.page contains 0 ampersands" => sub {
    my $file = File::Spec->catfile($plugin_dir, 'BuddysBackupSettings.page');
    open my $fh, "<", $file or die "Cannot open $file: $!";
    my $line_num = 0;
    my @amp_lines;
    while (my $line = <$fh>) {
        $line_num++;
        if ($line =~ /&/) {
            push @amp_lines, "line $line_num: $line";
        }
    }
    close $fh;

    is(scalar(@amp_lines), 0, "BuddysBackupSettings.page has zero raw ampersands")
        or diag("Ampersands found in BuddysBackupSettings.page:\n" . join("", @amp_lines));
};

subtest "evaluate common.php and verify essential functions & telemetry keys" => sub {
    my $eval_script = <<'PHP';
error_reporting(E_ALL & ~E_NOTICE);
ini_set("display_errors", 1);

$docroot = $argv[1];
$_SERVER['DOCUMENT_ROOT'] = $argv[1];

// Mock Unraid webgui builtins
if (!function_exists("mk_option")) { function mk_option($a, $b, $c) { return ""; } }
if (!function_exists("parse_plugin_cfg")) { function parse_plugin_cfg($p, $a = false) { return []; } }
if (!function_exists("my_parse_ini_file")) { function my_parse_ini_file($f, $s = false) { return []; } }

require_once $argv[2];

$required_functions = [
    "bb_task_telemetry",
    "datasets",
    "backups",
    "bb_is_dataset_overlapping",
    "bb_format_dashboard_time",
    "bb_dataset_mount_status"
];

$missing = [];
foreach ($required_functions as $fn) {
    if (!function_exists($fn)) {
        $missing[] = $fn;
    }
}
if (!empty($missing)) {
    echo "MISSING_FUNCTIONS:" . implode(",", $missing) . "\n";
    exit(1);
}

// Test bb_task_telemetry return shape
$telemetry = bb_task_telemetry("incoming", "nonexistent_buddy");
$expected_keys = [
    "last_ran",
    "last_ran_class",
    "compact_last_ran",
    "status_label",
    "status_class",
    "dest_size",
    "has_run",
    "raw_timestamp",
    "last_status",
    "last_error_time",
    "last_error_code",
    "last_error_message",
    "days_overdue"
];

$missing_keys = [];
foreach ($expected_keys as $k) {
    if (!array_key_exists($k, $telemetry)) {
        $missing_keys[] = $k;
    }
}

if (!empty($missing_keys)) {
    echo "MISSING_TELEMETRY_KEYS:" . implode(",", $missing_keys) . "\n";
    exit(2);
}

// Test failure state parsing
$test_fail_file = "/tmp/buddybackup-testfailuid";
file_put_contents($test_fail_file, "last_ran=1700000000\ndest_size=50G\nlast_status=failed\nlast_error_time=1700001000\nlast_error_code=255\nlast_error_message=\"SSH connection refused\"\n");
$fail_tel = bb_task_telemetry("testfailuid");
@unlink($test_fail_file);
if ($fail_tel["last_status"] !== "failed" || $fail_tel["status_label"] !== "Failed" || $fail_tel["status_class"] !== "red-text" || $fail_tel["last_error_code"] !== 255) {
    echo "FAILED_TELEMETRY_PARSING_CHECK\n";
    exit(3);
}

echo "OK\n";
PHP

    my $common_php = File::Spec->catfile($plugin_dir, "common.php");
    my $stdout = gensym;
    my $stderr = gensym;
    my $pid = open3(undef, $stdout, $stderr, $php_bin, "-r", $eval_script, "--", $mock_emhttp, $common_php);
    my $out = do { local $/; <$stdout> // "" };
    my $err = do { local $/; <$stderr> // "" };
    waitpid($pid, 0);
    my $exit_code = $? >> 8;

    is($exit_code, 0, "common.php executes and defines all required telemetry and helper functions")
        or diag("Output: $out\nError: $err");
    like($out, qr/\bOK\b/, "common.php telemetry structure verified");
};

subtest "evaluate .page files through simulated Dynamix template extraction" => sub {
    my $runner_script = <<'PHP';
error_reporting(E_ALL & ~E_NOTICE);
ini_set("display_errors", 1);

$docroot = $argv[1];
$_SERVER['DOCUMENT_ROOT'] = $argv[1];

// Mock Unraid webgui globals and builtins
$var = ["SESSION" => "valid", "THEME" => "white"];
$display = ["theme" => "white", "unit" => "B"];
$buddybackup_cfg = [];
$incoming_cfg = [];
$tab = "buddybackup";

if (!function_exists("mk_option")) { function mk_option($a, $b, $c) { return ""; } }
if (!function_exists("parse_plugin_cfg")) { function parse_plugin_cfg($p, $a = false) { return []; } }
if (!function_exists("my_parse_ini_file")) { function my_parse_ini_file($f, $s = false) { return []; } }

if (!function_exists("parse_text")) {
    function parse_text($text) {
        return preg_replace_callback('/_\((.+?)\)_/m', function($m){
            return str_replace("'", "&apos;", $m[1]);
        }, $text);
    }
}

require_once $argv[2]; // common.php

$page_file = $argv[3];
$content = file_get_contents($page_file);
$parts = explode("---", $content, 2);
$body = isset($parts[1]) ? $parts[1] : $content;

// Run parse_text just like Unraid does before eval
$processed = parse_text($body);

// Wrap in output buffering so template evaluation does not pollute test output
ob_start();
try {
    eval("?>" . $processed);
    ob_end_clean();
    echo "EVAL_OK\n";
    exit(0);
} catch (Throwable $e) {
    ob_end_clean();
    echo "EVAL_ERROR: " . $e->getMessage() . " on line " . $e->getLine() . "\n";
    exit(1);
}
PHP

    my $common_php = File::Spec->catfile($plugin_dir, "common.php");
    my @pages = grep { $_ =~ /\.page$/ } @php_and_page_files;

    for my $page (@pages) {
        my $relpath = File::Spec->abs2rel($page, $repo_root);
        my $stdout = gensym;
        my $stderr = gensym;
        my $pid = open3(undef, $stdout, $stderr, $php_bin, "-r", $runner_script, "--", $mock_emhttp, $common_php, $page);
        my $out = do { local $/; <$stdout> // "" };
        my $err = do { local $/; <$stderr> // "" };
        waitpid($pid, 0);
        my $exit_code = $? >> 8;

        is($exit_code, 0, "$relpath evaluates cleanly in simulated Dynamix environment")
            or diag("Eval failed for $relpath: Output: $out\nError: $err");
    }
};

subtest "Backups.page title bar and header send_backup resolution" => sub {
    my $backups_page = File::Spec->catfile($plugin_dir, "Backups.page");
    open my $fh, "<", $backups_page or die "Cannot open $backups_page: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/function\s+get_backup_form\s*\(/, "Backups.page defines get_backup_form");
    like($content, qr/function\s+send_backup\s*\([^)]*\)\s*\{\s*var\s+form\s*=\s*get_backup_form\(/, "send_backup resolves form via get_backup_form");
    like($content, qr/function\s+create_snapshot_and_send\s*\([^)]*\)\s*\{\s*var\s+form\s*=\s*get_backup_form\(/, "create_snapshot_and_send resolves form via get_backup_form");
    like($content, qr/class="buddybackup-header-right"[^>]*>.*?onclick="send_backup\(this\)"/s, "Title bar header contains Send backup now button wired to send_backup(this)");
    like($content, qr/<input[^>]*class="disable-on-unsaved"[^>]*data-uid=/, "Header Send backup now button includes data-uid attribute");
};

subtest "Direct scroll to log anchor navigation and Log.page anchors" => sub {
    my $bb_page = File::Spec->catfile($plugin_dir, "BuddyBackup.page");
    open my $fh, "<", $bb_page or die "Cannot open $bb_page: $!";
    my $bb_content = do { local $/; <$fh> };
    close $fh;

    unlike($bb_content, qr#/Settings/BuddyBackup/Log#, "BuddyBackup.page does not contain hardcoded /Settings/BuddyBackup/Log standalone link");
    like($bb_content, qr/function\s+buddybackup_scroll_to_log\s*\(/, "BuddyBackup.page defines buddybackup_scroll_to_log");
    like($bb_content, qr/scrollHeight/, "BuddyBackup.page scrolls log window to bottom using scrollHeight");
    unlike($bb_content, qr/logEl\.focus\(\)/, "BuddyBackup.page does not focus logEl directly to avoid scrolling to oldest entries");

    my $backups_page = File::Spec->catfile($plugin_dir, "Backups.page");
    open my $bfh, "<", $backups_page or die "Cannot open $backups_page: $!";
    my $b_content = do { local $/; <$bfh> };
    close $bfh;
    like($b_content, qr/onclick="buddybackup_scroll_to_log\(\)"/, "Backups.page View Log button calls buddybackup_scroll_to_log");

    my $buddy_page = File::Spec->catfile($plugin_dir, "BuddysBackupSettings.page");
    open my $bdfh, "<", $buddy_page or die "Cannot open $buddy_page: $!";
    my $bd_content = do { local $/; <$bdfh> };
    close $bdfh;
    like($bd_content, qr/onclick="buddybackup_scroll_to_log\(\)"/, "BuddysBackupSettings.page View Log button calls buddybackup_scroll_to_log");

    my $log_page = File::Spec->catfile($plugin_dir, "Log.page");
    open my $lfh, "<", $log_page or die "Cannot open $log_page: $!";
    my $log_content = do { local $/; <$lfh> };
    close $lfh;

    like($log_content, qr/id=['"]buddybackup-log['"]/, "Log.page contains buddybackup-log element");
    like($log_content, qr/id=['"]buddybackup-log-section['"]|id=['"]log['"]/, "Log.page contains log anchor target");
};

subtest "Section entries collapse and initial expand all toggle state" => sub {
    my %pages = (
        'Backups.page' => 'buddybackup-backup-list',
        'BuddysBackupSettings.page' => 'buddybackup-buddy-list',
        'SnapshotSettings.page' => 'buddybackup-snapshot-creation-list',
    );

    for my $pname (sort keys %pages) {
        my $pfile = File::Spec->catfile($plugin_dir, $pname);
        open my $fh, "<", $pfile or die "Cannot open $pfile: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        my $list_id = $pages{$pname};
        like($content, qr/onclick="buddybackup_toggle_all\('$list_id',\s*this\)"[^>]*>\s*<i\s+class="[^"]*fa-expand[^"]*"><\/i>\s*<span><\?=_?\('Expand All'\)\?>/s,
            "$pname starts with Expand All button with fa-expand");
        unlike($content, qr/onclick="buddybackup_toggle_all\('$list_id',\s*this\)"[^>]*>\s*<i\s+class="[^"]*fa-compress/s,
            "$pname does not start with Collapse All button");
        like($content, qr/id="$list_id"\s+data-collapsed="true"/,
            "$pname list container $list_id has data-collapsed='true'");
    }

    my $bb_page = File::Spec->catfile($plugin_dir, "BuddyBackup.page");
    open my $fh, "<", $bb_page or die "Cannot open $bb_page: $!";
    my $bb_content = do { local $/; <$fh> };
    close $fh;

    like($bb_content, qr/btn\.find\('\.fa-expand'\)\.length\s*>\s*0/, "BuddyBackup.page checks for fa-expand state on button");
};

subtest "Progress modal Done transition and skip_parent configuration" => sub {
    my $bb_page = File::Spec->catfile($plugin_dir, "BuddyBackup.page");
    open my $fh, "<", $bb_page or die "Cannot open $bb_page: $!";
    my $bb_content = do { local $/; <$fh> };
    close $fh;

    like($bb_content, qr/\[\[rc\.buddybackup finished\]\].*?button\.confirm.*?Done/s,
        "BuddyBackup.page switches confirm button to Done when finished signal is received");
    like($bb_content, qr/\[\[rc\.buddybackup finished\]\].*?button\.cancel.*?hide\(\)/s,
        "BuddyBackup.page hides cancel button when finished signal is received");

    my $backups_page = File::Spec->catfile($plugin_dir, "Backups.page");
    open my $bfh, "<", $backups_page or die "Cannot open $backups_page: $!";
    my $b_content = do { local $/; <$bfh> };
    close $bfh;

    like($b_content, qr/name="skip_parent"/, "Backups.page defines skip_parent dropdown");
    like($b_content, qr/class="[^"]*buddybackup-skip-parent-row[^"]*"/, "Backups.page defines buddybackup-skip-parent-row container");

    my $rc_php = File::Spec->catfile($plugin_dir, "scripts", "rc.buddybackup.php");
    open my $rfh, "<", $rc_php or die "Cannot open $rc_php: $!";
    my $rc_content = do { local $/; <$rfh> };
    close $rfh;

    like($rc_content, qr/\$skip_parent\s*=.*?\$cfg\['skip_parent'\]/, "rc.buddybackup.php evaluates skip_parent from config");

    my $rc_sh = File::Spec->catfile($plugin_dir, "scripts", "rc.buddybackup");
    open my $sfh, "<", $rc_sh or die "Cannot open $rc_sh: $!";
    my $sh_content = do { local $/; <$sfh> };
    close $sfh;

    like($sh_content, qr/--skip-parent/, "rc.buddybackup includes --skip-parent syncoid flag support");
};

subtest "Dataset immutability toggle and destination match support" => sub {
    my $buddy_page = File::Spec->catfile($plugin_dir, "BuddysBackupSettings.page");
    open my $fh, "<", $buddy_page or die "Cannot open $buddy_page: $!";
    my $buddy_content = do { local $/; <$fh> };
    close $fh;

    my $common_php = File::Spec->catfile($plugin_dir, "common.php");
    open my $cfh, "<", $common_php or die "Cannot open $common_php: $!";
    my $common_content = do { local $/; <$cfh> };
    close $cfh;

    like($common_content, qr/zfs get -H -t filesystem -o name,property,value mounted,readonly,keystatus,mountpoint -r/, "common.php restricts bb_dataset_mount_status to filesystem datasets");
    like($common_content, qr/strpos\(\$name,\s*'\@'\)\s*!==\s*false/, "common.php ignores snapshots in bb_dataset_mount_status");
    like($common_content, qr/preg_match\('\/\^\[A-Za-z0-9\]\[A-Za-z0-9_.: \\\/-\]\*\$\/',\s*\$dataset\)/, "common.php supports space in bb_dataset_mount_status regex");

    like($buddy_content, qr/name="immutable"/, "BuddysBackupSettings.page defines immutable dropdown");
    like($buddy_content, qr/class="[^"]*buddybackup-immutable-warning[^"]*"/, "BuddysBackupSettings.page defines immutable warning container");

    like($buddy_content, qr/bb_dataset_mount_status/, "BuddysBackupSettings.page calls bb_dataset_mount_status");
    like($buddy_content, qr/\$ds_pill_label/, "BuddysBackupSettings.page defines ds_pill_label");
    like($buddy_content, qr/Lock Failed/, "BuddysBackupSettings.page handles Lock Failed state");
    like($buddy_content, qr/children_mounted/, "BuddysBackupSettings.page checks children_mounted for Lock Failed state");
    like($buddy_content, qr/Key Locked/, "BuddysBackupSettings.page handles Key Locked state");
    like($buddy_content, qr/Mounted \(Partial\)/, "BuddysBackupSettings.page handles Mounted (Partial) state for partially encrypted child datasets");
    like($buddy_content, qr/Retry Lock/, "BuddysBackupSettings.page provides Retry Lock action banner");

    my $rc_php = File::Spec->catfile($plugin_dir, "scripts", "rc.buddybackup.php");
    open my $rfh, "<", $rc_php or die "Cannot open $rc_php: $!";
    my $rc_content = do { local $/; <$rfh> };
    close $rfh;

    like($rc_content, qr/\$immutable\s*=.*?\$buddy\['immutable'\]/, "rc.buddybackup.php evaluates immutable from buddy config");
    like($rc_content, qr/'allow_buddy_dataset',\s*\$dataset,\s*\$immutable/, "rc.buddybackup.php passes immutable to allow_buddy_dataset");
    like($rc_content, qr/\$allow_rc/, "rc.buddybackup.php captures allow_buddy_dataset exit status");
    like($rc_content, qr/"immutable"\s*=>\s*"yes"/, "rc.buddybackup.php sets immutable=yes during legacy migration");

    my $rc_sh = File::Spec->catfile($plugin_dir, "scripts", "rc.buddybackup");
    open my $sfh, "<", $rc_sh or die "Cannot open $rc_sh: $!";
    my $sh_content = do { local $/; <$sfh> };
    close $sfh;

    like($sh_content, qr/allow_buddy_dataset\(\)\s*\{\s*local dataset="\$1"\s*local immutable="\$\{2:-yes\}"/s, "rc.buddybackup allow_buddy_dataset accepts immutable parameter");
    like($sh_content, qr/if ! zfs list -H -o name "\$\{dataset\}" >\/dev\/null 2>&1;\s*then\s*return 0;?\s*fi/s, "rc.buddybackup returns cleanly when dataset does not exist");
    like($sh_content, qr/Destination dataset matches the receiver's configured dataset\./, "rc.buddybackup allows matching destination dataset in test_connection");
    like($sh_content, qr/Failed to lock dataset/, "rc.buddybackup verifies unmount and warns if locking fails");
    like($sh_content, qr/unraid_notify "\$\{err\}" "alert"/, "rc.buddybackup alerts via unraid_notify on lock failure");
    like($sh_content, qr/append_to_buddybackup_log "\$\{err\}"/, "rc.buddybackup writes lock failure to plugin log file");
    like($sh_content, qr/any_mounted=.*?zfs list -H -o mounted -r/s, "rc.buddybackup checks any_mounted across dataset tree");
    like($sh_content, qr/"\$\{final_mp\}" != "none" && "\$\{final_mp\}" != "legacy"/, "rc.buddybackup allows legacy mountpoint when checking lockdown status");
    like($sh_content, qr/zfs list -H -o name -r "\$\{dataset\}".*?sort.*?while IFS= read -r ds/s, "rc.buddybackup mounts children in sorted order");
    like($sh_content, qr/zfs list -H -o name -r "\$\{dataset\}".*?sort -r.*?while IFS= read -r ds/s, "rc.buddybackup unmounts children in reverse sorted order");
    like($sh_content, qr/zfs set setuid=off "\$\{dataset\}"/, "rc.buddybackup strictly sets setuid=off even when immutability is disabled");
    unlike($sh_content, qr/setuid=on/, "rc.buddybackup never enables setuid on backup datasets");
    unlike($sh_content, qr/zfs inherit -r (?:readonly|setuid|exec)\s+["']?\$\{dataset\}["']?/, "rc.buddybackup never runs recursive property inheritance on parent dataset");
    like($sh_content, qr/zfs set readonly=on\s+["']?\$\{dataset\}["']?/, "rc.buddybackup sets readonly=on on parent dataset");
    like($sh_content, qr/tail -n \+2.*?zfs inherit readonly/s, "rc.buddybackup only inherits readonly on child datasets");
    like($sh_content, qr/tail -n \+2.*?zfs inherit mountpoint/s, "rc.buddybackup inherits mountpoint on child datasets");
    like($buddy_content, qr/readonly_failed.*?Lock Failed/s, "BuddysBackupSettings.page flags Lock Failed if readonly is not on");
};

subtest "Overdue alert message formatting" => sub {
    my $buddy_page = File::Spec->catfile($plugin_dir, "BuddysBackupSettings.page");
    open my $fh, "<", $buddy_page or die "Cannot open $buddy_page: $!";
    my $buddy_content = do { local $/; <$fh> };
    close $fh;

    like($buddy_content, qr/sprintf\(_\('No incoming backup received from this buddy in over %s days\. Last received: %s'\)/, "BuddysBackupSettings.page formats overdue warning with sprintf and proper spaces");

    my $backups_page = File::Spec->catfile($plugin_dir, "Backups.page");
    open my $bfh, "<", $backups_page or die "Cannot open $backups_page: $!";
    my $backups_content = do { local $/; <$bfh> };
    close $bfh;

    like($backups_content, qr/sprintf\(_\('This backup has not successfully completed in over %s days\. Last successful run: %s'\)/, "Backups.page formats overdue warning with sprintf and proper spaces");
};

done_testing();
