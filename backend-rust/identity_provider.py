"""Stateless provider transport. All durable state lives in the Rust service's SQLite DB."""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import sys
import time
from contextlib import contextmanager, redirect_stdout
from pathlib import Path
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

TOKEN = re.compile(r"[a-zA-Z0-9_-]{43}")
VERIFIER = re.compile(r"[a-zA-Z0-9._~-]{43,128}")


def login(error=""):
    return {"ok": False, "token": "", "username": "", "error": error}


def digest(value):
    return hashlib.sha256(value.encode()).digest()


def challenge(value):
    return base64.urlsafe_b64encode(digest(value)).decode().rstrip("=")


@contextmanager
def immediate(db):
    db.execute("BEGIN IMMEDIATE")
    try:
        yield
        db.commit()
    finally:
        if db.in_transaction:
            db.rollback()


class Store:
    def __init__(self, db):
        self.db = db

    def save(self, value, purpose, ttl, data, owner=None):
        self.db.execute("DELETE FROM sso_challenges WHERE expires<=unixepoch()")
        self.db.execute("INSERT INTO sso_challenges VALUES(?,?,?,?,?)",
                        (digest(value), purpose, int(time.time()) + ttl, json.dumps(data), owner))

    def create_token(self, owner, purpose, ttl, value):
        token = secrets.token_urlsafe(32)
        with immediate(self.db):
            self.save(token, purpose, ttl, {"identity_value": value}, owner or None)
        return token

    def record(self, value, purpose, consume=False):
        if not TOKEN.fullmatch(value):
            return None
        condition = " WHERE digest=? AND purpose=? AND expires>unixepoch()"
        sql = ("DELETE FROM sso_challenges" + condition + " RETURNING data,owner" if consume else
               "SELECT data,owner FROM sso_challenges" + condition)
        row = self.db.execute(sql, (digest(value), purpose)).fetchone()
        return (json.loads(row[0]), row[1]) if row else None

    def peek_token(self, value, purpose):
        row = self.record(value, purpose)
        return row[0] if row else None

    def consume_token(self, value, purpose):
        row = self.record(value, purpose, True)
        return row[0] if row else None

    def resolve(self, provider, subject, email, linked=None, client="", sealed=""):
        email = email.strip().lower()
        if not subject:
            raise ValueError("Provider returned no verified account")
        db = self.db
        def owner_for(sql, args):
            row = db.execute(sql, args).fetchone()
            return row[0] if row else None
        bound = owner_for("SELECT owner FROM sso_bindings WHERE provider=? AND subject=?", (provider, subject))
        verified = owner_for("SELECT owner FROM sso_emails WHERE email=?", (email,)) if email else None
        if len(set(x for x in (bound, verified, linked) if x)) > 1:
            raise ValueError("This sign-in already belongs to another Stack account.")
        owner = linked or bound or verified
        if owner:
            account = db.execute("SELECT username FROM accounts WHERE id=?", (owner,)).fetchone()
            if not account:
                raise ValueError("Account no longer exists")
            username = account[0]
        else:
            if not email:
                raise ValueError("Share your email to create your Stack account.")
            owner = secrets.token_hex(32)
            username = provider + "_" + secrets.token_hex(16)
            # This account authenticates through a verified provider binding.
            db.execute("INSERT INTO accounts(id,username,password) VALUES(?,?,'!')", (owner, username))
        if not bound:
            db.execute("INSERT INTO sso_bindings VALUES(?,?,?)", (provider, subject, owner))
        if email and not verified:
            db.execute("INSERT INTO sso_emails VALUES(?,?)", (email, owner))
        if sealed:
            db.execute("INSERT INTO apple_grants VALUES(?,?,?) ON CONFLICT(owner,client) DO UPDATE SET sealed=excluded.sealed",
                       (owner, client, sealed))
        token = secrets.token_urlsafe(48)
        db.execute("INSERT INTO sessions VALUES(?,?,unixepoch()+604800)", (digest(token), owner))
        return owner, {"ok": True, "token": token, "username": username, "error": ""}


def google_exchange(code, verifier, redirect):
    body = urlencode(dict(grant_type="authorization_code", code=code, code_verifier=verifier,
                          redirect_uri=redirect, client_id=os.environ["GOOGLE_CLIENT_ID"],
                          client_secret=os.environ["GOOGLE_CLIENT_SECRET"])).encode()
    with urlopen(Request("https://oauth2.googleapis.com/token", data=body), timeout=12) as response:
        token = json.loads(response.read(65536))["access_token"]
    request = Request("https://www.googleapis.com/oauth2/v3/userinfo", headers={"Authorization": "Bearer " + token})
    with urlopen(request, timeout=12) as response:
        info = json.loads(response.read(65536))
    if info.get("email_verified") is not True or not info.get("sub") or not info.get("email"):
        raise ValueError("Google must verify your email before signing in.")
    return info["sub"], info["email"]


