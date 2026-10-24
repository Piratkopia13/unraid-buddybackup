#!/bin/bash

LOGFILE="${LOGFILE:-/var/log/buddybackup.log}"
touch "${LOGFILE}" 2>/dev/null || true

while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -n "${line}" ]]; then
        # Suppress known harmless upstream Sanoid v2.3.0 bareword filehandle collision warning (upstream issue #1020)
        if [[ "${line}" =~ print\(\)\ on\ closed\ filehandle\ FH\ at\ .*sanoid\ line\ 179[0-9] ]] || \
           [[ "${line}" =~ filehandle\ FH\ at\ .*sanoid\ line\ 179[0-9] ]]; then
            continue
        fi
        printf "%s: %s\n" "$(date '+%F %T')" "${line}" >> "${LOGFILE}"
    fi
done
