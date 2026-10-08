// Native microphone + durable owner-isolated files; screen and server workflow live in Jac.
import React, {useEffect, useRef, useState} from 'react';
import {AppState, Platform, Pressable, Text} from 'react-native';
import {AudioModule, useAudioRecorder, useAudioRecorderState, useAudioPlayer, useAudioPlayerStatus, setAudioModeAsync} from 'expo-audio';
import * as Files from 'expo-file-system/legacy';
import {requireOptionalNativeModule} from 'expo-modules-core';
const speech=Platform.OS==='ios'?requireOptionalNativeModule('StackSpeech'):null;

export const recordingOptions = {
  extension: '.wav', sampleRate: 16000, numberOfChannels: 1, bitRate: 256000, directory: 'document',
  ios: {outputFormat: 'lpcm', audioQuality: 127, linearPCMBitDepth: 16,
    linearPCMIsBigEndian: false, linearPCMIsFloat: false},
};
const ownerDir = owner => {
  if(!/^[a-zA-Z0-9_-]{1,80}$/.test(owner)) throw new Error('Sign in before recording.');
  return Files.documentDirectory+'stack-recordings/'+owner+'/';
};
const activeCaptures=new Set();
const identifier = () => Date.now().toString(36)+'-'+Math.random().toString(36).slice(2)+'-'+Math.random().toString(36).slice(2);
const safeUri = uri => typeof uri==='string' && uri.startsWith(Files.documentDirectory);

