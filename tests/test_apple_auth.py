"""Apple sign-in checks for native/web sessions, account continuity and invalid proofs."""
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from google.auth import crypt, jwt

if os.environ.get("JAC_DB_URL"):
    raise RuntimeError("Apple tests require disposable storage; unset JAC_DB_URL.")
os.environ["JAC_DB_SCRATCH"] = "1"
from jaclang.testing.testing import JacTestClient

ROOT = Path(__file__).resolve().parents[1]


class AppleSignIn(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".jac/apple-signin-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        directory = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(directory.cleanup)
        config = Path(directory.name) / "config.json"
        config.write_text(json.dumps({"invite_only": False}))
        self.directory = Path(directory.name)
        self.env = patch.dict(os.environ, {"STACK_APPLE_ENABLED": "1", "STACK_APPLE_CLIENT_ID": "com.fixture.stack", "STACK_APPLE_WEB_CLIENT_ID": "com.fixture.stack.web", "STACK_APPLE_WEB_REDIRECT_URI": "https://stack.example.com/auth/apple", "STACK_AGENT_CONFIG": str(config)})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.client = JacTestClient.from_file(str(ROOT / "main.jac"), base_path=directory.name)
        self.addCleanup(self.client.close)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        self.signer = crypt.RSASigner.from_string(pem, key_id="fixture-key")
        self.public = key.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        self.bind_keys()

    def bind_keys(self):
        fixture = patch.object(self.client.server.module.apple_auth, "public_keys", return_value={"fixture-key": self.public})
        fixture.start()
        self.addCleanup(fixture.stop)

    def rpc(self, name, args=None):
        response = self.client.post("/function/" + name, json=args or {})
        self.assertTrue(response.ok, response.text)
        return response.data["result"]

    def sign_in(self, changes=None, signer=None, mode="native", code=""):
        challenge = self.rpc("auth_apple_web_begin" if mode == "web" else "auth_apple_begin")
        self.assertTrue(challenge["ok"], challenge)
        claims = dict(iss="https://appleid.apple.com", aud="com.fixture.stack.web" if mode == "web" else "com.fixture.stack", sub="fixture-apple-user",
                      nonce=challenge["nonce"], iat=int(time.time()), exp=int(time.time()) + 300)
        if mode == "native":
            claims.update(email="fixture@example.test", email_verified="true")
        claims.update(changes or {})
        token = jwt.encode(signer or self.signer, claims).decode()
        self.proof = dict(state=challenge["state"], identity_token=token, authorization_code=code)
        return self.rpc("auth_apple_finish", self.proof)

    def test_valid_signin_creates_usable_stack_session(self):
        for mode in ("native", "web"):
            with self.subTest(mode=mode):
                self.client.clear_auth()
                subject = "fixture-" + mode
                result = self.sign_in({
                    "sub": subject, "email": f"{subject}@example.test", "email_verified": "true",
                }, mode=mode)
                self.assertTrue(result["ok"], result)
                manager, _ = self.client.server.module.apple_auth.runtime()
                uid = manager.validate_jwt_token(result["token"])
                self.assertTrue(uid)
                self.assertEqual(manager.get_user_by_sso("apple", subject)["user_id"], uid)
                self.client.set_auth_token(result["token"])
                self.assertEqual(self.rpc("bootstrap")["user_id"], manager.get_root_id(uid))
                # A proof cannot issue a second session after its state is consumed.
                self.assertFalse(self.rpc("auth_apple_finish", self.proof)["ok"])

    def test_verified_email_linking_and_account_deletion(self):
        result = self.sign_in()
        self.assertTrue(result["ok"], result)
        manager, _ = self.client.server.module.apple_auth.runtime()
        uid = manager.validate_jwt_token(result["token"])
        self.assertTrue(uid)
        self.assertEqual(manager.get_user_by_sso("apple", "fixture-apple-user")["user_id"], uid)
        self.client.set_auth_token(result["token"])
        owner = self.rpc("bootstrap")["user_id"]
        self.assertEqual(owner, manager.get_root_id(uid))
        self.assertEqual(manager.find_user_by_identity(" FIXTURE@example.test ")["user_id"], uid)
        from jaclang.scale.sso.provider import SSOUserInfo
        linked = self.client.server.module.accounts.complete_identity(
            manager, SSOUserInfo(email="FIXTURE@example.test", external_id="fixture-google-user"), "google")
        self.assertTrue(linked.ok)
        self.assertEqual(manager.validate_jwt_token(linked.token), uid)
        import hashlib
        directory = ROOT / "storage/resumes" / hashlib.sha256(owner.encode()).hexdigest()
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "orphaned-upload.pdf").write_bytes(b"fictional-upload")
        from jaclang.server.shared_store import shared_store
        from uuid import uuid4
        usage, global_usage = uuid4().hex, uuid4().hex
        for ident, key in [(usage, "cost:fixture:" + owner), (global_usage, "cost:fixture")]:
            shared_store().rows("INSERT INTO anchors (id,kind,arch_type,props) VALUES (:id,'NodeAnchor','AgentUsage',CAST(:p AS jsonb))",
                                {"id": ident, "p": json.dumps({"archetype": {"key": key, "cents": 1, "actions": 0}})})
        deleted = self.rpc("account_delete")
        self.assertTrue(deleted.get("deleted"), deleted)
        self.assertFalse(directory.exists())
        self.assertIsNone(manager.get_user(uid))
        self.assertIsNone(manager.find_user_by_identity("fixture@example.test"))
        self.assertIsNone(manager.get_user_by_sso("apple", "fixture-apple-user"))
        self.assertIsNone(manager.get_user_by_sso("google", "fixture-google-user"))
        self.assertFalse(self.client.post("/function/bootstrap", json={}).ok)
        self.assertEqual(shared_store().rows("SELECT count(*) FROM anchors WHERE replace(CAST(root_id AS text),'-','')=:o OR replace(CAST(id AS text),'-','')=:o OR COALESCE(props->'archetype'->>'owner',props->>'owner')=:o", {"o": owner.replace('-', '')})[0][0], 0)
        self.assertEqual(shared_store().rows("SELECT count(*) FROM anchors WHERE id=:id", {"id": usage})[0][0], 0)
        self.assertEqual(shared_store().rows("SELECT count(*) FROM anchors WHERE id=:id", {"id": global_usage})[0][0], 1)
        self.client.clear_auth()
        fresh = self.sign_in()
        self.assertTrue(fresh["ok"], fresh)
        self.client.set_auth_token(fresh["token"])
        self.assertNotEqual(self.rpc("bootstrap")["user_id"], owner)

    def test_public_grant_exchange_and_retryable_revocation(self):
        module = self.client.server.module.apple_auth
        key_path = self.directory / "fixture.p8"
        key = ec.generate_private_key(ec.SECP256R1())
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
        environment = {
            "STACK_APPLE_REQUIRE_REVOCATION": "1", "STACK_APPLE_KEY_PATH": str(key_path),
            "STACK_APPLE_KEY_ID": "fixture-id", "STACK_APPLE_TEAM_ID": "fixture-team",
            "STACK_CONNECTION_KEY": Fernet.generate_key().decode(),
        }
        client_id = "com.fixture.stack"
        calls = []
        fail_revoke = True

        def request(path, audience, values):
            calls.append((path, audience, values))
            if path == "/auth/token":
                proof = jwt.encode(self.signer, {
                    "iss": "https://appleid.apple.com", "aud": audience,
                    "sub": "another-account" if values["code"] == "unrelated-code" else "fixture-apple-user",
                    "iat": int(time.time()), "exp": int(time.time()) + 300,
                }).decode()
                return json.dumps({"id_token": proof, "refresh_token": "fixture-refresh-token"}).encode()
            if fail_revoke:
                raise OSError("Fixture timeout")
            return b""

        with patch.dict(os.environ, environment), patch.object(module, "_apple_post", side_effect=request):
            self.assertTrue(module._client_secret(client_id))
            self.assertFalse(self.sign_in()["ok"])
            self.assertFalse(self.sign_in(code="unrelated-code")["ok"])
            manager, _ = module.runtime()
            self.assertIsNone(manager.get_user_by_sso("apple", "fixture-apple-user"))
            result = self.sign_in(code="fixture-code")
            self.assertTrue(result["ok"], result)
            self.assertEqual(calls[-1], ("/auth/token", client_id, {"code": "fixture-code", "grant_type": "authorization_code"}))
            uid = manager.validate_jwt_token(result["token"])
            from jaclang.server.shared_store import shared_store
            rows = shared_store().rows("SELECT value FROM kv_state WHERE key = :key",
                                       {"key": f"stack:apple-grant:{uid}:{client_id}"})
            self.assertEqual(len(rows), 1)
            self.assertNotIn("fixture-refresh-token", rows[0][0])
            self.client.set_auth_token(result["token"])
            self.assertIn("retry account deletion", self.rpc("account_delete")["error"])
            self.assertIsNotNone(manager.get_user(uid))
            fail_revoke = False
            self.assertTrue(self.rpc("account_delete")["deleted"])
            self.assertEqual(calls[-1], ("/auth/revoke", client_id, {
                "token": "fixture-refresh-token", "token_type_hint": "refresh_token",
            }))
            self.assertIsNone(manager.get_user(uid))
            self.assertEqual(shared_store().rows("SELECT value FROM kv_state WHERE key = :key",
                                                  {"key": f"stack:apple-grant:{uid}:{client_id}"}), [])

    def test_returning_signin_preserves_account_and_data(self):
        first = self.sign_in()
        self.client.set_auth_token(first["token"])
        original = self.rpc("bootstrap")["user_id"]
        self.rpc("save_profile", dict(name="Preserved profile", role="Engineer", location="United States", mode="Any", notifications=False))
        self.client.clear_auth()
        self.client.reload()
        self.bind_keys()
        returning = self.sign_in(mode="web")
        self.assertTrue(returning["ok"], returning)
        self.client.set_auth_token(returning["token"])
        account = self.rpc("bootstrap")
        self.assertEqual(account["user_id"], original)
        self.assertEqual(account["profile"]["name"], "Preserved profile")
        self.client.clear_auth()
        native = self.sign_in()
        self.client.set_auth_token(native["token"])
        self.assertEqual(self.rpc("bootstrap")["user_id"], original)

    def test_invalid_proof_cannot_create_session(self):
        other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        wrong_signer = crypt.RSASigner.from_string(other.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()), key_id="fixture-key")
        for mode in ("native", "web"):
            wrong_audience = "com.fixture.stack" if mode == "web" else "com.fixture.stack.web"
            for changes, signer in [({}, wrong_signer), ({"exp": int(time.time()) - 60}, None),
                                    ({"aud": wrong_audience}, None), ({"nonce": "wrong-nonce"}, None)]:
                with self.subTest(mode=mode, changes=changes, wrong_signature=signer is not None):
                    result = self.sign_in(changes, signer, mode)
                    self.assertFalse(result["ok"])
                    self.assertNotIn("token", result)
        for redirect in ("http://stack.example.com/auth/apple", "https://127.0.0.1/auth/apple",
                         "https://localhost/auth/apple", "https://stack.example.com/other",
                         "https://stack.example.com/auth/apple#fragment"):
            with self.subTest(redirect=redirect), patch.dict(os.environ, {"STACK_APPLE_WEB_REDIRECT_URI": redirect}):
                self.assertFalse(self.rpc("auth_apple_web_begin")["ok"])
        with patch.dict(os.environ, {"STACK_APPLE_WEB_CLIENT_ID": ""}):
            self.assertFalse(self.rpc("auth_apple_web_begin")["ok"])
            self.assertTrue(self.rpc("auth_apple_begin")["ok"])
        without_email = self.sign_in(mode="web")
        self.assertFalse(without_email["ok"])
        self.assertNotIn("token", without_email)
        manager, _ = self.client.server.module.apple_auth.runtime()
        self.assertIsNone(manager.get_user_by_sso("apple", "fixture-apple-user"))


if __name__ == "__main__":
    unittest.main()
