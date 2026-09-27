// Stack v1 is a local Debug build. Release builds must not inherit LAN transport exceptions.
const {withEntitlementsPlist, withPodfileProperties} = require('expo/config-plugins');
const fs = require('fs');
const path = require('path');
function localNotificationsOnly(config) {
  config = withEntitlementsPlist(config, c => {
    delete c.modResults['aps-environment'];
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
  return {
    name:'Stack', slug:'stack', version:'0.1.0', orientation:'portrait', userInterfaceStyle:'light',
    ios:{supportsTablet:false,bundleIdentifier:'com.matthewkooy.stack',infoPlist:development ? {
      NSLocalNetworkUsageDescription:'Connect to your Mac for Stack development.',
      NSAppTransportSecurity:{NSAllowsArbitraryLoads:true,NSAllowsLocalNetworking:true},
    } : {}},
    plugins:[localNotificationsOnly],
    extra:{apiBaseUrl:development ? apiBaseUrl : ''},
  };
};
