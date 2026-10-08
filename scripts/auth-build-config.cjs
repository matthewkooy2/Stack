const fs = require('fs'), path = require('path');
const {buildSettings} = require('../native/build-config');
function settings(env = process.env) {
 const release = env.STACK_BUILD_MODE === 'release';
 const mode = env.STACK_AUTH_MODE || (release ? 'google-test' : 'mock');
 const data = env.STACK_DATA_MODE || (release ? 'live' : 'mock');
 if (!['mock', 'google-test'].includes(mode)) throw Error('STACK_AUTH_MODE must be mock or google-test.');
 if (!['mock', 'live'].includes(data)) throw Error('STACK_DATA_MODE must be mock or live.');
 if (release && (mode !== 'google-test' || data !== 'live')) throw Error('Release builds require real authentication and live data.');
 if (mode === 'mock') {
  if (data === 'live') throw Error('STACK_DATA_MODE=live requires STACK_AUTH_MODE=google-test.');
  return {mode, data};
 }
 const origin = env.STACK_AUTH_API_URL || (release ? buildSettings(env).apiBaseUrl : '');
 if (!origin) throw Error('Real authentication requires STACK_AUTH_API_URL.');
 const u = new URL(origin);
 if (u.protocol !== 'https:' || u.username || u.password || u.pathname !== '/' || u.search || u.hash) throw Error('STACK_AUTH_API_URL must be an HTTPS origin.');
 if (release && u.origin !== buildSettings(env).apiBaseUrl) throw Error('Release authentication and feature data must use STACK_API_URL.');
 return {mode, data, origin: u.origin};
}
function write(out, env = process.env) {
 const config = settings(env);
 fs.writeFileSync(path.join(out, 'auth-config.json'), JSON.stringify(config, null, 2) + '\n');
 return config;
}
module.exports = {settings, write};
