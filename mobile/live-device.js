// Native pieces of the live build that need the signed-in session: PDF preview, reminder alerts, foreground refresh.
// Mock builds never import this behavior; the device facade selects it only when the data mode is live.
import {useEffect,useRef} from 'react';
import {AppState} from 'react-native';
import * as Files from 'expo-file-system/legacy';
import * as Notifications from 'expo-notifications';
import {authSession} from './auth-platform';
import {refreshLive} from './prototype/live-store';
import {backend} from './prototype/backend';
import * as Documents from 'expo-document-picker';
const cacheDir=()=>Files.cacheDirectory+'stack-resumes/';
const safe=text=>String(text||'').replace(/[^a-zA-Z0-9]/g,'');
// Writes a base64 PDF into the cache folder that sign-out clears, and returns its file URI.
export async function cachePdf(name,content){
 if(!content)throw Error('This document is not available to preview.');
 await Files.makeDirectoryAsync(cacheDir(),{intermediates:true});
 const uri=cacheDir()+safe(name)+'-'+Date.now()+'.pdf';
 await Files.writeAsStringAsync(uri,content,{encoding:Files.EncodingType.Base64});
 return uri;
}
export async function previewResume(id){const result=await authSession.call('read_resume',{id});return cachePdf(id,result.content);}
export async function previewDocument(pdf){return cachePdf(pdf?.name||'document',pdf?.content);}
export const clearPdfCache=()=>Files.deleteAsync(cacheDir(),{idempotent:true});
// Signing out removes everything this device kept for the account: cached PDFs and scheduled reminder alerts.
export async function clearLocalAccountData(){
 const cleanup=await Promise.allSettled([clearPdfCache(),Notifications.cancelAllScheduledNotificationsAsync(),Notifications.dismissAllNotificationsAsync()]);
 if(cleanup.some(r=>r.status==='rejected'))throw Error('Signed out, but device cleanup failed. Close Stack and retry sign-out before switching accounts.');
}
export const uploadResumeFile=(endpoint,file,onProgress)=>authSession.upload(endpoint,file,onProgress);
let chain=Promise.resolve();
// Schedules a local alert for each open reminder (the same behavior as before, from this session's snapshot).
export function reconcileNotifications(state,ask=false){
 chain=chain.catch(()=>{}).then(async()=>{
  if(!state?.profile?.notifications){await Notifications.cancelAllScheduledNotificationsAsync();return '';}
  let permissions=await Notifications.getPermissionsAsync();
  if(ask&&!permissions.granted&&permissions.canAskAgain)permissions=await Notifications.requestPermissionsAsync();
  if(!permissions.granted){await Notifications.cancelAllScheduledNotificationsAsync();return ask?'Reminder saved. Enable notifications in iPhone Settings to receive alerts.':'';}
  const wanted=(state.reminders||[]).filter(r=>!r.done&&r.due_at>Date.now()/1000),scheduled=await Notifications.getAllScheduledNotificationsAsync();
  const idOf=r=>'stack-'+state.user_id+'-'+r.id;
  for(const old of scheduled){const r=wanted.find(x=>idOf(x)===old.identifier);if(!r||old.content.data?.due_at!==r.due_at||old.content.body!==r.title)await Notifications.cancelScheduledNotificationAsync(old.identifier);}
  for(const r of wanted){
   if(scheduled.some(n=>n.identifier===idOf(r)&&n.content.data?.due_at===r.due_at&&n.content.body===r.title))continue;
   await Notifications.scheduleNotificationAsync({identifier:idOf(r),content:{title:'Stack · Follow up',body:r.title,data:{user_id:state.user_id,target_type:r.target_type,target_id:r.target_id,due_at:r.due_at}},trigger:{type:Notifications.SchedulableTriggerInputTypes.DATE,date:new Date(r.due_at*1000)}});
  }
  return '';
 });
 return chain;
}
// Refreshes the account on foreground and every 15 s while visible, so agent progress and other devices show up.
export function Lifecycle({onRefresh,onOpen}){
 const latest=useRef({onRefresh,onOpen});latest.current={onRefresh,onOpen};
 useEffect(()=>{
  const tick=()=>{if(AppState.currentState==='active'){latest.current.onRefresh();refreshLive({quiet:true});}};
  const timer=setInterval(tick,15000),app=AppState.addEventListener('change',s=>{if(s==='active')tick();});
  const route=r=>{const d=r?.notification?.request?.content?.data;if(d?.target_id)latest.current.onOpen(d);};
  Notifications.getLastNotificationResponseAsync().then(route);
  const response=Notifications.addNotificationResponseReceivedListener(route);
  return()=>{clearInterval(timer);app.remove();response.remove();};
 },[]);
 return null;
}
export const liveEnabled=()=>backend.live;
// PDF resume picker for the signed-in app: returns {name, content (base64)} after checking size and type.
export async function pickResume(){
 const result=await Documents.getDocumentAsync({type:'application/pdf',copyToCacheDirectory:true,multiple:false});
 if(result.canceled)return null;
 const file=result.assets[0];
 try{
  const info=await Files.getInfoAsync(file.uri);
  if((file.size||info.size||0)>10*1024*1024)throw Error('PDF must be 10 MB or smaller.');
  const content=await Files.readAsStringAsync(file.uri,{encoding:Files.EncodingType.Base64});
  return {name:file.name,content};
 }finally{await Files.deleteAsync(file.uri,{idempotent:true}).catch(()=>{});}
}
