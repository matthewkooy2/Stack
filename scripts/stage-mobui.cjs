// Stage source-owned platform helpers alongside compiled Jac modules.
const fs=require('fs'),path=require('path');const root=path.resolve(__dirname,'..');
const out=path.join(root,'.jac/mobile-rn/jac-src/mobile');
const authConfig=require('./auth-build-config.cjs');authConfig.settings();
fs.mkdirSync(path.join(out,'prototype'),{recursive:true});
for(const name of fs.readdirSync(path.join(root,'mobile/prototype'))){
 if(!/\.(js|json)$/.test(name))continue;
 if(fs.existsSync(path.join(root,'mobile/prototype',name.replace(/\.js$/,'.jac')))&&name.endsWith('.js'))throw Error('Controller would overwrite Jac output: '+name);
 fs.copyFileSync(path.join(root,'mobile/prototype',name),path.join(out,'prototype',name));
}
// Preserve the Mac's native helpers (OAuth, speech and assets) when applying the UI overlay.
for(const name of fs.readdirSync(path.join(root,'native'))){if(/\.(js|png)$/.test(name)&&!['app.config.js','build-config.js'].includes(name))fs.copyFileSync(path.join(root,'native',name),path.join(out,name==='device.js'?'native-device.js':name));}
for(const name of ['mock-device.js','auth-google.js','auth-session.js','feature-rpcs.js','live-device.js','auth-platform.js','auth-platform.web.js','prep-session.js','prep-catalog.json','prep-motion.js'])fs.copyFileSync(path.join(root,'mobile',name),path.join(out,name));
fs.copyFileSync(path.join(root,'mobile/device-facade.js'),path.join(out,'device.js'));
const auth=authConfig.write(out);
fs.mkdirSync(path.join(root,'.jac/mobile-rn/app'),{recursive:true});
fs.copyFileSync(path.join(root,'native/mobui-App.tsx'),path.join(root,'.jac/mobile-rn/app/App.tsx'));
console.log('Staged shared UI; authentication mode:',auth.mode,'data mode:',auth.data);
