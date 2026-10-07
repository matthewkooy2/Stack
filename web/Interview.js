import React,{useEffect,useRef,useState} from 'react';
import {rpc,errorText} from './transport.js';
const h=React.createElement;
const uid=()=>crypto.randomUUID();

function LocalRecording({onTranscript}){
 const [status,setStatus]=useState(''),[active,setActive]=useState(false),[saved,setSaved]=useState(null),[audio,setAudio]=useState(null);
 const resources=useRef(null),requestId=useRef(''),busy=useRef(false),mounted=useRef(true),starting=useRef(false);
 const callback=useRef(onTranscript);callback.current=onTranscript;
 function stop(){
  const r=resources.current;if(!r)return;resources.current=null;
  clearTimeout(r.timer);r.processor.disconnect();r.source.disconnect();r.stream.getTracks().forEach(t=>t.stop());r.context.close();setActive(false);
  const samples=r.parts.reduce((n,p)=>n+p.length,0),buffer=new ArrayBuffer(44+samples*2),view=new DataView(buffer);
  const text=(at,s)=>{for(let i=0;i<s.length;i++)view.setUint8(at+i,s.charCodeAt(i));};
  text(0,'RIFF');view.setUint32(4,36+samples*2,true);text(8,'WAVE');text(12,'fmt ');view.setUint32(16,16,true);view.setUint16(20,1,true);view.setUint16(22,1,true);view.setUint32(24,16000,true);view.setUint32(28,32000,true);view.setUint16(32,2,true);view.setUint16(34,16,true);text(36,'data');view.setUint32(40,samples*2,true);
  let at=44;for(const part of r.parts)for(const x of part){view.setInt16(at,Math.max(-1,Math.min(1,x))*32767,true);at+=2;}
  requestId.current=uid();setAudio(new Uint8Array(buffer));setStatus('Recording stopped. Upload it for local transcription or keep typing.');
 }
 useEffect(()=>{mounted.current=true;const interrupted=()=>{if(document.hidden)stop();};document.addEventListener('visibilitychange',interrupted);return()=>{mounted.current=false;document.removeEventListener('visibilitychange',interrupted);const r=resources.current;if(r){clearTimeout(r.timer);r.processor.disconnect();r.source.disconnect();r.stream.getTracks().forEach(t=>t.stop());r.context.close();}};},[]);
 async function start(){
  if(starting.current||resources.current)return;starting.current=true;
  let stream,context;try{
   stream=await navigator.mediaDevices.getUserMedia({audio:true,video:false});
   if(!mounted.current||document.hidden){stream.getTracks().forEach(t=>t.stop());return;}
   context=new AudioContext({sampleRate:16000});
   if(context.sampleRate!==16000)throw new Error('16 kHz recording is unavailable. Type your answer or upload a supported WAV.');
   const source=context.createMediaStreamSource(stream),processor=context.createScriptProcessor(4096,1,1),parts=[];
   processor.onaudioprocess=e=>parts.push(new Float32Array(e.inputBuffer.getChannelData(0)));
   source.connect(processor);processor.connect(context.destination);resources.current={stream,context,source,processor,parts,timer:setTimeout(stop,300000)};
   setAudio(null);setSaved(null);setActive(true);setStatus('Recording locally. Stop to review a transcript. Five minute limit.');
  }catch(e){stream?.getTracks().forEach(t=>t.stop());context?.close();if(mounted.current)setStatus('Microphone unavailable. Your typed answer is still available. '+errorText(e));}finally{starting.current=false;}
 }
 async function upload(){if(!audio||busy.current)return;busy.current=true;try{
  let binary='';for(let i=0;i<audio.length;i+=8192)binary+=String.fromCharCode(...audio.subarray(i,i+8192));
  const result=await rpc('transcription_upload',{client_id:requestId.current,content:btoa(binary)});if(!mounted.current)return;setSaved(result);setAudio(null);
  if(result.status==='completed'){callback.current(result.transcript,result.id);setStatus('Review and correct the transcript before submitting.');}
  else setStatus('Saved for local transcription. You can type while it runs.');
 }catch(e){if(mounted.current)setStatus('Upload failed; recording retained here. Retry upload or type. '+errorText(e));}finally{busy.current=false;}}
 useEffect(()=>{if(!saved||['completed','failed','cancelled'].includes(saved.status))return;let alive=true;const timer=setInterval(async()=>{try{const result=await rpc('transcription_get',{id:saved.id});if(!alive)return;setSaved(result);if(result.status==='completed'){callback.current(result.transcript,result.id);setStatus('Review and correct the transcript before submitting.');}else if(result.error)setStatus(result.error+' You can type instead.');}catch(e){if(alive)setStatus('Reconnect to retrieve your saved recording. '+errorText(e));}},1500);return()=>{alive=false;clearInterval(timer);};},[saved?.id,saved?.status]);
 return h('div',{},h('p',{},'Optional recording uses Stack’s local transcription worker. Review text before submitting. You can always type.'),h('button',{onClick:active?stop:start},active?'Stop recording':'Record answer locally'),audio&&h('button',{onClick:upload},'Upload for local transcription'),h('p',{'role':'status'},status));
}

