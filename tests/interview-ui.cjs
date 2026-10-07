// Real React component regression checks with synthetic browser/audio/network boundaries.
// This is not physical-device or actual HTTP/browser acceptance.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {createRequire}=require('node:module');
const dependencyRequire=createRequire(path.resolve(process.env.MAT5_REACT_MODULES||'../mat5-react-test','package.json'));
const React=dependencyRequire('react'),renderer=dependencyRequire('react-test-renderer');
const {act}=renderer;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
const code=fs.readFileSync('web/Interview.js','utf8').replace(/^import [^\n]+\n/gm,'').replace('export function Interview','function Interview');
const intervals=new Map();let clock=0,deny=false,upload,failedSave=false,session,retry;
const clone=x=>JSON.parse(JSON.stringify(x));
function fresh(){session={id:'interview-one',revision:0,data:{mode:'interview',job:{title:'SQL Tools',company:'Class team'},status:'active',turns:[],questions:[
 {kind:'role',question:'Describe your SQL investigation.',evidence:[{source:'listing',quote:'Build SQL tools'}]},
 {kind:'experience',question:'What did you personally do?',evidence:[{source:'listing',quote:'Build SQL tools'}]}],analysis:{},coaching:{},pending:''},run:{}};}
async function rpc(name,args={}){
 if(name==='interview_sessions')return{sessions:[clone(session)]};
 if(name==='interview_get'||name==='interview_create')return clone(session);
 if(name==='transcription_upload')return upload(args);
 if(name==='agent_respond'||name==='agent_retry'){retry={name,args};session.run.status='queued';return clone(session.run);}
 if(name==='interview_answer'){
  if(failedSave)throw new Error('Synthetic connection lost');
  session.data.turns.push({question:session.data.questions[session.data.turns.length],answer:args.answer,original:args.answer,recording_id:args.recording_id});session.revision++;return clone(session);
 }
 throw new Error('Unexpected RPC '+name);
}
let audio;
class Context{
 constructor(){this.sampleRate=16000;audio=this;}
 createMediaStreamSource(){return{connect(){},disconnect(){}};}
 createScriptProcessor(){return{connect(){},disconnect(){}};}
 close(){}
}
const sandbox={React,useEffect:React.useEffect,useRef:React.useRef,useState:React.useState,rpc,errorText:e=>e.message,
 crypto:require('node:crypto'),AudioContext:Context,ArrayBuffer,DataView,Uint8Array,Float32Array,btoa:x=>Buffer.from(x,'binary').toString('base64'),
 navigator:{mediaDevices:{getUserMedia:async()=>{if(deny)throw new Error('Denied');return{getTracks:()=>[{stop(){}}]};}}},
 document:{hidden:false,addEventListener(){},removeEventListener(){}},
 setTimeout:()=>0,clearTimeout(){},setInterval:fn=>{intervals.set(++clock,fn);return clock;},clearInterval:id=>intervals.delete(id)};
