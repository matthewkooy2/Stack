// The signed-in account's server state. Most account RPCs answer with a fresh `bootstrap` snapshot, so every
// controller reads from this one store and applies whatever those calls return. It starts empty, never seeded.
import {useEffect,useSyncExternalStore} from 'react';
import {backend,call,describeError,isSessionError,onBackendChange} from './backend';
import {events} from './services';
import {valuesOfSections} from './resume-map';
const blank=()=>({status:'idle',error:'',expired:false,boot:null,loadedAt:0,refreshing:false,reviews:{}});
let state=blank(),inflight=null,epoch=0;
const listeners=new Set();
const set=patch=>{state={...state,...patch};listeners.forEach(fn=>fn());};
export const liveState=()=>state;
export const subscribeLive=fn=>{listeners.add(fn);return()=>listeners.delete(fn);};
export const isBootstrap=value=>!!value&&typeof value==='object'&&!!value.profile&&Array.isArray(value.applications);
// Adopts a snapshot returned by any account call. Returns it so callers can chain.
export function applyBootstrap(boot){
 if(!isBootstrap(boot))return boot;
 set({boot,status:'ready',error:'',expired:false,loadedAt:Date.now(),refreshing:false});
 syncReviews(boot);
 schedulePoll(boot);
 events.emit('stack-data-changed');
 return boot;
}
// Work the server does in the background (resume parsing, LaTeX builds, agent tasks) is followed until it settles.
let pollTimer=null;
const working=boot=>(boot.resumes||[]).some(r=>Object.values(r.processing||{}).some(p=>p&&['queued','running'].includes(p.status)))||(boot.agents?.runs||[]).some(r=>['queued','running','waiting'].includes(r.status));
function schedulePoll(boot){
 clearTimeout(pollTimer);pollTimer=null;
 if(backend.live&&working(boot))pollTimer=setTimeout(()=>refreshLive({quiet:true}),2500);
}
// Saved resume details are fetched regardless of processing status, then cached per resume state.
const reviewKey=r=>[r.details_status,r.processing?.pdf?.status,r.processing?.pdf?.id].join('|');
const fetching=new Map();
export const reviewOf=id=>state.reviews[id];
export function setReview(id,review,key){set({reviews:{...state.reviews,[id]:{...review,key:key||state.reviews[id]?.key||''}}});events.emit('stack-data-changed');}
async function syncReviews(boot){
 const observed=epoch,known=new Set((boot.resumes||[]).map(r=>r.id));
 const stale=Object.keys(state.reviews).filter(id=>!known.has(id));
 if(stale.length){const next={...state.reviews};for(const id of stale)delete next[id];set({reviews:next});}
 for(const r of boot.resumes||[]){
  const key=reviewKey(r);
  if(state.reviews[r.id]?.key===key||fetching.get(r.id)===key)continue;
  fetching.set(r.id,key);
  try{
   const review=await call('agent_extract_resume',{id:r.id});
   if(observed===epoch&&fetching.get(r.id)===key)setReview(r.id,{...review,values:valuesOfSections(review.sections)},key);
  }catch{/* The details load again with the next snapshot; the library shows the resume without them. */}
  finally{if(fetching.get(r.id)===key)fetching.delete(r.id);}
 }
}
export function refreshLive({quiet=false}={}){
 if(!backend.live)return Promise.resolve(null);
 if(inflight)return inflight;
 const observed=epoch;
 if(!quiet&&!state.boot)set({status:'loading',error:''});else set({refreshing:true});
 inflight=call('bootstrap').then(boot=>{if(observed===epoch)applyBootstrap(boot);return boot;}).catch(e=>{
  if(observed!==epoch)return null;
  set({status:state.boot?'ready':'error',error:describeError(e),expired:isSessionError(e),refreshing:false});
  return null;
 }).finally(()=>{inflight=null;});
 return inflight;
}
// Calls an account RPC, adopts the snapshot it returns, and rethrows failures for the caller to show.
export async function mutate(name,args){
 const observed=epoch,result=await call(name,args);
 if(observed===epoch)applyBootstrap(result);
 return result;
}
export function resetLive(){epoch++;inflight=null;clearTimeout(pollTimer);pollTimer=null;fetching.clear();state=blank();listeners.forEach(fn=>fn());}
events.addEventListener('reset',resetLive);
onBackendChange(()=>listeners.forEach(fn=>fn()));
// Screens call this once: it loads the snapshot on first use and reports the shared status.
export function useLive(){
 const snapshot=useSyncExternalStore(subscribeLive,liveState);
 useEffect(()=>{if(backend.live&&snapshot.status==='idle')refreshLive();},[snapshot.status]);
 return {...snapshot,live:backend.live,online:backend.online,retry:()=>refreshLive()};
}
