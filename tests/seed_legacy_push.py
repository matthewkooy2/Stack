"""Persist the old node schema in another process before current-candidate reads."""
import json
import os
import re
from pathlib import Path
import sys

from jaclang.testing.testing import JacTestClient
from jaclang.runtime.runtime import JacRuntime

connection = JacRuntime.get_context().mem.store.conninfo
assert re.fullmatch(r'jac_scratch_' + os.environ['STACK_TEST_PUSH_PARENT_PID'] + r'_[0-9a-f]+', connection.database)
assert connection.host in ('', 'localhost', '127.0.0.1')

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
