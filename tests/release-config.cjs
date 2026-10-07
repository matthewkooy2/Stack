const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {buildSettings, writeSettings} = require('../native/build-config');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'stack-release-'));
const release = {STACK_BUILD_MODE:'release', STACK_API_URL:'https://stack.example-tailnet.ts.net:8443/'};
let checks = 0;
function check(fn) {fn(); checks++;}
try {
  fs.writeFileSync(path.join(directory, 'stack-host.json'), JSON.stringify({apiBaseUrl:'http://old-mac.local:8000'}));
  check(() => assert.throws(() => buildSettings({STACK_BUILD_MODE:'release'}, directory), /explicit STACK_API_URL/));
  check(() => assert.equal(buildSettings({}, directory).apiBaseUrl, 'http://old-mac.local:8000'));
  check(() => {
    writeSettings(directory, release);
    const context = {}; vm.runInNewContext(fs.readFileSync(path.join(directory, '__jacApiBase.js'), 'utf8'), context);
    assert.equal(context.__JAC_API_BASE_URL__, 'https://stack.example-tailnet.ts.net:8443');
    assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'stack-host.json'))).apiBaseUrl, context.__JAC_API_BASE_URL__);
  });
  for (const api of ['http://stack.example.com','https://localhost','https://localhost.','https://old-mac.local','https://old-mac.local.',
    'https://127.0.0.1','https://2130706433','https://0.0.0.0','https://10.0.0.1','https://192.168.1.2','https://172.16.0.1',
    'https://169.254.1.2','https://[::1]','https://[::ffff:127.0.0.1]','https://[fd00::1]','https://user:password@stack.example.com',
    'https://stack.example.com/path','https://stack.example.com?token=foo','https://stack.example.com#foo','ftp://stack.example.com','bad-url']) {
    check(() => assert.throws(() => buildSettings({...release, STACK_API_URL:api}, directory), undefined, api));
  }
  function expoConfig(env) {
    const sandbox = {module:{exports:{}}, process:{env}, __dirname:directory, require: name => {
      if (name === './build-config') return {buildSettings};
      if (name === 'expo/config-plugins') return {
        withEntitlementsPlist:(c,fn) => ({...c, entitlements:fn({modResults:{'aps-environment':'production'}}).modResults}),
        withPodfileProperties:(c,fn) => ({...c, podProperties:fn({modResults:{}}).modResults}),
      };
      throw Error('Unexpected module '+name);
    }};
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../native/app.config.js'), 'utf8'), sandbox);
    const config = sandbox.module.exports();
    const inlinePlugins = config.plugins.filter(plugin => typeof plugin === 'function');
    assert.equal(inlinePlugins.length, 1, 'Expected the notification capabilities plugin');
    return {config, native:inlinePlugins[0](config)};
  }
  check(() => {
    const {config,native} = expoConfig(release);
    assert.equal(config.extra.pushEnabled, false);
    assert.equal(Object.keys(config.ios.infoPlist).length, 0);
    assert.equal('aps-environment' in native.entitlements, false);
    assert.equal(native.podProperties['ios.deploymentTarget'], '16.4');
  });
  check(() => {
    const {config,native} = expoConfig({...release, STACK_PUSH_ENABLED:'1', STACK_PUSH_ENVIRONMENT:'production', STACK_EAS_PROJECT_ID:'fixture'});
    assert.equal(config.extra.pushEnabled, true);
    assert.equal(native.entitlements['aps-environment'], 'production');
  });
  check(() => assert.equal('buildNumber' in expoConfig(release).config.ios, false));
  check(() => assert.equal(expoConfig({...release, STACK_BUILD_NUMBER:'41.2'}).config.ios.buildNumber, '41.2'));
  for (const build of ['0.1.2.3', '41.', '.2', '41-2', 'v41', '41 2', '1234567890']) {
    check(() => assert.throws(() => buildSettings({...release, STACK_BUILD_NUMBER:build}, directory), /STACK_BUILD_NUMBER/, build));
  }
  check(() => assert.throws(() => buildSettings({...release, STACK_PUSH_ENABLED:'1'}), /STACK_EAS_PROJECT_ID/));
  check(() => assert.throws(() => buildSettings({...release, STACK_PUSH_ENABLED:'1', STACK_EAS_PROJECT_ID:'fixture', STACK_PUSH_ENVIRONMENT:'wrong'}), /STACK_PUSH_ENVIRONMENT/));
  check(() => {
    const {config,native} = expoConfig({STACK_API_URL:'http://mac.local:8000'});
    assert.equal(config.ios.infoPlist.NSAppTransportSecurity.NSAllowsLocalNetworking, true);
    assert.equal('aps-environment' in native.entitlements, false);
  });
  console.log(`${checks} release configuration checks passed`);
} finally {fs.rmSync(directory, {recursive:true, force:true});}
