#!/bin/zsh

set -euo pipefail

BUNDLE_ID="tech.zh0ngtian.MuseumMuse"
APP_GROUP_ID="group.tech.zh0ngtian.MuseumMuse"
DEBUG_URL_BASE="dailymuseum://debug/widget-refresh"
CORESIM_ROOT="$HOME/Library/Developer/CoreSimulator/Devices"

udid=""
tail_count="80"
show_instances=0
clear_logs=0
trigger_refresh=0
json_output=0
device_home=""
instance_token=""
scope_raw_value=""
wait_seconds="3"
screenshot_path=""
go_home_screen=0

urlencode() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
}

usage() {
  cat <<'EOF'
Usage: scripts/pull_simulator_request_logs.sh [options]

Options:
  --udid <simulator-udid>   Read logs from the specified simulator.
  --device-home <path>      Read logs from an explicit CoreSimulator device data path.
  --instance-token <token>  Trigger refresh for a single shared widget group key (compat:<group>|<scope>).
  --scope-raw-value <raw>   Trigger refresh for a specific widget scope, e.g. single:met.
  --tail <count>            Show only the latest N log entries. Default: 80.
  --wait <seconds>          Wait time after --trigger-refresh. Default: 3.
  --screenshot-path <path>  Save a simulator screenshot to the given path.
  --home-screen             Send Simulator to Home Screen before taking screenshot.
  --instances               Also print widget instances.json.
  --clear                   Remove request-logs.json before reading.
  --trigger-refresh         Trigger dailymuseum://debug/widget-refresh before reading logs.
  --json                    Print raw JSON instead of formatted lines.
  --help                    Show this message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)
      udid="${2:-}"
      shift 2
      ;;
    --tail)
      tail_count="${2:-}"
      shift 2
      ;;
    --device-home)
      device_home="${2:-}"
      shift 2
      ;;
    --instance-token)
      instance_token="${2:-}"
      shift 2
      ;;
    --scope-raw-value)
      scope_raw_value="${2:-}"
      shift 2
      ;;
    --instances)
      show_instances=1
      shift
      ;;
    --wait)
      wait_seconds="${2:-}"
      shift 2
      ;;
    --screenshot-path)
      screenshot_path="${2:-}"
      shift 2
      ;;
    --home-screen)
      go_home_screen=1
      shift
      ;;
    --clear)
      clear_logs=1
      shift
      ;;
    --trigger-refresh)
      trigger_refresh=1
      shift
      ;;
    --json)
      json_output=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$udid" ]]; then
  if [[ -d "$CORESIM_ROOT" ]]; then
    udid="$(find "$CORESIM_ROOT" -maxdepth 8 -type f -name 'request-logs.json' -print 2>/dev/null \
      | sed -n 's#^.*/Devices/\([^/]*\)/data/Containers/Shared/AppGroup/.*/Logs/request-logs.json$#\1#p' \
      | head -n 1)"
  fi
fi

if [[ -z "$device_home" ]]; then
  if [[ -n "$udid" ]]; then
    device_home="$CORESIM_ROOT/$udid/data"
  elif [[ -d "$CORESIM_ROOT" ]]; then
    latest_log="$(find "$CORESIM_ROOT" -maxdepth 8 -type f -name 'request-logs.json' -print 2>/dev/null | head -n 1)"
    if [[ -n "$latest_log" ]]; then
      device_home="${latest_log%%/Containers/Shared/AppGroup/*}"
    fi
  fi
fi

if [[ -z "$device_home" || ! -d "$device_home" ]]; then
  echo "Could not resolve a simulator device data path. Pass --udid or --device-home." >&2
  exit 1
fi

app_group_root="$(find "$device_home/Containers/Shared/AppGroup" -maxdepth 2 -type d -name "$(basename "$APP_GROUP_ID")" 2>/dev/null | head -n 1)"

if [[ -z "$app_group_root" ]]; then
  app_group_root="$(find "$device_home/Containers/Shared/AppGroup" -maxdepth 3 -type f -name 'request-logs.json' -print 2>/dev/null | head -n 1)"
  app_group_root="${app_group_root%/Logs/request-logs.json}"
fi

