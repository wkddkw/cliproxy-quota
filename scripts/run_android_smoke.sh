#!/usr/bin/env bash
set -euo pipefail
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/monitor_worker_test.dart -d emulator-5554 --no-dds > /tmp/quota-worker-smoke.log 2>&1 &
quota_test_pid=$!
quota_granted=false
trap 'kill "$quota_test_pid" 2>/dev/null || true' EXIT
while kill -0 "$quota_test_pid" 2>/dev/null; do
  if [ "$quota_granted" = false ] && adb shell pm grant com.wkddkw.cliproxy_quota android.permission.POST_NOTIFICATIONS >/dev/null 2>&1; then
    quota_granted=true
  fi
  sleep 2
done
quota_exit=0
wait "$quota_test_pid" || quota_exit=$?
cat /tmp/quota-worker-smoke.log
adb logcat -d -s AndroidRuntime:E flutter:I | tail -100
exit "$quota_exit"
