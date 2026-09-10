#!/usr/bin/env python3
"""Serve the Phase -1 export pack for browser preview."""

from __future__ import annotations

import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORT = ROOT / "samples" / "mock-session" / "export"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(EXPORT), **kwargs)

    def map_index(self) -> None:
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self.path = "/SESSION_BRIEF.html"

    def do_GET(self):  # noqa: N802
        self.map_index()
        return super().do_GET()

    def do_HEAD(self):  # noqa: N802
        self.map_index()
        return super().do_HEAD()

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        print("[%s] %s" % (self.log_date_time_string(), format % args))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=43147)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    if not (EXPORT / "SESSION_BRIEF.html").exists():
        raise SystemExit(f"Missing {EXPORT / 'SESSION_BRIEF.html'}; run scripts/generate_mock_session.py")
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Serving {EXPORT} at http://{args.host}:{args.port}/")
    server.serve_forever()


if __name__ == "__main__":
    main()
