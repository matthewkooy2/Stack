"""Local IPC for staging generation; only the staging worker owns the OpenAI key and ledger."""
from contextvars import ContextVar
import json
import os
import pwd
import socket
import socketserver
import struct
import threading
from pathlib import Path

lease_context = ContextVar("staging_ai_lease", default=None)
MAX_PACKET = 2_000_000
STEPS = {"fit", "draft", "profile", "story", "coach", "interview_turn", "interview_coach",
         "tailor", "tailor_screen", "tailor_compose", "tailor_verify", "linkedin_review", "mail_scan"}


def read_packet(stream):
    line = stream.readline(MAX_PACKET + 1)
    if not line or len(line) > MAX_PACKET:
        raise ValueError("Invalid staging model request.")
    return json.loads(line)


def complete(step, system, prompt, schema, cap):
    if os.environ.get("STACK_FIRST_PARTY_AI_ONLY") == "1":
        raise ValueError("This deployment uses only Stack-hosted AI.")
    payload = json.dumps([lease_context.get(), step, system, prompt, schema, cap]).encode() + b"\n"
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(145)
        sock.connect(os.environ["STACK_STAGING_OPENAI_SOCKET"])
        sock.sendall(payload)
        with sock.makefile("rb") as stream:
            result = read_packet(stream)
    if "error" in result:
        raise ValueError(result["error"])
    return result["text"]


def start_server(generate):
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            _, uid, _ = struct.unpack("3i", self.request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            if uid != os.getuid() and pwd.getpwuid(uid).pw_name != "stack-rust":
                return
            self.request.settimeout(10)
            try:
                lease, step, system, prompt, schema, cap = read_packet(self.rfile)
                if step not in STEPS or type(cap) is not int or not 1 <= cap <= 32768:
                    raise ValueError("Invalid staging model operation.")
                result = {"text": generate(lease, step, system, prompt, schema, cap)}
            except ValueError as error:
                result = {"error": str(error)}
            except (OSError, RuntimeError, TypeError, KeyError):
                result = {"error": "The staging AI provider is unavailable. Please retry."}
            self.wfile.write(json.dumps(result).encode() + b"\n")

    class Server(socketserver.ThreadingUnixStreamServer):
        daemon_threads = True

    path = Path(os.environ["STACK_STAGING_OPENAI_SOCKET"])
    path.unlink(missing_ok=True)
    server = Server(str(path), Handler)
    path.chmod(0o666)  # Peer credentials restrict access to the two service identities.
    threading.Thread(target=server.serve_forever, daemon=True).start()