if [[ -z "$app_group_root" ]]; then
  app_group_root="$(find "$device_home/Containers/Shared/AppGroup" -maxdepth 3 -type d -name 'WidgetInstances' -print 2>/dev/null | head -n 1)"
  app_group_root="${app_group_root%/WidgetInstances}"
fi

if [[ -z "$app_group_root" ]]; then
  echo "Could not locate app group container for $APP_GROUP_ID on simulator $udid." >&2
  exit 1
fi

log_file="$app_group_root/Logs/request-logs.json"
instances_file="$app_group_root/WidgetInstances/instances.json"

if [[ "$clear_logs" -eq 1 ]]; then
  rm -f "$log_file"
fi

if [[ "$trigger_refresh" -eq 1 ]]; then
  if [[ -z "$udid" ]]; then
    echo "--trigger-refresh requires --udid or an auto-detected simulator device id." >&2
    exit 1
  fi

  trigger_url="$DEBUG_URL_BASE"
  query_parts=()
  if [[ -n "$instance_token" ]]; then
    query_parts+=("instanceToken=$(urlencode "$instance_token")")
  fi
  if [[ -n "$scope_raw_value" ]]; then
    query_parts+=("scopeRawValue=$(urlencode "$scope_raw_value")")
  fi
  if [[ ${#query_parts[@]} -gt 0 ]]; then
    query_string="$(IFS='&'; echo "${query_parts[*]}")"
    trigger_url="$trigger_url?$query_string"
  fi

  xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl openurl "$udid" "$trigger_url"
  sleep "$wait_seconds"
fi

if [[ -n "$screenshot_path" ]]; then
  if [[ -z "$udid" ]]; then
    echo "--screenshot-path requires --udid or an auto-detected simulator device id." >&2
    exit 1
  fi

  mkdir -p "$(dirname "$screenshot_path")"

  if [[ "$go_home_screen" -eq 1 ]]; then
    xcrun simctl spawn "$udid" notifyutil -p com.apple.springboard.homebutton >/dev/null 2>&1 || true
    sleep 1
  fi

  xcrun simctl io "$udid" screenshot "$screenshot_path" >/dev/null
fi

if [[ "$show_instances" -eq 1 ]]; then
  echo "=== Widget Instances ==="
  if [[ -f "$instances_file" ]]; then
    python3 - "$instances_file" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timedelta, timezone

path = pathlib.Path(sys.argv[1])
instances = json.loads(path.read_text()).get("instances", [])

if not instances:
    print("(empty)")
else:
    for item in sorted(instances, key=lambda current: (current.get("lastUpdatedAt", 0), current["instanceToken"])):
        updated_at = item.get("lastUpdatedAt", 0)
        ts = (datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=updated_at)).astimezone().strftime("%Y-%m-%d %H:%M:%S")
        print(f"{ts} | refreshKey={item['instanceToken']} | {item['scopeRawValue']} | {item['phase']}")
PY
  else
    echo "(missing $instances_file)"
  fi
fi

if [[ ! -f "$log_file" ]]; then
  if [[ "$show_instances" -eq 1 ]]; then
    exit 0
  fi
  echo "No request log file found at $log_file" >&2
  exit 1
fi

if [[ "$json_output" -eq 1 ]]; then
  cat "$log_file"
else
  python3 - "$log_file" "$tail_count" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timedelta, timezone

path = pathlib.Path(sys.argv[1])
tail_count = int(sys.argv[2])
entries = json.loads(path.read_text())
entries = entries[-tail_count:]

for entry in entries:
    ts = (datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=entry["timestamp"])).astimezone().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    url = entry.get("url") or ""
    method = entry.get("method") or ""
    instance_token = entry.get("instanceToken") or ""
    status = entry.get("statusCode")
    duration = entry.get("durationMilliseconds")
    suffix = []
    if instance_token:
        suffix.append(f"refreshKey={instance_token}")
    if method:
        suffix.append(method)
    if status is not None:
        suffix.append(f"status={status}")
    if duration is not None:
        suffix.append(f"{duration}ms")
    extra = f" [{' '.join(suffix)}]" if suffix else ""
    if url:
        print(f"{ts} | {entry['source']} | {entry['summary']}{extra} | {url}")
    else:
        print(f"{ts} | {entry['source']} | {entry['summary']}{extra}")
PY
fi

if [[ "$show_instances" -eq 1 ]]; then
  echo
fi
