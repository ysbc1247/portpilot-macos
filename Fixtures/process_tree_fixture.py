#!/usr/bin/env python3
"""Harmless process-tree fixture for DevBerth integration tests."""

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time


def serve(marker: str, listener_count: int, ignore_term: bool = False) -> None:
    if ignore_term:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    listeners = []
    ports = []
    for _ in range(listener_count):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(4)
        listeners.append(listener)
        ports.append(listener.getsockname()[1])
    print(
        json.dumps(
            {
                "event": "ready",
                "marker": marker,
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "pgid": os.getpgrp(),
                "ports": ports,
            }
        ),
        flush=True,
    )
    while True:
        time.sleep(0.2)


def child_arguments(script: str, marker: str, listener_count: int, ignore_term: bool = False) -> list[str]:
    arguments = [
        sys.executable,
        "-u",
        script,
        "--mode",
        "server",
        "--marker",
        marker,
        "--listeners",
        str(listener_count),
    ]
    if ignore_term:
        arguments.append("--ignore-term")
    return arguments


def supervise(script: str, marker: str, restart: bool, detach: bool, listener_count: int) -> None:
    while True:
        child = subprocess.Popen(
            child_arguments(script, marker, listener_count),
            start_new_session=detach,
        )
        print(
            json.dumps(
                {
                    "event": "spawned",
                    "marker": marker,
                    "pid": os.getpid(),
                    "child_pid": child.pid,
                    "pgid": os.getpgrp(),
                    "detached": detach,
                }
            ),
            flush=True,
        )
        child.wait()
        if not restart:
            while True:
                time.sleep(0.2)
        time.sleep(0.05)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=["server", "spawn-multiple", "replace", "restart", "detach", "ignore-term"],
        required=True,
    )
    parser.add_argument("--marker", required=True)
    parser.add_argument("--listeners", type=int, default=1)
    parser.add_argument("--ignore-term", action="store_true")
    args = parser.parse_args()
    script = os.path.abspath(__file__)

    if args.mode == "server":
        serve(args.marker, args.listeners, args.ignore_term)
    elif args.mode == "spawn-multiple":
        supervise(script, args.marker, restart=False, detach=False, listener_count=2)
    elif args.mode == "replace":
        os.execv(sys.executable, child_arguments(script, args.marker, 1))
    elif args.mode == "restart":
        supervise(script, args.marker, restart=True, detach=False, listener_count=1)
    elif args.mode == "detach":
        supervise(script, args.marker, restart=False, detach=True, listener_count=1)
    elif args.mode == "ignore-term":
        serve(args.marker, 1, ignore_term=True)


if __name__ == "__main__":
    main()