def google(store, method, args, linked):
    if method == "poll":
        record = store.record(args.get("poll", ""), "google-poll", True)
        return record[0] if record else login()
    config = os.environ["GOOGLE_CLIENT_ID"]
    host = os.environ["STACK_SSO_HOST"].rstrip("/")
    callback = os.environ.get("STACK_SSO_CALLBACK_URL", "")
    redirect = host + "/sso/google/callback"
    if not urlsplit(host).hostname or urlsplit(host).scheme != "https":
        raise ValueError("Google needs a registered HTTPS host.")
    if method == "begin":
        start = {"ok": False, "url": "", "state": "", "poll": "", "error": "Invalid sign-in request."}
        mode, proof = args.get("mode", "web"), args.get("challenge", "")
        if mode not in ("native", "web") or not TOKEN.fullmatch(proof):
            return start
        if mode == "web" and (not callback.startswith(host + "/") or urlsplit(callback).path != "/auth/google" or urlsplit(callback).query or urlsplit(callback).fragment):
            raise ValueError("Invalid callback URL.")
        poll = secrets.token_urlsafe(32) if mode == "native" else ""
        verifier = secrets.token_urlsafe(48) if mode == "native" else ""
        state = secrets.token_urlsafe(32)
        with immediate(store.db):
            store.save(state, "google", 600, dict(challenge=proof, mode=mode, verifier=verifier,
                       poll_hash=digest(poll).hex() if poll else "", client=config, redirect=redirect, callback=callback), linked)
        query = urlencode(dict(client_id=config, redirect_uri=redirect, response_type="code", state=state,
                               code_challenge=challenge(verifier) if verifier else proof, code_challenge_method="S256", scope="openid email profile"))
        return dict(ok=True, url="https://accounts.google.com/o/oauth2/v2/auth?" + query, state=state, poll=poll, error="")
    state = args.get("state", "")
    if method == "finish" and not VERIFIER.fullmatch(args.get("verifier","")):
        return login("Invalid sign-in verification.")
    record = store.record(state, "google")
    if not record or record[0]["client"] != config or record[0]["redirect"] != redirect:
        return login("Sign-in expired or belongs to another device. Please try again.")
    data, linked = record
    if method == "callback" and data["mode"] == "web":
        return {"mode":"web", "redirect":data["callback"]+"?"+urlencode({k:args.get(k,"") for k in ("code","state","error")})}
    native = method == "callback" and data["mode"] == "native"
    verifier = data["verifier"] if native else args.get("verifier", "")
    if not native and (data["mode"] != "web" or not hmac.compare_digest(data["challenge"], challenge(verifier))):
        return login("Sign-in expired or belongs to another device. Please try again.")
    if not store.record(state, "google", True):
        return login("This sign-in has already been used.")
    try:
        if not args.get("code") or args.get("error"):
            raise ValueError("Declined")
        subject, email = google_exchange(args["code"], verifier, redirect)
        with immediate(store.db):
            owner, result = store.resolve("google", subject, email, linked)
            if native:
                store.db.execute("INSERT INTO sso_challenges VALUES(?,'google-poll',unixepoch()+600,?,?)",
                                 (bytes.fromhex(data["poll_hash"]), json.dumps(result), owner))
    except Exception:
        result = login("Could not complete SSO sign-in. Please try again.")
        if native:
            store.db.execute("INSERT INTO sso_challenges VALUES(?,'google-poll',unixepoch()+600,?,NULL)",
                             (bytes.fromhex(data["poll_hash"]), json.dumps(result)))
    return {"mode":"native","success":result["ok"]} if native else result


def apple(store, method, args):
    from agents import apple_auth as provider
    if method == "revoke":
        for client, sealed in args["grants"]:
            token = provider._encryption().decrypt(sealed.encode()).decode()
            provider._apple_post("/auth/revoke", client, {"token": token, "token_type_hint": "refresh_token"})
        return {"ok": True}
    if method != "finish":
        return provider.begin("web" if method == "web_begin" else "native", store=store)

    def issue(subject, email, client, sealed):
        with immediate(store.db):
            _, result = store.resolve("apple", subject, email, client=client, sealed=sealed)
        result.pop("error")
        return result

    return provider.finish(args.get("state", ""), args.get("identity_token", ""), args.get("authorization_code", ""),
                           None, store=store, issue_identity=issue)


def main():
    # The release bundles the repository-pinned provider dependencies alongside score rendering.
    root = Path(sys.argv[1]).resolve()
    sys.path[:0] = [str(root), str(root / "score-docs")]
    request = json.load(sys.stdin)
    db = sqlite3.connect(Path(request["database"]).resolve().as_uri() + "?mode=rw", uri=True, timeout=10, isolation_level=None)
    db.execute("PRAGMA foreign_keys=ON")
    store = Store(db)
    if request["platform"] == "google":
        result = google(store, request["method"], request["args"], request.get("owner"))
    else:
        with redirect_stdout(sys.stderr):
            result = apple(store, request["method"], request["args"])
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(1)
