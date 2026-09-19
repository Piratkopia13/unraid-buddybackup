#!/bin/bash

LOGFILE="/var/log/buddybackup.log"

while IFS= read -r line; do
    if [[ -n "${line}" ]]; then
        printf "%s: %s\n" "$(date '+%F %T')" "${line}" >> "${LOGFILE}"
    fi
done
