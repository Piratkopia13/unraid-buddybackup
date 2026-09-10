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
keys in the TrueNAS UI). Self-verifying: finishes with a PASS/FAIL checklist, and
--verify runs only the checks.

Required:
  --role receiver|sender    receiver: this Unraid pushes backups to this host.
                            sender:   this Unraid pulls backups from this host.
  --dataset NAME            receiver: parent dataset backups are received into
                            (created with mountpoint=none if missing; an existing
                            dataset is only accepted if nothing below it is mounted).
                            sender:   dataset (or parent of datasets) to serve.
  --pubkey KEY              Unraid's SSH public key (single line).

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
PUBKEY=""
PORT="22"
SUDO_MODE="auto"
ALLOWLIST_DIR_ARG=""
VERIFY_ONLY=0
DRY_RUN=0

ERRORS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --role|--user|--dataset|--pubkey|--port|--sudo-mode|--allowlist-dir)
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
        --dataset) DATASET="$2"; shift 2 ;;
        --pubkey) PUBKEY="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --sudo-mode) SUDO_MODE="$2"; shift 2 ;;
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

if [ -z "$ROLE" ] || { [ "$ROLE" != "receiver" ] && [ "$ROLE" != "sender" ]; }; then
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
if ! printf '%s' "$DATASET" | grep -Eq "$DATASET_RE" || printf '%s' "$DATASET" | grep -qE '(//|/$)'; then
    fail "--dataset '$DATASET' is not a valid ZFS dataset name (characters allowed: letters, digits, '_', ' ', '-', '/'; no '@' or double slashes)"
    exit 1
fi

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
if [ -f /etc/version ] && grep -qi truenas /etc/version 2>/dev/null; then
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
elif [ "$IS_SCALE" -eq 1 ]; then
    ALLOWLIST_DIR=$(truenas_allowlist_dir)
else
    ALLOWLIST_DIR="/usr/local/sbin"
fi
# ALLOWLIST_PATH is embedded verbatim inside a double-quoted sshd forced-command
# option, so characters that would terminate or escape that quoting (quotes,
# backslashes, whitespace, shell metacharacters) must never reach it.
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

if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$(id -u)" != "0" ]; then
        fail "This script must run as root (try: sudo -i). Use --dry-run to preview without root."
        exit 1
    fi
    if ! command -v zfs >/dev/null 2>&1; then
        fail "zfs binary not found for root. This host does not have OpenZFS?"
        exit 1
    fi
    if ! command -v sshd >/dev/null 2>&1 && ! [ -x /usr/sbin/sshd ]; then
        fail "sshd not found. An SSH server must be installed."
        exit 1
    fi
fi

zfs_quiet() { zfs "$@" >/dev/null 2>&1; }
zfs_prop() { zfs get -H -o value "$1" "$DATASET" 2>/dev/null | tr -d '\n'; }

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
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would run: zfs allow -u ${USER_NAME} $1 ${DATASET}"
        return 0
    fi
    local perms="$1"
    if ! zfs allow -u "$USER_NAME" "$perms" "$DATASET"; then
        fail "zfs allow -u ${USER_NAME} ${perms} ${DATASET} failed"
        return 1
    fi
}

has_plain_send_grant() {
    zfs allow "$DATASET" 2>/dev/null | awk -v u="$USER_NAME" '
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
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would try: zfs allow -u ${USER_NAME} send:raw ${DATASET} (raw-only, OpenZFS 2.4+)"
        log "[dry-run]          and remove any plain 'send' grant: zfs unallow -u ${USER_NAME} send ${DATASET}"
        log "[dry-run]          fallback on older OpenZFS: zfs allow -u ${USER_NAME} send ${DATASET}"
        return 0
    fi
    if zfs allow -u "$USER_NAME" "send:raw" "$DATASET" 2>/dev/null; then
        log "Raw-only send delegation (send:raw, OpenZFS 2.4+): enabled"
        if has_plain_send_grant; then
            if zfs unallow -u "$USER_NAME" "send" "$DATASET" 2>/dev/null; then
                log "Removed plain 'send' delegation so only raw sends remain possible"
            else
                warn "Could not remove the plain 'send' delegation; raw-only is NOT enforced."
                warn "Remove it manually: zfs unallow -u ${USER_NAME} send ${DATASET}"
            fi
        fi
        return 0
    fi
    if [ "$ROLE" = "sender" ]; then
        warn "send:raw delegation not supported by this OpenZFS version (< 2.4); falling back to plain 'send'."
        warn "With plain 'send', a compromised Unraid server could request DECRYPTED streams of ${DATASET}."
        warn "Upgrade this host to OpenZFS 2.4+ and re-run this script to enforce raw-only sends."
    else
        log "send:raw delegation not supported by this ZFS version; plain 'send' covers raw streams"
    fi
    if ! zfs allow -u "$USER_NAME" "send" "$DATASET"; then
        fail "zfs allow -u ${USER_NAME} send ${DATASET} failed"
        return 1
    fi
}

