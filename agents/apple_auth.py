"""Native Apple identity boundary. No Jac browser Apple provider or email linking.

Apple secrets/grants are never returned or logged. Runtime imports are lazy so
cryptographic and identity behavior can be tested without starting Jac.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time
from contextlib import contextmanager, ExitStack
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, HTTPRedirectHandler, build_opener
from urllib.error import HTTPError
from typing import Any

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

ISSUER = "https://appleid.apple.com"
PURPOSE = "stack:apple:native:v1"
_keys = {}
_keys_until = 0
_keys_fetched = 0
_key_lock = threading.Lock()


class AppleError(ValueError):
    def __init__(self, code="APPLE_INVALID", message="Apple sign-in could not finish. Please try again."):
        super().__init__(message)
        self.code = code


def configuration(require_enabled=True):
    if require_enabled and os.environ.get("STACK_APPLE_ENABLED") != "1":
        raise AppleError("APPLE_DISABLED", "Apple sign-in is not available yet.")
    values = {k: os.environ.get(k, "").strip() for k in (
        "STACK_APPLE_CLIENT_ID", "STACK_APPLE_TEAM_ID", "STACK_APPLE_KEY_ID",
        "STACK_APPLE_KEY_FILE", "STACK_CONNECTION_KEY")}
    if not all(values.values()):
        raise AppleError("APPLE_DISABLED", "Apple sign-in is not available yet.")
    try:
        Fernet(values["STACK_CONNECTION_KEY"].encode())
    except Exception:
        raise AppleError("APPLE_DISABLED", "Apple sign-in is not available yet.") from None
    return values


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def unb64(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise AppleError()
    try:
        result = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        if b64(result) != value:
            raise AppleError()
        return result
    except Exception:
        raise AppleError() from None


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AppleError()
        result[key] = value
    return result


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise AppleError("APPLE_UNAVAILABLE", "Apple sign-in is temporarily unavailable.")


def provider(path, form=None):
    # Paths are constants, never supplied by a caller or token header (jku/x5u).
    if path not in ("/auth/keys", "/auth/token", "/auth/revoke"):
        raise AppleError()
    body = urlencode(form).encode() if form is not None else None
    request = Request(ISSUER + path, data=body,
                      headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        try:
            response = build_opener(NoRedirect()).open(request, timeout=15)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read(65537)
            if len(raw) > 65536:
                raise AppleError()
            value = json.loads(raw, object_pairs_hook=object_pairs) if raw else {}
            if response.status == 400 and isinstance(value, dict) and value.get("error") == "invalid_grant" and form and form.get("grant_type") == "refresh_token":
                raise AppleError("APPLE_REVOKED", "Apple authorization has expired. Sign in again.")
            if not isinstance(value, dict) or value.get("error") or response.status != 200:
                raise AppleError()
            return value
    except AppleError as error:
        if error.code == "APPLE_REVOKED":
            raise
        raise AppleError("APPLE_UNAVAILABLE", "Apple sign-in is temporarily unavailable.") from None
    except Exception:
        # HTTP bodies, request URLs and low-level exceptions can contain secrets.
        raise AppleError("APPLE_UNAVAILABLE", "Apple sign-in is temporarily unavailable.") from None


def signing_key(kid):
    global _keys, _keys_until, _keys_fetched
    with _key_lock:
        now = time.time()
        if now >= _keys_until or (kid not in _keys and now - _keys_fetched >= 60):
            document = provider("/auth/keys")
            candidates = document.get("keys")
            if not isinstance(candidates, list) or len(candidates) > 20:
                raise AppleError()
            keys = {}
            for value in candidates:
                if value.get("kty") == "RSA" and value.get("alg") == "RS256" and value.get("use") == "sig":
                    n = int.from_bytes(unb64(value["n"]), "big")
                    e = int.from_bytes(unb64(value["e"]), "big")
                    if n.bit_length() < 2048 or e != 65537 or value["kid"] in keys:
                        raise AppleError()
                    keys[value["kid"]] = rsa.RSAPublicNumbers(e, n).public_key()
            _keys, _keys_until, _keys_fetched = keys, now + 3600, now
        if kid not in _keys:
            raise AppleError()
        return _keys[kid]


def verify(token, audience, nonce=None, notification=False):
    try:
        if not isinstance(token, str) or len(token) > 16384:
            raise AppleError()
        header64, claims64, signature64 = token.split(".")
        header = json.loads(unb64(header64), object_pairs_hook=object_pairs)
        claims = json.loads(unb64(claims64), object_pairs_hook=object_pairs)
        if not isinstance(header, dict) or not isinstance(claims, dict):
            raise AppleError()
        if header.get("alg") != "RS256" or header.get("crit") or not isinstance(header.get("kid"), str):
            raise AppleError()
        signing_key(header["kid"]).verify(unb64(signature64),
            (header64 + "." + claims64).encode("ascii"), padding.PKCS1v15(), hashes.SHA256())
        now = time.time()
        if claims.get("iss") != ISSUER or claims.get("aud") != audience:
            raise AppleError()
        for field in (("iat",) if notification else ("exp", "iat")):
            if type(claims.get(field)) not in (int, float):
                raise AppleError()
        if notification:
            if not now - 2592000 <= claims["iat"] <= now + 30:
                raise AppleError()
            return claims
        if not now < claims["exp"] <= now + 86400 or not now - 600 <= claims["iat"] <= now + 30:
            raise AppleError()
        if claims["exp"] <= claims["iat"]:
            raise AppleError()
        if "nbf" in claims and (type(claims["nbf"]) not in (int, float) or claims["nbf"] > now):
            raise AppleError()
        if not isinstance(claims.get("sub"), str) or not 1 <= len(claims["sub"]) <= 255:
            raise AppleError()
        if nonce is not None and (not isinstance(claims.get("nonce"), str) or not hmac.compare_digest(claims["nonce"], nonce)):
            raise AppleError()
        return claims
    except AppleError:
        raise
    except Exception:
        raise AppleError() from None


def client_secret(cfg):
    try:
        key = serialization.load_pem_private_key(Path(cfg["STACK_APPLE_KEY_FILE"]).read_bytes(), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
            raise AppleError()
        now = int(time.time())
        header = b64(json.dumps({"alg": "ES256", "kid": cfg["STACK_APPLE_KEY_ID"]}).encode())
        claims = b64(json.dumps({"iss": cfg["STACK_APPLE_TEAM_ID"], "iat": now, "exp": now + 300,
            "aud": ISSUER, "sub": cfg["STACK_APPLE_CLIENT_ID"]}).encode())
        message = (header + "." + claims).encode()
        r, s = decode_dss_signature(key.sign(message, ec.ECDSA(hashes.SHA256())))
        return message.decode() + "." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
    except Exception:
        raise AppleError("APPLE_DISABLED", "Apple sign-in is not available yet.") from None


def runtime():
    from jaclang.server.identity.user_manager import UserManager
    from jaclang.server.identity.auth_tokens import AuthTokenStore
    from jaclang.server.shared_store import shared_store
    db = shared_store()
    if db is None:
        raise AppleError("APPLE_UNAVAILABLE", "Apple sign-in is temporarily unavailable.")
    return UserManager(), AuthTokenStore.instance(), db


@contextmanager
def identity_lock(db, subject):
    key = "stack-apple-lock:" + hashlib.sha256(subject.encode()).hexdigest()
    value = secrets.token_urlsafe(32)
    # Do not let a timer steal a lock during slow account cleanup. A crashed
    # worker leaves a fail-closed lock requiring an operator's verified recovery.
    rows = db.rows("""INSERT INTO kv_state (key,value,expires_at) VALUES (:k,:v,'infinity')
        ON CONFLICT (key) DO NOTHING RETURNING key""", {"k": key, "v": value})
    if not rows:
        raise AppleError("APPLE_CONFLICT", "An Apple request is already in progress. Please try again.")
    try:
        yield
    finally:
        db.rows("DELETE FROM kv_state WHERE key=:k AND value=:v", {"k": key, "v": value})


def begin(action: str = "login", owner: str = "", username: str = "", password: str = "") -> dict[str, Any]:
    try:
        cfg = configuration(require_enabled=action != "delete")
        manager, store, db = runtime()
        user_id = ""
        if action == "link":
            user = manager.authenticate(username, password)
            if not user or manager.get_root_id(user["user_id"]) != owner:
                raise AppleError("APPLE_INVALID", "Confirm this account's username and password to link Apple.")
            user_id = user["user_id"]
        elif action == "delete":
            if not owner:
                raise AppleError()
        elif action != "login":
            raise AppleError()
        nonce = hashlib.sha256(secrets.token_bytes(32)).hexdigest()
        state = store.create_token(user_id, PURPOSE, 300, json.dumps({
            "nonce": nonce, "audience": cfg["STACK_APPLE_CLIENT_ID"], "action": action, "owner": owner,
            "started_at": time.time()}))
        return {"ok": True, "state": state, "nonce": nonce, "expires_in": 300}
    except AppleError as error:
        return failure(error)
    except Exception:
        return failure(AppleError("APPLE_UNAVAILABLE", "Apple sign-in is temporarily unavailable."))


def failure(error):
    return {"ok": False, "code": error.code, "error": str(error)}


def _proof(state, identity_token, authorization_code, action, owner):
    cfg = configuration(require_enabled=action != "delete")
    manager, store, db = runtime()
    if not isinstance(state, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", state):
        raise AppleError()
    record = store.peek_token(state, PURPOSE)
    if not record:
        raise AppleError()
    challenge = json.loads(record["identity_value"])
    if challenge["action"] != action or challenge["owner"] != owner or challenge["audience"] != cfg["STACK_APPLE_CLIENT_ID"]:
        raise AppleError()
    if not isinstance(authorization_code, str) or not 1 <= len(authorization_code) <= 4096:
        raise AppleError()
    claims = verify(identity_token, cfg["STACK_APPLE_CLIENT_ID"], challenge["nonce"])
    if not store.consume_token(state, PURPOSE):
        raise AppleError()
    payload = provider("/auth/token", {"client_id": cfg["STACK_APPLE_CLIENT_ID"],
        "client_secret": client_secret(cfg), "grant_type": "authorization_code", "code": authorization_code})
    exchanged = verify(payload.get("id_token"), cfg["STACK_APPLE_CLIENT_ID"])
    if exchanged["sub"] != claims["sub"] or not isinstance(payload.get("refresh_token"), str) or not payload["refresh_token"]:
        raise AppleError()
    # Exchange id_token may omit nonce; if included it must still match.
    if "nonce" in exchanged and exchanged["nonce"] != challenge["nonce"]:
        raise AppleError()
    claims["_stack_started_at"] = challenge["started_at"]
    return cfg, manager, db, record, claims, payload["refresh_token"]


def finish(state: str, identity_token: str, authorization_code: str, name: str = "", action: str = "login", owner: str = "") -> dict[str, Any]:
    try:
        if action not in ("login", "link"):
            raise AppleError()
        cfg, manager, db, record, claims, refresh = _proof(state, identity_token, authorization_code, action, owner)
        subject = claims["sub"]
        with identity_lock(db, "subject:" + subject):
            watermark = read_state(db, "subject:" + hashlib.sha256(subject.encode()).hexdigest())
            if min(claims["iat"], claims["_stack_started_at"]) <= watermark.get("revoked_at", 0):
                raise AppleError("APPLE_REVOKED", "Start a new Apple sign-in to authorize this account.")
            existing = manager.get_user_by_sso("apple", subject)
            user_id = record["user_id"] if action == "link" else (existing or {}).get("user_id", "")
            if existing and existing["user_id"] != user_id:
                raise AppleError("APPLE_CONFLICT", "This Apple account is connected to another Stack account.")
            if action == "link" and (not user_id or manager.get_root_id(user_id) != owner):
                raise AppleError()
            created = False
            if not user_id:
                # A random internal username/password is never an email identity.
                result = manager.create_user("apple_" + secrets.token_hex(16), secrets.token_urlsafe(48))
                if result.get("error"):
                    raise AppleError()
                user_id, created = result["user_id"], True
            with identity_lock(db, "user:" + user_id):
                return _finish_user(cfg, manager, db, user_id, subject, refresh, claims, name, existing, created)
    except AppleError as error:
        return failure(error)
    except Exception:
        return failure(AppleError("APPLE_UNAVAILABLE", "Apple sign-in is temporarily unavailable."))


def _finish_user(cfg, manager, db, user_id, subject, refresh, claims, name, existing, created):
    user = manager.get_user(user_id)
    if not user or user.get("status", "active") != "active" or user.get("role") == "system":
        raise AppleError()
    accounts = manager.get_sso_accounts(user_id)
    lookups = db.rows("SELECT external_id FROM sso_lookups WHERE provider='apple' AND user_id=:u", {"u":user_id})
    if any(x[0] != subject for x in lookups) or any(x.get("platform") == "apple" and x.get("external_id") != subject for x in accounts):
        raise AppleError("APPLE_CONFLICT", "This Stack account already has an Apple account connected.")
    lifecycle = read_state(db, user_id)
    watermark = read_state(db, "subject:" + hashlib.sha256(subject.encode()).hexdigest())
    if watermark.get("revoked_at", 0) > lifecycle.get("revoked_at", 0):
        invalidate_sessions(db, user_id, lifecycle, watermark["revoked_at"])
    if min(claims["iat"], claims["_stack_started_at"]) <= lifecycle.get("revoked_at", 0):
        raise AppleError("APPLE_REVOKED", "Start a new Apple sign-in to authorize this account.")
    # Every fresh authorization replaces the Apple session generation. Without
    # this, a missed revocation followed by reauthorization could renew a saved
    # grant while keeping older Apple JWTs valid under the previous epoch.
    lifecycle["epoch"] = secrets.token_urlsafe(32)
    lifecycle["revoked"] = False
    grant = {"refresh_token": refresh, "subject": subject, "client_id": cfg["STACK_APPLE_CLIENT_ID"],
             "authorized_at": claims["iat"], "checked_at": time.time()}
    sealed = seal_grant(cfg, grant)
    try:
        # Publish the new epoch before replacing the grant. If a later identity
        # or metadata write fails, the old epoch must not gain a new 24h window.
        # The user lock prevents a preflight observing this intermediate state.
        write_state(db, user_id, lifecycle)
        # Persist first: a failed grant write must not link an existing account.
        db.rows("""INSERT INTO kv_state (key,value,expires_at) VALUES (:k,:v,'infinity')
            ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value,expires_at=EXCLUDED.expires_at""",
            {"k": "stack-apple-grant:" + user_id, "v": sealed})
        if not existing and manager.link_sso_account(user_id, "apple", subject).get("error"):
            raise AppleError("APPLE_CONFLICT", "This Apple account is connected to another Stack account.")
        # Jac 0.37.21 writes the SSO lookup and identity document separately.
        # A previous interrupted link may leave the lookup without its document.
        if not any(x.get("platform") == "apple" and x.get("external_id") == subject
                   for x in manager.get_sso_accounts(user_id)):
            identity = {"type":"sso", "provider":"apple", "external_id":subject,
                        "verified":True, "linked_at":str(time.time())}
            # UserManager.update_user_fields intentionally filters identities.
            # Use the pinned identity schema to append atomically, preserving
            # concurrent updates to unrelated providers/profile fields.
            db.rows("""UPDATE identity_users SET doc=jsonb_set(doc,'{identities}',
                COALESCE(doc->'identities','[]'::jsonb) || CAST(:i AS jsonb),true)
                WHERE user_id=:u AND NOT EXISTS (
                    SELECT 1 FROM jsonb_array_elements(COALESCE(doc->'identities','[]'::jsonb)) x
                    WHERE x->>'type'='sso' AND x->>'provider'='apple') RETURNING user_id""",
                {"u":user_id,"i":json.dumps([identity])})
            if not any(x.get("platform") == "apple" and x.get("external_id") == subject
                       for x in manager.get_sso_accounts(user_id)):
                raise AppleError()
    except Exception:
        if created:
            manager.delete_user(user_id)
        # Jac's identity write can fail after its lookup insert. Keep the grant
        # if that lookup exists so recovery/deletion can still revoke it.
        linked = manager.get_user_by_sso("apple", subject)
        if not linked or linked["user_id"] != user_id:
            db.rows("DELETE FROM kv_state WHERE key=:k", {"k":"stack-apple-grant:" + user_id})
        raise
    # Optional metadata only. Returning authorization commonly omits name.
    profile = dict(user.get("profile") or {})
    apple = dict(profile.get("apple") or {})
    if isinstance(name, str) and name.strip():
        apple["name"] = name.strip()[:200]
    if claims.get("email_verified") in (True, "true") and isinstance(claims.get("email"), str):
        apple["email"] = claims["email"][:320]
        apple["private_email"] = claims.get("is_private_email") in (True, "true")
    profile["apple"] = apple
    if not manager.update_user_fields(user_id, {"profile": profile}):
        raise AppleError()
    return {"ok": True, "token": apple_session_token(manager, user_id, lifecycle["epoch"]),
            "username": manager.get_username(user_id) or ""}


def deletion_proof(state: str, identity_token: str, authorization_code: str, owner: str) -> dict[str, Any]:
    """Server-only result passed to deletion_guard, never serialized to the client."""
    cfg, manager, db, record, claims, refresh = _proof(state, identity_token, authorization_code, "delete", owner)
    user = manager.get_user_by_sso("apple", claims["sub"])
    if not user or manager.get_root_id(user["user_id"]) != owner:
        raise AppleError()
    return {"user_id": user["user_id"], "refresh": refresh}


@contextmanager
def deletion_guard(user_id, fresh=""):
    manager, _, db = runtime()
    # Shared with sign-in/linking; hold through provider revocation, graph cleanup
    # and identity deletion so another callback cannot replace the revoked grant.
    lookups = db.rows("SELECT external_id FROM sso_lookups WHERE provider='apple' AND user_id=:u", {"u":user_id})
    subjects = {row[0] for row in lookups}
    with ExitStack() as locks:
        for subject in sorted(subjects):
            locks.enter_context(identity_lock(db, "subject:" + subject))
        locks.enter_context(identity_lock(db, "user:" + user_id))
        locked_lookups = db.rows("SELECT external_id FROM sso_lookups WHERE provider='apple' AND user_id=:u", {"u":user_id})
        if {row[0] for row in locked_lookups} != subjects:
            raise AppleError("APPLE_CONFLICT", "An Apple request is already in progress. Please try again.")
        revoke_user(user_id, manager=manager, db=db, fresh=fresh)
        now = time.time()
        for subject in subjects:
            key = "subject:" + hashlib.sha256(subject.encode()).hexdigest()
            watermark = read_state(db, key)
            watermark["revoked_at"] = max(now, watermark.get("revoked_at", 0))
            write_state(db, key, watermark)
        if subjects:
            invalidate_sessions(db, user_id, read_state(db,user_id), now)
        yield


def revoke_user(user_id, cfg=None, manager=None, db=None, fresh=None):
    if manager is None:
        manager, _, db = runtime()
    rows = db.rows("SELECT value FROM kv_state WHERE key=:k", {"k": "stack-apple-grant:" + user_id})
    linked = any(x.get("platform") == "apple" for x in manager.get_sso_accounts(user_id))
    # A partial Jac link can have a grant/lookup but no identity document yet.
    if not linked and not rows and not fresh:
        return
    cfg = cfg or configuration(require_enabled=False)
    grant = None
    try:
        if rows:
            grant = json.loads(Fernet(cfg["STACK_CONNECTION_KEY"].encode()).decrypt(rows[0][0].encode()))
        if grant and grant["client_id"] != cfg["STACK_APPLE_CLIENT_ID"]:
            raise AppleError()
    except Exception:
        grant = None
    if not grant and not fresh:
        raise AppleError("APPLE_UNAVAILABLE", "Confirm Apple sign-in again to delete this account.")
    tokens = ([grant["refresh_token"]] if grant else []) + ([fresh] if fresh else [])
    for token in dict.fromkeys(tokens):
        provider("/auth/revoke", {"client_id": cfg["STACK_APPLE_CLIENT_ID"], "client_secret": client_secret(cfg),
            "token": token, "token_type_hint": "refresh_token"})
    # Keep the encrypted grant until account cleanup succeeds, so a failed deletion
    # can retry revocation. Apple revocation is idempotent.


def forget_grant(user_id):
    _, _, db = runtime()
    db.rows("DELETE FROM kv_state WHERE key=:k", {"k": "stack-apple-grant:" + user_id})


def read_state(db, user_id):
    rows = db.rows("SELECT value FROM kv_state WHERE key=:k", {"k":"stack-apple-state:" + user_id})
    return json.loads(rows[0][0]) if rows else {}


def write_state(db, user_id, state):
    db.rows("""INSERT INTO kv_state (key,value,expires_at) VALUES (:k,:v,'infinity')
        ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value,expires_at=EXCLUDED.expires_at""",
        {"k":"stack-apple-state:" + user_id,"v":json.dumps(state)})


def seal_grant(cfg, grant):
    return Fernet(cfg["STACK_CONNECTION_KEY"].encode()).encrypt(json.dumps(grant).encode()).decode()


def sign_session(claims):
    from jaclang.server.identity.config import signing_secret, signing_algorithm
    from jaclang.server.serving.authcrypt import jwt_encode
    return jwt_encode(claims, signing_secret(), algorithm=signing_algorithm())


def apple_session_token(manager, user_id, epoch):
    # Keep Jac's standard claims/TTL; the signed marker cannot be supplied by a
    # client and distinguishes Apple sessions from Google/password sessions.
    claims = manager.get_jwt_claims(manager.create_jwt_token(user_id))
    if not claims or claims.get("sub") != user_id:
        raise AppleError()
    claims["stack_apple"] = epoch
    return sign_session(claims)


def invalidate_sessions(db, user_id, state, revoked_at):
    state.update(epoch=secrets.token_urlsafe(32), revoked=True,
                 revoked_at=max(state.get("revoked_at", 0), revoked_at))
    write_state(db, user_id, state)


def session_status(token: str, owner: str) -> dict[str, Any]:
    """Internal gateway preflight. No provider material is returned to clients."""
    try:
        manager, _, db = runtime()
        detail = manager.validate_jwt_token_detail(token)
        uid = detail.get("user_id")
        if detail.get("status") != "ok" or not uid or manager.get_root_id(uid) != owner:
            raise AppleError("APPLE_REVOKED", "Sign in again.")
        claims = manager.get_jwt_claims(token)
        if not claims:
            raise AppleError("APPLE_REVOKED", "Sign in again.")
        if "stack_apple" not in claims:
            return {"ok":True}  # Existing Google/password sessions are unchanged.
        cfg = configuration(require_enabled=False)
        with identity_lock(db, "user:" + uid):
            state = read_state(db, uid)
            if state.get("revoked") or not isinstance(claims["stack_apple"], str) or not hmac.compare_digest(claims["stack_apple"], state.get("epoch", "")):
                raise AppleError("APPLE_REVOKED", "Apple authorization has expired. Sign in again.")
            rows = db.rows("SELECT value FROM kv_state WHERE key=:k", {"k":"stack-apple-grant:" + uid})
            if not rows:
                raise AppleError("APPLE_UNAVAILABLE", "Apple session could not be checked. Try again.")
            grant = json.loads(Fernet(cfg["STACK_CONNECTION_KEY"].encode()).decrypt(rows[0][0].encode()))
            if grant["client_id"] != cfg["STACK_APPLE_CLIENT_ID"]:
                raise AppleError()
            watermark = read_state(db, "subject:" + hashlib.sha256(grant["subject"].encode()).hexdigest())
            if watermark.get("revoked_at", 0) >= grant.get("authorized_at", 0):
                invalidate_sessions(db, uid, state, watermark["revoked_at"])
                raise AppleError("APPLE_REVOKED", "Apple authorization has expired. Sign in again.")
            if time.time() - grant.get("checked_at", 0) >= 86400:
                try:
                    payload = provider("/auth/token", {"client_id":cfg["STACK_APPLE_CLIENT_ID"],
                        "client_secret":client_secret(cfg),"grant_type":"refresh_token",
                        "refresh_token":grant["refresh_token"]})
                except AppleError as error:
                    if error.code == "APPLE_REVOKED":
                        invalidate_sessions(db, uid, state, time.time())
                    raise
                refreshed = verify(payload.get("id_token"), cfg["STACK_APPLE_CLIENT_ID"])
                if refreshed["sub"] != grant["subject"]:
                    raise AppleError()
                if "refresh_token" in payload:
                    if not isinstance(payload["refresh_token"], str) or not payload["refresh_token"]:
                        raise AppleError()
                    grant["refresh_token"] = payload["refresh_token"]
                grant["checked_at"] = time.time()
                db.rows("UPDATE kv_state SET value=:v WHERE key=:k",
                    {"k":"stack-apple-grant:" + uid,"v":seal_grant(cfg,grant)})
        return {"ok":True}
    except AppleError as error:
        return failure(error)
    except Exception:
        return failure(AppleError("APPLE_UNAVAILABLE", "Apple session could not be checked. Try again."))


def notification(payload: str) -> dict[str, Any]:
    try:
        cfg = configuration(require_enabled=False)
        claims = verify(payload, cfg["STACK_APPLE_CLIENT_ID"], notification=True)
        events = claims.get("events")
        if isinstance(events, str):
            events = json.loads(events, object_pairs_hook=object_pairs)
        if not isinstance(events, dict) or events.get("type") not in {"consent-revoked","account-deleted","email-enabled","email-disabled"}:
            raise AppleError()
        subject, event_time = events.get("sub"), events.get("event_time")
        if not isinstance(claims.get("jti"), str) or not 1 <= len(claims["jti"]) <= 255 or not isinstance(subject, str) or not 1 <= len(subject) <= 255:
            raise AppleError()
        if type(event_time) not in (int, float) or not claims["iat"] - 2592000 <= event_time <= claims["iat"] + 30:
            raise AppleError()
        manager, _, db = runtime()
        with identity_lock(db, "subject:" + subject):
            subject_key = "subject:" + hashlib.sha256(subject.encode()).hexdigest()
            watermark = read_state(db, subject_key)
            if events["type"] in {"consent-revoked","account-deleted"} and event_time > watermark.get("revoked_at", 0):
                watermark["revoked_at"] = event_time
                write_state(db, subject_key, watermark)
            user = manager.get_user_by_sso("apple", subject)
            if not user:
                return {"ok":True}
            with identity_lock(db, "user:" + user["user_id"]):
                apply_notification(cfg, db, user["user_id"], events, event_time)
        # Apple account deletion revokes Apple sessions, not the independent
        # Stack account or its Google/password identities. No automatic merging.
        return {"ok":True}
    except AppleError as error:
        return failure(error)
    except Exception:
        return failure(AppleError("APPLE_UNAVAILABLE", "Apple notification could not be processed."))


def apply_notification(cfg, db, uid, events, event_time):
    state = read_state(db, uid)
    if events["type"] in {"consent-revoked","account-deleted"}:
        if event_time > state.get("revoked_at", 0):
            rows = db.rows("SELECT value FROM kv_state WHERE key=:k", {"k":"stack-apple-grant:" + uid})
            grant = json.loads(Fernet(cfg["STACK_CONNECTION_KEY"].encode()).decrypt(rows[0][0].encode())) if rows else {}
            if event_time >= grant.get("authorized_at", 0):
                invalidate_sessions(db, uid, state, event_time)
            else:
                state["revoked_at"] = event_time
                write_state(db, uid, state)
    elif event_time > state.get("email_event_at", 0):
        state.update(email_event_at=event_time, email_forwarding=events["type"] == "email-enabled")
        write_state(db, uid, state)
