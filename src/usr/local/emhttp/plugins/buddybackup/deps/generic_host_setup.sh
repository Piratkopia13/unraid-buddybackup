#!/bin/bash
set -o pipefail
set -o nounset

export PATH="/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin${PATH:+:${PATH}}"

usage() {
    cat <<'USAGE_EOF'
Usage: generic_host_setup.sh --role receiver|sender --dataset NAME --pubkey KEY [options]

One-time setup for a generic OpenZFS host (TrueNAS SCALE, Proxmox VE, Debian, Ubuntu)
so an Unraid server running the BuddyBackup plugin can push backups to this host
(role receiver) or pull backups from this host (role sender).

Run as root on the remote host. Idempotent: safe to re-run (e.g. after editing SSH
keys in the TrueNAS UI). --dataset may be repeated; every run converges the zfs
allow grants it manages: datasets no longer requested (or whose role changed)
are revoked. Grants are tracked in a root-owned state file next to the allowlist.
Self-verifying: finishes with a PASS/FAIL checklist, and --verify runs only the
checks.

Setup (creates/updates the restricted user, allowlist and delegations):
  --role receiver|sender    receiver: this Unraid pushes backups to this host.
                            sender:   this Unraid pulls backups from this host.
  --dataset NAME            repeatable. receiver: parent dataset backups are
                            received into (created with mountpoint=none if
                            missing; an existing dataset is only accepted if
                            nothing below it is mounted).
                            sender:   dataset (or parent of datasets) to serve.
  --pubkey KEY              Unraid's SSH public key (single line).

Revocation and uninstall:
  --revoke NAME             revoke all zfs delegations for the user on NAME and
                            drop it from the tracked grant set. Can be combined
                            with a normal setup run, or used alone to only
                            revoke.
  --clean                   full uninstall for this user: revoke every tracked
                            (and discovered) zfs delegation, remove the
                            allowlist script(s), sudo flag files, sudoers entry,
                            sshd drop-in and the forced-command line from
                            authorized_keys. Never touches datasets or data.
  --delete-user             with --clean only: also delete the user account
                            (TrueNAS: printed as UI instructions).

Optional:
  --user NAME               SSH user to create/use (default: buddybackup; must be
                            a dedicated user, root/UID 0 is refused)
  --port N                  SSH service port, for notes only (default: 22)
  --sudo-mode auto|yes|no   allow validated commands to run via sudo where the
                            zfs binary is not executable by the user
                            (default: auto)
  --allowlist-dir PATH      directory for the forced-command allowlist script
                            (default: /usr/local/sbin; on TrueNAS SCALE, which
                            has a read-only and non-persistent root filesystem,
                            a hidden root-owned .buddybackup directory on the
                            dataset's pool; must be root-owned and not writable
                            by the SSH user)
  --verify                  only run the verification checklist
  --dry-run                 print what would be done, change nothing
  -h|--help                 this help

sudo mode keeps the forced-command allowlist as the fine-grained gate; sudo only
provides the coarse ability to execute the already-validated commands as root:
  <user> ALL=(root) NOPASSWD: /usr/bin/bash -c *
USAGE_EOF
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; ERRORS=$((ERRORS+1)); }
check_pass() { printf 'PASS: %s\n' "$*"; }
check_fail() { printf 'FAIL: %s\n' "$*" >&2; ERRORS=$((ERRORS+1)); }
check_warn() { printf 'WARN: %s\n' "$*" >&2; }

ROLE=""
USER_NAME=""
USER_ARG=""
DATASET=""
DATASET_LIST=()
REVOKE_LIST=()
DO_CLEAN=0
DELETE_USER=0
PUBKEY=""
PORT="22"
SUDO_MODE="auto"
ALLOWLIST_DIR_ARG=""
VERIFY_ONLY=0
DRY_RUN=0

ERRORS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --role|--user|--dataset|--revoke|--pubkey|--port|--sudo-mode|--allowlist-dir)
            # Guard: shift 2 with only one argument left would silently keep $1,
            # looping forever on the same option.
            if [ $# -lt 2 ]; then
                fail "Option $1 requires a value"
                exit 1
            fi
            ;;
    esac
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --user) USER_ARG="$2"; shift 2 ;;
        --dataset) DATASET_LIST+=("$2"); shift 2 ;;
        --revoke) REVOKE_LIST+=("$2"); shift 2 ;;
        --pubkey) PUBKEY="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --sudo-mode) SUDO_MODE="$2"; shift 2 ;;
        --clean) DO_CLEAN=1; shift ;;
        --delete-user) DELETE_USER=1; shift ;;
        --allowlist-dir)
            if [ -z "$2" ]; then
                fail "--allowlist-dir requires a non-empty value"
                exit 1
            fi
            ALLOWLIST_DIR_ARG="$2"
            shift 2
            ;;
        --verify) VERIFY_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
done

MODE="setup"
if [ "$DO_CLEAN" -eq 1 ]; then
    MODE="clean"
elif [ "${#REVOKE_LIST[@]}" -gt 0 ] && [ "${#DATASET_LIST[@]}" -eq 0 ]; then
    MODE="revoke"
fi
if [ "$DO_CLEAN" -eq 1 ] && { [ "${#REVOKE_LIST[@]}" -gt 0 ] || [ "${#DATASET_LIST[@]}" -gt 0 ]; }; then
    fail "--clean cannot be combined with --dataset or --revoke"
    exit 1
fi
if [ "$DELETE_USER" -eq 1 ] && [ "$DO_CLEAN" -eq 0 ]; then
    fail "--delete-user requires --clean"
    exit 1
fi
if [ "$VERIFY_ONLY" -eq 1 ] && { [ "$DO_CLEAN" -eq 1 ] || [ "${#REVOKE_LIST[@]}" -gt 0 ]; }; then
    fail "--verify cannot be combined with --clean or --revoke"
    exit 1
fi
if [ "$MODE" = "setup" ] && { [ -z "$ROLE" ] || { [ "$ROLE" != "receiver" ] && [ "$ROLE" != "sender" ]; }; }; then
    fail "--role must be 'receiver' or 'sender'"
    usage >&2
    exit 1
fi
if [ "$SUDO_MODE" != "auto" ] && [ "$SUDO_MODE" != "yes" ] && [ "$SUDO_MODE" != "no" ]; then
    fail "--sudo-mode must be auto, yes or no"
    exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    fail "--port must be a TCP port between 1 and 65535"
    exit 1
fi

USER_ARG="${USER_ARG:-buddybackup}"
USER_NAME="$USER_ARG"

DATASET_RE='^[A-Za-z0-9_][A-Za-z0-9_ /-]*(/[A-Za-z0-9_][A-Za-z0-9_ /-]*)*$'
candidate=""
for candidate in "${DATASET_LIST[@]}" "${REVOKE_LIST[@]}"; do
    if ! printf '%s' "$candidate" | grep -Eq "$DATASET_RE" || printf '%s' "$candidate" | grep -qE '(//|/$)'; then
        fail "Dataset name '$candidate' is not a valid ZFS dataset name (characters allowed: letters, digits, '_', ' ', '-', '/'; no '@' or double slashes)"
        exit 1
    fi
done
if [ "$MODE" = "setup" ] || [ "$VERIFY_ONLY" -eq 1 ]; then
    if [ "${#DATASET_LIST[@]}" -eq 0 ]; then
        fail "--dataset is required (repeat the option for more than one dataset)"
        exit 1
    fi
    for candidate in "${DATASET_LIST[@]}"; do
        for revoked in "${REVOKE_LIST[@]}"; do
            if [ "$candidate" = "$revoked" ]; then
                fail "Dataset '$candidate' is named by both --dataset and --revoke; use one or the other"
                exit 1
            fi
        done
    done
fi
DATASET="${DATASET_LIST[0]:-}"

if ! [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}\$?$ ]]; then
    fail "--user '$USER_NAME' is not a valid POSIX user name"
    exit 1
fi

# Never manage root (or any UID-0 alias): the SSH restrictions installed below
# (forced command, PasswordAuthentication no, PermitTTY no) would break
# administrative SSH access and could lock the operator out of the host.
if [ "$(id -u "$USER_NAME" 2>/dev/null)" = "0" ]; then
    fail "--user '$USER_NAME' resolves to UID 0; refusing to restrict administrative SSH access. Use a dedicated user (default: buddybackup)."
    exit 1
fi

