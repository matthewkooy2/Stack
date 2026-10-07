// Browser capabilities only. Session tokens stay in memory; reload signs out.
import React, {useRef, useState, useEffect} from 'react';
import {beginGoogle,finishGoogle} from './google-auth.js';
let token = '', epoch = 0;
const browserStreams=new Set();
export async function request(path, body, authenticated=true) {
  const observed=epoch;
  const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json',...(authenticated?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(25000)});
  const result=await response.json();
  if(observed!==epoch)throw new Error('Session changed.');
  if(!response.ok||result.ok===false)throw new Error(result.error?.message||'Request failed.');
  return result.data;
}
export async function rpc(name,args={}){const result=(await request('/function/'+name,args)).result;if(result?.error)throw new Error(result.error);return result;}
export async function login(username,password,signup=false){
  const identity={type:'username',value:username.trim().toLowerCase()},credential={type:'password',password};
  const result=await request(signup?'/user/register':'/user/login',signup?{identities:[identity],credential}:{identity,credential},false);
  if(!result.token)throw new Error('No session returned.');token=result.token;epoch++;
}
export function logout(){token='';epoch++;for(const close of browserStreams)close();browserStreams.clear();}
export async function googleSignIn(invite='',link=false){return beginGoogle(request,invite,link);}
export async function googleSignInResult(){
  const observed=epoch,result=await finishGoogle(request);
  if(!result)return null;
  if(observed!==epoch)throw new Error('Your session changed. Start Google sign-in again.');
  token=result.token;epoch++;return result;
}
export function errorText(e){return e?.message||'Request failed.';}
export function oauthResult(){if(location.pathname!=='/oauth/google')return {};const q=new URLSearchParams(location.search);const result={code:q.get('code')||'',state:q.get('state')||''};if(result.code)history.replaceState(null,'',location.pathname);return result;}
export function downloadJSON(value){const url=URL.createObjectURL(new Blob([JSON.stringify(value,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='stack-export.json';a.click();URL.revokeObjectURL(url);}
export function downloadPDF(pdf){const raw=Uint8Array.from(atob(pdf.content),c=>c.charCodeAt(0));const url=URL.createObjectURL(new Blob([raw],{type:'application/pdf'}));const a=document.createElement('a');a.href=url;a.download=pdf.name;a.click();URL.revokeObjectURL(url);}
export function Timer({seconds=0,onChange}){
 const [value,setValue]=useState(seconds),[running,setRunning]=useState(false);const callback=useRef(onChange);callback.current=onChange;
 useEffect(()=>{if(!running)return;const t=setInterval(()=>setValue(v=>{callback.current(v+1);return v+1;}),1000);return()=>clearInterval(t);},[running]);
 return React.createElement('button',{onClick:()=>setRunning(!running),type:'button'},`${running?'Pause':'Start'} timer · ${Math.floor(value/60)}:${String(value%60).padStart(2,'0')}`);
}
export function Diagram({value,onChange}){
 const [selected,setSelected]=useState('');const svg=useRef();
 const nodes=value?.nodes||[],edges=value?.edges||[];
 function click(e){const r=svg.current.getBoundingClientRect();const x=(e.clientX-r.left)*900/r.width,y=(e.clientY-r.top)*420/r.height;const id=crypto.randomUUID();const label=prompt('Component name');if(label)onChange({nodes:[...nodes,{id,label:label.slice(0,60),x,y}],edges});}
 return React.createElement('div',{},React.createElement('p',{},'Click blank space to add a component. Select two components to connect them.'),React.createElement('svg',{ref:svg,viewBox:'0 0 900 420',className:'diagram',onClick:click,role:'img','aria-label':'System design canvas'},
 ...edges.map((e,i)=>{const a=nodes.find(n=>n.id===e.from),b=nodes.find(n=>n.id===e.to);return a&&b?React.createElement('line',{key:i,x1:a.x,y1:a.y,x2:b.x,y2:b.y,stroke:'#3765e8',strokeWidth:2}):null;}),
 ...nodes.map(n=>React.createElement('g',{key:n.id,onClick:e=>{e.stopPropagation();if(selected&&selected!==n.id){onChange({nodes,edges:[...edges,{from:selected,to:n.id}]});setSelected('');}else setSelected(n.id);}},React.createElement('rect',{x:n.x-65,y:n.y-22,width:130,height:44,rx:8,fill:selected===n.id?'#dbe7ff':'white',stroke:'#3765e8'}),React.createElement('text',{x:n.x,y:n.y+5,textAnchor:'middle',fontSize:13},n.label)))),React.createElement('button',{onClick:()=>onChange({nodes:[],edges:[]})},'Clear diagram'));
}
export function BrowserView({image,onEvent,sessionId,onFrame}){
 const controller=useRef('viewer-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2)),sequence=useRef(0),control=useRef({}),safe=useRef(true),receipt=useRef(null),frameCallback=useRef(onFrame),[connection,setConnection]=useState('connecting'),[age,setAge]=useState(Infinity);
 if(image?.control&&(image.control.instance!==control.current.instance||image.control.generation>=control.current.generation))control.current=image.control;frameCallback.current=onFrame;
 const owned=control.current.mode==='user'&&control.current.controller===controller.current;
 useEffect(()=>{
  if(!sessionId)return;
  let closed=false,xhr=null,timer=null;const observed=epoch;
  const connect=()=>{
   if(closed||observed!==epoch)return;setConnection('connecting');
   const r=new XMLHttpRequest();xhr=r;let cursor=0,tail='';r.open('POST','/browser/stream');r.setRequestHeader('Content-Type','application/json');r.setRequestHeader('Authorization','Bearer '+token);r.timeout=35000;
   const read=()=>{if(closed||observed!==epoch)return;if(r.status!==200)return;tail+=(r.responseText||'').slice(cursor);cursor=(r.responseText||'').length;if(tail.length>1024*1024){r.abort();return;}let end;while((end=tail.indexOf('\n\n'))>=0){const chunk=tail.slice(0,end);tail=tail.slice(end+2);try{if(chunk.startsWith('data: ')){const event=JSON.parse(chunk.slice(6));if(event.control.instance===control.current.instance&&event.control.generation<control.current.generation)continue;if(event.control.instance!==control.current.instance)sequence.current=0;control.current=event.control;sequence.current=Math.max(sequence.current,event.control.sequence||0);receipt.current={at:Date.now(),age:Math.max(0,(event.server_time-(event.observed_at||0))*1000)};setAge(receipt.current.age);setConnection('connected');frameCallback.current?.({...(event.frame||{}),control:event.control});}}catch{setConnection('unavailable');r.abort();}}};
   const finish=()=>{if(closed)return;if(r.status===401||r.status===403){setConnection('unavailable');return;}setConnection('reconnecting');timer=setTimeout(connect,500);};
   r.onprogress=read;r.onload=()=>{read();finish();};r.onerror=r.ontimeout=finish;r.send(JSON.stringify({id:sessionId}));
  };
  const clock=setInterval(()=>setAge(receipt.current?receipt.current.age+Date.now()-receipt.current.at:Infinity),500);const close=()=>{closed=true;clearTimeout(timer);clearInterval(clock);xhr?.abort();};browserStreams.add(close);connect();return()=>{close();browserStreams.delete(close);};
 },[sessionId]);
 async function action(type){
  try {if(type==='resume'){flush();await queue.current;if(!safe.current)throw new Error('Take control again to confirm your input before resuming.');}else{clearTimeout(timer.current);text.current='';}
   const result=await callback.current({type,generation:control.current.generation,instance:control.current.instance,controller:controller.current});
   if(result?.error)throw new Error(result.error);
   if(result?.control){control.current=result.control;sequence.current=result.control.sequence||0;if(type==='take'){safe.current=true;setInputError('');}}
  }catch(e){setInputError(e.message||'Control could not be confirmed. Reconnect before continuing.');}
 }

 const keyboard=useRef(null),callback=useRef(onEvent),queue=useRef(Promise.resolve()),text=useRef(''),timer=useRef(null),alive=useRef(true),composing=useRef(false);
 const [sending,setSending]=useState(false),[inputError,setInputError]=useState('');
 callback.current=onEvent;
 useEffect(()=>{alive.current=true;return()=>{alive.current=false;clearTimeout(timer.current);timer.current=null;text.current='';if(keyboard.current)keyboard.current.value='';};},[]);
 function send(event){
  if(!alive.current||!safe.current||control.current.mode!=='user'||control.current.controller!==controller.current||connection!=='connected'||age>=5000)return;
  const authority={generation:control.current.generation,instance:control.current.instance,controller:controller.current};
  setSending(true);
  queue.current=queue.current.then(async()=>{if(alive.current&&safe.current&&authority.generation===control.current.generation&&authority.instance===control.current.instance){const result=await callback.current({...event,...authority,sequence:++sequence.current});if(result?.error)throw new Error(result.error);}}).catch(()=>{if(alive.current){safe.current=false;setInputError('Input was not confirmed. Take control again before continuing.');}});
  const latest=queue.current;latest.then(()=>{if(alive.current&&queue.current===latest)setSending(false);});
 }
 function flush(){clearTimeout(timer.current);timer.current=null;const value=text.current;text.current='';if(value)send({type:'text',text:value});}
 function insert(value){
  if(!value)return;
  if(text.current.length+value.length>8000){setInputError('Paste up to 8,000 characters at a time.');return;}
  text.current+=value;clearTimeout(timer.current);timer.current=setTimeout(flush,35);
 }
 function keyDown(e){
  if(e.isComposing||e.nativeEvent?.isComposing)return;
  if(['Tab','Enter','Backspace','Escape','ArrowDown','ArrowUp'].includes(e.key)){
   e.preventDefault();flush();send({type:'key',key:e.key});
  }
 }
 function input(e){if(composing.current||e.nativeEvent?.isComposing)return;const value=e.currentTarget.value;e.currentTarget.value='';insert(value);}
 function paste(e){e.preventDefault();insert(e.clipboardData.getData('text/plain'));flush();}
 return React.createElement('div',{},
 React.createElement('p',{'aria-live':'polite'},connection==='connected'?(!safe.current?'Input unconfirmed':age>=5000?'Waiting for a fresh view…':owned?'You have control':control.current.mode==='pausing'?'Pausing agent…':control.current.mode==='stopped'?'Task stopped':'Agent is working'):'Reconnecting…'),
 React.createElement('div',{},React.createElement('button',{onClick:()=>action(owned&&safe.current?'resume':'take'),disabled:sending||connection!=='connected'||!['agent','user'].includes(control.current.mode)},owned&&safe.current?'Resume agent':'Take control'),React.createElement('button',{onClick:()=>action('stop'),disabled:['stopping','stopped'].includes(control.current.mode)},'Stop task')),
 image?.url?React.createElement('p',{},'Browser: '+image.url):null,
 image?.image?React.createElement('div',{},
  React.createElement('p',{},'Click inside the browser, then type or paste. Enter and Tab work here.'),
  React.createElement('div',{style:{position:'relative',maxWidth:image.width||430,width:'100%',margin:'0 auto'}},
   React.createElement('img',{src:'data:image/jpeg;base64,'+image.image,alt:'Your task browser',draggable:false,style:{display:'block',width:'100%',border:'1px solid #ccc',cursor:owned?'text':'default',pointerEvents:owned&&safe.current&&connection==='connected'&&age<5000?'auto':'none'},onClick:e=>{const r=e.currentTarget.getBoundingClientRect();keyboard.current?.focus({preventScroll:true});flush();send({type:'click',x:(e.clientX-r.left)*image.width/r.width,y:(e.clientY-r.top)*image.height/r.height});}}),
   React.createElement('textarea',{ref:keyboard,disabled:!owned||!safe.current||connection!=='connected'||age>=5000,'aria-label':'Task browser keyboard',autoComplete:'off',autoCorrect:'off',autoCapitalize:'none',spellCheck:false,style:{position:'absolute',width:1,height:1,opacity:0,pointerEvents:'none',top:0,left:0,padding:0,border:0},onKeyDown:keyDown,onInput:input,onPaste:paste,onCompositionStart:()=>{composing.current=true;},onCompositionEnd:e=>{composing.current=false;input(e);}})),
  React.createElement('p',{'aria-live':'polite',style:{minHeight:'1.4em'}},inputError||(sending?'Sending input…':''))):null,
 React.createElement('button',{onClick:()=>{flush();send({type:'scroll',dy:500});}},'Scroll down'),React.createElement('button',{onClick:()=>{flush();send({type:'snapshot'});}},'Refresh browser'),image?.private_login?React.createElement('button',{onClick:()=>{flush();send({type:'reload'});}},'Reload my profile'):null);
}
export function Recorder({onTranscript}){
 const [recording,setRecording]=useState(false),[message,setMessage]=useState('');const recognition=useRef();
 useEffect(()=>()=>recognition.current?.abort(),[]);
 function start(){const Speech=window.SpeechRecognition||window.webkitSpeechRecognition;if(!Speech){setMessage('Speech transcription is unavailable in this browser. You can type or paste a transcript.');return;}
  const r=new Speech();recognition.current=r;r.continuous=true;r.interimResults=false;r.lang='en-US';r.onresult=e=>{let text='';for(let i=0;i<e.results.length;i++)text+=e.results[i][0].transcript+' ';onTranscript(text.trim());};r.onend=()=>setRecording(false);r.onerror=()=>{setMessage('Microphone or transcription was unavailable.');setRecording(false);};r.start();setRecording(true);
 }
 return React.createElement('div',{},React.createElement('p',{},'Browser speech recognition may send audio to your browser’s provider. Stack saves only the transcript you review.'),React.createElement('button',{onClick:()=>recording?recognition.current.stop():start()},recording?'Stop spoken answer':'Start spoken answer'),React.createElement('p',{},message));
}

export function LiveInterview({sessionId,onTranscript}){
 const [status,setStatus]=useState(''),[active,setActive]=useState(false),[listening,setListening]=useState(false);
 const resources=useRef(null),transcript=useRef('');
 const callback=useRef(onTranscript);callback.current=onTranscript;
 function stop(){const r=resources.current;if(!r)return;resources.current=null;r.socket?.close();r.source?.disconnect();r.processor?.disconnect();r.stream?.getTracks().forEach(t=>t.stop());r.context?.close();for(const node of r.playing||[])try{node.stop();}catch{}setActive(false);setListening(false);}
 useEffect(()=>()=>stop(),[sessionId]);
 async function start(){
  let stream;
  try{
   stream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true},video:false});
   const ticket=await rpc('prep_live',{id:sessionId});
   const context=new AudioContext();await context.resume();
   const socket=new WebSocket(ticket.url);const r={socket,context,stream,playing:[],cursor:0,capture:false,ready:false,spokenAt:0,answerReady:false,complete:false};resources.current=r;
   transcript.current='';setActive(true);setStatus('Connecting to your interviewer…');
   const source=context.createMediaStreamSource(stream),processor=context.createScriptProcessor(4096,1,1);r.source=source;r.processor=processor;
   processor.onaudioprocess=e=>{
    if(!r.ready||!r.capture||socket.readyState!==WebSocket.OPEN||socket.bufferedAmount>192000)return;
    const samples=e.inputBuffer.getChannelData(0),ratio=context.sampleRate/24000,pcm=new Int16Array(Math.floor(samples.length/ratio));
    for(let i=0;i<pcm.length;i++){const position=i*ratio,index=Math.floor(position),fraction=position-index;const sample=samples[index]*(1-fraction)+(samples[Math.min(index+1,samples.length-1)]||0)*fraction;pcm[i]=Math.max(-32768,Math.min(32767,Math.round(sample*32767)));}
    let binary='';for(const byte of new Uint8Array(pcm.buffer))binary+=String.fromCharCode(byte);
    socket.send(JSON.stringify({type:'audio',audio:btoa(binary)}));
   };
   const silent=context.createGain();silent.gain.value=0;source.connect(processor);processor.connect(silent);silent.connect(context.destination);
   socket.onopen=()=>socket.send(JSON.stringify({id:ticket.id,owner:ticket.owner,ticket:ticket.ticket}));
   socket.onmessage=e=>{
    const event=JSON.parse(e.data);
    if(event.type==='ready'){r.ready=true;setStatus('Your interviewer is preparing a question.');}
    if(event.type==='audio'){
     r.capture=false;setListening(false);setStatus('Interviewer speaking. You can interrupt.');
     const raw=Uint8Array.from(atob(event.audio),c=>c.charCodeAt(0)),pcm=new Int16Array(raw.buffer),buffer=context.createBuffer(1,pcm.length,24000),samples=buffer.getChannelData(0);
     for(let i=0;i<pcm.length;i++)samples[i]=pcm[i]/32768;
     const node=context.createBufferSource();node.buffer=buffer;node.connect(context.destination);r.cursor=Math.max(context.currentTime,r.cursor);if(!r.spokenAt)r.spokenAt=r.cursor;node.start(r.cursor);r.cursor+=buffer.duration;r.playing.push(node);node.onended=()=>{r.playing=r.playing.filter(n=>n!==node);if(!r.playing.length&&r.answerReady&&!r.complete){r.capture=true;setListening(true);setStatus('Answer aloud, then choose Finish answer.');}};
    }
    if(event.type==='listening'){r.answerReady=true;if(!r.playing.length){r.capture=true;setListening(true);setStatus('Answer aloud, then choose Finish answer.');}}
    if(event.type==='complete'){r.complete=true;r.capture=false;setListening(false);setStatus('Interview complete. End the session, then review and save your transcript.');}
    if(event.type==='transcript'){transcript.current+=(transcript.current?'\n':'')+event.text;callback.current(transcript.current);}
    if(event.type==='error'){setStatus(event.message);stop();}
   };
   socket.onclose=()=>{setStatus('Interview ended. Review and save your transcript before coaching.');stop();};
   socket.onerror=()=>{setStatus('The live connection is unavailable. Your transcript remains editable.');stop();};
  }catch(e){stream?.getTracks().forEach(t=>t.stop());setStatus(errorText(e));stop();}
 }
 function interrupt(){const r=resources.current;if(!r||r.complete)return;const played=Math.max(0,(r.context.currentTime-r.spokenAt)*1000);for(const node of r.playing)try{node.stop();}catch{}r.playing=[];r.cursor=0;r.capture=true;r.socket.send(JSON.stringify({type:'interrupt',played_ms:Math.floor(played)}));setListening(true);setStatus('Listening. Finish your answer when ready.');}
 function answer(){const r=resources.current;if(!r)return;r.capture=false;r.answerReady=false;r.spokenAt=0;setListening(false);r.socket.send(JSON.stringify({type:'answer'}));setStatus('Considering your answer…');}
 return React.createElement('section',{},React.createElement('h3',{},'Live mock interview'),React.createElement('p',{},'Audio is sent to the interview provider while this session is open. Five minutes, up to eight interviewer responses. Stack stores your transcript, not raw audio.'),
  active?React.createElement('div',{},React.createElement('button',{onClick:interrupt},'Interrupt'),React.createElement('button',{onClick:answer,disabled:!listening},'Finish answer'),React.createElement('button',{onClick:()=>{resources.current?.socket.send(JSON.stringify({type:'end'}));stop();}},'End interview')):React.createElement('button',{onClick:start},'Start live interviewer'),React.createElement('p',{role:'status'},status));
}

// Refreshes agent progress while the tab is visible; the callback decides what is safe to replace.
export function Poll({onTick,seconds=5}){
 const callback=useRef(onTick);callback.current=onTick;
 useEffect(()=>{const t=setInterval(()=>{if(document.visibilityState==='visible')callback.current();},seconds*1000);return()=>clearInterval(t);},[seconds]);
 return null;
}
export function isoTime(value){const d=new Date(value);return value&&!isNaN(d)?d.toLocaleString():'Time not stated';}
export function confirmAccountDelete(){return window.confirm('Delete your Stack account, applications, PDFs, and practice data? This cannot be undone. External submissions and messages cannot be recalled.');}
