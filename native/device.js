// Native capabilities only. Product state, workflows and screens live in Jac.
import React, {useEffect, useRef, useState} from 'react';
import {Alert, Animated, AppState, Linking, PanResponder, View, Text, TextInput, Modal, ScrollView, Pressable, Image, useWindowDimensions} from 'react-native';
import * as SecureStore from 'expo-secure-store';
import * as Documents from 'expo-document-picker';
import * as Files from 'expo-file-system/legacy';
import * as Notifications from 'expo-notifications';
import Constants from 'expo-constants';
import DateTimePicker from '@react-native-community/datetimepicker';
import Pdf from 'react-native-pdf';
import {BrowserViewer,createBrowserStream} from './browser-viewer.js';
import {beginGoogle,waitGoogle,cancelGoogle,pendingGoogle} from './google-auth.js';
import {Layers, BriefcaseBusiness, Users, FileText, UserRound, MapPin, ArrowUpRight, ArrowRight, X, Check, SlidersHorizontal, ChevronLeft, ChevronRight, Bell, Plus, Upload, MoreHorizontal, Sparkles, Bookmark, Search, LogOut, Clock, Mail, ShieldCheck, CircleCheck, RotateCcw, Settings, GraduationCap, CodeXml, MessagesSquare, CircleAlert, CalendarDays, Pencil, Mic, Play, Pause, Shuffle, Sprout, MessageCircle, ArrowLeft, CirclePlus, CirclePlay, FileQuestionMark} from 'lucide-react-native';
const glyphs = {mic:Mic,play:Play,pause:Pause,shuffle:Shuffle,sprout:Sprout,chat:MessageCircle,return:ArrowLeft,"add-session":CirclePlus,"continue-session":CirclePlay,"question-file":FileQuestionMark,layers:Layers, jobs:Layers, applications:BriefcaseBusiness, network:Users, resume:FileText, profile:UserRound, prep:GraduationCap, code:CodeXml, conversation:MessagesSquare, pin:MapPin, arrow:ArrowUpRight, next:ArrowRight, x:X, check:Check, filter:SlidersHorizontal, back:ChevronLeft, chevron:ChevronRight, bell:Bell, plus:Plus, upload:Upload, more:MoreHorizontal, sparkles:Sparkles, bookmark:Bookmark, search:Search, logout:LogOut, clock:Clock, mail:Mail, shield:ShieldCheck, done:CircleCheck, retry:RotateCcw, settings:Settings, alert:CircleAlert, calendar:CalendarDays};
glyphs.edit = Pencil;
export function Icon({name,size=22,color='#64748B'}) {return React.createElement(glyphs[name] || Layers,{size,color,strokeWidth:1.8});}
export const apiBase = () => globalThis.__JAC_API_BASE_URL__ || Constants.expoConfig?.extra?.apiBaseUrl || 'http://127.0.0.1:8000';
let token='', generation=0;
// Shared UI owns the live session; legacy native helpers borrow its current credentials.
let borrowed=null;
export function borrowSession(next){generation++;borrowed=next;}
const currentToken=()=>borrowed?borrowed.token():token;
const currentBase=()=>borrowed?borrowed.origin:apiBase();
let pushToken='', pushAttempt=0;
let notifyChain=Promise.resolve();
const sessionKey='stack.session.v1';
const cacheDir=()=>Files.cacheDirectory+'stack-resumes/';
async function request(path,body,authenticated=true) {
  const epoch=generation,session=currentToken(),origin=currentBase(), controller=new AbortController();
  const timer=setTimeout(()=>controller.abort(),20000);
  try {
    const r=await fetch(origin+path,{method:'POST',headers:{'Content-Type':'application/json',...(authenticated&&session?{Authorization:'Bearer '+session}:{})},body:JSON.stringify(body),signal:controller.signal});
    const json=await r.json();
    if(epoch!==generation||session!==currentToken()||origin!==currentBase()) throw new Error('Session changed. Please try again.');
    if(!r.ok || json.ok===false) {
      const message=json.error?.message || json.detail || 'Request failed. Please try again.';
      const error=new Error(typeof message==='string'?message:'Check your details and try again.'); error.status=r.status; throw error;
    }
    return json.data;
  } catch(e) {
    if(e.name==='AbortError' || e.message==='Network request failed') throw new Error('Cannot reach Stack. Check your connection and retry.');
    throw e;
  } finally {clearTimeout(timer);}
}
async function adoptGoogle(pending){
  const observed=generation,result=await waitGoogle(request,SecureStore,pending,()=>AppState.currentState==='active');
  if(observed!==generation)throw new Error('Your session changed. Start Google sign-in again.');
  await SecureStore.setItemAsync(sessionKey,result.token);
  if(observed!==generation){
    // Cancellation/account changes can occur while the OS persists the result.
    if(token)await SecureStore.setItemAsync(sessionKey,token);else await SecureStore.deleteItemAsync(sessionKey);
    throw new Error('Your session changed. Start Google sign-in again.');
  }
  generation++;token=result.token;
  if(result.invite)await rpc('agent_accept_invite',{invite:result.invite});
  return result;
}
export async function restoreSession(){
  token=await SecureStore.getItemAsync(sessionKey)||'';
  const pending=await pendingGoogle(SecureStore);
  if(pending)await adoptGoogle(pending);
  return !!token;
}
export async function authenticateGoogle(invite='',link=false){
  const pending=await beginGoogle(request,SecureStore,url=>Linking.openURL(url),invite,link);
  return adoptGoogle(pending);
}
export async function cancelGoogleSignIn(){generation++;await cancelGoogle(SecureStore);}
export async function authenticate(username,password,signup){
  const identity={type:'username',value:username.trim().toLowerCase()};
  const credential={type:'password',password};
  const result=await request(signup?'/user/register':'/user/login',signup?{identities:[identity],credential}:{identity,credential},false);
  if(!result.token) throw new Error('Sign-in did not return a session. Please try again.');
  await SecureStore.setItemAsync(sessionKey,result.token); generation++; token=result.token;
  return true;
}
export async function rpc(name,args={}) {const data=await request('/function/'+name,args); const result=data?.result; if(result?.error) throw new Error(result.error); return result;}
let swipeQueue=Promise.resolve();
export function persistSwipe(jobId,action,startAgent=false){
  const observed=generation;
  const operation=swipeQueue.catch(()=>{}).then(async()=>{
    if(observed!==generation) throw new Error('Your session changed. Please sign in again.');
    const result=await rpc('swipe',{job_id:jobId,action,start_agent:startAgent});
    if(observed!==generation) throw new Error('Your session changed.');
    return result;
  });
  swipeQueue=operation;return operation;
}
export async function signOut(){
  await cancelGoogleSignIn();
  if(pushToken && token){try {await rpc('agent_remove_push',{device_token:pushToken});}catch {} pushToken='';}pushAttempt=0;
  generation++; token='';
  for(const close of browserStreams)close();browserStreams.clear();
  await notifyChain.catch(()=>{});
  const cleanup=await Promise.allSettled([SecureStore.deleteItemAsync(sessionKey),Notifications.cancelAllScheduledNotificationsAsync(),Notifications.dismissAllNotificationsAsync(),Files.deleteAsync(cacheDir(),{idempotent:true})]);
  if(cleanup.some(r=>r.status==='rejected')) throw new Error('Signed out, but device cleanup failed. Close Stack and retry sign-out before switching accounts.');
}
export function errorText(error){return error?.message || String(error);}
export function isUnauthorized(error){return error?.status===401;}
export function shortDate(seconds){return new Date(seconds*1000).toLocaleDateString(undefined,{month:'short',day:'numeric'});}
export function dateTime(seconds){return new Date(seconds*1000).toLocaleString(undefined,{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'});}
export function isoTime(value){const d=new Date(value);return value&&!isNaN(d)?d.toLocaleString(undefined,{weekday:'short',month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}):'Time not stated';}
export function tomorrow(){return Date.now()/1000+86400;}
export function later(minutes){return Date.now()/1000+minutes*60;}
export function openSettings(){Linking.openSettings();}
export function confirmDelete(label,action){Alert.alert('Delete '+label+'?','This removes the file from your Stack account.',[{text:'Cancel',style:'cancel'},{text:'Delete',style:'destructive',onPress:action}]);}
export async function pickResume(){
  const result=await Documents.getDocumentAsync({type:'application/pdf',copyToCacheDirectory:true,multiple:false});
  if(result.canceled) return null;
  const file=result.assets[0];
  try {
    const info=await Files.getInfoAsync(file.uri);
    if((file.size||info.size||0)>10*1024*1024) throw new Error('PDF must be 10 MB or smaller.');
    const content=await Files.readAsStringAsync(file.uri,{encoding:Files.EncodingType.Base64});
    return {name:file.name,content};
  } finally {await Files.deleteAsync(file.uri,{idempotent:true}).catch(()=>{});}
}
// LaTeX sources: a .tex file or Overleaf's source .zip. iOS has no reliable .tex type, so the name is checked here.
export async function pickLatexSource(){
  const result=await Documents.getDocumentAsync({type:'*/*',copyToCacheDirectory:true,multiple:false});
  if(result.canceled) return null;
  const file=result.assets[0];
  try {
    if(!/\.(tex|zip)$/i.test(file.name||'')) throw new Error('Choose a .tex file, or the source .zip from Overleaf (Menu → Download → Source).');
    const info=await Files.getInfoAsync(file.uri);
    if((file.size||info.size||0)>2*1024*1024) throw new Error('LaTeX source must be 2 MB or smaller.');
    const content=await Files.readAsStringAsync(file.uri,{encoding:Files.EncodingType.Base64});
    return {name:file.name,content};
  } finally {await Files.deleteAsync(file.uri,{idempotent:true}).catch(()=>{});}
}
export async function previewResume(id){
  const epoch=generation;
  const result=await rpc('read_resume',{id});
  if(epoch!==generation) throw new Error('Session changed.');
  await Files.makeDirectoryAsync(cacheDir(),{intermediates:true});
  const uri=cacheDir()+id.replace(/[^a-zA-Z0-9]/g,'')+'.pdf';
  await Files.writeAsStringAsync(uri,result.content,{encoding:Files.EncodingType.Base64});
  if(epoch!==generation){await Files.deleteAsync(uri,{idempotent:true});throw new Error('Session changed.');}
  return uri;
}
// Agent-generated PDFs (tailored resume, cover letter) share the signed-out cache cleanup.
export async function previewDocument(pdf){
  const epoch=generation;
  if(!pdf?.content) throw new Error('This document is not available to preview.');
  await Files.makeDirectoryAsync(cacheDir(),{intermediates:true});
  const uri=cacheDir()+'agent-'+String(pdf.name||'document').replace(/[^a-zA-Z0-9]/g,'')+'-'+Date.now()+'.pdf';
  await Files.writeAsStringAsync(uri,pdf.content,{encoding:Files.EncodingType.Base64});
  if(epoch!==generation){await Files.deleteAsync(uri,{idempotent:true});throw new Error('Session changed.');}
  return uri;
}
Notifications.setNotificationHandler({handleNotification:async()=>({shouldShowBanner:true,shouldShowList:true,shouldPlaySound:false,shouldSetBadge:false})});
export function reconcileNotifications(state,ask=false){
  const epoch=generation;
  notifyChain=notifyChain.catch(()=>{}).then(async()=>{
    if(epoch!==generation || !token) return '';
    if(!state.profile.notifications){if(pushToken){await rpc('agent_remove_push',{device_token:pushToken});pushToken='';}await Notifications.cancelAllScheduledNotificationsAsync();return '';}
    let permissions=await Notifications.getPermissionsAsync();
    if(ask && !permissions.granted && permissions.canAskAgain) permissions=await Notifications.requestPermissionsAsync();
    if(!permissions.granted){await Notifications.cancelAllScheduledNotificationsAsync();return ask?'Reminder saved. Enable notifications in iPhone Settings to receive alerts.':'';}
    const projectId=Constants.expoConfig?.extra?.eas?.projectId;
    if(Constants.expoConfig?.extra?.pushEnabled && projectId && !pushToken && Date.now()-pushAttempt>60000){
      pushAttempt=Date.now();
      try {const device=await Notifications.getExpoPushTokenAsync({projectId});if(epoch===generation){await rpc('agent_register_push',{device_token:device.data});pushToken=device.data;}} catch { /* Local reminders remain available while registration is retried. */ }
    }
    const wanted=state.reminders.filter(r=>!r.done && r.due_at>Date.now()/1000);
    const scheduled=await Notifications.getAllScheduledNotificationsAsync();
    for(const old of scheduled){const r=wanted.find(r=>'stack-'+state.user_id+'-'+r.id===old.identifier);if(!r || (old.content.data?.due_at!==r.due_at || old.content.body!==r.title)) await Notifications.cancelScheduledNotificationAsync(old.identifier);}
    for(const r of wanted){
      if(epoch!==generation) return '';
      const identifier='stack-'+state.user_id+'-'+r.id;
      if(scheduled.some(n=>n.identifier===identifier&&n.content.data?.due_at===r.due_at&&n.content.body===r.title)) continue;
      await Notifications.scheduleNotificationAsync({identifier,content:{title:'Stack · Follow up',body:r.title,data:{user_id:state.user_id,target_type:r.target_type,target_id:r.target_id,due_at:r.due_at}},trigger:{type:Notifications.SchedulableTriggerInputTypes.DATE,date:new Date(r.due_at*1000)}});
    }
    return '';
  }); return notifyChain;
}
export function Lifecycle({onRefresh,onOpen}){
  const latest=useRef({onRefresh,onOpen}); latest.current={onRefresh,onOpen};
  useEffect(()=>{
    const timer=setInterval(()=>{if(AppState.currentState==='active') latest.current.onRefresh();},4000);
    const app=AppState.addEventListener('change',s=>{if(s==='active') latest.current.onRefresh();});
    const route=r=>{const d=r?.notification?.request?.content?.data;if(d?.target_id) latest.current.onOpen(d);};
    Notifications.getLastNotificationResponseAsync().then(route);
    const response=Notifications.addNotificationResponseReceivedListener(route);
    return()=>{clearInterval(timer);app.remove();response.remove();};
  },[]); return null;
}

// Shared viewer owns its stream lifetime; closing it leaves background work alone.
const browserStreams=new Set();
function openBrowserStream(id,onEvent,onState){
  const observed=generation;
  const viewerToken=currentToken(),viewerOrigin=currentBase();
  const close=createBrowserStream({id,origin:viewerOrigin,authorization:'Bearer '+viewerToken,isCurrent:()=>observed===generation&&viewerToken===currentToken()&&viewerOrigin===currentBase(),onEvent,onState});
  browserStreams.add(close);return()=>{close();browserStreams.delete(close);};
}
export function AgentBrowser({id,task,requestBrowser=rpc,onChanged}) {
  return React.createElement(BrowserViewer,{id,task,requestBrowser,openStream:openBrowserStream,onChanged});
}
export function SwipeSurface({children,onSwipe,disabled,cardId}){
  const x=useRef(new Animated.Value(0)).current;
  const {width}=useWindowDimensions();
  const latest=useRef({onSwipe,disabled,width});latest.current={onSwipe,disabled,width};
  const active=useRef(false);
  const reset=()=>{active.current=false;Animated.spring(x,{toValue:0,useNativeDriver:true}).start();};
  useEffect(()=>{x.setValue(0);active.current=false;},[cardId]);
  const horizontal=(_,g)=>!active.current&&!latest.current.disabled&&Math.abs(g.dx)>10&&Math.abs(g.dx)>Math.abs(g.dy)*1.3;
  const responder=useRef(PanResponder.create({
    onMoveShouldSetPanResponder:horizontal,
    onMoveShouldSetPanResponderCapture:horizontal,
    onPanResponderTerminationRequest:()=>false,
    onPanResponderMove:(_,g)=>{if(!active.current)x.setValue(g.dx);},
    onPanResponderRelease:(_,g)=>{
      if(active.current)return;
      const crossed=Math.abs(g.dx)>Math.min(90,latest.current.width*.2)||(Math.abs(g.vx)>.65&&Math.abs(g.dx)>25);
      if(crossed&&!latest.current.disabled){
        active.current=true;const action=g.dx>0?'apply':'pass';
        Animated.timing(x,{toValue:g.dx>0?latest.current.width+40:-latest.current.width-40,duration:150,useNativeDriver:true}).start(()=>{
          Promise.resolve(latest.current.onSwipe(action)).catch(reset);
        });
      }else reset();
    },
    onPanResponderTerminate:reset
  })).current;
  const badge=(label,color,range)=>React.createElement(Animated.View,{pointerEvents:'none',style:{position:'absolute',top:14,left:14,padding:10,borderWidth:2,borderColor:color,borderRadius:12,backgroundColor:'white',opacity:x.interpolate({inputRange:range,outputRange:[0,0,1],extrapolate:'clamp'})}},React.createElement(Text,{style:{fontWeight:'800',color}},label));
  return React.createElement(Animated.View,{...responder.panHandlers,testID:'job-swipe-card',style:{transform:[{translateX:x},{rotate:x.interpolate({inputRange:[-300,0,300],outputRange:['-8deg','0deg','8deg']})}]}},children,badge('SAVE','#167867',[-90,15,90]),
    React.createElement(Animated.View,{pointerEvents:'none',style:{position:'absolute',top:14,right:14,padding:10,borderWidth:2,borderColor:'#B42318',borderRadius:12,backgroundColor:'white',opacity:x.interpolate({inputRange:[-90,-15,90],outputRange:[1,0,0],extrapolate:'clamp'})}},React.createElement(Text,{style:{fontWeight:'800',color:'#B42318'}},'PASS')));
}
export function DateField({value,onChange}){
  return React.createElement(View,{style:{gap:10}},
    React.createElement(DateTimePicker,{value:new Date(value*1000),minimumDate:new Date(),mode:'date',display:'compact',themeVariant:'light',onChange:(_,d)=>d&&onChange(d.getTime()/1000)}),
    React.createElement(DateTimePicker,{value:new Date(value*1000),mode:'time',display:'compact',themeVariant:'light',onChange:(_,d)=>d&&onChange(d.getTime()/1000)}));
}
export function PDFView({uri}){
  const [error,setError]=useState(''); const {width}=useWindowDimensions();
  return error?React.createElement(Text,{style:{padding:24,color:'#B42318'}},error):React.createElement(Pdf,{source:{uri,cache:false},trustAllCerts:false,onError:()=>setError('Unable to preview this PDF. Please upload a new copy.'),style:{flex:1,width:width-32,alignSelf:'center'}});
}

export async function openJobLink(url){
  const parsed=new URL(url);
  if(!['https:','http:'].includes(parsed.protocol)) throw new Error('Invalid application link.');
  await Linking.openURL(url);
}
export function SourceAttribution({job}){
  const a=job.attribution||{};
  if(a.label==='Jobs by Adzuna') return React.createElement(Pressable,{accessibilityRole:'link',accessibilityLabel:a.label,onPress:()=>openJobLink(a.url).catch(()=>Alert.alert('Cannot open source link'))},
    React.createElement(View,{style:{flexDirection:'row',alignItems:'center',minWidth:116,minHeight:23}},
      React.createElement(Text,{style:{fontSize:14,color:'#3765E8'}},'Jobs by '),
      React.createElement(Image,{source:require('./adzuna-logo.png'),style:{width:100,height:28},resizeMode:'contain',accessibilityLabel:'Adzuna'})));
  return React.createElement(Text,{style:{fontSize:12,color:'#64748B'}},'Source: '+job.source_name+' · Checked '+new Date(job.checked_at*1000).toLocaleDateString());
}

// Upload progress measures bytes handed to the network. Acceptance means the
// file and processing ticket have been committed; processing belongs to the worker.
export async function uploadResumeFile(endpoint, file, onProgress=()=>{}) {
  const epoch=generation, started=Date.now();
  const body=JSON.stringify(file);
  onProgress({status:'uploading',loaded:0,total:body.length,percent:null});
  let json;
  if(typeof XMLHttpRequest==='undefined') {
    const result=await rpc(endpoint,file);
    json={data:{result}};
  } else {
    json=await new Promise((resolve,reject)=>{
      const xhr=new XMLHttpRequest();
      xhr.open('POST',currentBase()+'/function/'+endpoint);
      xhr.timeout=20000;
      xhr.setRequestHeader('Content-Type','application/json');
      if(currentToken())xhr.setRequestHeader('Authorization','Bearer '+currentToken());
      xhr.upload.onprogress=event=>{
        if(epoch!==generation)return;
        onProgress({status:'uploading',loaded:event.loaded,total:event.total,
          percent:event.lengthComputable?Math.min(100,Math.round(event.loaded/event.total*100)):null});
      };
      xhr.onload=()=>{
        try {
          if(epoch!==generation)throw new Error('Session changed. Please try again.');
          const value=JSON.parse(xhr.responseText);
          if(xhr.status<200||xhr.status>=300||value.ok===false||value.data?.result?.error){
            const error=new Error(value.data?.result?.error||value.error?.message||value.detail||'Upload failed. Retry the same file.');
            error.status=xhr.status;throw error;
          }
          resolve(value);
        }catch(error){reject(error);}
      };
      xhr.onerror=xhr.ontimeout=xhr.onabort=()=>reject(new Error('Upload interrupted. Reopen Stack to check whether it was saved, or retry the same file.'));
      xhr.send(body);
    });
  }
  if(epoch!==generation)throw new Error('Session changed. Please try again.');
  const result=json.data?.result;
  if(!result)throw new Error('Upload did not return its saved status. Reopen Stack to check.');
  const elapsed=Date.now()-started;
  if(endpoint==='transcription_upload'){
    result.timings={...result.timings,transfer_ms:elapsed};
    rpc('transcription_transfer_complete',{id:result.id,elapsed_ms:elapsed}).catch(()=>{});
    onProgress({status:'saved',percent:100,elapsed_ms:elapsed});
    return result;
  }
  const kind=endpoint==='upload_resume'?'pdf':'source';
  const resume=file.id?result.resumes?.find(r=>r.id===file.id):result.resumes?.filter(r=>r.name===file.name).sort((a,b)=>b.created_at-a.created_at)[0];
  const job=resume?.processing?.[kind];
  if(job){
    job.timings={...job.timings,transfer_ms:elapsed};
    // Telemetry is independent of acceptance; losing this response never loses work.
    rpc('resume_transfer_complete',{id:resume.id,job_id:job.id,elapsed_ms:elapsed}).catch(()=>{});
  }
  onProgress({status:'saved',percent:100,elapsed_ms:elapsed});
  return result;
}
export function uploadProgressText(progress){
  if(progress?.status==='uploading')return progress.percent==null?'Uploading…':`Uploading ${progress.percent}%`;
  return '';
}
export function ResumeProcessing({resumeId,kind='pdf',processing={},onChanged,onCompleted}) {
  const [error,setError]=useState(''),[retrying,setRetrying]=useState(false);
  const current=useRef({onChanged,onCompleted});current.current={onChanged,onCompleted};
  const delivered=useRef('');
  useEffect(()=>{
    if(processing.status==='completed'&&onCompleted&&delivered.current!==processing.id){
      delivered.current=processing.id;current.current.onCompleted();
    }
  },[processing.id,processing.status]);
  const retry=async()=>{
    if(retrying)return;setRetrying(true);setError('');
    try{const next=await rpc('retry_resume_processing',{id:resumeId,kind});current.current.onChanged?.(next);}catch(e){setError(errorText(e));}
    finally{setRetrying(false);}
  };
  if(!processing.status||processing.status==='cancelled')return null;
  const labels={queued:'Saved · Waiting to process',parsing:kind==='pdf'?'Reading PDF…':'Reading LaTeX source…',compiling:'Compiling LaTeX…',completed:kind==='pdf'?'PDF ready to review':'LaTeX compiled',failed:'Processing failed'};
  const timings=processing.timings||{};
  const elapsed=Object.entries({transfer_ms:'Upload',queue_ms:'Queue',parse_ms:'Parse',compile_ms:'Compile'})
    .filter(([key])=>timings[key]>0).map(([key,label])=>`${label} ${(timings[key]/1000).toFixed(2)}s`).join(' · ');
  return React.createElement(View,{style:{gap:6}},
    React.createElement(Text,{accessibilityLiveRegion:'polite',style:{fontSize:14,color:processing.status==='failed'?'#B42318':'#3765E8'}},labels[processing.status]||processing.status),
    ['queued','parsing','compiling'].includes(processing.status)&&React.createElement(Text,{style:{fontSize:12,color:'#64748B'}},'Saved on the server. You can close Stack and reopen later.'),
    !!elapsed&&React.createElement(Text,{style:{fontSize:12,color:'#64748B'}},elapsed),
    !!processing.error&&React.createElement(Text,{style:{color:'#B42318'}},processing.error),
    processing.status==='failed'&&React.createElement(Pressable,{accessibilityRole:'button',accessibilityLabel:'Retry '+(kind==='pdf'?'PDF parsing':'LaTeX processing'),disabled:retrying,onPress:retry,style:{padding:10}},React.createElement(Text,null,retrying?'Retrying…':'Retry processing')),
    !!error&&React.createElement(Text,{style:{color:'#B42318'}},error));
}
// Poll a pending review/setup while it is mounted; unmounting only stops polling.
export function ProcessingPoll({active,onRefresh}) {
  const current=useRef(onRefresh);current.current=onRefresh;
  const pending=useRef(false);
  useEffect(()=>{
    if(!active)return;
    const timer=setInterval(async()=>{
      if(pending.current||AppState.currentState!=='active')return;
      pending.current=true;try{await current.current();}finally{pending.current=false;}
    },1500);
    return()=>clearInterval(timer);
  },[active]);
  return null;
}
