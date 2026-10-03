// Native microphone + durable owner-isolated files; screen and server workflow live in Jac.
import {useEffect, useRef, useState} from 'react';
import {AppState, Platform} from 'react-native';
import {AudioModule, useAudioRecorder, useAudioRecorderState, setAudioModeAsync} from 'expo-audio';
import * as Files from 'expo-file-system/legacy';

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
      if(!name.startsWith(value.client_id+'.')||!safeUri(value.uri)) continue;
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
export function recordingClock(milliseconds) {
  const seconds=Math.max(0,Math.floor(milliseconds/1000));
  return String(Math.floor(seconds/60))+':'+String(seconds%60).padStart(2,'0');
}
export function useRecording(owner) {
  const recorder=useAudioRecorder(recordingOptions);
  const status=useAudioRecorderState(recorder,200);
  const [current,setCurrent]=useState(null),[captureError,setCaptureError]=useState('');
  const active=useRef(null),operation=useRef(false),alive=useRef(true);
  const ownerRef=useRef(owner);ownerRef.current=owner;
  const ending=useRef(null),seenRecording=useRef(false),lastDuration=useRef(0);
  if(status.isRecording){seenRecording.current=true;lastDuration.current=status.durationMillis;}
  async function stop() {
    if(ending.current) return ending.current;
    if(!active.current) return null;
    const row=active.current;
    ending.current=(async()=>{
      try {
        const duration=Math.max(lastDuration.current,recorder.getStatus().durationMillis||0);
        await recorder.stop();
        const saved=await saveLocalRecording(row.owner,{...row,uri:recorder.uri||row.uri,status:'ready',duration_ms:duration});
        active.current=null;seenRecording.current=false;
        if(alive.current&&ownerRef.current===row.owner)setCurrent(saved);
        return saved;
      } finally {
        activeCaptures.delete(row.client_id);active.current=null;seenRecording.current=false;
        await setAudioModeAsync({allowsRecording:false,shouldPlayInBackground:false}).catch(()=>{});
        ending.current=null;
      }
    })();
    return ending.current;
  }
  async function start() {
    if(operation.current||active.current) throw new Error('A recording is already in progress.');
    if(Platform.OS!=='ios') throw new Error('Audio recording is available on iPhone in this version.');
    operation.current=true;setCaptureError('');
    const captureOwner=owner;
    try {
      if((await localRecordings(captureOwner)).length>=50)throw new Error('Delete a saved phone recording before recording another.');
      const permission=await AudioModule.requestRecordingPermissionsAsync();
      if(!permission.granted)throw new Error('Microphone access is denied. Enable it for Stack in iPhone Settings.');
      if(!alive.current||ownerRef.current!==captureOwner)throw new Error('Your account changed. Record again after signing in.');
      await setAudioModeAsync({allowsRecording:true,playsInSilentMode:true,shouldPlayInBackground:false,interruptionMode:'doNotMix'});
      await recorder.prepareToRecordAsync(recordingOptions);
      if(!recorder.uri)throw new Error('The microphone did not create a recording file.');
      const row=await saveLocalRecording(captureOwner,{client_id:identifier(),owner:captureOwner,uri:recorder.uri,status:'recording',created_at:Date.now()/1000,duration_ms:0});
      active.current=row;activeCaptures.add(row.client_id);
      if(!alive.current||ownerRef.current!==captureOwner){await stop();throw new Error('Your account changed. The partial recording was kept.');}
      lastDuration.current=0;seenRecording.current=false;
      recorder.record({forDuration:300});
      if(!recorder.getStatus().isRecording)throw new Error('The microphone did not start. Your partial recording was kept.');
      seenRecording.current=true;
      setCurrent(row);
    } catch(error) {
      await recorder.stop().catch(()=>{});
      if(active.current){await saveLocalRecording(captureOwner,{...active.current,status:'interrupted'}).catch(()=>{});activeCaptures.delete(active.current.client_id);active.current=null;}
      await setAudioModeAsync({allowsRecording:false}).catch(()=>{});
      throw error;
    } finally {operation.current=false;}
  }
  useEffect(()=>{
    alive.current=true;
    const subscription=AppState.addEventListener('change',value=>{
      if(value!=='active'&&active.current)stop().catch(e=>{if(alive.current)setCaptureError(e.message);});
    });
    return ()=>{alive.current=false;subscription.remove();if(active.current)stop().catch(()=>{});};
  },[]);
  useEffect(()=>{
    if(active.current&&!operation.current&&seenRecording.current&&!status.isRecording&&!recorder.getStatus().isRecording)stop().catch(e=>{if(alive.current)setCaptureError(e.message);});
  },[status.isRecording,status.durationMillis]);
  useEffect(()=>{if(active.current&&active.current.owner!==owner)stop().catch(()=>{});},[owner]);
  return {start,stop,current,recording:status.isRecording,elapsed:status.durationMillis,error:captureError};
}