PUBKEY_ALGO_RE='^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)@openssh\.com)) [A-Za-z0-9+/]+={0,2}( [^ ].*)?$'
if [ -n "$PUBKEY" ]; then
    # Any embedded newline (wc -l > 0) is rejected outright: grep validates line by
    # line, so a second line could otherwise smuggle an unrestricted key into
    # authorized_keys.
    if [ "$(printf '%s' "$PUBKEY" | wc -l)" -gt 0 ] || ! printf '%s' "$PUBKEY" | grep -Eq "$PUBKEY_ALGO_RE"; then
        fail "--pubkey is not a valid single-line OpenSSH public key"
        exit 1
    fi
fi

IS_SCALE=0
if { [ -f /etc/version ] && grep -qi truenas /etc/version 2>/dev/null; } \
   || { [ "$(uname -s)" = "Linux" ] && command -v midclt >/dev/null 2>&1; }; then
    # /etc/version carries the TrueNAS string on most releases, but some
    # versions drop or reformat it; midclt (the middleware CLI) has shipped on
    # every TrueNAS SCALE release. Combined with the Linux check this excludes
    # TrueNAS CORE (FreeBSD), which this Linux-only script does not support.
    IS_SCALE=1
fi

# Directory that receives the forced-command allowlist script. Constraints:
# root-writable, persistent across reboots, and NOT writable by the restricted
# SSH user - a user-writable forced-command target could be replaced with an
# unrestricted script, voiding the entire SSH lockdown.
# /usr/local/sbin fits generic hosts (Proxmox, Debian, Ubuntu). TrueNAS SCALE
# 24.04+ mounts its root filesystem read-only, so /usr/local/sbin cannot be
# written and would not survive a reboot anyway; there the allowlist is placed
# in a hidden root-owned .buddybackup directory on the pool that --dataset
# lives on (data pools are the persistent storage TrueNAS provides).
truenas_allowlist_dir() {
    local pool="${DATASET%%/*}"
    local mp
    mp=$(zfs get -H -o value mountpoint "$pool" 2>/dev/null | tr -d '\n')
    case "$mp" in
        /*) ;;
        # none, legacy, or zfs unavailable (dry-run without root): fall back to
        # the canonical pool mountpoint; a later failure points at the override.
        *) mp="/mnt/${pool}" ;;
    esac
    printf '%s' "${mp}/.buddybackup"
}

if [ -n "$ALLOWLIST_DIR_ARG" ]; then
    ALLOWLIST_DIR="$ALLOWLIST_DIR_ARG"
elif [ "$IS_SCALE" -eq 1 ] && [ -n "$DATASET" ]; then
    ALLOWLIST_DIR=$(truenas_allowlist_dir)
elif [ "$IS_SCALE" -eq 1 ]; then
    # clean/revoke without a dataset: relevant directories are found by scanning
    # the pool roots (collect_buddybackup_dirs), not derived here.
    ALLOWLIST_DIR=""
else
    ALLOWLIST_DIR="/usr/local/sbin"
fi
# ALLOWLIST_PATH is embedded verbatim inside a double-quoted sshd forced-command
# option, so characters that would terminate or escape that quoting (quotes,
# backslashes, whitespace, shell metacharacters) must never reach it.
if [ -n "$ALLOWLIST_DIR" ]; then
    ALLOWLIST_PATH_RE='^/[A-Za-z0-9_@+=.,:/-]+$'
    if ! printf '%s' "$ALLOWLIST_DIR" | grep -Eq "$ALLOWLIST_PATH_RE"; then
        fail "--allowlist-dir must be an absolute path using only letters, digits, '_', '-', '/', '.', '@', '+', '=', ',' and ':'"
        exit 1
    fi
    if [ "$ROLE" = "receiver" ]; then
        ALLOWLIST_PATH="${ALLOWLIST_DIR}/buddybackup-restrict_zfs"
    else
        ALLOWLIST_PATH="${ALLOWLIST_DIR}/buddybackup-restrict_zfs_send"
    fi
fi

if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$(id -u)" != "0" ]; then
        fail "This script must run as root (try: sudo -i). Use --dry-run to preview without root."
        exit 1
    fi
    if [ "$MODE" != "clean" ]; then
        if ! command -v zfs >/dev/null 2>&1; then
            fail "zfs binary not found for root. This host does not have OpenZFS?"
            exit 1
        fi
    fi
    if [ "$MODE" = "setup" ] || [ "$VERIFY_ONLY" -eq 1 ]; then
        if ! command -v sshd >/dev/null 2>&1 && ! [ -x /usr/sbin/sshd ]; then
            fail "sshd not found. An SSH server must be installed."
            exit 1
        fi
    fi
fi

zfs_quiet() { zfs "$@" >/dev/null 2>&1; }
zfs_prop() { zfs get -H -o value "$2" "$1" 2>/dev/null | tr -d '\n'; }

user_home() {
    getent passwd "$USER_NAME" 2>/dev/null | cut -d: -f6
}

user_can_exec_zfs() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$USER_NAME" -- sh -c 'command -v zfs >/dev/null 2>&1'
    else
        su -s /bin/sh "$USER_NAME" -c 'command -v zfs >/dev/null 2>&1'
    fi
}

# Runs `test <op> <path>` as the restricted user (access(2)-style check, so ACLs
# are caught too). Used to confirm the SSH user can traverse/execute the
# allowlist but can never rewrite it; a missing user simply yields "no".
user_path_test() {
    local op="$1"
    local path="$2"
    # Guard for the command-string fallback: every current caller passes a
    # path validated by ALLOWLIST_PATH_RE, and these characters are inert
    # inside single quotes. Anything else must not reach the shell below.
    if [ -z "$path" ] || printf '%s' "$path" | grep -Eq '[^A-Za-z0-9_@+=.,:/-]' || printf '%s' "$op" | grep -Eq '[^-wx]'; then
        return 2
    fi
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$USER_NAME" -- test "$op" "$path" 2>/dev/null
    else
        su -s /bin/sh "$USER_NAME" -c "test '$op' '$path'" 2>/dev/null
    fi
}

install_allowlist() {
    log "Installing command allowlist to ${ALLOWLIST_PATH}"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would install allowlist script ${ALLOWLIST_PATH}"
        return 0
    fi
    local allowlist_parent
    allowlist_parent=$(dirname "${ALLOWLIST_DIR}")
    if [ -d "${ALLOWLIST_DIR}" ]; then
        # Pre-existing directory: never silently take ownership. It must already
        # be root-owned and closed to the SSH user, otherwise the forced command
        # could be replaced by the very user it restricts.
        if [ "$(stat -c %u "${ALLOWLIST_DIR}" 2>/dev/null)" != "0" ]; then
            fail "${ALLOWLIST_DIR} must be owned by root so ${USER_NAME} cannot replace the forced-command script (chown it to root with mode 0755, or choose another location with --allowlist-dir)"
            return 1
        fi
        if user_path_test -w "${ALLOWLIST_DIR}"; then
            fail "${ALLOWLIST_DIR} is writable by ${USER_NAME}; the forced-command script could be replaced with an unrestricted one (make the directory root-owned 0755, or choose another location with --allowlist-dir)"
            return 1
        fi
    else
        if ! mkdir -p "${ALLOWLIST_DIR}"; then
            fail "Could not create ${ALLOWLIST_DIR}"
            if [ "$IS_SCALE" -eq 1 ]; then
                log "TrueNAS SCALE mounts its root filesystem read-only: system paths such as"
                log "/usr/local/sbin cannot be written and do not survive reboots. Point"
                log "--allowlist-dir at a persistent, root-owned directory on a data pool,"
                log "for example: --allowlist-dir /mnt/<pool>/.buddybackup"
            fi
            return 1
        fi
        if ! chown 0:0 "${ALLOWLIST_DIR}"; then
            fail "Could not enforce root ownership on ${ALLOWLIST_DIR}"
            return 1
        fi
        if ! chmod 755 "${ALLOWLIST_DIR}"; then
            fail "Could not set 0755 on ${ALLOWLIST_DIR}"
            return 1
        fi
    fi
    # Even with the directory itself locked down, a user-writable parent would
    # let the user remove it and plant a replacement in its place.
    if user_path_test -w "${allowlist_parent}"; then
        fail "${allowlist_parent} is writable by ${USER_NAME}; the allowlist directory could be removed and replaced (make it root-owned 0755, or choose another location with --allowlist-dir)"
        return 1
    fi
    # Write to a temp file in the same directory and rename atomically, so the
    # forced-command target never exists as a partially written file.
    local tmp_file="${ALLOWLIST_PATH}.tmp.$$"
    if [ "$ROLE" = "receiver" ]; then
        cat > "${tmp_file}" <<'BUDDYBACKUP_RESTRICT_ZFS_EOF'
#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Sys::Syslog qw(:standard :macros);
use Scalar::Util qw(looks_like_number);

$ENV{'PATH'} = join(':', grep { length } qw(/usr/local/sbin /usr/sbin /sbin /usr/local/bin /usr/bin /bin), ($ENV{'PATH'} // ''));

# Sudo mode: generic_host_setup.sh creates this flag file when the zfs binary is not
# executable for the user (TrueNAS SCALE). Validated commands are then run through
# sudo -n; the allowlist below remains the fine-grained gate either way.
my $use_sudo = (-f "$0.sudo") ? 1 : 0;

my $POOL = qr/'[\w-]+'/;
my $DATASET = qr/'[\w\/ -]+'/;
my $DATASET_SNAPSHOT = qr/'[\w\/ -]+('?)@('?)[\w:-]+'/;

my $SYNCOID_SNAPSHOT = qr/'[\w\/ -]+'@('?)syncoid_[\w:-]+\1/;

my $REDIRS = qr/(?:\s+(?:2>\/dev\/null|2>&1))?/;
my $PIPE = qr/\s*\|\s*/;
my $MBUFFER_CMD = qr/mbuffer (?:-[rR] \d+[kM])? (?:-W \d+ -I [\w.:-]+ )?-q -s \d+[kM] -m \d+[kM]/;
my $COMPRESS_CMD = qr/(?:(?:gzip -3|zcat|pigz -(?:\d+|dc)|(?:zstd|zstdmt) -(?:\d+|dc)|xz(?: -d)?|lzop(?: -dfc)?|lz4(?: -dc)?)\s*\|)?/;
my $SHORTOPTSVALS = qr/(?:-[A-Za-z0-9]+(?:\s+[a-z0-9:._=\/-]+)?\s+)*/;

my @ALLOWED_COMMANDS = (
    qr/exit/,
    qr/echo -n/,
    qr/echo ok/,
    qr/command -v (?:zstd|zstdmt|mbuffer)/,
    qr/zpool get -o value -H feature\@extensible_dataset $POOL/,
    qr/ps -Ao args=/,
    qr/zfs get -H (?:name|receive_resume_token|-p used|-o value used|syncoid:sync) $DATASET$REDIRS/,
    qr/zfs get -j (?:used) $DATASET$REDIRS/,
    qr/zfs get -j -p -d 1 -t snapshot guid,creation $DATASET$REDIRS/,
    qr/zfs get -Hpd 1 (?:-t (?:snapshot|bookmark) |type,)(?:guid,creation|all) $DATASET$REDIRS/,
    qr/zfs list -r -j -o name,origin -t filesystem,volume $DATASET/,
    qr/zfs list -o name,origin -t filesystem,volume -Hr $DATASET/,
    qr/$MBUFFER_CMD$PIPE$COMPRESS_CMD\s*zfs receive\s+$SHORTOPTSVALS$DATASET$REDIRS/,
    qr/zfs receive -A $DATASET/,
    qr/zfs send -w -nvP $DATASET_SNAPSHOT/,
    qr/zfs send -w -nvP -I $DATASET_SNAPSHOT\s+$DATASET_SNAPSHOT/,
    qr/zfs send -w\s+$DATASET_SNAPSHOT$PIPE$COMPRESS_CMD\s*$MBUFFER_CMD/,
    qr/zfs send -w\s+-i $DATASET_SNAPSHOT\s+$DATASET_SNAPSHOT$PIPE$COMPRESS_CMD\s*$MBUFFER_CMD/,
    qr/\/usr\/local\/emhttp\/plugins\/buddybackup\/scripts\/rc.buddybackup.php probe_zfs/,
    qr/\/usr\/local\/emhttp\/plugins\/buddybackup\/scripts\/rc.buddybackup.php mark_received_backup/,
);

sub check_allowed {
    my ($command) = @_;
    foreach my $regex (@ALLOWED_COMMANDS) {
        return 1 if $command =~ /^$regex$/;
    }
    return 0;
}

my $dry_run = 0;
my $verbose = 0;
my @log = ();
GetOptions(
    'dry-run' => \$dry_run,
    'verbose' => \$verbose,
    'log=s@'  => \@log,
);
@log = ('syslog') unless @log;

my $original_command = $ENV{'SSH_ORIGINAL_COMMAND'};
die "No SSH_ORIGINAL_COMMAND environment variable" unless defined $original_command;

openlog('buddybackup-restrict-ssh', 'pid', LOG_USER);

foreach my $command (split /;/, $original_command) {
    $command =~ s/^\s+|\s+$//g;
    my $is_allowed = check_allowed($command);

    my $log_text;
    if (!$is_allowed) {
        $log_text = "blocked command: $command";
    } elsif ($dry_run) {
        $log_text = "would run command: $command";
    } else {
        if ($verbose) {
            $log_text = "running command: $command";
        }
        if ($use_sudo) {
            system('/usr/bin/sudo', '-n', '--', '/usr/bin/bash', '-c', $command) == 0 or warn "Failed to execute command: $!";
        } else {
            system('/bin/bash', '-c', $command) == 0 or warn "Failed to execute command: $!";
        }
    }

    if ($log_text) {
        if (grep { $_ eq 'stderr' } @log) {
            print STDERR "$log_text\n";
        }
        if (grep { $_ eq 'syslog' } @log) {
            syslog(LOG_INFO, $log_text);
        }
    }
}

closelog();
BUDDYBACKUP_RESTRICT_ZFS_EOF
    else
        cat > "${tmp_file}" <<'BUDDYBACKUP_RESTRICT_ZFS_SEND_EOF'
#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Sys::Syslog qw(:standard :macros);

$ENV{'PATH'} = join(':', grep { length } qw(/usr/local/sbin /usr/sbin /sbin /usr/local/bin /usr/bin /bin), ($ENV{'PATH'} // ''));

# Sudo mode: generic_host_setup.sh creates this flag file when the zfs binary is not
# executable for the user (TrueNAS SCALE). Validated commands are then run through
# sudo -n; the allowlist below remains the fine-grained gate either way.
my $use_sudo = (-f "$0.sudo") ? 1 : 0;

my $POOL = qr/'[\w-]+'/;
my $DATASET = qr/'[\w\/ -]+'/;
my $DATASET_SNAPSHOT = qr/'[\w\/ -]+('?)@('?)[\w:-]+'/;

my $REDIRS = qr/(?:\s+(?:2>\/dev\/null|2>&1))?/;
my $PIPE = qr/\s*\|\s*/;
my $MBUFFER_CMD = qr/mbuffer (?:-[rR] \d+[kM])? (?:-W \d+ -I [\w.:-]+ )?-q -s \d+[kM] -m \d+[kM]/;
my $COMPRESS_CMD = qr/(?:(?:gzip -3|zcat|pigz -(?:\d+|dc)|(?:zstd|zstdmt) -(?:\d+|dc)|xz(?: -d)?|lzop(?: -dfc)?|lz4(?: -dc)?)\s*\|)?/;

my @ALLOWED_COMMANDS = (
    qr/exit/,
    qr/echo -n/,
    qr/echo ok/,
    qr/command -v (?:zfs|zstd|zstdmt|mbuffer)/,
    qr/zfs version/,
    qr/zpool get -o value -H feature\@extensible_dataset $POOL/,
    qr/zfs get -H (?:name|type|encryption|receive_resume_token|-p used|-o value used|syncoid:sync) $DATASET$REDIRS/,
    qr/zfs get -j (?:used|encryption) $DATASET$REDIRS/,
    qr/zfs get -j -p -d 1 -t snapshot guid,creation $DATASET$REDIRS/,
    qr/zfs get -Hpd 1 (?:-t (?:snapshot|bookmark) |type,)(?:guid,creation|all) $DATASET$REDIRS/,
    qr/zfs list -r -j -o name,origin -t filesystem,volume $DATASET/,
    qr/zfs list -o name,origin -t filesystem,volume -Hr $DATASET/,
    qr/zfs send\s+-nvP -t \d+/,
    qr/zfs send\s+-t \d+$PIPE$COMPRESS_CMD\s*$MBUFFER_CMD/,
    qr/zfs send -w -nvP $DATASET_SNAPSHOT/,
    qr/zfs send -w -nvP -I $DATASET_SNAPSHOT\s+$DATASET_SNAPSHOT/,
    qr/zfs send -w\s+$DATASET_SNAPSHOT$PIPE$COMPRESS_CMD\s*$MBUFFER_CMD/,
    qr/zfs send -w\s+-[Ii] $DATASET_SNAPSHOT\s+$DATASET_SNAPSHOT$PIPE$COMPRESS_CMD\s*$MBUFFER_CMD/,
);

sub check_allowed {
    my ($command) = @_;
    foreach my $regex (@ALLOWED_COMMANDS) {
        return 1 if $command =~ /^$regex$/;
    }
    return 0;
}

my $dry_run = 0;
my $verbose = 0;
my @log = ();
GetOptions(
    'dry-run' => \$dry_run,
    'verbose' => \$verbose,
    'log=s@'  => \@log,
);
@log = ('syslog') unless @log;

my $original_command = $ENV{'SSH_ORIGINAL_COMMAND'};
die "No SSH_ORIGINAL_COMMAND environment variable" unless defined $original_command;

openlog('buddybackup-restrict-ssh-send', 'pid', LOG_USER);

foreach my $command (split /;/, $original_command) {
    $command =~ s/^\s+|\s+$//g;
    my $is_allowed = check_allowed($command);

    my $log_text;
    if (!$is_allowed) {
        $log_text = "blocked command: $command";
    } elsif ($dry_run) {
        $log_text = "would run command: $command";
    } else {
        if ($verbose) {
            $log_text = "running command: $command";
        }
        if ($use_sudo) {
            system('/usr/bin/sudo', '-n', '--', '/usr/bin/bash', '-c', $command) == 0 or warn "Failed to execute command: $!";
        } else {
            system('/bin/bash', '-c', $command) == 0 or warn "Failed to execute command: $!";
        }
    }

    if ($log_text) {
        if (grep { $_ eq 'stderr' } @log) {
            print STDERR "$log_text\n";
        }
        if (grep { $_ eq 'syslog' } @log) {
            syslog(LOG_INFO, $log_text);
        }
    }
}

closelog();
BUDDYBACKUP_RESTRICT_ZFS_SEND_EOF
    fi
    # Exit status of the if/else above is the exit status of the heredoc cat.
    if [ $? -ne 0 ]; then
        fail "Could not write ${tmp_file}"
        rm -f "${tmp_file}"
        return 1
    fi
    if ! chmod 755 "${tmp_file}"; then
        fail "Could not chmod ${tmp_file}"
        rm -f "${tmp_file}"
        return 1
    fi
    if ! mv -f "${tmp_file}" "${ALLOWLIST_PATH}"; then
        fail "Could not install ${ALLOWLIST_PATH}"
        rm -f "${tmp_file}"
        return 1
    fi
    chown 0:0 "${ALLOWLIST_PATH}" >/dev/null 2>&1 || true
}

set_sudo_flag() {
    local flag_path="${ALLOWLIST_PATH}.sudo"
    local want_sudo="$1"
    if [ "$want_sudo" = "yes" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log "[dry-run] would create ${flag_path}"
        elif ! touch "${flag_path}"; then
            fail "Could not create ${flag_path}"
        else
            chmod 644 "${flag_path}"
            log "Sudo mode enabled (${flag_path})"
        fi
    else
        if [ -e "${flag_path}" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log "[dry-run] would remove ${flag_path}"
            else
                rm -f "${flag_path}"
                log "Sudo mode disabled (${flag_path} removed)"
            fi
        fi
    fi
}

install_sudoers() {
    local sudoers_file="/etc/sudoers.d/buddybackup-${USER_NAME}"
    if [ "$IS_SCALE" -eq 1 ]; then
        log ""
        log "TrueNAS SCALE detected: add the following line to the user's"
        log "'Allowed sudo commands with no password' field in the UI"
        log "(Credentials -> Users -> Edit -> Allowed sudo commands with no password):"
        log ""
        log "    /usr/bin/bash -c *"
        log ""
        log "That grant is coarse on purpose: the forced-command allowlist script"
        log "(${ALLOWLIST_PATH}) is the fine-grained gate for every SSH session."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would write ${sudoers_file}:"
        log "[dry-run]     Defaults:${USER_NAME} !requiretty"
        log "[dry-run]     ${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/bash -c *"
        return 0
    fi
    if ! command -v visudo >/dev/null 2>&1; then
        fail "visudo not found; cannot safely install a sudoers entry (is sudo installed?)"
        return 1
    fi
    # Temp file lives in /etc/sudoers.d itself so the final rename is atomic.
    # The dot in its name makes sudo skip it while it exists (sudo ignores
    # includedir entries containing a '.'), so a half-written file can never be
    # parsed and break sudo for everyone.
    local tmp_file
    tmp_file=$(mktemp "/etc/sudoers.d/.buddybackup-${USER_NAME}.XXXXXX") || { fail "Could not create a temp file in /etc/sudoers.d"; return 1; }
    {
        printf 'Defaults:%s !requiretty\n' "$USER_NAME"
        printf '%s ALL=(root) NOPASSWD: /usr/bin/bash -c *\n' "$USER_NAME"
    } > "${tmp_file}" || { fail "Could not write sudoers temp file"; rm -f "${tmp_file}"; return 1; }
    if ! visudo -cf "${tmp_file}" >/dev/null 2>&1; then
        fail "Generated sudoers file failed visudo validation"
        rm -f "${tmp_file}"
        return 1
    fi
    chmod 440 "${tmp_file}"
    if ! mv -f "${tmp_file}" "${sudoers_file}"; then
        fail "Could not install ${sudoers_file}"
        rm -f "${tmp_file}"
        return 1
    fi
    log "Installed ${sudoers_file} (coarse sudo grant; allowlist remains the fine-grained gate)"
}

remove_sudoers() {
    local sudoers_file="/etc/sudoers.d/buddybackup-${USER_NAME}"
    # TrueNAS SCALE manages sudo grants through its UI; nothing for us to remove.
    [ "$IS_SCALE" -eq 1 ] && return 0
    if [ -e "${sudoers_file}" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log "[dry-run] would remove leftover ${sudoers_file} (sudo mode disabled)"
        elif rm -f "${sudoers_file}"; then
            log "Removed leftover ${sudoers_file} (sudo mode disabled)"
        else
            fail "Could not remove ${sudoers_file}"
            return 1
        fi
    fi
    return 0
}

create_user() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would create user ${USER_NAME} (random undisclosed password, home dir, bash shell)"
        return 0
    fi
    if id "$USER_NAME" >/dev/null 2>&1; then
        log "User ${USER_NAME} already exists; leaving its credentials untouched"
        return 0
    fi
    if ! useradd -m -s /bin/bash "$USER_NAME"; then
        fail "Could not create user ${USER_NAME}"
        return 1
    fi
    if command -v openssl >/dev/null 2>&1; then
        echo "${USER_NAME}:$(openssl rand -base64 32)" | chpasswd >/dev/null
    else
        echo "${USER_NAME}:$(head -c 32 /dev/urandom | base64)" | chpasswd >/dev/null
    fi
    log "Created user ${USER_NAME} with a random, undisclosed password"
}

apply_zfs_allow() {
    local perms="$1"
    local ds="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would run: zfs allow -u ${USER_NAME} ${perms} ${ds}"
        return 0
    fi
    if ! zfs allow -u "$USER_NAME" "$perms" "$ds"; then
        fail "zfs allow -u ${USER_NAME} ${perms} ${ds} failed"
        return 1
    fi
}

has_plain_send_grant() {
    local ds="$1"
    zfs allow "$ds" 2>/dev/null | awk -v u="$USER_NAME" '
        $1 == "user" && $2 == u {
            n = split($3, perms, ",")
            for (i = 1; i <= n; i++) {
                if (perms[i] == "send") found = 1
            }
        }
        END { exit(found ? 0 : 1) }'
}

# Grant send access, preferring the raw-only send:raw permission (OpenZFS 2.4+).
# With send:raw, the user is physically unable to request a decrypted stream of an
# encrypted dataset. Any pre-existing plain 'send' grant is removed afterwards,
# because with both grants present the raw-only guarantee would be void.
apply_zfs_allow_send() {
    local ds="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would try: zfs allow -u ${USER_NAME} send:raw ${ds} (raw-only, OpenZFS 2.4+)"
        log "[dry-run]          and remove any plain 'send' grant: zfs unallow -u ${USER_NAME} send ${ds}"
        log "[dry-run]          fallback on older OpenZFS: zfs allow -u ${USER_NAME} send ${ds}"
        return 0
    fi
    if zfs allow -u "$USER_NAME" "send:raw" "$ds" 2>/dev/null; then
        log "Raw-only send delegation (send:raw, OpenZFS 2.4+): enabled"
        if has_plain_send_grant "$ds"; then
            if zfs unallow -u "$USER_NAME" "send" "$ds" 2>/dev/null; then
                log "Removed plain 'send' delegation so only raw sends remain possible"
            else
                warn "Could not remove the plain 'send' delegation; raw-only is NOT enforced."
                warn "Remove it manually: zfs unallow -u ${USER_NAME} send ${ds}"
            fi
        fi
        return 0
    fi
    if [ "$ROLE" = "sender" ]; then
        warn "send:raw delegation not supported by this OpenZFS version (< 2.4); falling back to plain 'send'."
        warn "With plain 'send', a compromised Unraid server could request DECRYPTED streams of ${ds}."
        warn "Upgrade this host to OpenZFS 2.4+ and re-run this script to enforce raw-only sends."
    else
        log "send:raw delegation not supported by this ZFS version; plain 'send' covers raw streams"
    fi
    if ! zfs allow -u "$USER_NAME" "send" "$ds"; then
        fail "zfs allow -u ${USER_NAME} send ${ds} failed"
        return 1
    fi
}

ensure_receiver_dataset() {
    local ds="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        if zfs_prop "$ds" "name" >/dev/null 2>&1; then
            log "[dry-run] dataset ${ds} exists; would ensure mountpoint=none (or legacy)"
        else
            log "[dry-run] would create parent dataset ${ds} with mountpoint=none"
        fi
        return 0
    fi
    if ! zfs_prop "$ds" "name" >/dev/null 2>&1; then
        log "Creating parent dataset ${ds} with mountpoint=none"
        if ! zfs create -p -o mountpoint=none "$ds"; then
            fail "Could not create dataset ${ds}"
            return 1
        fi
        return 0
    fi
    local mp
    mp=$(zfs_prop "$ds" "mountpoint" || echo "")
    case "$mp" in
        none|legacy)
            ;;
        *)
            # Never flip the mountpoint of a dataset (or tree) that is currently
            # mounted: zfs set mountpoint=none would unmount live data and could
            # disrupt running services. Only touch idle datasets.
            # (grep without -q consumes all input: no SIGPIPE/pipefail pitfalls
            # on large dataset trees.)
            local mounted_yes
            mounted_yes=$(zfs list -r -H -o mounted "$ds" 2>/dev/null | grep -x "yes" || true)
            if [ -n "$mounted_yes" ]; then
                fail "Dataset ${ds} or a dataset below it is currently MOUNTED (mountpoint '${mp}')."
                log "Refusing to set mountpoint=none on mounted data, as that would unmount it while in use."
                log "Pick a dataset path that does not exist yet (this script creates it with mountpoint=none),"
                log "or unmount the dataset and its children yourself first and re-run."
                return 1
            fi
            log "Setting mountpoint=none on ${ds} (was: '${mp}', nothing mounted). Received backups must never mount on this host - Linux cannot mount as a non-root user, and receive fails if mount is attempted."
            if ! zfs set mountpoint=none "$ds"; then
                fail "Could not set mountpoint=none on ${ds}"
                return 1
            fi
            ;;
    esac
}

# --- grant tracking, revocation and uninstall ---------------------------------
# Every setup run records the datasets it granted (one "<dataset><TAB><role>"
# line each) in a root-owned state file next to the allowlist. Later runs use
# it to converge: datasets no longer requested, or whose role changed, are
# revoked. --revoke removes single datasets; --clean uninstalls everything.

state_file_name() {
    printf 'buddybackup-%s-zfs-grants.txt' "$USER_NAME"
}

state_file_path() {
    printf '%s/%s' "$ALLOWLIST_DIR" "$(state_file_name)"
}

# Prints validated "<ds><TAB><role>" lines from a state file; corrupt or
# foreign lines are skipped rather than trusted.
read_tracked_grants() {
    local f="$1"
    [ -n "$f" ] && [ -f "$f" ] || return 0
    local ds role
    while IFS=$'\t' read -r ds role || [ -n "$ds" ]; do
        [ -n "$ds" ] || continue
        case "$ds" in '#'*) continue ;; esac
        if printf '%s' "$ds" | grep -Eq "$DATASET_RE" && ! printf '%s' "$ds" | grep -qE '(//|/$)'; then
            printf '%s\t%s\n' "$ds" "$role"
        fi
    done < "$f"
}

write_tracked_grants() {
    local f="$1"
    local entries="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would record granted datasets in ${f}"
        return 0
    fi
    if [ -z "$ALLOWLIST_DIR" ] || [ ! -d "$ALLOWLIST_DIR" ]; then
        warn "Could not record grant state: ${ALLOWLIST_DIR:-no allowlist directory} is not available"
        return 1
    fi
    if user_path_test -w "$ALLOWLIST_DIR"; then
        warn "Grant state not recorded: ${ALLOWLIST_DIR} is writable by ${USER_NAME}"
        return 1
    fi
    local tmp_file
    tmp_file=$(mktemp "${ALLOWLIST_DIR}/.buddybackup-grants.XXXXXX") || { warn "Could not create a grant state temp file in ${ALLOWLIST_DIR}"; return 1; }
    printf '%s\n' "$entries" > "${tmp_file}" || { warn "Could not write grant state"; rm -f "${tmp_file}"; return 1; }
    if ! mv -f "${tmp_file}" "$f"; then
        warn "Could not install grant state file ${f}"
        rm -f "${tmp_file}"
        return 1
    fi
    chmod 644 "$f" 2>/dev/null || true
    log "Grant state recorded in ${f}"
}

# Directories (root-owned) that contain BuddyBackup state or allowlist files:
# the resolved one, the generic default, and every pool root's .buddybackup
# dir - catches stranded files after the allowlist location changed.
collect_buddybackup_dirs() {
    local d mp seen=""
    for d in "$ALLOWLIST_DIR" "/usr/local/sbin"; do
        [ -n "$d" ] || continue
        [ -d "$d" ] || continue
        if ls "${d}/buddybackup-restrict_zfs"* >/dev/null 2>&1 || [ -f "${d}/$(state_file_name)" ]; then
            case "$seen" in *"|${d}|"*) ;; *) seen="${seen}|${d}|"; printf '%s\n' "$d" ;; esac
        fi
    done
    if command -v zfs >/dev/null 2>&1; then
        while IFS= read -r mp; do
            case "$mp" in
                /*)
                    d="${mp}/.buddybackup"
                    if [ -d "$d" ] && ls "${d}/buddybackup-"* >/dev/null 2>&1; then
                        case "$seen" in *"|${d}|"*) ;; *) seen="${seen}|${d}|"; printf '%s\n' "$d" ;; esac
                    fi
                    ;;
            esac
        done < <(zfs list -H -o mountpoint -d 1 -t filesystem 2>/dev/null)
    fi
}

# Every dataset whose zfs allow output names this user (used by --clean to
# catch delegations made outside recorded state, e.g. by older script versions
# or manually).
discover_user_delegations() {
    local ds
    while IFS= read -r ds; do
        [ -n "$ds" ] || continue
        if zfs allow "$ds" 2>/dev/null | grep -Eq "user ${USER_NAME}( |\$)"; then
            printf '%s\n' "$ds"
        fi
    done < <(zfs list -H -o name -t filesystem,volume 2>/dev/null)
}

# Revokes ALL zfs delegations the user holds on one dataset. Tolerates datasets
# that never had a delegation or no longer exist.
revoke_dataset_grants() {
    local ds="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would run: zfs unallow -u ${USER_NAME} ${ds}"
        return 0
    fi
    if ! zfs allow "$ds" 2>/dev/null | grep -Eq "user ${USER_NAME}( |\$)"; then
        log "No zfs delegation for ${USER_NAME} on ${ds}; nothing to revoke"
        return 0
    fi
    if zfs unallow -u "$USER_NAME" "$ds"; then
        log "Revoked all zfs delegations for ${USER_NAME} on ${ds}"
    else
        fail "zfs unallow -u ${USER_NAME} ${ds} failed"
        return 1
    fi
}

# Drops the --revoke datasets from a state file, rewriting it atomically.
filter_state_file() {
    local f="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would drop revoked entries from ${f}"
        return 0
    fi
    local tmp_file
    tmp_file=$(mktemp "$(dirname "$f")/.buddybackup-grants.XXXXXX") || { warn "Could not create a temp file in $(dirname "$f")"; return 1; }
    local ds role skip rev
    : > "${tmp_file}"
    while IFS=$'\t' read -r ds role || [ -n "$ds" ]; do
        [ -n "$ds" ] || continue
        skip="no"
        for rev in "${REVOKE_LIST[@]}"; do
            if [ "$ds" = "$rev" ]; then skip="yes"; fi
        done
        if [ "$skip" = "no" ]; then
            printf '%s\t%s\n' "$ds" "$role" >> "${tmp_file}"
        fi
    done < "$f"
    if ! mv -f "${tmp_file}" "$f"; then
        warn "Could not update ${f}"
        rm -f "${tmp_file}"
        return 1
    fi
    log "Removed revoked entries from ${f}"
}

# Points at grant state files outside the current allowlist dir, so operators
# learn about stranded grants instead of silently missing them.
warn_stranded_state() {
    local d f
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$d" = "$ALLOWLIST_DIR" ]; then continue; fi
        f="${d}/$(state_file_name)"
        if [ -f "$f" ]; then
            warn "Another grant state file exists at ${f}; its datasets are not touched by this run. Revoke them with --revoke, or uninstall with --clean."
        fi
    done < <(collect_buddybackup_dirs)
}

# Applies the role's delegations for every requested dataset and converges the
# tracked grant set: previously granted datasets that are no longer in the
# --dataset list (or whose role changed) are revoked first, then the requested
# ones are granted, then the state file is rewritten to exactly this run's set.
apply_grants_and_converge() {
    local tracked_file
    tracked_file=$(state_file_path)
    local -a tracked_ds=() tracked_role=() applied_ds=()
    local ds role keep i j rev entries=""
    while IFS=$'\t' read -r ds role || [ -n "$ds" ]; do
        [ -n "$ds" ] || continue
        tracked_ds+=("$ds")
        tracked_role+=("$role")
    done < <(read_tracked_grants "$tracked_file")

    for rev in "${REVOKE_LIST[@]}"; do
        revoke_dataset_grants "$rev" || true
    done

    for i in "${!tracked_ds[@]}"; do
        ds="${tracked_ds[$i]}"
        role="${tracked_role[$i]}"
        keep="no"
        for j in "${!DATASET_LIST[@]}"; do
            if [ "${DATASET_LIST[$j]}" = "$ds" ]; then
                keep="yes"
            fi
        done
        if [ "$keep" = "yes" ] && [ "$role" = "$ROLE" ]; then
            continue
        fi
        revoke_dataset_grants "$ds" || true
    done

    for ds in "${DATASET_LIST[@]}"; do
        if [ "$ROLE" = "receiver" ]; then
            if ensure_receiver_dataset "$ds"; then
                apply_zfs_allow "create,mount,receive" "$ds" || true
                apply_zfs_allow_send "$ds" || true
                applied_ds+=("$ds")
            else
                log "Skipping ZFS delegations because dataset ${ds} is not ready."
            fi
        else
            if zfs_prop "$ds" "name" >/dev/null 2>&1; then
                if [ "$DRY_RUN" -eq 1 ]; then
                    log "[dry-run] dataset ${ds} exists"
                fi
                apply_zfs_allow "hold" "$ds" || true
                apply_zfs_allow_send "$ds" || true
                applied_ds+=("$ds")
            else
                fail "Dataset ${ds} does not exist; sender role needs an existing dataset"
            fi
        fi
    done

    for i in "${!applied_ds[@]}"; do
        if [ -n "$entries" ]; then entries+=$'\n'; fi
        entries+="${applied_ds[$i]}"$'\t'"$ROLE"
    done
    write_tracked_grants "$tracked_file" "$entries"
    warn_stranded_state
}

# Standalone revocation: only the requested datasets lose their delegations;
# allowlist, SSH keys and the user are untouched.
run_revoke_mode() {
    log "Revoking zfs delegations for user ${USER_NAME}..."
    local rev d f
    for rev in "${REVOKE_LIST[@]}"; do
        revoke_dataset_grants "$rev" || true
    done
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        f="${d}/$(state_file_name)"
        if [ -f "$f" ]; then
            filter_state_file "$f"
        fi
    done < <(collect_buddybackup_dirs)
    if [ "$ERRORS" -gt 0 ]; then return 1; fi
    log "Revocation complete."
    return 0
}

remove_buddybackup_files() {
    local d f p
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        for f in "buddybackup-restrict_zfs" "buddybackup-restrict_zfs.sudo" \
                 "buddybackup-restrict_zfs_send" "buddybackup-restrict_zfs_send.sudo" \
                 "$(state_file_name)"; do
            p="${d}/${f}"
            if [ -f "$p" ]; then
                if [ "$DRY_RUN" -eq 1 ]; then
                    log "[dry-run] would remove ${p}"
                elif rm -f "$p"; then
                    log "Removed ${p}"
                else
                    warn "Could not remove ${p}"
                fi
            fi
        done
    done < <(collect_buddybackup_dirs)
}

remove_sshd_dropin() {
    if [ "$IS_SCALE" -eq 1 ]; then
        return 0
    fi
    local dropin_file="/etc/ssh/sshd_config.d/buddybackup-${USER_NAME}.conf"
    if [ ! -f "$dropin_file" ]; then
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would remove ${dropin_file}"
        return 0
    fi
    if ! rm -f "$dropin_file"; then
        warn "Could not remove ${dropin_file}"
        return 1
    fi
    log "Removed ${dropin_file}"
    local sshd_bin
    sshd_bin=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
    if ! "$sshd_bin" -t >/dev/null 2>&1; then
        warn "sshd config validation failed after drop-in removal; check the SSH configuration"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl reload ssh >/dev/null 2>&1 && ! systemctl reload sshd >/dev/null 2>&1; then
            warn "Could not reload the SSH service automatically; reload it manually"
        else
            log "SSH service reloaded"
        fi
    fi
    return 0
}

# Removes every line whose forced command points at a BuddyBackup allowlist,
# regardless of which directory it was installed in.
strip_forced_command_lines() {
    local home_dir
    home_dir=$(user_home)
    if [ -z "$home_dir" ] || [ ! -f "${home_dir}/.ssh/authorized_keys" ]; then
        log "No authorized_keys found for ${USER_NAME}; nothing to strip"
        return 0
    fi
    local ak_file="${home_dir}/.ssh/authorized_keys"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would remove buddybackup forced-command lines from ${ak_file}"
        return 0
    fi
    local tmp_file
    tmp_file=$(mktemp "${home_dir}/.ssh/.authorized_keys.XXXXXX") || { warn "Could not create a temp file in ${home_dir}/.ssh"; return 1; }
    if ! grep -Ev 'command="[^"]*buddybackup-restrict_zfs' "${ak_file}" > "${tmp_file}"; then
        : > "${tmp_file}"
    fi
    if ! mv -f "${tmp_file}" "${ak_file}"; then
        warn "Could not rewrite ${ak_file}"
        rm -f "${tmp_file}"
        return 1
    fi
    chmod 600 "${ak_file}"
    local owner_group
    owner_group="$(getent passwd "$USER_NAME" 2>/dev/null | cut -d: -f3):$(id -g "$USER_NAME" 2>/dev/null || echo "")"
    chown "$owner_group" "${ak_file}" 2>/dev/null || true
    log "Removed buddybackup forced-command lines from ${ak_file}"
}

delete_user_cleanup() {
    if [ "$IS_SCALE" -eq 1 ]; then
        log "TrueNAS SCALE detected: delete the user in the UI"
        log "(Credentials -> Users -> ${USER_NAME} -> Delete); the middleware manages"
        log "user accounts, so this script does not run userdel on TrueNAS."
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would delete user ${USER_NAME} and its home directory"
        return 0
    fi
    if id "$USER_NAME" >/dev/null 2>&1; then
        if userdel -r "$USER_NAME" >/dev/null 2>&1; then
            log "Deleted user ${USER_NAME} and its home directory"
        else
            fail "Could not delete user ${USER_NAME}"
            return 1
        fi
    else
        log "User ${USER_NAME} does not exist; nothing to delete"
    fi
}

clean_host() {
    log "Uninstalling everything this script set up for user ${USER_NAME}..."
    if command -v zfs >/dev/null 2>&1; then
        local -a to_revoke=()
        local -A seen_ds=()
        local d f ds dsr
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            f="${d}/$(state_file_name)"
            if [ -f "$f" ]; then
                while IFS=$'\t' read -r ds _role || [ -n "$ds" ]; do
                    [ -n "$ds" ] || continue
                    if [ -z "${seen_ds[$ds]-}" ]; then
                        seen_ds[$ds]=1
                        to_revoke+=("$ds")
                    fi
                done < "$f"
            fi
        done < <(collect_buddybackup_dirs)
        log "Scanning all datasets for zfs delegations held by ${USER_NAME}..."
        while IFS= read -r ds; do
            [ -n "$ds" ] || continue
            if [ -z "${seen_ds[$ds]-}" ]; then
                seen_ds[$ds]=1
                to_revoke+=("$ds")
            fi
        done < <(discover_user_delegations)
        if [ "${#to_revoke[@]}" -gt 0 ]; then
            for dsr in "${to_revoke[@]}"; do
                revoke_dataset_grants "$dsr" || true
            done
        else
            log "No zfs delegations found for ${USER_NAME}"
        fi
    else
        log "zfs not found; skipping delegation cleanup"
    fi
    remove_buddybackup_files
    if [ "$IS_SCALE" -eq 0 ] && [ -f "/etc/sudoers.d/buddybackup-${USER_NAME}" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log "[dry-run] would remove /etc/sudoers.d/buddybackup-${USER_NAME}"
        elif rm -f "/etc/sudoers.d/buddybackup-${USER_NAME}"; then
            log "Removed /etc/sudoers.d/buddybackup-${USER_NAME}"
        else
            warn "Could not remove /etc/sudoers.d/buddybackup-${USER_NAME}"
        fi
    fi
    remove_sshd_dropin
    strip_forced_command_lines
    if [ "$DELETE_USER" -eq 1 ]; then
        delete_user_cleanup
    fi
    if [ "$IS_SCALE" -eq 1 ]; then
        log ""
        log "TrueNAS UI cleanup steps (not done by this script):"
        log "  - Remove the 'Match User ${USER_NAME}' block from the SSH service's 'Auxiliary"
        log "    Parameters' (System Settings -> Services -> SSH)."
        log "  - Remove the user's SSH public key, or delete the user, in Credentials -> Users."
    fi
    log "Uninstall complete. Datasets and their data were not touched."
    if [ "$ERRORS" -gt 0 ]; then return 1; fi
    return 0
}

write_authorized_keys() {
    local home_dir
    home_dir=$(user_home)
    local ssh_dir="${home_dir}/.ssh"
    local ak_file="${ssh_dir}/authorized_keys"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would ensure ${ak_file} contains exactly one forced-command line for ${ALLOWLIST_PATH} and this key"
        return 0
    fi
    if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
        fail "Home directory for ${USER_NAME} not found"
        return 1
    fi
    mkdir -p "${ssh_dir}" || { fail "Could not create ${ssh_dir}"; return 1; }
    chmod 700 "${ssh_dir}"
    touch "${ak_file}"
    chmod 600 "${ak_file}"
    local key_b64
    key_b64=$(printf '%s' "$PUBKEY" | awk '{print $2}')
    # Temp file lives next to authorized_keys so the final rename is atomic;
    # sshd only ever reads the real filename, never the dotfile temp.
    local tmp_file
    tmp_file=$(mktemp "${ssh_dir}/.authorized_keys.XXXXXX") || { fail "Could not create a temp file in ${ssh_dir}"; return 1; }
    if ! grep -Fv -e "command=\"${ALLOWLIST_PATH}\"" -e "${key_b64}" "${ak_file}" > "${tmp_file}"; then
        : > "${tmp_file}"
    fi
    printf 'restrict,command="%s" %s\n' "${ALLOWLIST_PATH}" "${PUBKEY}" >> "${tmp_file}"
    if ! mv -f "${tmp_file}" "${ak_file}"; then
        fail "Could not replace ${ak_file}"
        rm -f "${tmp_file}"
        return 1
    fi
    chmod 600 "${ak_file}"
    local owner_group
    owner_group=$(getent passwd "$USER_NAME" | cut -d: -f3):"$(id -g "$USER_NAME")"
    chown "$owner_group" "${ssh_dir}" "${ak_file}" || fail "Could not chown ${ssh_dir}"
    log "Wrote forced-command key line to ${ak_file}"
}

write_sshd_dropin() {
    local dropin_dir="/etc/ssh/sshd_config.d"
    local dropin_file="${dropin_dir}/buddybackup-${USER_NAME}.conf"
    local match_block="Match User ${USER_NAME}
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AuthenticationMethods publickey
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    PermitTunnel no
    PermitUserRC no"

    if [ "$IS_SCALE" -eq 1 ]; then
        log ""
        log "TrueNAS SCALE detected: paste the following block into the SSH service's"
        log "'Auxiliary Parameters' field (System Settings -> Services -> SSH):"
        log ""
        printf '%s\n' "$match_block"
        log ""
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would write ${dropin_file}:"
        printf '%s\n' "$match_block" | sed 's/^/[dry-run]     /'
        return 0
    fi
    if ! [ -d "$dropin_dir" ] || ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*' /etc/ssh/sshd_config 2>/dev/null; then
        warn "sshd_config.d is not used on this host. Add this block to /etc/ssh/sshd_config manually:"
        printf '%s\n' "$match_block" | sed 's/^/    /'
        return 0
    fi
    local sshd_bin
    sshd_bin=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
    # Write to a dotfile temp in the same directory, then rename atomically.
    # sshd's Include glob never matches a dotfile, so a partially written
    # drop-in can never be parsed and break sshd on its next start.
    local tmp_file
    tmp_file=$(mktemp "${dropin_dir}/.buddybackup-${USER_NAME}.XXXXXX") || { fail "Could not create a temp file in ${dropin_dir}"; return 1; }
    if ! printf '%s\n' "$match_block" > "${tmp_file}"; then
        fail "Could not write drop-in content"
        rm -f "${tmp_file}"
        return 1
    fi
    chmod 644 "${tmp_file}"
    if ! mv -f "${tmp_file}" "${dropin_file}"; then
        fail "Could not install ${dropin_file}"
        rm -f "${tmp_file}"
        return 1
    fi
    # Validate the whole sshd config (now including the drop-in); on failure,
    # roll back so the host's SSH config is exactly as we found it.
    if ! "$sshd_bin" -t >/dev/null 2>&1; then
        fail "sshd config validation failed with ${dropin_file} installed; drop-in removed again"
        rm -f "${dropin_file}"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl reload ssh >/dev/null 2>&1 && ! systemctl reload sshd >/dev/null 2>&1; then
            warn "Could not reload the SSH service automatically; reload it manually to activate ${dropin_file}"
        else
            log "SSH service reloaded (${dropin_file} active)"
        fi
    fi
}

show_port_note() {
    if [ "$PORT" != "22" ]; then
        log "Note: make sure the SSH service listens on port ${PORT} (see the plugin's Generic ZFS hosts page)."
    fi
}

verify() {
    # Note: ERRORS is deliberately not reset here. Errors already recorded by the
    # setup steps above must still fail the overall run; verify() re-checks state
    # and adds any problems it finds on top.
    log "Verification checklist:"
    if getent passwd "$USER_NAME" >/dev/null 2>&1; then
        check_pass "user ${USER_NAME} exists"
        local shell_path
        shell_path=$(getent passwd "$USER_NAME" | cut -d: -f7)
        case "$shell_path" in
            */bash|*/sh|*/zsh) check_pass "user shell is usable (${shell_path})" ;;
            *) check_fail "user shell '${shell_path}' cannot run SSH forced commands" ;;
        esac
    else
        check_fail "user ${USER_NAME} does not exist"
    fi

    if [ -f "${ALLOWLIST_PATH}" ]; then
        check_pass "allowlist script installed at ${ALLOWLIST_PATH}"
        if [ -x "${ALLOWLIST_PATH}" ]; then
            check_pass "allowlist script is executable"
        else
            check_fail "allowlist script is not executable"
        fi
        if [ "$(stat -c %u "${ALLOWLIST_PATH}" 2>/dev/null)" = "0" ] && ! user_path_test -w "${ALLOWLIST_PATH}"; then
            check_pass "allowlist script is root-owned and not writable by ${USER_NAME}"
        else
            check_fail "allowlist script is writable by ${USER_NAME}; the forced command could be replaced with an unrestricted script (re-run this script)"
        fi
        if user_path_test -x "${ALLOWLIST_PATH}"; then
            check_pass "allowlist script is executable by ${USER_NAME}"
        else
            check_fail "allowlist script is not executable by ${USER_NAME} (check ownership and permissions of ${ALLOWLIST_DIR})"
        fi
        local allowlist_parent
        allowlist_parent=$(dirname "${ALLOWLIST_DIR}")
        if user_path_test -w "${ALLOWLIST_DIR}" || user_path_test -w "${allowlist_parent}"; then
            check_fail "allowlist location is writable by ${USER_NAME}; the forced-command script could be removed or replaced (make ${ALLOWLIST_DIR} and ${allowlist_parent} root-owned 0755, or re-run this script)"
        fi
    else
        check_fail "allowlist script missing at ${ALLOWLIST_PATH}"
    fi

    # Sudo mode is judged by the installed state (flag file), not only by the
    # --sudo-mode argument: with --sudo-mode auto the flag is what counts.
    if [ -f "${ALLOWLIST_PATH}.sudo" ]; then
        check_pass "sudo mode flag present (${ALLOWLIST_PATH}.sudo)"
        if [ "$IS_SCALE" -eq 1 ]; then
            check_warn "sudoers entry must be configured via the TrueNAS UI (script cannot check it)"
        elif [ -f "/etc/sudoers.d/buddybackup-${USER_NAME}" ]; then
            check_pass "sudoers entry installed (/etc/sudoers.d/buddybackup-${USER_NAME})"
        else
            check_fail "sudo mode flag present but sudoers entry missing (/etc/sudoers.d/buddybackup-${USER_NAME}); re-run this script"
        fi
    elif [ "$SUDO_MODE" = "yes" ]; then
        check_fail "sudo mode requested (--sudo-mode yes) but flag missing (${ALLOWLIST_PATH}.sudo); re-run this script"
    elif user_can_exec_zfs; then
        check_pass "user ${USER_NAME} can execute zfs directly (no sudo mode needed)"
        if [ "$IS_SCALE" -eq 0 ] && [ -f "/etc/sudoers.d/buddybackup-${USER_NAME}" ]; then
            check_warn "leftover sudoers entry (/etc/sudoers.d/buddybackup-${USER_NAME}); re-run with --sudo-mode no to remove it"
        fi
    else
        check_fail "user ${USER_NAME} cannot execute zfs and sudo mode is not enabled (re-run with --sudo-mode yes)"
    fi

    local home_dir
    home_dir=$(user_home)
    if [ -n "$home_dir" ] && [ -f "${home_dir}/.ssh/authorized_keys" ]; then
        local key_b64
        key_b64=$(printf '%s' "$PUBKEY" | awk '{print $2}')
        if grep -Fq "command=\"${ALLOWLIST_PATH}\"" "${home_dir}/.ssh/authorized_keys" && { [ -z "$key_b64" ] || grep -Fq "${key_b64}" "${home_dir}/.ssh/authorized_keys"; }; then
            check_pass "forced-command SSH key line present in ${home_dir}/.ssh/authorized_keys"
        else
            check_fail "forced-command SSH key line missing in ${home_dir}/.ssh/authorized_keys (re-run this script)"
        fi
    else
        check_fail "authorized_keys not found for ${USER_NAME}"
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        local ds
        for ds in "${DATASET_LIST[@]}"; do
            if zfs_prop "$ds" "name" >/dev/null 2>&1; then
                check_pass "dataset ${ds} exists"
                local perms
                perms=$(zfs allow "$ds" 2>/dev/null | grep "${USER_NAME}" || echo "")
                if [ -n "$perms" ]; then
                    check_pass "zfs allow delegation present: ${perms}"
                else
                    check_fail "no zfs allow delegation for ${USER_NAME} on ${ds} (re-run this script)"
                fi
                if [ "$ROLE" = "receiver" ]; then
                    local mp
                    mp=$(zfs_prop "$ds" "mountpoint" || echo "")
                    case "$mp" in
                        none|legacy) check_pass "mountpoint is '${mp}' (received data will not mount)" ;;
                        *) check_fail "mountpoint is '${mp}'; expected none or legacy" ;;
                    esac
                fi
            else
                if [ "$ROLE" = "receiver" ]; then
                    check_fail "dataset ${ds} does not exist (re-run this script to create it)"
                else
                    check_fail "dataset ${ds} does not exist (sender requires an existing dataset)"
                fi
            fi
        done

        if [ "$IS_SCALE" -eq 0 ]; then
            if [ -f "/etc/ssh/sshd_config.d/buddybackup-${USER_NAME}.conf" ]; then
                check_pass "sshd drop-in installed"
            else
                check_warn "sshd drop-in missing (only a warning: the key options already restrict sessions)"
            fi
        fi
    else
        check_warn "dry-run: ZFS and SSH state not checked"
    fi

    local helper_bin=""
    if command -v runuser >/dev/null 2>&1; then
        helper_bin="runuser -u ${USER_NAME} --"
    fi
    local cmd_out=""
    if [ -n "$helper_bin" ]; then
        cmd_out=$($helper_bin sh -c 'command -v mbuffer; command -v zstdmt' 2>/dev/null || echo "")
    else
        cmd_out=$(su -s /bin/sh "$USER_NAME" -c 'command -v mbuffer; command -v zstdmt' 2>/dev/null || echo "")
    fi
    if printf '%s' "$cmd_out" | grep -q mbuffer && printf '%s' "$cmd_out" | grep -q zstdmt; then
        check_pass "mbuffer and zstdmt available for ${USER_NAME}"
    else
        check_warn "mbuffer/zstdmt not both available for ${USER_NAME}; transfers degrade gracefully without them"
    fi

    if [ "$ERRORS" -gt 0 ]; then
        log "Verification finished with ${ERRORS} problem(s)."
        return 1
    fi
    log "Verification finished: all checks passed."
    return 0
}

