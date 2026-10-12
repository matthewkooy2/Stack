#!/usr/bin/env python3
"""Run one xcodebuild command with bounded process cleanup and preserved output."""
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time


cancel_signal = None


def request_cancel(signum, _frame):
    global cancel_signal
    cancel_signal = signum


def process_group_exists(group_id):
    try:
        os.killpg(group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_process_tree(process):
    if os.name == "nt":
        try:
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=8,
            )
        except subprocess.TimeoutExpired:
            pass
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        return

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    grace_deadline = time.monotonic() + 8
    while process_group_exists(process.pid) and time.monotonic() < grace_deadline:
        process.poll()
        time.sleep(0.1)
    if process_group_exists(process.pid):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def main(argv):
    if len(argv) < 3:
        print("Usage: ios-xcodebuild.py TIMEOUT_SECONDS COMMAND [ARG ...]", file=sys.stderr)
        return 2
    try:
        timeout = int(argv[1])
    except ValueError:
        print("TIMEOUT_SECONDS must be an integer", file=sys.stderr)
        return 2
    if timeout < 1 or timeout > 3600:
        print("TIMEOUT_SECONDS must be between 1 and 3600", file=sys.stderr)
        return 2

    command = argv[2:]
    started = time.monotonic()
    deadline = started + timeout
    signal.signal(signal.SIGTERM, request_cancel)
    signal.signal(signal.SIGINT, request_cancel)
    with tempfile.TemporaryFile(mode="w+b") as output:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=(os.name != "nt"),
            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0,
        )
        suite_complete = threading.Event()
        ui_suite_complete = threading.Event()

        def collect_output():
            assert process.stdout is not None
            for line in process.stdout:
                try:
                    output.write(line)
                    sys.stdout.buffer.write(line)
                    sys.stdout.buffer.flush()
                except (OSError, ValueError):
                    return
                if re.search(rb"Test Suite 'StackUITests\.xctest' (?:passed|failed) at ", line):
                    ui_suite_complete.set()
                if ui_suite_complete.is_set() and re.search(rb"Test Suite 'Selected tests' (?:passed|failed) at ", line):
                    suite_complete.set()

        collector = threading.Thread(target=collect_output, daemon=True)
        collector.start()
        timed_out = False
        cancelled = False
        cleanup_failed = False
        reported_suite_complete = False
        next_notice = started + 60
        while process.poll() is None:
            now = time.monotonic()
            if suite_complete.is_set() and not reported_suite_complete:
                reported_suite_complete = True
                print("[ios-xcodebuild] selected XCTest suite completed; waiting for xcodebuild result and diagnostics", flush=True)
            if cancel_signal is not None:
                cancelled = True
                stop_process_tree(process)
                break
            if now >= deadline:
                timed_out = True
                stop_process_tree(process)
                break
            if now >= next_notice:
                stage = "collecting xcodebuild result/diagnostics after XCTest completion" if suite_complete.is_set() else "xcodebuild/test command still active"
                print(f"[ios-xcodebuild] {stage} after {int(now - started)}s", flush=True)
                next_notice = now + 60
            time.sleep(min(1, max(0.05, deadline - now)))

        collector.join(timeout=8)
        if cancel_signal is not None:
            cancelled = True
        if collector.is_alive():
            print("[ios-xcodebuild] output pipe remained open after process cleanup; returning without waiting for orphaned writers", file=sys.stderr)
            if os.name != "nt":
                try:
                    stop_process_tree(process)
                except ProcessLookupError:
                    pass
            try:
                process.stdout.close()
            except (OSError, ValueError):
                pass
            collector.join(timeout=1)
            cleanup_failed = True
        output.flush()

    if cancelled:
        print(f"[ios-xcodebuild] received signal {cancel_signal}; process tree stopped; xcodebuild failed", file=sys.stderr)
        return 128 + int(cancel_signal)
    if cleanup_failed:
        print("[ios-xcodebuild] output pipe did not close after process cleanup; xcodebuild failed", file=sys.stderr)
        return 1
    if timed_out:
        stage = "after XCTest completion while collecting xcodebuild diagnostics" if suite_complete.is_set() else "while xcodebuild/test was active"
        print(f"[ios-xcodebuild] exceeded the existing {timeout}s budget {stage}; process tree stopped; xcodebuild failed", file=sys.stderr)
        return 124
    return process.returncode if process.returncode is not None else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))


