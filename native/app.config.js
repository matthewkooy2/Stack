// Local reminders work without APNs. Remote push is explicitly provisioned later.
const {withEntitlementsPlist, withPodfileProperties} = require('expo/config-plugins');
const {buildSettings} = require('./build-config');
function notificationCapabilities(config, pushEnabled, pushEnvironment) {
  config = withEntitlementsPlist(config, c => {
    if(pushEnabled) c.modResults['aps-environment']=pushEnvironment;
    else delete c.modResults['aps-environment'];
    return c;
  });
  return withPodfileProperties(config, c => {
    c.modResults['ios.deploymentTarget'] = '16.4';
    return c;
  });
}
module.exports = () => {
  const {release, apiBaseUrl, pushEnabled, pushEnvironment, buildNumber} = buildSettings(process.env, __dirname);
  const development = !release;
  return {
    name:'Stack', slug:'stack', version:'0.1.0', orientation:'portrait', userInterfaceStyle:'light',
    // Prebuild writes this literally into CFBundleVersion; Xcode build settings cannot override it.
    ios:{supportsTablet:false,bundleIdentifier:'com.matthewkooy.stack',...(buildNumber ? {buildNumber} : {}),infoPlist:development ? {
      NSLocalNetworkUsageDescription:'Connect to your Mac for Stack development.',
      NSAppTransportSecurity:{NSAllowsArbitraryLoads:true,NSAllowsLocalNetworking:true},
    } : {}},
    plugins:[
      ['expo-audio',{microphonePermission:'Allow Stack to record your practice answers.',enableBackgroundRecording:false,enableBackgroundPlayback:false}],
      config => notificationCapabilities(config, pushEnabled, pushEnvironment),
      // SDK 57 keeps the legacy lifecycle unless scene support is enabled for iOS 27.
      ['expo-build-properties',{ios:{enableSceneSupport:true}}],
    ],
    extra:{apiBaseUrl,pushEnabled,eas:{projectId:process.env.STACK_EAS_PROJECT_ID||''}},
  };
};
