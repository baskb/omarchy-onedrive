#!/bin/bash
emit() { printf '{"MESSAGE":"%s","__REALTIME_TIMESTAMP":"%s"}\n' "$1" "$(( $(date +%s) * 1000000 ))"; }
emit "Starting a sync with Microsoft OneDrive"
emit "Syncing changes from Microsoft OneDrive"
emit "Number of items to download from Microsoft OneDrive: 200"
for i in $(seq 1 200); do
  sleep 1
  emit "Downloading file: ./Photos/2026/holiday-$i.jpg ... done"
done
emit "Sync with Microsoft OneDrive is complete"
sleep 3600
