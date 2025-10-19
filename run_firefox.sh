#!/usr/bin/env bash

CONSTANTS_FILE="$(dirname "$0")/constants.sh"
if [[ -f "$CONSTANTS_FILE" ]]; then
    source "$CONSTANTS_FILE"
else
    echo "Error: Constants file not found" >&2
    exit 1
fi

if [[ $EUID -eq 0 ]]; then
   log "ERROR" "The Firejail wrapper script should not be run as root."
   exit 1
fi

# --- Configuration ---
APP=(
    firejail
    --netns="${NS}"
    --private="${HOMEJ}"
    firefox
)

log "INFO" "Launching application: ${APP[*]}"
"${APP[@]}"
if [ $? -ne 0 ]; then
    log "ERROR" "Application exited with a non-zero status."
fi

