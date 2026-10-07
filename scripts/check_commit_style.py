"""Check the mechanical rules of personal-commit-style; content still needs review."""
import argparse
import json
import re
import subprocess
import sys

TITLE = re.compile(r"[a-z]+<[a-z0-9][a-z0-9._/-]*>: \S(?:.*\S)?")


def errors(subject):
    result = []
    if not TITLE.fullmatch(subject):
        result.append("use type<scope>: outcome")
    if subject != subject.lower():
        result.append("use a lowercase subject")
    if subject.endswith("."):
        result.append("omit the final period")
    if any(char in subject for char in "\r\n\u2013\u2014"):
        result.append("omit newlines and em/en dashes")
    return result


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def message_errors(message):
    result = errors(message.splitlines()[0] if message else "")
    if re.search(r"^co-authored-by\s*:", message, re.I | re.M):
        result.append("omit coauthor attribution")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", help="GitHub pull_request event file")
    parser.add_argument("--range", dest="revision_range", help="Git commit range, including merges")
    args = parser.parse_args()
    subjects = []
    if args.event:
        with open(args.event, encoding="utf-8") as stream:
            pr = json.load(stream)["pull_request"]
        subjects.append(("PR title", pr["title"]))
        base, head = pr["base"]["sha"], pr["head"]["sha"]
        for sha in git("rev-list", f"{base}..{head}").splitlines():
            subjects.append((sha, git("show", "-s", "--format=%B", sha)))
    if args.revision_range:
        for sha in git("rev-list", args.revision_range).splitlines():
            subjects.append((sha, git("show", "-s", "--format=%B", sha)))
    if not args.event and not args.revision_range:
        parser.error("provide --event or --range")
    failed = False
    for label, subject in subjects:
        problems = errors(subject) if label == "PR title" else message_errors(subject)
        if problems:
            # JSON escaping prevents subjects from injecting workflow commands.
            print(json.dumps({"revision": label, "subject": subject, "errors": problems}))
            failed = True
    if not failed:
        print(f"Commit style passed for {len(subjects)} subjects.")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