ensure_receiver_dataset() {
    if [ "$DRY_RUN" -eq 1 ]; then
        if zfs_prop "name" >/dev/null 2>&1; then
            log "[dry-run] dataset ${DATASET} exists; would ensure mountpoint=none (or legacy)"
        else
            log "[dry-run] would create parent dataset ${DATASET} with mountpoint=none"
        fi
        return 0
    fi
    if ! zfs_prop "name" >/dev/null 2>&1; then
        log "Creating parent dataset ${DATASET} with mountpoint=none"
        if ! zfs create -p -o mountpoint=none "$DATASET"; then
            fail "Could not create dataset ${DATASET}"
            return 1
        fi
        return 0
    fi
    local mp
    mp=$(zfs_prop "mountpoint" || echo "")
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
            mounted_yes=$(zfs list -r -H -o mounted "$DATASET" 2>/dev/null | grep -x "yes" || true)
            if [ -n "$mounted_yes" ]; then
                fail "Dataset ${DATASET} or a dataset below it is currently MOUNTED (mountpoint '${mp}')."
                log "Refusing to set mountpoint=none on mounted data, as that would unmount it while in use."
                log "Pick a dataset path that does not exist yet (this script creates it with mountpoint=none),"
                log "or unmount the dataset and its children yourself first and re-run."
                return 1
            fi
            log "Setting mountpoint=none on ${DATASET} (was: '${mp}', nothing mounted). Received backups must never mount on this host - Linux cannot mount as a non-root user, and receive fails if mount is attempted."
            if ! zfs set mountpoint=none "$DATASET"; then
                fail "Could not set mountpoint=none on ${DATASET}"
                return 1
            fi
            ;;
    esac
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
        if zfs_prop "name" >/dev/null 2>&1; then
            check_pass "dataset ${DATASET} exists"
            local perms
            perms=$(zfs allow "$DATASET" 2>/dev/null | grep "${USER_NAME}" || echo "")
            if [ -n "$perms" ]; then
                check_pass "zfs allow delegation present: ${perms}"
            else
                check_fail "no zfs allow delegation for ${USER_NAME} on ${DATASET} (re-run this script)"
            fi
            if [ "$ROLE" = "receiver" ]; then
                local mp
                mp=$(zfs_prop "mountpoint" || echo "")
                case "$mp" in
                    none|legacy) check_pass "mountpoint is '${mp}' (received data will not mount)" ;;
                    *) check_fail "mountpoint is '${mp}'; expected none or legacy" ;;
                esac
            fi
        else
            if [ "$ROLE" = "receiver" ]; then
                check_fail "dataset ${DATASET} does not exist (re-run this script to create it)"
            else
                check_fail "dataset ${DATASET} does not exist (sender requires an existing dataset)"
            fi
        fi

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

if [ -n "$PUBKEY" ]; then
    log "Configuration:"
    log "  role:       ${ROLE}"
    log "  user:       ${USER_NAME}"
    log "  dataset:    ${DATASET}"
    log "  port:       ${PORT}"
    log "  sudo-mode:  ${SUDO_MODE}"
    log ""
fi

if [ "$VERIFY_ONLY" -eq 1 ]; then
    verify
    exit $?
fi

if [ "$DRY_RUN" -eq 0 ] && [ -z "$PUBKEY" ]; then
    fail "--pubkey is required (Unraid's SSH public key from the plugin's Backup page)"
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN - no changes will be made"
    log ""
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

if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$ROLE" = "receiver" ]; then
        if ensure_receiver_dataset; then
            apply_zfs_allow "create,mount,receive" || true
            apply_zfs_allow_send || true
        else
            log "Skipping ZFS delegations because dataset ${DATASET} is not ready."
        fi
    else
        if ! zfs_prop "name" >/dev/null 2>&1; then
            fail "Dataset ${DATASET} does not exist; sender role needs an existing dataset"
        fi
        apply_zfs_allow "hold" || true
        apply_zfs_allow_send || true
    fi
else
    if [ "$ROLE" = "receiver" ]; then
        ensure_receiver_dataset
        apply_zfs_allow "create,mount,receive"
        apply_zfs_allow_send
    else
        if zfs_prop "name" >/dev/null 2>&1; then
            log "[dry-run] dataset ${DATASET} exists"
        else
            log "[dry-run] would require existing dataset ${DATASET} (sender role)"
        fi
        apply_zfs_allow "hold"
        apply_zfs_allow_send
    fi
fi

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
