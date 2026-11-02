"""Three sign-in checks: real Stack storage/session, locally signed Apple proofs."""
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
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
        self.env = patch.dict(os.environ, {"STACK_APPLE_ENABLED": "1", "STACK_APPLE_CLIENT_ID": "com.fixture.stack", "STACK_AGENT_CONFIG": str(config)})
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

    def sign_in(self, changes=None, signer=None):
        challenge = self.rpc("auth_apple_begin")
        self.assertTrue(challenge["ok"], challenge)
        claims = dict(iss="https://appleid.apple.com", aud="com.fixture.stack", sub="fixture-apple-user",
                      nonce=challenge["nonce"], iat=int(time.time()), exp=int(time.time()) + 300)
        claims.update(changes or {})
        token = jwt.encode(signer or self.signer, claims).decode()
        return self.rpc("auth_apple_finish", dict(state=challenge["state"], identity_token=token))

    def test_valid_signin_creates_usable_stack_session(self):
        result = self.sign_in()
        self.assertTrue(result["ok"], result)
        manager, _ = self.client.server.module.apple_auth.runtime()
        uid = manager.validate_jwt_token(result["token"])
        self.assertTrue(uid)
        self.assertEqual(manager.get_user_by_sso("apple", "fixture-apple-user")["user_id"], uid)
        self.client.set_auth_token(result["token"])
        self.assertEqual(self.rpc("bootstrap")["user_id"], manager.get_root_id(uid))

    def test_returning_signin_preserves_account_and_data(self):
        first = self.sign_in()
        self.client.set_auth_token(first["token"])
        original = self.rpc("bootstrap")["user_id"]
        self.rpc("save_profile", dict(name="Preserved profile", role="Engineer", location="United States", mode="Any", notifications=False))
        self.client.clear_auth()
        self.client.reload()
        self.bind_keys()
        returning = self.sign_in()
        self.assertTrue(returning["ok"], returning)
        self.client.set_auth_token(returning["token"])
        account = self.rpc("bootstrap")
        self.assertEqual(account["user_id"], original)
        self.assertEqual(account["profile"]["name"], "Preserved profile")

    def test_invalid_proof_cannot_create_session(self):
        other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        wrong_signer = crypt.RSASigner.from_string(other.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()), key_id="fixture-key")
        for changes, signer in [({}, wrong_signer), ({"exp": int(time.time()) - 60}, None), ({"aud": "other.app"}, None)]:
            with self.subTest(changes=changes, wrong_signature=signer is not None):
                result = self.sign_in(changes, signer)
                self.assertFalse(result["ok"])
                self.assertNotIn("token", result)
        manager, _ = self.client.server.module.apple_auth.runtime()
        self.assertIsNone(manager.get_user_by_sso("apple", "fixture-apple-user"))


if __name__ == "__main__":
    unittest.main()
