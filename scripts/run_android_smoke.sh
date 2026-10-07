#!/usr/bin/env bash
set -euo pipefail
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/monitor_worker_test.dart -d emulator-5554 --no-dds > /tmp/quota-worker-smoke.log 2>&1 &
quota_test_pid=$!
quota_granted=false
quota_job_started=false
trap 'kill "$quota_test_pid" 2>/dev/null || true' EXIT
while kill -0 "$quota_test_pid" 2>/dev/null; do
  if [ "$quota_granted" = false ] && adb shell pm grant com.wkddkw.cliproxy_quota android.permission.POST_NOTIFICATIONS >/dev/null 2>&1; then
    quota_granted=true
  fi
  if [ "$quota_job_started" = false ] && grep -q 'QUOTA_SMOKE_RUN_JOB:' /tmp/quota-worker-smoke.log; then
    quota_job_id=$(sed -n 's/.*QUOTA_SMOKE_RUN_JOB:\([0-9][0-9]*\).*/\1/p' /tmp/quota-worker-smoke.log | head -1)
    # Let the first periodic execution finish before forcing the next one.
    sleep 5
    adb shell cmd jobscheduler run -f com.wkddkw.cliproxy_quota "$quota_job_id"
    quota_job_started=true
  fi
  sleep 2
done
quota_exit=0
wait "$quota_test_pid" || quota_exit=$?
cat /tmp/quota-worker-smoke.log
adb logcat -d -s AndroidRuntime:E flutter:I | tail -100
exit "$quota_exit"