const {Interview}=vm.runInNewContext(code+'\n;({Interview,LocalRecording});',sandbox);
const text=node=>node.children.map(x=>typeof x==='string'?x:text(x)).join('');
const button=(root,label)=>root.root.findAllByType('button').find(n=>text(n)===label);
const answer=root=>root.root.findByProps({'aria-label':'Review your answer'});
const content=root=>JSON.stringify(root.toJSON());
async function click(root,label){const node=button(root,label);assert.ok(node,label);await act(async()=>{await node.props.onClick();});}
async function type(root,value){await act(async()=>{answer(root).props.onChange({target:{value}});});}
async function start(){fresh();deny=false;failedSave=false;intervals.clear();let root;
 await act(async()=>{root=renderer.create(React.createElement(Interview,{applications:[{id:'role',job:{title:'SQL Tools',company:'Class team'}}]}));});
 await act(async()=>{root.root.findByProps({'aria-label':'Saved role'}).props.onChange({target:{value:'role'}});});
 await click(root,'Start job interview');return root;
}
async function record(root){await click(root,'Record answer locally');await click(root,'Stop recording');}
(async()=>{
 let root=await start();await type(root,'Typed answer survives microphone denial.');deny=true;
 await click(root,'Record answer locally');assert.equal(answer(root).props.value,'Typed answer survives microphone denial.');assert.ok(content(root).includes('Microphone unavailable'));
 failedSave=true;await click(root,'Save reviewed answer and analyze');assert.equal(answer(root).props.value,'Typed answer survives microphone denial.');failedSave=false;
 await click(root,'Save reviewed answer and analyze');assert.equal(session.data.turns.length,1);await act(async()=>root.unmount());

 root=await start();await record(root);await type(root,'Typed while transcription runs.');
 upload=async()=>{throw new Error('Lost accepted response');};await click(root,'Upload for local transcription');
 assert.ok(button(root,'Upload for local transcription'),'failed upload retains recording for retry');
 upload=async()=>({id:'recording-one',status:'completed',transcript:'Previously completed transcript.'});await click(root,'Upload for local transcription');
 assert.equal(answer(root).props.value,'Typed while transcription runs.');assert.ok(button(root,'Use recorded transcript'));
 await click(root,'Use recorded transcript');assert.equal(answer(root).props.value,'Previously completed transcript.');
 await click(root,'Save reviewed answer and analyze');assert.equal(session.data.turns[0].recording_id,'recording-one');await act(async()=>root.unmount());

 root=await start();await record(root);await type(root,'Save typed answer while upload is in flight.');let resolveUpload;
 upload=()=>new Promise(resolve=>{resolveUpload=resolve;});let pending;
 await act(async()=>{pending=button(root,'Upload for local transcription').props.onClick();});
 await click(root,'Save reviewed answer and analyze');await type(root,'New answer draft.');
 await act(async()=>{resolveUpload({id:'old-recording',status:'completed',transcript:'Old session transcript.'});await pending;});
 assert.equal(answer(root).props.value,'New answer draft.');assert.ok(!button(root,'Use recorded transcript'));await act(async()=>root.unmount());

 for(const status of ['needs_input','blocked','failed']){
  root=await start();session.run={id:'local-run',status,message:'Synthetic recoverable model failure'};
  await act(async()=>{await root.root.findAllByType('button').find(n=>text(n).startsWith('SQL Tools')&&text(n).includes('answers')).props.onClick();});
  await click(root,'Retry local Qwen');assert.equal(retry.name,status==='needs_input'?'agent_respond':'agent_retry');assert.equal(retry.args.id,'local-run');
  if(status==='needs_input'){assert.equal(retry.args.reuse,false);assert.equal(retry.args.values.length,0);}
  assert.equal(session.run.status,'queued');await act(async()=>root.unmount());
 }

 root=await start();session.data.status='finished';session.data.coaching={summary:'Assessment uses reviewed excerpts.',strengths:[{criterion:'Verification',source:'answer:1',quote:'I inspected the plan.'}],
 rubric:[{criterion:'Specificity',score:2,feedback:'Explain your contribution.'}],next_exercises:['Describe a limitation.'],followup_questions:['What did you personally do?','How did you verify the result?'],evidence:[]};
 await act(async()=>{await root.root.findAllByType('button').find(n=>text(n).startsWith('SQL Tools')&&text(n).includes('answers')).props.onClick();});
 assert.ok(content(root).includes('Practice questions'));assert.ok(content(root).includes('How did you verify the result?'));assert.ok(content(root).includes('Model-selected strength to build on: Verification'));
 await act(async()=>root.unmount());console.log('PASS: microphone denial, connection retry, completed upload retry, draft preservation, stale upload isolation, model retry routing, visible final questions/strengths');
})().catch(error=>{console.error(error);process.exitCode=1;});
