#!/usr/bin/env python3
"""Development-only TCP/UDP and failure fixtures for DevBerth."""

import argparse
import json
import os
import signal
import socket
import sys
import time


def announce(event: str, **values: object) -> None:
    print(json.dumps({"event": event, "pid": os.getpid(), **values}), flush=True)


def serve(protocol: str, port: int, delay: float) -> None:
    if delay:
        time.sleep(delay)
    kind = socket.SOCK_DGRAM if protocol == "udp" else socket.SOCK_STREAM
    listener = socket.socket(socket.AF_INET, kind)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    if protocol == "tcp":
        listener.listen(4)
    announce("ready", protocol=protocol, port=listener.getsockname()[1], pgid=os.getpgrp())
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        time.sleep(0.2)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["tcp", "udp", "failed-readiness", "immediate-exit", "dependency-failure"], required=True)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--delay", type=float, default=0)
    args = parser.parse_args()
    if args.mode in ("tcp", "udp"):
        serve(args.mode, args.port, args.delay)
        return 0
    if args.mode == "failed-readiness":
        announce("failed", reason="fixture readiness failed deterministically")
        return 22
    if args.mode == "dependency-failure":
        announce("failed", reason="fixture dependency failed deterministically")
        return 23
    announce("exited", reason="fixture exited immediately as requested")
    return 0


if __name__ == "__main__":
    sys.exit(main())
