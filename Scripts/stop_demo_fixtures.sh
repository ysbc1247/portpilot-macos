#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
runtime_directory="$repository_root/.devberth-fixtures"

if [[ ! -d "$runtime_directory" ]]; then
  print "No DevBerth fixture runtime directory exists."
  exit 0
fi

for pid_file in "$runtime_directory"/*.pid(N); do
  pid="$(<"$pid_file")"
  if [[ "$pid" == <-> ]] && /bin/kill -0 "$pid" 2>/dev/null; then
    /bin/kill -TERM "$pid" 2>/dev/null || true
  fi
done

/bin/sleep 0.5
for pid_file in "$runtime_directory"/*.pid(N); do
  pid="$(<"$pid_file")"
  if [[ "$pid" == <-> ]] && /bin/kill -0 "$pid" 2>/dev/null; then
    /bin/kill -KILL "$pid" 2>/dev/null || true
  fi
done

print "Stopped DevBerth demo fixtures. Logs remain in $runtime_directory."
