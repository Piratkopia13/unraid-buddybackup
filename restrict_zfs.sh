#!/usr/bin/env bash

# This file is work in progress and currently not functional (or used in the plugin)
# Bash regex does not support zero-or-more matching, like (?:) which is used below. This has to be solved.
# When functional, this file should replace restrict_zfs.py and remove python as a prerequisite for the buddybackup plugin

# Define allowed regex patterns
POOL="'[a-zA-Z0-9_-]+'"
DATASET="'[a-zA-Z0-9_\/-]+'"
MBUFFER_CMD="mbuffer (?:-[rR] [0-9]+[kM])? (?:-W [0-9]+ -I [a-zA-Z0-9_.:-]+ )?-q -s [0-9]+[kM] -m [0-9]+[kM]"
COMPRESS_CMD="(?:(?:gzip -3|zcat|pigz -(?:[0-9]+|dc)|zstd -(?:[0-9]+|dc)|xz(?: -d)?|lzop(?: -dfc)?|lz4(?: -dc)?)\s*\|)?"
REDIRS="(?:\s+(?:2>/dev/null|2>&1))?"

ALLOWED_COMMANDS=(
    "^exit$"
    "^echo -n$"
    "^command -v (gzip|zcat|pigz|zstd|xz|lzop|lz4|mbuffer|socat|busybox)$"
    "^zpool get -o value -H feature@extensible_dataset ${POOL}$"
    "^ps -Ao args=$"
    "^zfs get -H (name|receive_resume_token|-p used|syncoid:sync) ${DATASET}${REDIRS}$"
    "^zfs get -Hpd 1 (-t (snapshot|bookmark) |type,)guid,creation ${DATASET}${REDIRS}$"
    "^zfs list -o name,origin -t filesystem,volume -Hr ${DATASET}$"
    "^${MBUFFER_CMD}|${COMPRESS_CMD}|zfs receive ${DATASET}${REDIRS}$"
    "^zfs receive -A ${DATASET}$"
)

function check_allowed() {
    local command="$1"
    for pattern in "${ALLOWED_COMMANDS[@]}"; do
        if [[ $command =~ $pattern ]]; then
            if $dry_run; then
                echo "allowed on: ${pattern}"
            fi
            return 0
        fi
    done
    return 1
}

function log_message() {
    local log_text="$1"
    [[ " ${log_dest[@]} " =~ " syslog " ]] && logger "$log_text"
    [[ " ${log_dest[@]} " =~ " stderr " ]] && echo "$log_text" >&2
}

dry_run=false
verbose=false
log_dest=("syslog")

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --verbose) verbose=true ;;
        --log) shift; IFS=',' read -r -a log_dest <<< "$1" ;;
    esac
    shift
done

original_command="${SSH_ORIGINAL_COMMAND:-}"
IFS=';' read -r -a commands <<< "$original_command"

for command in "${commands[@]}"; do
    command=$(echo "$command" | xargs)  # Trim spaces
    if check_allowed "$command"; then
        if $dry_run; then
            log_message "would run command: $command"
        else
            $verbose && log_message "running command: $command"
            eval "$command"
        fi
    else
        log_message "blocked command: $command"
    fi
done