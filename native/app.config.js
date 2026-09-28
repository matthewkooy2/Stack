// Local reminders remain available; hosted releases require HTTPS and push provisioning.
const {withEntitlementsPlist, withPodfileProperties} = require('expo/config-plugins');
const fs = require('fs');
const path = require('path');
function notificationCapabilities(config) {
  config = withEntitlementsPlist(config, c => {
    if(process.env.STACK_BUILD_MODE==='release') c.modResults['aps-environment']='production';
    else delete c.modResults['aps-environment'];
    return c;
  });
  return withPodfileProperties(config, c => {
    c.modResults['ios.deploymentTarget'] = '16.4';
    return c;
  });
}
module.exports = () => {
  const development = process.env.STACK_BUILD_MODE !== 'release';
  const hostFile = path.join(__dirname, 'stack-host.json');
  const apiBaseUrl = process.env.STACK_API_URL || (fs.existsSync(hostFile) ? JSON.parse(fs.readFileSync(hostFile)).apiBaseUrl : 'http://localhost:8000');
  if(!development && !/^https:\/\//.test(apiBaseUrl)) throw new Error('A release build requires STACK_API_URL=https://your-host.');
  return {
    name:'Stack', slug:'stack', version:'0.1.0', orientation:'portrait', userInterfaceStyle:'light',
    ios:{supportsTablet:false,bundleIdentifier:'com.matthewkooy.stack',infoPlist:development ? {
      NSLocalNetworkUsageDescription:'Connect to your Mac for Stack development.',
      NSAppTransportSecurity:{NSAllowsArbitraryLoads:true,NSAllowsLocalNetworking:true},
    } : {}},
    plugins:[notificationCapabilities],
    extra:{apiBaseUrl,pushEnabled:!development,eas:{projectId:process.env.STACK_EAS_PROJECT_ID||''}},
  };
};
