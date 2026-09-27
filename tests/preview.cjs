// Browser visual QA of the real compiled Jac screens. OS-only integrations are stubbed.
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..'),out=path.join(root,'.jac/ui-preview');
const esbuild=require(path.join(out,'node_modules/esbuild'));
const rn=path.join(out,'node_modules/react-native-web/dist/index.js');
const noop=`import React from 'react';export default ()=>null;export const NavigationContainer=({children})=>children;export const CommonActions={};export const useNavigation=()=>({});export const useRoute=()=>({});export const createNativeStackNavigator=()=>({});`;
const shims={
 'expo-secure-store':`const saved=new Map();export const getItemAsync=async k=>saved.get(k);export const setItemAsync=async(k,v)=>saved.set(k,v);export const deleteItemAsync=async k=>saved.delete(k);`,
 'expo-constants':`export default {expoConfig:{extra:{}}};`,
 'expo-notifications':`export const setNotificationHandler=()=>{};export const getPermissionsAsync=async()=>({granted:false});export const getAllScheduledNotificationsAsync=async()=>[];export const cancelAllScheduledNotificationsAsync=async()=>{};export const dismissAllNotificationsAsync=async()=>{};export const getLastNotificationResponseAsync=async()=>null;export const addNotificationResponseReceivedListener=()=>({remove(){}});`,
 'expo-document-picker':`export const getDocumentAsync=async()=>({canceled:true});`,
 'expo-file-system/legacy':`export const cacheDirectory='';export const deleteAsync=async()=>{};`,
 '@react-native-community/datetimepicker':noop,'react-native-pdf':noop,
 '@react-navigation/native':noop,'@react-navigation/native-stack':noop
};
const glyphs=fs.readFileSync(path.join(root,'native/device.js'),'utf8').match(/import \{([^}]+)\} from 'lucide-react-native'/)[1];
shims['lucide-react-native']=`import React from 'react';const Glyph=({size=22})=>React.createElement('span',{style:{width:size,height:size,display:'inline-block'}});export const ${glyphs.split(',').map(x=>x.trim()+'=Glyph').join(',')};`;
fs.writeFileSync(path.join(out,'entry.jsx'),`import React from 'react';import{createRoot}from'react-dom/client';import{app as App}from'../mobile-rn/jac-src/mobile/main.js';globalThis.__JAC_API_BASE_URL__=location.origin;createRoot(document.getElementById('root')).render(React.createElement(App));`);
fs.writeFileSync(path.join(out,'index.html'),`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Stack phone preview</title><style>html,body{margin:0;background:#e6e9ef;font-family:system-ui}#root{width:390px;height:844px;margin:20px auto;background:#F7F8FC;display:flex;flex-direction:column;overflow:hidden;border:1px solid #ddd}#root>div{flex:1;min-height:0}#note{text-align:center;font-size:12px;color:#536070;margin:8px}button,input{font:inherit}</style><div id="note">Stack phone-sized browser check · OS integrations stubbed</div><div id="root"></div><script src="bundle.js"></script>`);
esbuild.build({entryPoints:[path.join(out,'entry.jsx')],bundle:true,outfile:path.join(out,'bundle.js'),platform:'browser',format:'iife',define:{'process.env.NODE_ENV':'"development"',__DEV__:'true'},loader:{'.png':'dataurl'},nodePaths:[path.join(out,'node_modules'),path.join(root,'.jac/mobile-rn/node_modules')],plugins:[{name:'native-preview',setup(build){build.onResolve({filter:/.*/},args=>{
 if(args.path in shims)return {path:args.path,namespace:'stub'};
 if(args.path==='react-native')return{path:rn};
 if(args.path==='react')return{path:path.join(out,'node_modules/react/index.js')};
 if(args.path==='@jac/runtime')return{path:path.join(root,'.jac/mobile-rn/jac-src/client_runtime.js')};
 if(args.path==='@jac/mobui')return{path:path.join(root,'.jac/mobile-rn/jac-src/client_mobui.js')};
 });build.onLoad({filter:/.*/,namespace:'stub'},args=>({contents:shims[args.path],loader:'js',resolveDir:out}));}}]}).then(()=>console.log('Built actual Jac screens for browser QA.')).catch(()=>process.exit(1));
