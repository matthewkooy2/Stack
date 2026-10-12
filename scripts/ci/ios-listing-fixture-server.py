#!/usr/bin/env python3
"""Loopback HTTP fixture for the native listing-browser UI tests (ios/StackUITests/JobListingSafariTests.swift).

Test-only. It binds 127.0.0.1, serves a handful of fictional static pages and holds no data, accounts or
forms. Nothing here is a real job page. Usage:

    python3 scripts/ci/ios-listing-fixture-server.py [--port 18765]

Pages: /listing (long title and links), /detail, /redirect (302 to /redirected), /blank (target=_blank),
/flaky (connection is dropped while the fail switch is on), /control/fail?on=1|0, /control/hits?path=/x.
"""
import argparse
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LONG_TITLE = (
    "Senior Principal Staff Machine Learning Platform Reliability Engineer, Distributed Systems and "
    "Global Marketplace Infrastructure (Hybrid, Chicago, Illinois) Fixture Listing"
)

PAGE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>body{{font:17px -apple-system,sans-serif;margin:24px;background:#fffde7;color:#2c1d10}}a{{display:block;margin:18px 0;color:#5a4729}}</style>
</head><body><h1 id="heading">{title}</h1>{body}</body></html>"""

PAGES = {
    "/listing": (LONG_TITLE, (
        "<p>Fictional listing for UI tests. Nothing here is a real job.</p>"
        '<a id="detail-link" href="/detail">Read the internal detail page</a>'
        '<a id="blank-link" href="/blank" target="_blank">Open the new tab page</a>'
        '<a id="redirect-link" href="/redirect">Follow the redirect</a>'
    )),
    "/detail": ("Internal detail page", '<p>Reached through an internal link.</p><a href="/listing">Back to the listing</a>'),
    "/redirected": ("Redirect destination", "<p>You arrived through a 302 redirect.</p>"),
    "/blank": ("New tab page", "<p>Opened by a target=_blank link.</p>"),
    "/recovered": ("Recovered page", "<p>The connection works again.</p>"),
}

state = {"fail": False, "hits": {}}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_body(self, status, body, content_type="text/html; charset=utf-8", extra=None):
        data = body.encode("utf8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        with lock:
            state["hits"][path] = state["hits"].get(path, 0) + 1
            failing = state["fail"]
            hits = state["hits"].get("/flaky", 0)
        print(f"{time.time():.3f} path={self.path} fail={failing} flaky_hits={hits}", flush=True)
        if path == "/control/fail":
            on = parse_qs(url.query).get("on", ["0"])[0] == "1"
            with lock:
                state["fail"] = on
                if on:
                    state["hits"]["/flaky"] = 0
            return self.send_body(200, "ok", "text/plain")
        if path == "/control/hits":
            target = parse_qs(url.query).get("path", [""])[0]
            with lock:
                count = state["hits"].get(target, 0)
            return self.send_body(200, str(count), "text/plain")
        if path == "/health":
            return self.send_body(200, "ok", "text/plain")
        if path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/redirected")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/flaky":
            if failing:
                # Drop the connection without any response, as a dead server would.
                self.close_connection = True
                self.connection.close()
                return
            title, body = PAGES["/recovered"]
            return self.send_body(200, PAGE.format(title=title, body=body))
        if path in PAGES:
            title, body = PAGES[path]
            return self.send_body(200, PAGE.format(title=title, body=body))
        return self.send_body(404, PAGE.format(title="Not found", body="<p>No such fixture page.</p>"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"listing fixture on http://127.0.0.1:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
