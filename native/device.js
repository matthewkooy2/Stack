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
import {Layers, BriefcaseBusiness, Users, FileText, UserRound, MapPin, ArrowUpRight, ArrowRight, X, Check, SlidersHorizontal, ChevronLeft, ChevronRight, Bell, Plus, Upload, MoreHorizontal, Sparkles, Bookmark, Search, LogOut, Clock, Mail, ShieldCheck, CircleCheck, RotateCcw, Settings, GraduationCap, CodeXml, MessagesSquare, CircleAlert, CalendarDays, Pencil} from 'lucide-react-native';
const glyphs = {layers:Layers, jobs:Layers, applications:BriefcaseBusiness, network:Users, resume:FileText, profile:UserRound, prep:GraduationCap, code:CodeXml, conversation:MessagesSquare, pin:MapPin, arrow:ArrowUpRight, next:ArrowRight, x:X, check:Check, filter:SlidersHorizontal, back:ChevronLeft, chevron:ChevronRight, bell:Bell, plus:Plus, upload:Upload, more:MoreHorizontal, sparkles:Sparkles, bookmark:Bookmark, search:Search, logout:LogOut, clock:Clock, mail:Mail, shield:ShieldCheck, done:CircleCheck, retry:RotateCcw, settings:Settings, alert:CircleAlert, calendar:CalendarDays};
glyphs.edit = Pencil;
export function Icon({name,size=22,color='#64748B'}) {return React.createElement(glyphs[name] || Layers,{size,color,strokeWidth:1.8});}
export const apiBase = () => globalThis.__JAC_API_BASE_URL__ || Constants.expoConfig?.extra?.apiBaseUrl || 'http://127.0.0.1:8000';
let token='', generation=0;
let pushToken='', pushAttempt=0;
let notifyChain=Promise.resolve();
const sessionKey='stack.session.v1';
const cacheDir=()=>Files.cacheDirectory+'stack-resumes/';
async function request(path,body,authenticated=true) {
  const epoch=generation, controller=new AbortController();
  const timer=setTimeout(()=>controller.abort(),20000);
  try {
    const r=await fetch(apiBase()+path,{method:'POST',headers:{'Content-Type':'application/json',...(authenticated&&token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:controller.signal});
    const json=await r.json();
    if(epoch!==generation) throw new Error('Session changed. Please try again.');
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
export async function restoreSession(){token=await SecureStore.getItemAsync(sessionKey)||''; return !!token;}
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
  if(pushToken && token){try {await rpc('agent_remove_push',{device_token:pushToken});}catch {} pushToken='';}pushAttempt=0;
  generation++; token='';
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

// Display and control the remote browser; login input never enters task drafts.
export function AgentBrowser({id,interactive=false,requestBrowser,onAnalyze,canAnalyze=false,statusMessage=''}) {
  const [frame,setFrame]=useState(null),[input,setInput]=useState(''),[error,setError]=useState('');
  const [busy,setBusy]=useState(false),[expanded,setExpanded]=useState(false),[width,setWidth]=useState(1),[expired,setExpired]=useState(false);
  const current=useRef({id,interactive,requestBrowser});current.current={id,interactive,requestBrowser};
  const locked=useRef(false),alive=useRef(false),active=useRef(AppState.currentState==='active');
  const session=useRef(generation);
  const send=async(event={type:'snapshot'})=>{
    if(locked.current||!active.current||!alive.current||session.current!==generation) return;
    if(event.type!=='snapshot'&&!current.current.interactive) return;
    locked.current=true;setBusy(true);
    const task=current.current.id;
    try {
      const result=await current.current.requestBrowser('agent_browser',{id:task,event});
      if(alive.current&&active.current&&task===current.current.id&&session.current===generation){
        setExpired(!!result.expired);
        if(result.expired){setFrame(null);setInput('');}
        else if(result.image)setFrame(result);
        setError('');
      }
    } catch(e){if(alive.current&&active.current&&task===current.current.id)setError(errorText(e));}
    finally {locked.current=false;if(alive.current)setBusy(false);}
  };
  const typeInput=()=>{
    if(locked.current)return;
    const text=input;setInput('');send({type:'text',text});
  };
  const latestSend=useRef(send);latestSend.current=send;
  useEffect(()=>{
    alive.current=true;session.current=generation;setFrame(null);setInput('');setError('');setExpired(false);
    latestSend.current();
    const timer=setInterval(()=>latestSend.current(),1500);
    const app=AppState.addEventListener('change',state=>{
      active.current=state==='active';
      if(!active.current){setInput('');setFrame(null);setExpanded(false);}
      else latestSend.current();
    });
    return()=>{alive.current=false;clearInterval(timer);app.remove();};
  },[id]);
  useEffect(()=>{if(!interactive)setInput('');},[interactive]);
  const button=(label,action,disabled=false)=>React.createElement(Pressable,{accessibilityRole:'button',accessibilityLabel:label,onPress:action,disabled,style:{padding:12,borderRadius:12,backgroundColor:disabled?'#EDF0F5':'#E5EDFF'}},React.createElement(Text,{style:{color:'#17345C',fontWeight:'600'}},label));
  const controls=()=>React.createElement(View,{style:{gap:10}},
    React.createElement(Text,{style:{fontWeight:'700',fontSize:18}},'Agent browser'),
    React.createElement(Text,null,interactive?(statusMessage||'Your turn. Sign in here, then confirm the profile is yours.'):'The agent is working. You can watch; controls return when it needs you.'),
    frame?.url?React.createElement(Text,{numberOfLines:1},frame.url):null,
    !interactive&&frame?.progress?React.createElement(Text,{accessibilityLiveRegion:'polite'},frame.progress):null,
    error?React.createElement(Text,{accessibilityRole:'alert',style:{color:'#B42318'}},error):null,
    frame?.image?React.createElement(Pressable,{
      accessibilityLabel:'Agent browser page',disabled:!interactive||busy,
      onLayout:e=>setWidth(e.nativeEvent.layout.width),
      onPress:e=>{const {locationX,locationY}=e.nativeEvent;send({type:'click',x:Math.min(frame.width-1,Math.max(0,locationX*frame.width/width)),y:Math.min(frame.height-1,Math.max(0,locationY*frame.width/width))});},
      style:{width:'100%',aspectRatio:frame.width/frame.height,borderWidth:1,borderColor:'#CBD5E1',borderRadius:8,overflow:'hidden'}
    },React.createElement(Image,{source:{uri:'data:image/jpeg;base64,'+frame.image},resizeMode:'contain',style:{width:'100%',height:'100%'}})):
      error?null:expired?React.createElement(Text,null,'This browser session ended. Open it again to sign in.'):React.createElement(Text,null,'Opening the agent’s browser…'),
    expired&&interactive?button('Open browser again',()=>send({type:'reopen'}),busy):null,
    React.createElement(View,{style:{flexDirection:'row',flexWrap:'wrap',gap:8}},
      button(expanded?'Close full screen':'Full screen',()=>setExpanded(!expanded)),
      button('Refresh browser',()=>send(),busy),
      ...[[-550,'Scroll up'],[550,'Scroll down']].map(([dy,label])=>React.createElement(React.Fragment,{key:label},button(label,()=>send({type:'scroll',dy}),!interactive||busy)))),
    interactive&&!expired?React.createElement(View,{style:{gap:8}},
      React.createElement(Text,null,'Tap a field in the browser, type below, then choose Type in browser. Passwords and verification codes stay out of your saved task.'),
      React.createElement(TextInput,{accessibilityLabel:'Private browser input',value:input,onChangeText:setInput,secureTextEntry:true,autoCapitalize:'none',autoCorrect:false,autoComplete:'off',textContentType:'none',
        style:{padding:12,borderWidth:1,borderColor:'#CBD5E1',borderRadius:10},
        onSubmitEditing:typeInput}),
      React.createElement(View,{style:{flexDirection:'row',flexWrap:'wrap',gap:8}},
        button('Type in browser',typeInput,busy||!input),
        ...['Tab','Enter','Backspace'].map(key=>React.createElement(React.Fragment,{key},button(key,()=>send({type:'key',key}),busy)))),
      button('Open my profile',()=>send({type:'reload'}),busy),
      button('Open LinkedIn sign-in',()=>send({type:'login'}),busy),
      canAnalyze?button('I’m signed in · Analyze my profile',()=>{setInput('');onAnalyze();},busy):null):null);
  return React.createElement(View,{style:{gap:10}},expanded?null:controls(),
    React.createElement(Modal,{visible:expanded,animationType:'slide',presentationStyle:'fullScreen',onRequestClose:()=>setExpanded(false)},
      React.createElement(ScrollView,{contentContainerStyle:{padding:20,paddingTop:60,paddingBottom:40},keyboardShouldPersistTaps:'handled'},controls())));
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
