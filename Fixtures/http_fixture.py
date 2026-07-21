#!/usr/bin/env python3
"""Development-only harmless HTTP listener for DevBerth integration tests."""

import argparse
import http.server
import signal
import socketserver
import sys
import time

STARTED_AT = time.monotonic()
HEALTH_DELAY = 0.0


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200 if time.monotonic() - STARTED_AT >= HEALTH_DELAY else 503)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--delay", type=float, default=0)
    parser.add_argument("--ignore-term", action="store_true")
    parser.add_argument("--health-delay", type=float, default=0)
    args = parser.parse_args()
    global HEALTH_DELAY
    HEALTH_DELAY = args.health_delay
    if args.ignore_term:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if args.delay:
        time.sleep(args.delay)
    with socketserver.TCPServer(("127.0.0.1", args.port), Handler) as server:
        print(f"READY {args.port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
