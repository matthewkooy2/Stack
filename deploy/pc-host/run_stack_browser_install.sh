#!/bin/bash
set -u
task_dir=/mnt/c/Users/Ryan/Documents/Codex/2026-09-30/task
attempt_id=$(date -u +%Y%m%dT%H%M%SZ)
archive_dir="$task_dir/stack-browser-install-attempts/$attempt_id-$$-prior"
# Preserve the previous metadata evidence; do not mistake its exit marker for
# this attempt's terminal result. These files contain no credential values.
for prior_file in stack-browser-installation-result.json stack-browser-install-exit.txt stack-browser-install-stage.txt; do
    if [ -f "$task_dir/$prior_file" ]; then
        mkdir -p -- "$archive_dir" || exit 1
        mv -- "$task_dir/$prior_file" "$archive_dir/$prior_file" || exit 1
    fi
done
printf 'Stack browser installation only. Enter Ubuntu password locally; no password is recorded.\n'
printf 'waiting_for_attended_sudo\n' > "$task_dir/stack-browser-install-stage.txt"
sudo -- /usr/bin/env PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$task_dir/stack-browser-prepared/install_stack_browser.py"
exit_code=$?
printf '%s\n' "$exit_code" > "$task_dir/stack-browser-install-exit.txt"
printf 'finished\n' > "$task_dir/stack-browser-install-stage.txt"
read -r -p 'Press Enter to close this window when finished. ' unused
exit "$exit_code"
