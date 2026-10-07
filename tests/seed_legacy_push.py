"""Persist the old node schema in another process before current-candidate reads."""
import json
from pathlib import Path
import sys

from jaclang.testing.testing import JacTestClient

root = Path(__file__).resolve().parent
client = JacTestClient.from_file(str(root / 'fixtures/push_legacy/main.jac'), base_path=sys.argv[1])
try:
    response = client.register_user('push-legacy', 'Synthetic-password-123')
    assert response.ok, response.text
    auth = response.data['token']
    client.set_auth_token(auth)
    response = client.post('/function/seed_legacy_notifications', json={})
    assert response.ok, response.text
    Path(sys.argv[2]).write_text(json.dumps({'auth': auth, 'records': response.data['result']}))
finally:
    client.close()
