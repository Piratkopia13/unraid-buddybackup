#!/bin/bash
set -o pipefail

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
                            (created with mountpoint=none if missing).
                            sender:   dataset (or parent of datasets) to serve.
  --pubkey KEY              Unraid's SSH public key (single line).

Optional:
  --user NAME               SSH user to create/use (default: buddybackup)
  --port N                  SSH service port, for notes only (default: 22)
  --sudo-mode auto|yes|no   allow validated commands to run via sudo where the
                            zfs binary is not executable by the user
                            (default: auto)
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
DATASET=""
PUBKEY=""
PORT="22"
SUDO_MODE="auto"
VERIFY_ONLY=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --role) ROLE="${2:-}"; shift 2 ;;
        --user) USER_ARG="${2:-}"; shift 2 ;;
        --dataset) DATASET="${2:-}"; shift 2 ;;
        --pubkey) PUBKEY="${2:-}"; shift 2 ;;
        --port) PORT="${2:-}"; shift 2 ;;
        --sudo-mode) SUDO_MODE="${2:-}"; shift 2 ;;
        --verify) VERIFY_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
done

ERRORS=0

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

PUBKEY_ALGO_RE='^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)@openssh\.com)) [A-Za-z0-9+/]+={0,2}( [^ ].*)?$'
if [ -n "$PUBKEY" ]; then
    if [ "$(printf '%s' "$PUBKEY" | wc -l)" -gt 1 ] || ! printf '%s' "$PUBKEY" | grep -Eq "$PUBKEY_ALGO_RE"; then
        fail "--pubkey is not a valid single-line OpenSSH public key"
        exit 1
    fi
fi

run_as_user() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$USER_NAME" -- "$@"
    else
        su -s /bin/bash "$USER_NAME" -c "$*"
    fi
}

IS_SCALE=0
if [ -f /etc/version ] && grep -qi truenas /etc/version 2>/dev/null; then
    IS_SCALE=1
fi

ALLOWLIST_DIR="/usr/local/sbin"
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

install_allowlist() {
    log "Installing command allowlist to ${ALLOWLIST_PATH}"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would install allowlist script ${ALLOWLIST_PATH}"
        return 0
    fi
    if [ "$ROLE" = "receiver" ]; then
        cat > "${ALLOWLIST_PATH}" <<'BUDDYBACKUP_RESTRICT_ZFS_EOF'
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
        cat > "${ALLOWLIST_PATH}" <<'BUDDYBACKUP_RESTRICT_ZFS_SEND_EOF'
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
    chmod 755 "${ALLOWLIST_PATH}" || fail "Could not chmod ${ALLOWLIST_PATH}"
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
    local tmp_file
    tmp_file=$(mktemp)
    {
        printf 'Defaults:%s !requiretty\n' "$USER_NAME"
        printf '%s ALL=(root) NOPASSWD: /usr/bin/bash -c *\n' "$USER_NAME"
    } > "${tmp_file}"
    if ! visudo -cf "${tmp_file}" >/dev/null 2>&1; then
        fail "Generated sudoers file failed visudo validation"
        rm -f "${tmp_file}"
        return 1
    fi
    install -m 440 -o root -g root "${tmp_file}" "${sudoers_file}" || fail "Could not install ${sudoers_file}"
    rm -f "${tmp_file}"
    log "Installed ${sudoers_file} (coarse sudo grant; allowlist remains the fine-grained gate)"
}

