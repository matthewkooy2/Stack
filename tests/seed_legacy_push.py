"""Persist the old node schema in another process before current-candidate reads."""
import json
import os
import re
from pathlib import Path
import sys
from unittest.mock import patch

from jaclang.testing.testing import JacTestClient
from jaclang.runtime.runtime import JacRuntime
import jaclang.server.session as session

assert not os.environ.get('JAC_DB_URL')
database = os.environ['STACK_TEST_PUSH_DATABASE']
parent_pid = os.environ['STACK_TEST_PUSH_PARENT_PID']
assert re.fullmatch(r'jac_scratch_' + parent_pid + r'_[0-9a-f]+', database)

# Jac 0.37.21's URL parser cannot represent embedded Unix sockets. Select the
# parent's generated scratch database at the runtime-construction boundary;
# all schema, SQL persistence, identity and endpoint operations remain real.
# Do not replace scratch_lease's global state: its atexit cleanup must still
# target the child's own scratch database, never the parent's database.
runtime = session.PgRuntime(data_dir=session.shared_pg_data_dir(), database=database,
    owner_path=sys.argv[1], kind=session.DbKind.SCRATCH, owner_pid=int(parent_pid), retention_days=0)
lease = session.RuntimeLease(runtime=runtime, reset=False)

root = Path(__file__).resolve().parent
with patch.object(session, 'runtime_for_base', return_value=lease):
    client = JacTestClient.from_file(str(root / 'main.jac'), base_path=sys.argv[1])
    try:
        response = client.register_user('push-legacy', 'Synthetic-password-123')
        assert response.ok, response.text
        connection = JacRuntime.get_context().mem.store.conninfo
        assert connection.database == database and connection.host in ('', 'localhost', '127.0.0.1')
        auth = response.data['token']
        client.set_auth_token(auth)
        response = client.post('/function/seed_legacy_notifications', json={})
        assert response.ok, response.text
        Path(sys.argv[2]).write_text(json.dumps({'auth': auth, 'records': response.data['result']}))
    finally:
        client.close()
