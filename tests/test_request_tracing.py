"""Manual HTTP and storage checks for request tracing."""

from contextlib import redirect_stdout
import io
import json
import threading
import unittest
from unittest.mock import patch
from urllib.request import Request, urlopen

from agents import gateway


class RequestTracing(unittest.TestCase):
    def test_http_200_application_failure_correlates_without_logging_payload(self):
        from pathlib import Path
        from runpy import run_path
        from agents.request_trace import response_outcome
        sanitize = run_path(str(Path(__file__).resolve().parents[1]
                                / "deploy/monitoring/read-stack-logs.py"))["sanitize"]
        request_id = "0123456789abcdef" * 2
        route = "/function/auth_apple_web_begin"
        response = b'{"ok":true,"data":{"result":{"ok":false,"error":"private-sentinel"}},"error":null}'

        class Backend(gateway.SimpleHTTPRequestHandler):
            def do_POST(self):
                self.server.forwarded_id = self.headers["X-Request-Id"]
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("X-Trace-Id", self.server.forwarded_id)
                self.end_headers()
                self.wfile.write(response)

            def log_message(self, *_):
                pass

        backend = gateway.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
        proxy = gateway.ThreadingHTTPServer(("127.0.0.1", 0), gateway.Handler)
        servers = (backend, proxy)
        threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in servers]
        for thread in threads:
            thread.start()
        try:
            output = io.StringIO()
            with (redirect_stdout(output), patch.dict(gateway._rates, clear=True),
                  patch.object(gateway, "BASE", f"http://127.0.0.1:{backend.server_port}")):
                request = Request(f"http://127.0.0.1:{proxy.server_port}" + route, data=b"{}",
                                  headers={"X-Request-Id": request_id})
                with urlopen(request, timeout=5) as reply:
                    self.assertEqual(reply.read(), response)
                    self.assertEqual(reply.headers["X-Request-Id"], request_id)
                proxy.shutdown()
            self.assertEqual(backend.forwarded_id, request_id)
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            event = next(row for row in events if row["event"] == "upstream_response")
            self.assertEqual((event["status"], event["outcome"]), (200, "application_error"))
            self.assertEqual((event["request_id"], event["backend_trace_id"]), (request_id, request_id))
            self.assertNotIn("private-sentinel", output.getvalue())
            stored_gateway = sanitize("gateway", json.dumps(event))
            stored_api = sanitize("api", f'172.17.0.1 "POST {route}?code=private-sentinel HTTP/1.1" 200 80 2.5ms {request_id}')
            self.assertEqual(stored_gateway["outcome"], "application_error")
            self.assertEqual(stored_gateway["request_id"], stored_api["request_id"])
            self.assertNotIn("private-sentinel", json.dumps(stored_api))
            self.assertNotIn("172.17.0.1", json.dumps(stored_api))
            cases = [(b'{"ok":false}', "application_error"),
                     (b'{"data":{"result":{"error":"private-sentinel"}}}', "application_error"),
                     (b'{"ok":true,"error":null,"data":{"result":{"ok":true}}}', "response"),
                     (b'invalid-json', "inspection_skipped")]
            for payload, outcome in cases:
                self.assertEqual(response_outcome(200, "application/json; charset=utf-8", payload), outcome)
        finally:
            for server, thread in zip(servers, threads):
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == "__main__":
    unittest.main()
