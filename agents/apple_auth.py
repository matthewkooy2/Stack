"""Verify native or web Apple identity and issue an ordinary Stack session."""
import base64
import hashlib
import hmac
import json
import os
import secrets
from typing import Any
from urllib.parse import urlsplit
import ipaddress
from urllib.request import urlopen

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from google.auth import jwt

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


def begin(mode="native") -> dict[str, Any]:
    try:
        configuration = web_configuration() if mode == "web" else {}
        client_id = audience(mode)
        _, store = runtime()
        nonce = hashlib.sha256(secrets.token_bytes(32)).hexdigest()
        state = store.create_token("", PURPOSE, 300, json.dumps({"nonce": nonce, "audience": client_id, "mode": mode}))
        return {"ok": True, "state": state, "nonce": nonce, "expires_in": 300, **configuration}
    except Exception:
        return {"ok": False, "error": ("Apple web sign-in is not configured. Set the Apple Services ID and registered HTTPS return URL on the Stack server." if mode == "web" else "Stack could not prepare Apple sign-in. Please retry.")}


def finish(state: str, identity_token: str) -> dict[str, Any]:
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
        claims = jwt.decode(identity_token, public_keys(), audience=client_id)
        if (claims.get("iss") != ISSUER or not claims.get("sub")
                or challenge["audience"] != client_id
                or not hmac.compare_digest(claims.get("nonce", ""), challenge["nonce"])):
            raise ValueError("Apple identity did not match this sign-in request.")
        if not store.consume_token(state, PURPOSE):
            raise ValueError("Apple sign-in expired. Please start again.")
        user = manager.get_user_by_sso("apple", claims["sub"])
        if not user:
            user = manager.create_user("apple_" + secrets.token_hex(16), secrets.token_urlsafe(48))
            if user.get("error"):
                raise ValueError("Stack could not create your account.")
            linked = manager.link_sso_account(user["user_id"], "apple", claims["sub"])
            if linked.get("error"):
                raise ValueError("Stack could not save your Apple identity.")
        return {"ok": True, "token": manager.create_jwt_token(user["user_id"]),
                "username": manager.get_username(user["user_id"]) or ""}
    except Exception:
        return {"ok": False, "error": "Apple sign-in could not finish. Please try again."}
