"""Stack's email identity policy and account-owned storage cleanup."""
import hashlib
import json
from pathlib import Path
import secrets
import shutil
import threading

from jaclang.server.shared_store import shared_store
from jaclang.scale.sso import oauth_session
from jaclang.scale.sso.google import GoogleSSOProvider
from jaclang.scale.sso.provider import SSOUserInfo
from jaclang.server.serving.client import arequest

_identity_lock = threading.RLock()
_original_complete = oauth_session.complete_identity
_installed = False


def resolve(manager, platform, subject, email="", link_user=""):
    email = email.strip().lower()
    with _identity_lock:
        existing = manager.get_user_by_sso(platform, subject)
        by_email = manager.find_user_by_identity(email) if email else None
        user = existing or by_email
        if link_user:
            if user and user["user_id"] != link_user:
                raise ValueError("That sign-in already belongs to another Stack account.")
            user = manager.get_user(link_user)
        if existing and by_email and existing["user_id"] != by_email["user_id"]:
            raise ValueError("This email is already connected to another Stack account.")
        if not user:
            if not email:
                raise ValueError("Share your email to create your Stack account.")
            created = manager.create_user_with_identities([
                {"type": "username", "value": platform + "_" + secrets.token_hex(16)},
                {"type": "email", "value": email, "verified": True},
            ], {"type": "password", "password": secrets.token_urlsafe(48)})
            if created.get("error"):
                user = manager.find_user_by_identity(email)
                if not user:
                    raise ValueError("Stack could not create your account.")
            else:
                user = manager.get_user(created["user_id"])
                # The runtime's lookup key is unique; use its winner even if another
                # registration claimed that email while the identity was created.
                winner = manager.find_user_by_identity(email)
                if winner["user_id"] != user["user_id"]:
                    purge_records(manager, user["user_id"], user["root_id"])
                    manager.delete_user(user["user_id"])
                    user = winner
        if user.get("status", "active") != "active" or user.get("role") == "system":
            raise ValueError("This account cannot sign in.")
        uid = user["user_id"]
        if email and not by_email and not any(i.get("value_normalized") == email for i in user.get("identities", [])):
            manager.add_identity(uid, {"type": "email", "value_raw": email,
                                      "value_normalized": email, "verified": True, "is_recovery": True})
        linked = manager.link_sso_account(uid, platform, subject) if not existing else {}
        if linked.get("error"):
            raise ValueError("Stack could not connect your sign-in.")
        return manager.get_user(uid)


async def google_user(self, access_token, token_payload):
    response = await arequest("GET", "https://www.googleapis.com/oauth2/v3/userinfo",
                              headers={"Authorization": "Bearer " + access_token})
    if not response.ok():
        raise ValueError("Google could not confirm your account.")
    info = response.json()
    if info.get("email_verified") is not True or not info.get("email") or not info.get("sub"):
        raise ValueError("Google must verify your email before signing in.")
    return SSOUserInfo(email=info["email"], external_id=info["sub"], display_name=info.get("name"),
                       first_name=info.get("given_name"), last_name=info.get("family_name"), picture=info.get("picture"))


def complete_identity(manager, info, platform, link_user=""):
    if platform != "google":
        return _original_complete(manager, info, platform, link_user)
    try:
        user = resolve(manager, platform, info.external_id, info.email, link_user)
        profile = user.get("profile") or {}
        profile.setdefault("sso", {})[platform] = {**info.profile_fields(), "email": info.email.strip().lower()}
        manager.update_user_fields(user["user_id"], {"profile": profile})
        return oauth_session.OAuthLogin(ok=True, token=manager.create_jwt_token(user["user_id"]),
                                        username=manager.get_username(user["user_id"]) or info.email)
    except ValueError as error:
        return oauth_session.OAuthLogin(error=str(error))


def install():
    global _installed
    if _installed:
        return
    # Jac 0.37.21 has no application identity-resolution hook. Keep its OAuth/PKCE
    # transport and replace only Google's final account lookup and verified email read.
    oauth_session.complete_identity = complete_identity
    GoogleSSOProvider.fetch_user = google_user
    _installed = True


def user_for_root(owner):
    rows = shared_store().rows("SELECT user_id FROM identity_users WHERE doc->>'root_id' = :owner", {"owner": owner})
    return rows[0][0] if rows else None


def purge_files(owner):
    directory = Path("storage/resumes") / hashlib.sha256(owner.encode()).hexdigest()
    if directory.exists():
        shutil.rmtree(directory)


def purge_records(manager, user_id, owner):
    db = shared_store()
    for key, value in db.rows("SELECT key, value FROM kv_state WHERE key LIKE 'oauth-result:%'", {}):
        claims = manager.get_jwt_claims(json.loads(value).get("token", "")) or {}
        if claims.get("sub") == user_id:
            db.kv_delete(key)
    db.rows("DELETE FROM kv_state WHERE key LIKE 'authtok:%' AND value::jsonb->>'user_id' IN (:uid, :owner)",
            {"uid": user_id, "owner": owner})
    db.rows("DELETE FROM jac_docs WHERE doc->>'user_id' IN (:uid, :owner)", {"uid": user_id, "owner": owner})
    db.rows("""WITH doomed AS (
        SELECT id FROM anchors WHERE replace(CAST(root_id AS text), '-', '') = replace(:owner, '-', '')
        OR replace(CAST(id AS text), '-', '') = replace(:owner, '-', '') OR props->>'owner' = :owner
        OR (arch_type = 'AgentUsage' AND right(props->>'key', length(:owner) + 1) = ':' || :owner)
    ) DELETE FROM anchors WHERE id IN (SELECT id FROM doomed)
        OR src IN (SELECT id FROM doomed) OR dst IN (SELECT id FROM doomed)""", {"owner": owner})


def delete_identity(manager, user_id, owner):
    db = shared_store()
    db.begin()
    try:
        purge_records(manager, user_id, owner)
        result = manager.delete_user(user_id)
        if result.get("error"):
            raise ValueError(result["error"])
        db.commit()
    except Exception:
        db.rollback()
        raise