create_user() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would create user ${USER_NAME} (locked random password, home dir, bash shell)"
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
        log "[dry-run] would attempt: zfs allow -u ${USER_NAME} send:raw ${DATASET}"
        return 0
    fi
    local perms="$1"
    if ! zfs allow -u "$USER_NAME" "$perms" "$DATASET"; then
        fail "zfs allow -u ${USER_NAME} ${perms} ${DATASET} failed"
        return 1
    fi
    if zfs allow -u "$USER_NAME" "send:raw" "$DATASET" 2>/dev/null; then
        log "Raw send delegation (send:raw, OpenZFS 2.4+): enabled"
    else
        log "send:raw delegation not supported by this ZFS version; plain 'send' covers raw streams"
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
            log "Setting mountpoint=none on ${DATASET} (was: '${mp}'). Received backups must never mount on this host - Linux cannot mount as a non-root user, and receive fails if mount is attempted."
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
    local tmp_file
    tmp_file=$(mktemp)
    if ! grep -Fv -e "command=\"${ALLOWLIST_PATH}\"" -e "${key_b64}" "${ak_file}" > "${tmp_file}"; then
        : > "${tmp_file}"
    fi
    printf 'restrict,command="%s" %s\n' "${ALLOWLIST_PATH}" "${PUBKEY}" >> "${tmp_file}"
    mv "${tmp_file}" "${ak_file}"
    chmod 600 "${ak_file}"
    local owner_group
    owner_group=$(getent passwd "$USER_NAME" | cut -d: -f3):"$(id -g "$USER_NAME")"
    chown "$owner_group" "${ssh_dir}" "${ak_file}" || fail "Could not chown ${ssh_dir}"
    log "Wrote forced-command key line to ${ak_file}"
}

user_home() {
    getent passwd "$USER_NAME" 2>/dev/null | cut -d: -f6
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
    printf '%s\n' "$match_block" > "${dropin_file}" || { fail "Could not write ${dropin_file}"; return 1; }
    local sshd_bin
    sshd_bin=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
    if ! "$sshd_bin" -t >/dev/null 2>&1; then
        fail "sshd config validation failed after writing ${dropin_file}"
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
    ERRORS=0
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
    else
        check_fail "allowlist script missing at ${ALLOWLIST_PATH}"
    fi

    if [ "$SUDO_MODE" = "yes" ]; then
        if [ -f "${ALLOWLIST_PATH}.sudo" ]; then
            check_pass "sudo mode flag present (${ALLOWLIST_PATH}.sudo)"
        else
            check_fail "sudo mode flag missing (${ALLOWLIST_PATH}.sudo)"
        fi
        if [ "$IS_SCALE" -eq 1 ]; then
            check_warn "sudoers entry must be configured via the TrueNAS UI (script cannot check it)"
        elif [ -f "/etc/sudoers.d/buddybackup-${USER_NAME}" ]; then
            check_pass "sudoers entry installed (/etc/sudoers.d/buddybackup-${USER_NAME})"
        else
            check_fail "sudoers entry missing (/etc/sudoers.d/buddybackup-${USER_NAME})"
        fi
    elif user_can_exec_zfs; then
        check_pass "user ${USER_NAME} can execute zfs directly (no sudo mode needed)"
        if [ -e "${ALLOWLIST_PATH}.sudo" ]; then
            check_warn "sudo mode flag present although zfs is directly executable; remove with --sudo-mode no"
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

    if [ "$DRY_RUN" -eq 1 ]; then
        check_warn "dry-run: ZFS and SSH state not checked"
        return 0
    fi

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
set_sudo_flag "$ALLOW_SUDO"
if [ "$ALLOW_SUDO" = "yes" ]; then
    install_sudoers || true
fi

if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$ROLE" = "receiver" ]; then
        ensure_receiver_dataset || true
        apply_zfs_allow "create,mount,receive,send" || true
    else
        if ! zfs_prop "name" >/dev/null 2>&1; then
            fail "Dataset ${DATASET} does not exist; sender role needs an existing dataset"
        fi
        apply_zfs_allow "send,hold" || true
    fi
else
    if [ "$ROLE" = "receiver" ]; then
        ensure_receiver_dataset
        log "[dry-run] would run: zfs allow -u ${USER_NAME} create,mount,receive,send ${DATASET}"
    else
        if zfs_prop "name" >/dev/null 2>&1; then
            log "[dry-run] dataset ${DATASET} exists"
        else
            log "[dry-run] would require existing dataset ${DATASET} (sender role)"
        fi
        log "[dry-run] would run: zfs allow -u ${USER_NAME} send,hold ${DATASET}"
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
