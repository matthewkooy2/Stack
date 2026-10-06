const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
(async () => {
  const source = fs.readFileSync(path.join(__dirname, '../web/model-permission.js'), 'utf8');
  const {updateModelPermission} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
  const now = 1000;
  const fresh = {enabled: false, actions: [], domains: [], daily_limits: {}, expires_at: 0, followup_limit: 0};
  const enabled = updateModelPermission(fresh, true, now);
  assert.deepEqual(enabled.actions, ['model']);
  assert.equal(enabled.enabled, true);
  assert.equal(enabled.expires_at, now + 86400);
  assert.deepEqual(fresh.actions, []);
  const mixed = {enabled: true, actions: ['gmail_read'], domains: ['example.com'], daily_limits: {gmail_read: 2}, expires_at: now + 100, followup_limit: 2, analyze_top_matches: true};
  assert.deepEqual(updateModelPermission(mixed, true, now), {...mixed, actions: ['gmail_read', 'model']});
  assert.deepEqual(updateModelPermission({...mixed, actions: ['gmail_read', 'model']}, false, now), mixed);
  for (const policy of [{...mixed, enabled: false}, {...mixed, expires_at: now - 1}, {...mixed, expires_at: now + 86401}]) {
    const before = JSON.stringify(policy);
    assert.throws(() => updateModelPermission(policy, true, now), /no permissions were changed/);
    assert.equal(JSON.stringify(policy), before);
  }
  assert.deepEqual(updateModelPermission({...enabled, actions: ['model']}, false, now).actions, []);
  console.log('Browser Model permission preserves unrelated grants and refuses unsafe activation.');
})().catch(error => {console.error(error); process.exitCode = 1;});