// New revision first, then prune the previous revision. A crash cannot truncate
// the only manifest; interrupted captures remain discoverable on reopening.
export async function saveLocalRecording(owner, row) {
  const dir=ownerDir(owner);
  if(!/^[a-zA-Z0-9_-]{12,80}$/.test(row.client_id)) throw new Error('Invalid recording identifier.');
  await Files.makeDirectoryAsync(dir,{intermediates:true});
  const value={...row,sequence:(row.sequence||0)+1,updated_at:Date.now()};
  const name=row.client_id+'.'+value.sequence+'.'+identifier()+'.json';
  await Files.writeAsStringAsync(dir+name,JSON.stringify(value));
  const names=await Files.readDirectoryAsync(dir);
  const previous=names.filter(n=>n.startsWith(row.client_id+'.')&&n.endsWith('.json')&&n!==name);
  // Pruning failures do not turn a completed durable save into a failed save.
  for(const old of previous) await Files.deleteAsync(dir+old,{idempotent:true}).catch(()=>{});
  return value;
}
export async function localRecordings(owner) {
  const dir=ownerDir(owner), rows=new Map();
  await Files.makeDirectoryAsync(dir,{intermediates:true});
  for(const name of await Files.readDirectoryAsync(dir)) {
    if(!name.endsWith('.json')) continue;
    try {
      const value=JSON.parse(await Files.readAsStringAsync(dir+name));
      if(value.owner!==owner||!name.startsWith(value.client_id+'.')||!safeUri(value.uri)) continue;
      if(!rows.has(value.client_id)||(rows.get(value.client_id).sequence||0)<value.sequence)rows.set(value.client_id,value);
    } catch { /* An interrupted new manifest leaves its previous revision intact. */ }
  }
  return [...rows.values()].sort((a,b)=>b.created_at-a.created_at).map(r=>r.status==='recording'&&!activeCaptures.has(r.client_id)?{...r,status:'interrupted'}:r);
}
export async function recordingContent(row) {
  if(!safeUri(row.uri)) throw new Error('Recording file is unavailable.');
  const info=await Files.getInfoAsync(row.uri);
  if(!info.exists||!info.size) throw new Error('This recording has no saved audio. Record another answer.');
  if(info.size>10*1024*1024) throw new Error('Recording must be 10 MB or less.');
  return {client_id:row.client_id,content:await Files.readAsStringAsync(row.uri,{encoding:Files.EncodingType.Base64})};
}
export async function deleteLocalRecording(owner, row) {
  const dir=ownerDir(owner);
  const saved=(await localRecordings(owner)).find(r=>r.client_id===row.client_id);
  if(!saved) return;
  if(safeUri(saved.uri)) await Files.deleteAsync(saved.uri,{idempotent:true});
  for(const name of await Files.readDirectoryAsync(dir))if(name.startsWith(saved.client_id+'.'))await Files.deleteAsync(dir+name,{idempotent:true});
}
export async function cacheAnswerAudio(owner, serverId, content) {
  if(!/^[a-zA-Z0-9_-]{1,100}$/.test(serverId)||typeof content!=='string'||content.length>14*1024*1024)throw new Error('Saved audio is unavailable.');
  const existing=(await localRecordings(owner)).find(row=>row.server_id===serverId);
  if(existing&&(await Files.getInfoAsync(existing.uri)).exists)return existing;
  const dir=ownerDir(owner),uri=dir+'answer-'+serverId+'.wav';
  await Files.writeAsStringAsync(uri,content,{encoding:Files.EncodingType.Base64});
  return saveLocalRecording(owner,{client_id:identifier(),owner,uri,server_id:serverId,status:'uploaded',created_at:Date.now()/1000,duration_ms:0});
}
export function recordingClock(milliseconds) {
  const seconds=Math.max(0,Math.floor(milliseconds/1000));
  return String(Math.floor(seconds/60))+':'+String(seconds%60).padStart(2,'0');
}
export async function savePhoneTranscript(owner,row,text,revision) {
  const saved=(await localRecordings(owner)).find(r=>r.client_id===row.client_id);
  if(!saved||saved.status!=='completed')throw new Error('Reopen this saved phone transcript.');
  if(saved.revision!==revision)throw new Error('The transcript changed. Reopen it before saving.');
  if(typeof text!=='string'||text.length>30000)throw new Error('Transcript must be 30,000 characters or less.');
  return saveLocalRecording(owner,{...saved,transcript:text,revision:revision+1});
}
export function useRecording(owner) {
  const recorder=useAudioRecorder(recordingOptions);
  const status=useAudioRecorderState(recorder,200);
  const [current,setCurrent]=useState(null),[captureError,setCaptureError]=useState('');
  const [nativeStatus,setNativeStatus]=useState({isRecording:false,durationMillis:0,text:''}),[engineMessage,setEngineMessage]=useState('');
  const mode=useRef('pc'),nativeSave=useRef(null),pendingNative=useRef(null);
  const active=useRef(null),operation=useRef(false),alive=useRef(true);
  const ownerRef=useRef(owner);ownerRef.current=owner;
  const [paused,setPaused]=useState(false);const pausedRef=useRef(false);
  const ending=useRef(null),seenRecording=useRef(false),lastDuration=useRef(0);
  if(status.isRecording){seenRecording.current=true;lastDuration.current=status.durationMillis;}
  async function finishNative(result,row) {
    if(nativeSave.current)return nativeSave.current;
    pendingNative.current={result,row};
    // Microphone state follows native completion even when a manifest write fails.
    if(alive.current&&ownerRef.current===row.owner)setNativeStatus({isRecording:false,durationMillis:result.duration_ms||lastDuration.current,text:''});
    nativeSave.current=(async()=>{
      try {
        const text=result.complete?result.text:'';
        const saved=await saveLocalRecording(row.owner,{...row,uri:result.uri||row.uri,status:text?'completed':'ready',
          duration_ms:result.duration_ms||lastDuration.current,original_transcript:text,transcript:text,revision:text?1:0,
          model:text?'Apple SpeechTranscriber':'whisper.cpp/base.en',message:result.message||'',cancelled:!!result.cancelled});
        pendingNative.current=null;
        if(alive.current&&ownerRef.current===row.owner){setCurrent(saved);setEngineMessage(saved.message);}
        return saved;
      } catch(error) {
        nativeSave.current=null;
        throw error;
      } finally {
        activeCaptures.delete(row.client_id);
        if(active.current?.client_id===row.client_id)active.current=null;
        seenRecording.current=false;pausedRef.current=false;if(alive.current)setPaused(false);
      }
    })();
    return nativeSave.current;
  }
  async function stop(cancelled=false) {
    if(ending.current) return ending.current;
    if(!active.current) return pendingNative.current?finishNative(pendingNative.current.result,pendingNative.current.row):null;
    const row=active.current;
    ending.current=(async()=>{
      try {
        if(mode.current==='apple'){
          const result=await speech.stop(row.client_id,cancelled);
          return await finishNative(result,row);
        }
        const duration=Math.max(lastDuration.current,recorder.getStatus().durationMillis||0);
        await recorder.stop();
        const saved=await saveLocalRecording(row.owner,{...row,uri:recorder.uri||row.uri,status:'ready',duration_ms:duration,cancelled});
        active.current=null;seenRecording.current=false;pausedRef.current=false;if(alive.current)setPaused(false);
        if(alive.current&&ownerRef.current===row.owner)setCurrent(saved);
        return saved;
      } finally {
        activeCaptures.delete(row.client_id);active.current=null;seenRecording.current=false;pausedRef.current=false;if(alive.current)setPaused(false);
        await setAudioModeAsync({allowsRecording:false,shouldPlayInBackground:false}).catch(()=>{});
        ending.current=null;
      }
    })();
    return ending.current;
  }
  async function start(context={}) {
    if(operation.current||active.current) throw new Error('A recording is already in progress.');
    if(Platform.OS!=='ios') throw new Error('Audio recording is available on iPhone in this version.');
    operation.current=true;setCaptureError('');nativeSave.current=null;setNativeStatus({isRecording:false,durationMillis:0,text:''});
    const captureOwner=owner;
    const checkStartContext=()=>{
      if(!alive.current||ownerRef.current!==captureOwner)throw new Error('Your account changed. Record again after signing in.');
      if(AppState.currentState&&AppState.currentState!=='active')throw new Error('Return to Stack before recording.');
    };
    try {
      // Retain a finalized result in memory and retry its durable save before
      // another capture can replace it after a temporary storage failure.
      if(pendingNative.current)await finishNative(pendingNative.current.result,pendingNative.current.row);
      nativeSave.current=null;
      if((await localRecordings(captureOwner)).length>=50)throw new Error('Delete a saved phone recording before recording another.');
      checkStartContext();
      const permission=await AudioModule.requestRecordingPermissionsAsync();
      if(!permission.granted)throw new Error('Microphone access is denied. Enable it for Stack in iPhone Settings.');
      checkStartContext();
      const capabilities=speech?await speech.capabilities().catch(()=>({available:false,reason:'On-device speech could not start. PC transcription will be used.'})): {available:false,reason:'PC transcription will be used.'};
      checkStartContext();
      setEngineMessage(capabilities.reason||'');
      mode.current=capabilities.available?'apple':'pc';
      const clientId=identifier();
      let row;
      if(mode.current==='apple') {
        const uri=ownerDir(captureOwner)+clientId+'.wav';
        row=await saveLocalRecording(captureOwner,{client_id:clientId,owner:captureOwner,uri,status:'recording',created_at:Date.now()/1000,duration_ms:0,prep_session:typeof context.sessionId==='string'?context.sessionId.slice(0,100):'',question_index:Number.isInteger(context.questionIndex)?context.questionIndex:-1});
        active.current=row;activeCaptures.add(clientId);
        checkStartContext();
        try {
          await speech.start(uri,clientId);
          if(!alive.current||ownerRef.current!==captureOwner){await stop(true);throw new Error('Your account changed. The partial recording was kept.');}
          if(nativeSave.current)return await nativeSave.current;
          lastDuration.current=0;seenRecording.current=true;
          setCurrent(row);setNativeStatus({isRecording:true,durationMillis:0,text:''});return row;
        } catch(error) {
          if(!alive.current||ownerRef.current!==captureOwner)throw error;
          const existing=await Files.getInfoAsync(uri);
          if(existing.exists&&existing.size>44){
            const result=await speech.stop(clientId,true);await finishNative({...result,message:error.message},row);
            throw new Error('On-device recording was interrupted. Your partial audio was kept.');
          }
          mode.current='pc';setEngineMessage('On-device speech could not start. PC transcription will be used.');nativeSave.current=null;
        }
      }
      checkStartContext();
      await setAudioModeAsync({allowsRecording:true,playsInSilentMode:true,shouldPlayInBackground:false,interruptionMode:'doNotMix'});
      checkStartContext();
      await recorder.prepareToRecordAsync(recordingOptions);
      checkStartContext();
      if(!recorder.uri)throw new Error('The microphone did not create a recording file.');
      row=await saveLocalRecording(captureOwner,{...row,client_id:clientId,owner:captureOwner,uri:recorder.uri,status:'recording',created_at:row?.created_at||Date.now()/1000,duration_ms:0,prep_session:typeof context.sessionId==='string'?context.sessionId.slice(0,100):'',question_index:Number.isInteger(context.questionIndex)?context.questionIndex:-1});
      active.current=row;activeCaptures.add(row.client_id);
      checkStartContext();
      lastDuration.current=0;seenRecording.current=false;
      recorder.record({forDuration:300});
      if(!recorder.getStatus().isRecording)throw new Error('The microphone did not start. Your partial recording was kept.');
      seenRecording.current=true;
      setCurrent(row);return row;
    } catch(error) {
      if(mode.current==='apple'&&active.current)await speech.stop(active.current.client_id,true).catch(()=>{});
      await recorder.stop().catch(()=>{});
      if(active.current){await saveLocalRecording(captureOwner,{...active.current,status:'interrupted'}).catch(()=>{});activeCaptures.delete(active.current.client_id);active.current=null;}
      await setAudioModeAsync({allowsRecording:false}).catch(()=>{});
      throw error;
    } finally {operation.current=false;}
  }
  async function pause(){
    if(!active.current||pausedRef.current||ending.current)return;
    pausedRef.current=true;
    try{if(mode.current==='apple')await speech.pause(active.current.client_id);else recorder.pause();setPaused(true);}
    catch(error){pausedRef.current=false;throw error;}
  }
  async function resume(){
    if(!active.current||!pausedRef.current||ending.current)return;
    if(mode.current==='apple')await speech.resume(active.current.client_id);else recorder.record();
    pausedRef.current=false;setPaused(false);
  }
  useEffect(()=>{
    alive.current=true;
    const nativeSubscription=speech?.addListener('capture',event=>{
      const row=active.current;
      if(!row||mode.current!=='apple'||event.id!==row.client_id)return;
      if(event.kind==='finished'){finishNative(event,row).catch(e=>{if(alive.current&&ownerRef.current===row.owner)setCaptureError(e.message);});return;}
      if(event.kind==='progress'){
        lastDuration.current=event.duration_ms;
        if(alive.current&&ownerRef.current===row.owner)setNativeStatus({isRecording:true,durationMillis:event.duration_ms,text:event.text||''});
      }
    });
    const subscription=AppState.addEventListener('change',value=>{
      if(value!=='active'&&active.current)stop().catch(e=>{if(alive.current)setCaptureError(e.message);});
    });
    return ()=>{alive.current=false;subscription.remove();nativeSubscription?.remove();if(active.current)stop().catch(()=>{});};
  },[]);
  useEffect(()=>{
    if(mode.current!=='apple'&&active.current&&!operation.current&&!pausedRef.current&&seenRecording.current&&!status.isRecording&&!recorder.getStatus().isRecording)stop().catch(e=>{if(alive.current)setCaptureError(e.message);});
  },[status.isRecording,status.durationMillis]);
  useEffect(()=>{setCurrent(null);setCaptureError('');setNativeStatus({isRecording:false,durationMillis:0,text:''});if(active.current&&active.current.owner!==owner)stop().catch(()=>{});},[owner]);
  return {start,stop,pause,resume,paused,current,recording:!paused&&(mode.current==='apple'?nativeStatus.isRecording:status.isRecording),elapsed:Math.max(current?.duration_ms||0,mode.current==='apple'?nativeStatus.durationMillis:status.durationMillis),liveText:nativeStatus.text,engineMessage,error:captureError};
}

export function AnswerPlayback({uri}) {
  const player=useAudioPlayer(uri||null),status=useAudioPlayerStatus(player);
  return React.createElement(Pressable,{accessibilityRole:'button',accessibilityLabel:status.playing?'Pause answer':'Play answer',onPress:()=>{if(status.playing)player.pause();else {if(status.didJustFinish)player.seekTo(0);player.play();}},style:{padding:20,borderRadius:24,backgroundColor:'#FFEFCB',alignItems:'center'}},React.createElement(Text,{style:{fontSize:18,color:'#342416'}},(status.playing?'Pause answer':'Play answer')+' · '+recordingClock((status.currentTime||0)*1000)));
}
