#!/usr/bin/env python3
"""Toolchain-free structural checks for the SwiftUI app in ios/.

These checks run anywhere Python runs (including Windows and Linux CI) and catch the mistakes that
do not need a Swift compiler: unbalanced delimiters, unterminated strings, a file missing from the
project, duplicate top-level types, and backend function names the app calls that the gateway does
not publish. They do not replace `xcodebuild`; see scripts/ci/ios-swift.sh for the compile and test
route, which needs macOS.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "ios"
SOURCES = sorted((IOS / "Stack").rglob("*.swift")) + sorted((IOS / "StackTests").rglob("*.swift")) + sorted((IOS / "StackUITests").rglob("*.swift"))
PAIRS = {")": "(", "]": "[", "}": "{"}


def scan(path: Path) -> list[str]:
    """Balanced-delimiter scan that understands comments, strings, raw strings and interpolation."""
    text = path.read_text(encoding="utf8")
    problems: list[str] = []
    stack: list[tuple[str, int]] = []
    line = 1
    i = 0
    n = len(text)

    def fail(message: str) -> None:
        problems.append(f"{path.relative_to(ROOT)}:{line}: {message}")

    def read_string(start: int, hashes: int, multiline: bool) -> int:
        """Return the index after the closing quote; handles \\( ... ) interpolation recursively."""
        nonlocal line
        j = start
        close = '"' * (3 if multiline else 1) + "#" * hashes
        escape = "\\" + "#" * hashes
        while j < n:
            if text.startswith(close, j):
                return j + len(close)
            if text.startswith(escape + "(", j):
                depth = 1
                j += len(escape) + 1
                while j < n and depth:
                    c = text[j]
                    if c == "\n":
                        line += 1
                    if c == '"':
                        multi = text.startswith('"""', j)
                        j = read_string(j + (3 if multi else 1), 0, multi)
                        continue
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                    j += 1
                continue
            c = text[j]
            if c == "\n":
                if not multiline:
                    fail("unterminated string literal")
                    return j
                line += 1
            elif c == "\\" and hashes == 0:
                j += 1
            j += 1
        fail("unterminated string literal")
        return n

    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if text[i] == "\n":
                        line += 1
                    i += 1
        elif c == "#" and re.match(r"#+\"", text[i:i + 8] or ""):
            hashes = len(re.match(r"#+", text[i:]).group(0))
            multi = text.startswith('"""', i + hashes)
            i = read_string(i + hashes + (3 if multi else 1), hashes, multi)
        elif c == '"':
            multi = text.startswith('"""', i)
            i = read_string(i + (3 if multi else 1), 0, multi)
        elif c in "([{":
            stack.append((c, line))
            i += 1
        elif c in ")]}":
            if not stack or stack[-1][0] != PAIRS[c]:
                fail(f"unmatched '{c}'")
            else:
                stack.pop()
            i += 1
        else:
            i += 1
    for opener, opened in stack:
        problems.append(f"{path.relative_to(ROOT)}:{opened}: '{opener}' is never closed")
    return problems


def declared_types() -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    pattern = re.compile(r"^(?:final\s+|private\s+|fileprivate\s+|public\s+)*(?:struct|class|enum|actor)\s+([A-Z]\w*)", re.M)
    for path in SOURCES:
        for name in pattern.findall(path.read_text(encoding="utf8")):
            found.setdefault(name, []).append(str(path.relative_to(ROOT)))
    return found


def check_types() -> list[str]:
    problems = []
    for name, files in declared_types().items():
        if len(files) > 1:
            problems.append(f"type {name} is declared more than once: {', '.join(files)}")
    return problems


def check_project() -> list[str]:
    problems = []
    spec = (IOS / "project.yml").read_text(encoding="utf8")
    for needle in ("sources:", "- path: Stack", "- path: StackTests", "NSMicrophoneUsageDescription", "StackAPIBaseURL"):
        if needle not in spec:
            problems.append(f"ios/project.yml is missing {needle!r}")
    if not (IOS / "Stack" / "Resources" / "prep-catalog.json").exists():
        problems.append("ios/Stack/Resources/prep-catalog.json is missing")
    return problems


def gateway_functions() -> set[str]:
    """Function names the public gateway publishes for signed-in users (mobile/feature-rpcs.js)."""
    text = (ROOT / "mobile" / "feature-rpcs.js").read_text(encoding="utf8")
    match = re.search(r"`(.*?)`", text, re.S)
    return set(match.group(1).split()) if match else set()


def check_backend_calls() -> list[str]:
    """Every literal `call("name")` in the app must be a function the gateway publishes."""
    allowed = gateway_functions()
    if not allowed:
        return ["could not read the published function list from mobile/feature-rpcs.js"]
    # Account sign-in helpers and the anonymous endpoints are published separately.
    allowed |= {"auth_google_status", "auth_google_recover", "agent_admission", "agent_accept_invite"}
    problems = []
    pattern = re.compile(r"\.(?:call|callAccount|mutate)\(\s*\"([a-z_]+)\"")
    for path in SOURCES:
        if path.parts[-2] == "StackTests":
            continue
        text = path.read_text(encoding="utf8")
        for match in pattern.finditer(text):
            if match.group(1) not in allowed:
                line = text.count("\n", 0, match.start()) + 1
                problems.append(f"{path.relative_to(ROOT)}:{line}: unknown backend function {match.group(1)!r}")
    return problems


def main() -> int:
    problems: list[str] = []
    if not SOURCES:
        problems.append("no Swift sources found under ios/")
    for path in SOURCES:
        problems += scan(path)
    problems += check_types()
    problems += check_project()
    problems += check_backend_calls()
    if problems:
        print("\n".join(problems))
        print(f"\n{len(problems)} problem(s) in {len(SOURCES)} Swift files.")
        return 1
    print(f"{len(SOURCES)} Swift files: delimiters balanced, types unique, backend calls published.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
