#!/usr/bin/env bash
# Runs Nudge's built-in self-test (debug builds only) and prints the results.
# It opens a TextEdit document, rewrites, edits and undoes text, checks what
# Nudge recorded, then cleans up. Please don't type while it runs.
set -euo pipefail
LOG="$HOME/Library/Logs/Nudge/nudge.log"
start=$(wc -l < "$LOG" 2>/dev/null || echo 0)
/usr/bin/swift - <<'SWIFT'
import Foundation
DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("com.barrynapier.nudge.selftest"), object: nil, userInfo: nil, deliverImmediately: true)
SWIFT
for _ in $(seq 1 120); do
  sleep 1
  if tail -n +"$((start + 1))" "$LOG" | grep -qE "SELFTEST (PASS|FAIL [0-9]+ check|FAIL could not)"; then break; fi
done
tail -n +"$((start + 1))" "$LOG" | grep -E "SELFTEST|Outcome \||Learning \||Undo \||Improve \|" | cut -c15-