log "Configuration:"
log "  mode:       ${MODE}"
if [ "$MODE" = "clean" ]; then
    if [ "$DELETE_USER" -eq 1 ]; then
        log "  delete-user: yes"
    else
        log "  delete-user: no (account kept; add --delete-user to remove it)"
    fi
    log "  user:       ${USER_NAME}"
elif [ "$MODE" = "revoke" ]; then
    log "  user:       ${USER_NAME}"
    log "  datasets:   ${REVOKE_LIST[*]}"
else
    log "  role:       ${ROLE}"
    log "  user:       ${USER_NAME}"
    log "  datasets:   ${DATASET_LIST[*]}"
    log "  port:       ${PORT}"
    log "  sudo-mode:  ${SUDO_MODE}"
fi
log ""

if [ "$VERIFY_ONLY" -eq 1 ]; then
    verify
    exit $?
fi

if [ "$MODE" = "setup" ] && [ "$DRY_RUN" -eq 0 ] && [ -z "$PUBKEY" ]; then
    fail "--pubkey is required (Unraid's SSH public key from the plugin's Backup page)"
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN - no changes will be made"
    log ""
fi

if [ "$MODE" = "clean" ]; then
    clean_host
    if [ "$DRY_RUN" -eq 1 ]; then
        log ""
        log "Dry run complete. No changes were made."
        exit 0
    fi
    exit $?