export function Interview({applications}){
 const [sessions,setSessions]=useState([]),[current,setCurrent]=useState(null),[role,setRole]=useState(''),[draft,setDraft]=useState(''),[recording,setRecording]=useState(''),[error,setError]=useState(''),[busy,setBusy]=useState(false),[correction,setCorrection]=useState(-1),[edited,setEdited]=useState('');
 const [transcript,setTranscript]=useState(null);
 const createId=useRef(uid()),answerId=useRef(uid()),lock=useRef(false),epoch=useRef(0);
 async function list(){const result=await rpc('interview_sessions');setSessions(result.sessions);}
 useEffect(()=>{list().catch(e=>setError(errorText(e)));return()=>{epoch.current++;};},[]);
 async function open(id){const generation=++epoch.current;try{const result=await rpc('interview_get',{id});if(generation!==epoch.current)return;setCurrent(result);if(current?.id!==id){setDraft('');setRecording('');setTranscript(null);answerId.current=uid();}setCorrection(-1);setError('');}catch(e){setError(errorText(e));}}
 useEffect(()=>{if(!current?.id)return;const id=current.id;let alive=true;const timer=setInterval(async()=>{if(lock.current)return;try{const result=await rpc('interview_get',{id});if(alive)setCurrent(result);}catch(e){if(alive)setError('Connection failed. Your draft is retained; reopen after reconnecting. '+errorText(e));}},1500);return()=>{alive=false;clearInterval(timer);};},[current?.id]);
 async function act(name,args,clear=false){if(lock.current)return;lock.current=true;setBusy(true);setError('');try{const result=await rpc(name,args);setCurrent(result);if(clear){setDraft('');setRecording('');setTranscript(null);answerId.current=uid();setCorrection(-1);}await list();return result;}catch(e){setError(errorText(e));}finally{lock.current=false;setBusy(false);}}
 const data=current?.data,turns=data?.turns||[],question=data?.questions[turns.length],run=current?.run,analysis=data?.analysis[String(turns.length)];
 function action(action){return act('interview_continue',{id:current.id,revision:current.revision,action});}
 return h('section',{'aria-label':'Job-specific mock interview'},
  h('h2',{},'Job-specific mock interview'),h('p',{},'Short interview: up to six reviewed answers. Analysis and coaching use local Qwen. Saved role and confirmed resume facts guide questions. Native iPhone acceptance is still pending.'),
  h('label',{},'Saved role',h('select',{'aria-label':'Saved role',value:role,onChange:e=>{setRole(e.target.value);createId.current=uid();}},h('option',{value:''},'Choose a saved role'),...applications.map(a=>h('option',{key:a.id,value:a.id},a.job.title+' · '+(a.job.company||''))))),
  h('button',{disabled:busy||!role,onClick:async()=>{const result=await act('interview_create',{application_id:role,client_id:createId.current});if(result){epoch.current++;setDraft('');setRecording('');setTranscript(null);setCorrection(-1);answerId.current=uid();createId.current=uid();}}},'Start job interview'),
  h('div',{},h('h3',{},'Saved interviews'),...sessions.map(s=>h('button',{key:s.id,disabled:busy,onClick:()=>open(s.id)},s.data.job.title+' · '+s.data.turns.length+' answers · '+s.data.status))),
  error&&h('p',{role:'alert'},error),
  data&&h('div',{},h('h3',{},data.job.title+' interview'),h('p',{},'Session '+data.status+' · '+turns.length+' reviewed answers'),
   run&&run.id&&h('div',{},h('p',{role:'status'},run.message),['needs_input','blocked','failed'].includes(run.status)&&h('button',{disabled:busy,onClick:async()=>{try{await rpc(run.status==='needs_input'?'agent_respond':'agent_retry',run.status==='needs_input'?{id:run.id,values:[],reuse:false}:{id:run.id});setCurrent(await rpc('interview_get',{id:current.id}));}catch(e){setError(errorText(e));}}},'Retry local Qwen')),
   analysis&&h('article',{},h('h4',{},'Answer coaching'),h('p',{},'Model-selected strength to build on: '+analysis.strength),h('p',{},analysis.improvement),h('blockquote',{},analysis.focus_quote),h('button',{disabled:busy||turns.length>=6||data.status!=='active',onClick:()=>action('followup')},'Ask answer follow-up')),
   data.status==='active'&&question&&turns.length<6&&h('article',{},h('h4',{},'Current question'),h('p',{},question.question),...question.evidence.map((e,i)=>h('blockquote',{key:i},e.source+': '+e.quote)),
    h('label',{},'Review your answer',h('textarea',{'aria-label':'Review your answer',value:draft,maxLength:4000,onChange:e=>setDraft(e.target.value)})),
    h(LocalRecording,{key:current.id+':'+turns.length,onTranscript:(text,id)=>{if(draft.trim()){setTranscript({text,id});}else{setDraft(text);setRecording(id);}}}),
    transcript&&h('div',{},h('p',{},'Your recorded transcript is ready. Your typed draft has been preserved.'),h('blockquote',{},transcript.text),h('button',{onClick:()=>{setDraft(transcript.text);setRecording(transcript.id);setTranscript(null);}},'Use recorded transcript')),
    data.pending?h('button',{disabled:busy,onClick:()=>action('next')},'Continue with typed role question'):h('button',{disabled:busy||!draft.trim(),onClick:()=>act('interview_answer',{id:current.id,revision:current.revision,answer:draft,client_id:answerId.current,recording_id:recording},true)},'Save reviewed answer and analyze')),
   turns.length>0&&!data.pending&&!analysis&&h('button',{disabled:busy,onClick:()=>action('analyze')},data.status==='finished'?'Get local Qwen coaching':'Analyze reviewed answer'),
   h('h3',{},'Reviewed transcript'),...turns.map((t,i)=>h('article',{key:i},h('h4',{},'Answer '+(i+1)),h('p',{},t.question.question),h('p',{},t.answer),t.original!==t.answer&&h('details',{},h('summary',{},'Original transcript'),h('p',{},t.original)),h('button',{disabled:busy,onClick:()=>{setCorrection(i);setEdited(t.answer);}},'Correct answer '+(i+1)),correction===i&&h('div',{},h('textarea',{'aria-label':'Corrected answer',value:edited,maxLength:4000,onChange:e=>setEdited(e.target.value)}),h('button',{disabled:busy||!edited.trim(),onClick:()=>act('interview_correct',{id:current.id,revision:current.revision,index:i,answer:edited},true)},'Save transcript correction')))),
   data.status==='active'&&h('button',{disabled:busy||turns.length<2,onClick:()=>action('finish')},'Finish interview'),
   data.status==='finished'&&!data.pending&&h('button',{disabled:busy,onClick:()=>action('analyze')},'Get final coaching'),
   data.coaching?.summary&&h('article',{},h('h3',{},'Final coaching'),h('p',{},data.coaching.summary),...data.coaching.strengths.map((s,i)=>h('div',{key:'s'+i},h('p',{},'Model-selected strength to build on: '+s.criterion),h('blockquote',{},s.source+': '+s.quote))),...Object.entries(data.coaching.rubric).map(([criterion,r])=>h('p',{key:criterion},criterion+' '+r.score+'/4: '+r.feedback)),...data.coaching.next_exercises.map((x,i)=>h('p',{key:'x'+i},x)),h('h4',{},'Practice questions'),...data.coaching.followup_questions.map((q,i)=>h('p',{key:'q'+i},q)),...data.coaching.evidence.map((e,i)=>h('blockquote',{key:'e'+i},e.source+': '+e.quote+' - '+e.claim)))
  ));
}
