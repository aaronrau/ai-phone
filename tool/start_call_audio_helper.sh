#!/usr/bin/env bash
# Starts the call-audio helper on the phone as the adb shell user.
# Usage: tool/start_call_audio_helper.sh <android-serial>
# The helper survives the adb session but not a reboot or an app reinstall;
# run this again after either. It only connects to the app's local socket.
set -euo pipefail
SERIAL=${1:?usage: $0 <android-serial>}
ADB=(adb -s "$SERIAL")
APK=$("${ADB[@]}" shell pm path ai.local.receptionist | head -1 | cut -d: -f2 | tr -d '\r')
[ -n "$APK" ] || { echo "Install the app first." >&2; exit 1; }
"${ADB[@]}" shell "pkill -f ai.local.receptionist.shell.ShellCallAudio" || true
"${ADB[@]}" shell "CLASSPATH=$APK setsid nohup app_process /system/bin ai.local.receptionist.shell.ShellCallAudio bridge > /data/local/tmp/receptionist-call-audio.log 2>&1 < /dev/null &"
sleep 2
# After an install or update the app's background service is not restarted on
# some phones; start it so calls are answered without opening the app first.
"${ADB[@]}" shell am start-foreground-service -n ai.local.receptionist/.ReceptionistService > /dev/null 2>&1 || true
"${ADB[@]}" shell "pgrep -f ai.local.receptionist.shell.ShellCallAudio > /dev/null" && echo "Call-audio helper running." || { echo "Helper failed to start:" >&2; "${ADB[@]}" shell cat /data/local/tmp/receptionist-call-audio.log >&2; exit 1; }
