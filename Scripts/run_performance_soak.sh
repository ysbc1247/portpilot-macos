#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h}"
duration_seconds="${DEVBERTH_PERFORMANCE_SOAK_SECONDS:-900}"
sample_interval_seconds="${DEVBERTH_PERFORMANCE_SAMPLE_SECONDS:-5}"
derived_data="${DEVBERTH_PERFORMANCE_DERIVED_DATA:-/tmp/devberth-performance-soak-derived}"
result_directory="${DEVBERTH_PERFORMANCE_RESULTS:-/tmp/devberth-performance-soak-$(date +%Y%m%d-%H%M%S)}"
application_pid=""

mkdir -p "$result_directory"

function cleanup {
  if [[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null; then
    kill -TERM "$application_pid"
    wait "$application_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

cd "$repository_root"

if [[ "${DEVBERTH_PERFORMANCE_SKIP_TESTS:-0}" != "1" ]]; then
  DEVBERTH_SOAK_PASSES="${DEVBERTH_SOAK_PASSES:-2}" Scripts/run_soak_tests.sh \
    >"$result_directory/test-output.log" 2>&1
fi

xcodegen generate >"$result_directory/xcodegen.log"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project DevBerth.xcodeproj \
  -scheme DevBerth \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build >"$result_directory/release-build.log"

application="$derived_data/Build/Products/Release/DevBerth.app"
executable="$application/Contents/MacOS/DevBerth"
if [[ ! -x "$executable" ]]; then
  print -u2 "The isolated Release application was not built at $application."
  exit 1
fi

DEVBERTH_UI_TESTING=1 "$executable" \
  >"$result_directory/application.log" 2>&1 &
application_pid="$!"

for _ in {1..100}; do
  if kill -0 "$application_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
if ! kill -0 "$application_pid" 2>/dev/null; then
  print -u2 "The isolated DevBerth process exited during startup."
  exit 1
fi

csv="$result_directory/process-samples.csv"
print 'timestamp_epoch,elapsed_seconds,cpu_percent,rss_kb,thread_count,child_count,cumulative_cpu' >"$csv"
started_at="$(date +%s)"
deadline="$((started_at + duration_seconds))"

while [[ "$(date +%s)" -lt "$deadline" ]]; do
  now="$(date +%s)"
  elapsed="$((now - started_at))"
  process_values="$(ps -p "$application_pid" -o %cpu=,rss=,time= | awk '{$1=$1; print}')"
  if [[ -z "$process_values" ]]; then
    print -u2 "The isolated DevBerth process exited before the soak completed."
    exit 1
  fi
  cpu_percent="${process_values%% *}"
  remaining="${process_values#* }"
  rss_kb="${remaining%% *}"
  cumulative_cpu="${remaining##* }"
  thread_count="$(( $(ps -M -p "$application_pid" | wc -l | tr -d ' ') - 1 ))"
  child_pids="$(pgrep -P "$application_pid" 2>/dev/null || true)"
  if [[ -z "$child_pids" ]]; then
    child_count=0
  else
    child_count="$(print -r -- "$child_pids" | wc -l | tr -d ' ')"
  fi
  print "$now,$elapsed,$cpu_percent,$rss_kb,$thread_count,$child_count,$cumulative_cpu" >>"$csv"
  sleep "$sample_interval_seconds"
done

first_sample="$(sed -n '2p' "$csv")"
last_sample="$(tail -n 1 "$csv")"
sample_count="$(( $(wc -l <"$csv" | tr -d ' ') - 1 ))"
error_count="$(grep -Eic 'error|fatal|crash' "$result_directory/application.log" || true)"

{
  print "duration_seconds=$duration_seconds"
  print "sample_interval_seconds=$sample_interval_seconds"
  print "sample_count=$sample_count"
  print "first_sample=$first_sample"
  print "last_sample=$last_sample"
  print "application_error_lines=$error_count"
  print "isolation=DEVBERTH_UI_TESTING_in_memory_static_fixtures_no_control_socket"
} >"$result_directory/summary.txt"

print "Performance soak completed: $result_directory"
