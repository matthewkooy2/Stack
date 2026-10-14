// Signed-in product API boundary. The device facade installs the transport once at startup; controllers
// never import the session. In mock builds `live` stays false and every controller keeps its sample data.
let transport=null,extras={};
export const backend={live:false,online:true};
const listeners=new Set();
export const onBackendChange=fn=>{listeners.add(fn);return()=>listeners.delete(fn);};
const notify=()=>listeners.forEach(fn=>fn());
export function configureBackend(next){transport=next?.call||null;extras={upload:next?.upload,previewDocument:next?.previewDocument};backend.live=!!next?.live&&!!transport;notify();}
// Large bodies report progress when the device can; documents come back as data URIs the PDF viewer opens directly.
export const upload=(name,args,onProgress)=>extras.upload?extras.upload(name,args,onProgress):call(name,args,{timeout:60000});
export const pdfDataUri=content=>'data:application/pdf;base64,'+content;
export function bytesToBase64(bytes){
 const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';let out='';
 for(let i=0;i<bytes.length;i+=3){const n=(bytes[i]<<16)|((bytes[i+1]||0)<<8)|(bytes[i+2]||0);out+=alphabet[n>>>18]+alphabet[(n>>>12)&63]+(i+1<bytes.length?alphabet[(n>>>6)&63]:'=')+(i+2<bytes.length?alphabet[n&63]:'=');}
 return out;
}
// A request that never reached Stack (no network, timeout) is distinct from one Stack refused.
export function describeError(e){
 const text=String(e?.message||e||'');
 if(e?.offline||/network request failed|failed to fetch|did not respond|cannot reach|load failed|aborted/i.test(text))return 'Cannot reach Stack. Check your connection and try again.';
 return text||'Something went wrong. Please try again.';
}
export const isSessionError=e=>e?.status===401||e?.status===403;
export async function call(name,args={},options){
 if(!transport)throw Object.assign(Error('Stack is not connected in this build.'),{offline:true});
 try{
  const result=await transport(name,args,options);
  if(!backend.online){backend.online=true;notify();}
  return result;
 }catch(e){
  const offline=!e?.status&&/network request failed|failed to fetch|did not respond|cannot reach|load failed|aborted/i.test(String(e?.message||''));
  if(offline){if(backend.online){backend.online=false;notify();}throw Object.assign(new Error(describeError(e)),{offline:true});}
  throw e;
 }
}
// Runs one user-triggered backend action and reports progress the way every screen shows it.
export async function perform(action,{busy=()=>{},fail=()=>{}}={}){
 busy(true);
 try{return await action();}
 catch(e){fail(describeError(e),e);return undefined;}
 finally{busy(false);}
}
