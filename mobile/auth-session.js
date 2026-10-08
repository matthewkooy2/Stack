// The existing Jac OAuthSession protocol, isolated from mock product services.
import {beginGoogle,waitGoogle,cancelGoogle,pendingGoogle} from './auth-google.js';
export function normalizeOrigin(value){const u=new URL(value);if(u.protocol!=='https:'||u.username||u.password||u.pathname!=='/'||u.search||u.hash)throw Error('Google testing requires an HTTPS API origin.');return u.origin;}
import {FEATURE_RPCS} from './feature-rpcs.js';
// `features` opts a build into the signed-in product API (see call below). Authentication-only builds keep it off.
export function createAuthSession({origin,store,openURL,fetcher=fetch,isActive=()=>true,delay,features=false,progress=true}){
 const base=normalizeOrigin(origin),prefix='stack.ui-auth.v1.'+Array.from(base).map(c=>c.charCodeAt(0).toString(16).padStart(2,'0')).join('')+'.';
 const scoped={getItemAsync:k=>store.getItemAsync(prefix+k),setItemAsync:(k,v)=>store.setItemAsync(prefix+k,v),deleteItemAsync:k=>store.deleteItemAsync(prefix+k)};
 let token='',epoch=0,queue=Promise.resolve(),pending=false;
 const serial=fn=>{const next=queue.catch(()=>{}).then(fn);queue=next;return next;};
 const current=e=>{if(e!==epoch)throw Error('Sign-in was cancelled or the session changed.');};
 async function request(path,body,authenticated=true,timeout=20000){
  const observed=epoch,controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeout);
  try{const response=await fetcher(base+path,{method:'POST',redirect:'error',headers:{'Content-Type':'application/json',...(authenticated&&token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:controller.signal});
   let json;try{json=await response.json();}catch{current(observed);throw Object.assign(Error(response.status===404?'This sign-in option is unavailable on this server. Use your Stack username and password.':'Stack returned an invalid response. Please retry.'),{status:response.status});}current(observed);
   if(!response.ok||json.ok===false){const error=Error(typeof json.error?.message==='string'?json.error.message:'Sign-in request failed. Please retry.');error.status=response.status;throw error;}
   return json.data;
  }catch(e){if(e.name==='AbortError')throw Error('Stack did not respond. Check your connection and retry.');throw e;}finally{clearTimeout(timer);}
 }
 const allowed=new Set(['auth_google_status','auth_google_recover','agent_admission','agent_accept_invite']);
 async function rpc(name,args={}){if(!allowed.has(name))throw Error('This build only connects account authentication.');let result;try{result=(await request('/function/'+name,args))?.result;}catch(error){if(name==='auth_google_status'&&error.status===404)return {};throw error;}if(result?.error)throw Error(result.error);return result;}
 // The signed-in product API, for builds created with `features`. Only the personal functions the gateway
 // publishes are callable; uploads pass a longer timeout. Errors keep their HTTP status (401 = session expired).
 async function call(name,args={},{timeout=25000}={}){
  if(!features)throw Error('This build does not connect Stack feature data.');
  if(!FEATURE_RPCS.has(name))throw Error('Unknown Stack request: '+name);
  if(!token)throw Object.assign(Error('Sign in to continue.'),{status:401});
  const result=(await request('/function/'+name,args,true,timeout))?.result;
  if(result?.error)throw Error(result.error);
  return result;
 }
 // Same as call, for a large body: reports bytes handed to the network. Falls back to call without XMLHttpRequest.
 async function upload(name,args,onProgress=()=>{},{timeout=60000}={}){
  if(!features)throw Error('This build does not connect Stack feature data.');
  if(!FEATURE_RPCS.has(name))throw Error('Unknown Stack request: '+name);
  if(!token)throw Object.assign(Error('Sign in to continue.'),{status:401});
  if(!progress||typeof XMLHttpRequest==='undefined')return call(name,args,{timeout});
  const observed=epoch,body=JSON.stringify(args);
  onProgress({status:'uploading',loaded:0,total:body.length,percent:null});
  const json=await new Promise((resolve,reject)=>{
   const xhr=new XMLHttpRequest();xhr.open('POST',base+'/function/'+name);xhr.timeout=timeout;
   xhr.setRequestHeader('Content-Type','application/json');xhr.setRequestHeader('Authorization','Bearer '+token);
   xhr.upload.onprogress=e=>{if(observed===epoch)onProgress({status:'uploading',loaded:e.loaded,total:e.total,percent:e.lengthComputable?Math.min(100,Math.round(e.loaded/e.total*100)):null});};
   xhr.onload=()=>{try{
    if(observed!==epoch)throw Error('Session changed. Please try again.');
    const value=JSON.parse(xhr.responseText);
    if(xhr.status<200||xhr.status>=300||value.ok===false||value.data?.result?.error){const error=Error(value.data?.result?.error||value.error?.message||'Upload failed. Retry the same file.');error.status=xhr.status;throw error;}
    resolve(value);
   }catch(error){reject(error);}};
   xhr.onerror=xhr.ontimeout=xhr.onabort=()=>reject(Error('Upload interrupted. Check your connection, then retry the same file.'));
   xhr.send(body);
  });
  const result=json.data?.result;
  if(!result)throw Error('Upload did not return its saved status. Reopen Stack to check.');
  return result;
 }
 async function adopt(value,observed){if(typeof value!=='string'||!value)throw Error('Sign-in did not return a session.');return serial(async()=>{current(observed);const prior=token;await scoped.setItemAsync('session',value);if(observed!==epoch){if(prior)await scoped.setItemAsync('session',prior);else await scoped.deleteItemAsync('session');current(observed);}token=value;});}
 async function finish(handoff,observed){const result=await waitGoogle(request,scoped,handoff,isActive,delay);current(observed);await adopt(result.token,observed);return true;}
 async function cancel(){epoch++;await cancelGoogle(scoped);await queue.catch(()=>{});}
 return {
  origin:base,rpc,call,upload,features,token:()=>token,
  async restoreSession(){const observed=epoch,saved=await scoped.getItemAsync('session')||'';current(observed);token=saved;const handoff=await pendingGoogle(scoped);current(observed);if(handoff){pending=true;try{await finish(handoff,observed);}finally{pending=false;}}return !!token;},
  async authenticate(username,password,signup){if(pending)throw Error('Finish or cancel Google sign-in first.');const observed=++epoch,identity={type:'username',value:username.trim().toLowerCase()},credential={type:'password',password};const result=await request(signup?'/user/register':'/user/login',signup?{identities:[identity],credential}:{identity,credential},false);await adopt(result?.token,observed);return true;},
  async authenticateProvider(provider,link=false){if(provider!=='google')throw Error('Apple sign-in is not connected in this test build. Use Google or Stack.');if(pending)throw Error('A Google sign-in is already pending.');const observed=++epoch;pending=true;try{const handoff=await beginGoogle(request,scoped,openURL,'',link);current(observed);return await finish(handoff,observed);}finally{pending=false;}},
  cancel,
  async recover(username,password){const observed=++epoch,result=await rpc('auth_google_recover',{username,password});await adopt(result?.token,observed);return true;},
  async signOut(){await cancel();await serial(async()=>{token='';await scoped.deleteItemAsync('session');});}
 };
}