fi
if [ "$MODE" = "revoke" ]; then
    run_revoke_mode
    if [ "$DRY_RUN" -eq 1 ]; then
        log ""
        log "Dry run complete. No changes were made."
        exit 0
    fi
    exit $?
fi

if [ "$IS_SCALE" -eq 1 ]; then
    log "TrueNAS SCALE detected: commands that the UI must configure are printed below."
    log ""
fi

create_user || true

ALLOW_SUDO="no"
case "$SUDO_MODE" in
    yes) ALLOW_SUDO="yes" ;;
    no)  ALLOW_SUDO="no" ;;
    auto)
        if id "$USER_NAME" >/dev/null 2>&1 && ! user_can_exec_zfs; then
            ALLOW_SUDO="yes"
            log "zfs is not executable for user ${USER_NAME}; enabling sudo mode (auto)"
        fi
        ;;
esac

install_allowlist || true
if [ "$ALLOW_SUDO" = "yes" ]; then
    # Only enable the sudo flag after the sudoers entry is actually in place;
    # otherwise the allowlist would run validated commands through a sudo grant
    # that does not exist yet.
    if install_sudoers; then
        set_sudo_flag "yes"
    else
        log "Sudo mode left disabled because the sudoers entry could not be installed."
        set_sudo_flag "no"
    fi
else
    set_sudo_flag "no"
    remove_sudoers || true
fi

apply_grants_and_converge

write_authorized_keys || true
write_sshd_dropin || true
show_port_note

if [ "$IS_SCALE" -eq 1 ]; then
    log ""
    log "TrueNAS reminders:"
    log "  - Editing the user's SSH keys in the UI rewrites authorized_keys and removes the"
    log "    forced-command line. Re-run this script (or --verify) afterwards."
    log "  - The forced-command allowlist lives at ${ALLOWLIST_PATH} (root-owned;"
    log "    TrueNAS system dirs are read-only). Deleting or moving it breaks SSH"
    log "    access for ${USER_NAME}."
    log "  - Raw encrypted receives require feature@encryption on the destination pool."
    log "  - Run with --clean (optionally --delete-user) to uninstall everything this"
    log "    script set up; --revoke DATASET removes single datasets from the grant set."
fi

log ""
if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry run complete. No changes were made."
    exit 0
fi
if ! verify; then
    exit 1
fi
exit 0
