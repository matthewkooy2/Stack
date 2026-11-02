"""Verify native Apple identity, resolve its Stack account, issue a normal session."""
import base64
import hashlib
import hmac
import json
import os
import secrets
from typing import Any
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


def audience():
    value = os.environ.get("STACK_APPLE_CLIENT_ID", "").strip()
    if os.environ.get("STACK_APPLE_ENABLED") != "1" or not value:
        raise ValueError("Apple sign-in is not available.")
    return value


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


def begin() -> dict[str, Any]:
    try:
        client_id = audience()
        _, store = runtime()
        nonce = hashlib.sha256(secrets.token_bytes(32)).hexdigest()
        state = store.create_token("", PURPOSE, 300, json.dumps({"nonce": nonce, "audience": client_id}))
        return {"ok": True, "state": state, "nonce": nonce, "expires_in": 300}
    except Exception:
        return {"ok": False, "error": "Stack could not prepare Apple sign-in. Please retry."}


def finish(state: str, identity_token: str) -> dict[str, Any]:
    try:
        client_id = audience()
        manager, store = runtime()
        record = store.peek_token(state, PURPOSE)
        if not record:
            raise ValueError("Apple sign-in expired. Please start again.")
        challenge = json.loads(record["identity_value"])
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
