#!/bin/zsh
set -euo pipefail

repository_root="${0:A:h:h}"
runtime_directory="$repository_root/.portpilot-fixtures"
mkdir -p "$runtime_directory"

function start_fixture() {
  local name="$1"
  shift
  /usr/bin/nohup /usr/bin/python3 "$@" >"$runtime_directory/$name.log" 2>&1 &
  print $! >"$runtime_directory/$name.pid"
}

start_fixture simple "$repository_root/Fixtures/http_fixture.py" --port 49151
start_fixture multi "$repository_root/Fixtures/multi_port_fixture.py" --ports 49152,49153
start_fixture ignores-term "$repository_root/Fixtures/http_fixture.py" --port 49154 --ignore-term
start_fixture conflict "$repository_root/Fixtures/http_fixture.py" --port 49155
start_fixture delayed-health "$repository_root/Fixtures/http_fixture.py" --port 49156 --health-delay 8

(/bin/sleep 0.2; /usr/bin/false) >"$runtime_directory/exits-during-startup.log" 2>&1 &
print $! >"$runtime_directory/exits-during-startup.pid"

print "Started PortPilot demo fixtures on ports 49151–49156."
print "Runtime files: $runtime_directory"

