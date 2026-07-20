#!/usr/bin/env python3
"""Development-only process that listens on multiple loopback TCP ports."""

import argparse
import signal
import socket
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ports", required=True, help="Comma-separated high-numbered ports")
    args = parser.parse_args()
    sockets = []
    for value in args.ports.split(","):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", int(value)))
        listener.listen()
        sockets.append(listener)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    print("READY " + args.ports, flush=True)
    while True:
        time.sleep(1)


if __name__ == "__main__":
    main()

