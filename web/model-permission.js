// A single expiry covers every action; never revive or extend unrelated grants.
export function updateModelPermission(policy, enabled, now = Date.now() / 1000) {
  const current = policy || {};
  const actions = [...(current.actions || [])];
  const others = actions.filter(action => action !== 'model');
  if (!enabled) return {...current, actions: others};
  if (others.length && (!current.enabled || current.expires_at <= now || current.expires_at > now + 86400)) {
    throw new Error('Other standing permissions share this expiry. Manage them in the iPhone app before enabling Model here; no permissions were changed.');
  }
  return {...current, enabled: true, actions: [...others, 'model'],
    expires_at: others.length ? current.expires_at : now + 86400};
}
