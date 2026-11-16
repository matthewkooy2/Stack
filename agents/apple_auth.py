"""Verify native or web Apple identity and issue an ordinary Stack session."""
import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, urlsplit
import ipaddress
from urllib.request import Request, urlopen

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from google.auth import crypt, jwt
from jaclang.server.shared_store import shared_store
from agents.accounts import resolve

ISSUER = "https://appleid.apple.com"
PURPOSE = "stack:apple:native:v1"


def runtime():
    from jaclang.server.identity.user_manager import UserManager
    from jaclang.server.identity.auth_tokens import AuthTokenStore
    return UserManager(), AuthTokenStore.instance()


def audience(mode="native"):
    key = "STACK_APPLE_WEB_CLIENT_ID" if mode == "web" else "STACK_APPLE_CLIENT_ID"
    value = os.environ.get(key, "").strip()
    if os.environ.get("STACK_APPLE_ENABLED") != "1" or not value:
        raise ValueError("Apple sign-in is not available.")
    return value


def web_configuration():
    client_id = audience("web")
    if client_id == os.environ.get("STACK_APPLE_CLIENT_ID", "").strip():
        raise ValueError("Use a web Services ID, not the native App ID.")
    redirect = os.environ.get("STACK_APPLE_WEB_REDIRECT_URI", "").strip()
    url = urlsplit(redirect)
    if (url.scheme != "https" or not url.hostname or "." not in url.hostname
            or url.hostname.lower() == "localhost" or url.hostname.lower().endswith(".localhost")
            or url.username or url.password or url.fragment or url.query
            or url.path != "/auth/apple"):
        raise ValueError("Configure the registered HTTPS Apple return URL ending in /auth/apple.")
    try:
        ipaddress.ip_address(url.hostname)
    except ValueError:
        pass
    else:
        raise ValueError("The Apple return URL must use a domain name.")
    # Reading port also rejects malformed values instead of returning unsafe configuration.
    url.port
    return {"client_id": client_id, "redirect_uri": redirect}


def public_keys():
    with urlopen(ISSUER + "/auth/keys", timeout=15) as response:
        keys = json.load(response)["keys"]
    return {
        key["kid"]: rsa.RSAPublicNumbers(
            int.from_bytes(base64.urlsafe_b64decode(key["e"] + "=="), "big"),
            int.from_bytes(base64.urlsafe_b64decode(key["n"] + "=="), "big"),
        ).public_key().public_bytes(
            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
        )
        for key in keys if key["kty"] == "RSA" and key["alg"] == "RS256"
    }


def _client_secret(client_id):
    now = int(time.time())
    key_id = os.environ["STACK_APPLE_KEY_ID"]
    team_id = os.environ["STACK_APPLE_TEAM_ID"]
    key = Path(os.environ["STACK_APPLE_KEY_PATH"]).read_bytes()
    signer = crypt.ES256Signer.from_string(key, key_id=key_id)
    return jwt.encode(signer, {
        "iss": team_id, "sub": client_id, "aud": ISSUER,
        "iat": now, "exp": now + 300,
    }).decode()


def _grant_required():
    return os.environ.get("STACK_APPLE_REQUIRE_REVOCATION") == "1" or bool(os.environ.get("STACK_APPLE_KEY_PATH"))


def _encryption():
    return Fernet(os.environ["STACK_CONNECTION_KEY"].encode())


def _apple_post(path, client_id, values):
    body = urlencode({
        "client_id": client_id,
        "client_secret": _client_secret(client_id),
        **values,
    }).encode()
    request = Request(ISSUER + path, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urlopen(request, timeout=15) as response:
        return response.read(65536)


def _exchange(code, client_id, mode, keys, subject):
    form = {"code": code, "grant_type": "authorization_code"}
    if mode == "web":
        form["redirect_uri"] = web_configuration()["redirect_uri"]
    result = json.loads(_apple_post("/auth/token", client_id, form))
    claims = jwt.decode(result["id_token"], keys, audience=client_id)
    if claims.get("iss") != ISSUER or claims.get("sub") != subject or not result.get("refresh_token"):
        raise ValueError("Apple returned an unrelated authorization.")
    return _encryption().encrypt(result["refresh_token"].encode()).decode()


def _save_grant(user_id, client_id, sealed):
    shared_store().rows(
        "INSERT INTO kv_state (key, value) VALUES (:key, :value) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        {"key": f"stack:apple-grant:{user_id}:{client_id}", "value": sealed},
    )


def revoke_account(user_id):
    prefix = f"stack:apple-grant:{user_id}:"
    for key, value in shared_store().rows(
        "SELECT key, value FROM kv_state WHERE starts_with(key, :prefix)", {"prefix": prefix}
    ):
        token = _encryption().decrypt(value.encode()).decode()
        _apple_post("/auth/revoke", key.removeprefix(prefix), {"token": token, "token_type_hint": "refresh_token"})
        shared_store().kv_delete(key)


def begin(mode="native") -> dict[str, Any]:
    try:
        configuration = web_configuration() if mode == "web" else {}
        client_id = audience(mode)
        if _grant_required():
            _client_secret(client_id)
            _encryption()
        _, store = runtime()
        nonce = hashlib.sha256(secrets.token_bytes(32)).hexdigest()
        state = store.create_token("", PURPOSE, 300, json.dumps({"nonce": nonce, "audience": client_id, "mode": mode}))
        return {"ok": True, "state": state, "nonce": nonce, "expires_in": 300, **configuration}
    except Exception:
        return {"ok": False, "error": ("Apple web sign-in is not configured. Set the Apple Services ID and registered HTTPS return URL on the Stack server." if mode == "web" else "Stack could not prepare Apple sign-in. Please retry.")}


def finish(state: str, identity_token: str, authorization_code: str, account_lock) -> dict[str, Any]:
    try:
        manager, store = runtime()
        record = store.peek_token(state, PURPOSE)
        if not record:
            raise ValueError("Apple sign-in expired. Please start again.")
        challenge = json.loads(record["identity_value"])
        mode = challenge.get("mode", "native")
        if mode not in ("native", "web"):
            raise ValueError("Invalid Apple sign-in request.")
        client_id = audience(mode)
        keys = public_keys()
        claims = jwt.decode(identity_token, keys, audience=client_id)
        if (claims.get("iss") != ISSUER or not claims.get("sub")
                or challenge["audience"] != client_id
                or not hmac.compare_digest(claims.get("nonce", ""), challenge["nonce"])):
            raise ValueError("Apple identity did not match this sign-in request.")
        if not store.consume_token(state, PURPOSE):
            raise ValueError("Apple sign-in expired. Please start again.")
        if _grant_required() and not authorization_code:
            raise ValueError("Update Stack to complete Apple sign-in.")
        sealed = _exchange(authorization_code, client_id, mode, keys, claims["sub"]) if _grant_required() else ""
        email = claims.get("email", "") if claims.get("email_verified") in (True, "true") else ""
        user = resolve(manager, "apple", claims["sub"], email)
        uid = user["user_id"]
        with account_lock(user["root_id"]):
            if not manager.get_user(uid):
                raise ValueError("That Stack account no longer exists.")
            if sealed:
                _save_grant(uid, client_id, sealed)
            return {"ok": True, "token": manager.create_jwt_token(uid), "username": manager.get_username(uid) or ""}
    except Exception:
        return {"ok": False, "error": "Apple sign-in could not finish. Please try again."}
