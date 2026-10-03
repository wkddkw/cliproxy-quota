#!/usr/bin/env bash
set -euo pipefail
# Grant the notification permission as soon as the test APK is installed.
# Connect directly to the VM; DDS startup can fail on the hosted emulator.
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/monitor_service_test.dart -d emulator-5554 --no-dds > /tmp/quota-service-smoke.log 2>&1 &
quota_test_pid=$!
quota_idle=false
quota_granted=false
trap 'kill "$quota_test_pid" 2>/dev/null || true; adb shell dumpsys deviceidle unforce >/dev/null 2>&1 || true; adb shell dumpsys battery reset >/dev/null 2>&1 || true' EXIT
while kill -0 "$quota_test_pid" 2>/dev/null; do
  if [ "$quota_granted" = false ] && adb shell pm grant com.wkddkw.cliproxy_quota android.permission.POST_NOTIFICATIONS >/dev/null 2>&1; then
    adb shell appops set com.wkddkw.cliproxy_quota SCHEDULE_EXACT_ALARM allow
    quota_granted=true
  fi
  if [ "$quota_idle" = false ] && grep -q QUOTA_SMOKE_FORCE_IDLE /tmp/quota-service-smoke.log; then
    adb shell dumpsys battery unplug
    adb shell input keyevent 223
    adb shell dumpsys deviceidle force-idle
    quota_idle=true
  fi
  if [ "$quota_idle" = true ] && grep -q QUOTA_SMOKE_EXIT_IDLE /tmp/quota-service-smoke.log; then
    adb shell dumpsys deviceidle unforce
    adb shell dumpsys battery reset
    adb shell input keyevent 224
    quota_idle=done
  fi
  sleep 2
done
quota_exit=0
wait "$quota_test_pid" || quota_exit=$?
cat /tmp/quota-service-smoke.log
adb logcat -d -s AndroidRuntime:E flutter:I | tail -100
exit "$quota_exit"
