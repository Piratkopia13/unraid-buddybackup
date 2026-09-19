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
    "bb_format_dashboard_time"
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
    "raw_timestamp"
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

done_testing();
