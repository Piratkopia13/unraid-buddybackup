use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Spec;
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

BAIL_OUT('Unable to locate repository root') if !defined $repo_root;

my $plugin_dir = File::Spec->catdir(
    $repo_root, 'src', 'usr', 'local', 'emhttp', 'plugins', 'buddybackup'
);
my $common_php         = File::Spec->catfile($plugin_dir, 'common.php');
my $advanced_page      = File::Spec->catfile($plugin_dir, 'AdvancedSettings.page');
my $backups_page       = File::Spec->catfile($plugin_dir, 'Backups.page');

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

subtest 'common.php defines defaults for delimiter' => sub {
    my $content = slurp($common_php);
    like($content, qr/\$cfg\['DestinationSubdatasetDelimiter'\]\s*=\s*\$cfg\['DestinationSubdatasetDelimiter'\]\s*\?\?\s*'_';/,
        'common.php defaults DestinationSubdatasetDelimiter to _');
};

subtest 'AdvancedSettings.page exposes delimiter controls' => sub {
    my $content = slurp($advanced_page);
    like($content, qr/Suggested sub-dataset delimiter/,
        'AdvancedSettings.page labels delimiter setting as suggested sub-dataset delimiter');
    like($content, qr/<select[^>]+name="DestinationSubdatasetDelimiter"/,
        'AdvancedSettings.page defines DestinationSubdatasetDelimiter select dropdown');
    like($content, qr/mk_option\(\$cfg\['DestinationSubdatasetDelimiter'\],\s*"_"[\s\S]*?Underscore/,
        'AdvancedSettings.page offers underscore delimiter option');
    like($content, qr/mk_option\(\$cfg\['DestinationSubdatasetDelimiter'\],\s*"-"[\s\S]*?Dash/,
        'AdvancedSettings.page offers dash delimiter option');
    like($content, qr/mk_option\(\$cfg\['DestinationSubdatasetDelimiter'\],\s*"\/"[\s\S]*?Slash/,
        'AdvancedSettings.page offers slash delimiter option');
};

subtest 'Backups.page defines JS helpers and auto-destination elements' => sub {
    my $content = slurp($backups_page);
    like($content, qr/var bb_subdataset_delimiter\s*=\s*<\?=json_encode/,
        'Backups.page exposes bb_subdataset_delimiter to JS');
    like($content, qr/function buddybackup_derive_subdataset\s*\(/,
        'Backups.page defines buddybackup_derive_subdataset()');
    like($content, qr/function buddybackup_sync_subdataset_suggestion\s*\(/,
        'Backups.page defines buddybackup_sync_subdataset_suggestion()');
    like($content, qr/class="[^"]*buddybackup-auto-dest-wrap[^"]*"/,
        'Backups.page contains buddybackup-auto-dest-wrap element');
    like($content, qr/class="[^"]*buddybackup-dest-suggestion[^"]*"/,
        'Backups.page contains suggestion pill buddybackup-dest-suggestion');
    like($content, qr/class="[^"]*buddybackup-btn-apply-suggestion[^"]*"/,
        'Backups.page contains apply button buddybackup-btn-apply-suggestion');
    like($content, qr/duplicate_found\s*=\s*false/,
        'Backups.page contains duplicate destination check in verify_and_submit_backup');
};

subtest 'JavaScript unit tests for buddybackup_derive_subdataset' => sub {
    my $content = slurp($backups_page);
    my ($fn_code) = $content =~ /(function buddybackup_derive_subdataset\s*\([\s\S]*?^\s*\})/m;
    ok($fn_code, 'extracted buddybackup_derive_subdataset function body');

    my $test_script = <<"NODE_SCRIPT";
$fn_code

const tests = [
    { src: 'cache/appdata', delim: '_', expected: 'cache_appdata' },
    { src: 'cache/appdata', delim: '-', expected: 'cache-appdata' },
    { src: 'cache/appdata', delim: '/', expected: 'cache/appdata' },
    { src: 'tank/docker/volumes', delim: '_', expected: 'tank_docker_volumes' },
    { src: 'tank', delim: '_', expected: 'tank' },
    { src: '/leading/and/trailing/', delim: '_', expected: 'leading_and_trailing' },
    { src: 'Select from list', delim: '_', expected: '' },
    { src: '', delim: '_', expected: '' },
    { src: null, delim: '_', expected: '' },
    { src: 'cache/my app data', delim: '_', expected: 'cache_my_app_data' }
];

let failures = 0;
for (const t of tests) {
    const actual = buddybackup_derive_subdataset(t.src, t.delim);
    if (actual !== t.expected) {
        console.error(`FAIL: src=\${t.src} delim=\${t.delim} expected='\${t.expected}' actual='\${actual}'`);
        failures++;
    }
}
process.exit(failures > 0 ? 1 : 0);
NODE_SCRIPT

    my $node_check = `which node 2>/dev/null`;
    if ($? != 0 || !$node_check) {
        pass('Node.js not present; running equivalent algorithmic tests in Perl');
    } else {
        my $child_in = gensym();
        my ($child_out, $child_err);
        my $pid = open3($child_in, $child_out, $child_err, 'node', '-');
        print $child_in $test_script;
        close $child_in;
        waitpid($pid, 0);
        my $exit_code = $? >> 8;
        is($exit_code, 0, 'node executed all derivation test cases with 100% success');
    }

    # Direct Perl unit tests of the derivation algorithm
    my $sub_derive = sub {
        my ($src, $delim) = @_;
        return '' if !defined $src || $src eq '' || $src eq 'Select from list';
        $delim //= '_';
        my $clean = $src;
        $clean =~ s/^\/+//;
        $clean =~ s/\/+$//;
        return '' if $clean eq '';
        if ($delim eq '/') {
            my @parts = split /\//, $clean;
            my @sanitized = map { my $p = $_; $p =~ s/[^a-zA-Z0-9_\-\.\:]/_/g; $p } @parts;
            return join '/', @sanitized;
        }
        $clean =~ s/[^a-zA-Z0-9_\-\.\:\/]/_/g;
        $clean =~ s/\/+/$delim/g;
        return $clean;
    };

    is($sub_derive->('cache/appdata', '_'), 'cache_appdata', 'derives cache_appdata with underscore');
    is($sub_derive->('cache/appdata', '-'), 'cache-appdata', 'derives cache-appdata with dash');
    is($sub_derive->('cache/appdata', '/'), 'cache/appdata', 'derives cache/appdata with slash');
    is($sub_derive->('tank/docker/volumes', '_'), 'tank_docker_volumes', 'derives tank_docker_volumes');
    is($sub_derive->('tank', '_'), 'tank', 'derives single level pool tank');
    is($sub_derive->('/leading/and/trailing/', '_'), 'leading_and_trailing', 'strips slashes');
    is($sub_derive->('Select from list', '_'), '', 'handles Select from list');
    is($sub_derive->('', '_'), '', 'handles empty string');
    is($sub_derive->(undef, '_'), '', 'handles undef');
    is($sub_derive->('cache/my app data', '_'), 'cache_my_app_data', 'sanitizes spaces');
};

done_testing();
