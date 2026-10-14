// Actual generated Jac screen/runtime and native adapter; OS boundaries mocked.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {createRequire}=require('node:module');
const root=path.resolve(__dirname,'..'),req=createRequire(path.join(process.env.MAT5_NATIVE_MODULES||path.join(root,'.jac/mobile-rn'),'package.json'));
const React=req('react'),renderer=req('react-test-renderer'),babel=req('@babel/core'),{act}=renderer;
globalThis.IS_REACT_ACT_ENVIRONMENT=true;
const intervalFns=new Map(),realInterval=global.setInterval,realClear=global.clearInterval;
global.setInterval=fn=>{const id={};intervalFns.set(id,fn);return id;};global.clearInterval=id=>intervalFns.delete(id);
const documents=new Map(),permissions={granted:true},listeners=new Set(),recorders=[];
let microphonePrompts=0,uploadFailure=false,forceManifestFailure=false,uploads=[],records=[],holdingGet=null,holdingSave=null;
const primitive=name=>props=>React.createElement(name,props,props.children);
// Animated stand-in: every animation completes immediately and is counted, so the harness can prove motion ran.
const motion=(()=>{const started={timing:0,spring:0,loop:0,loopStop:0};const run=kind=>()=>({start(done){started[kind]++;done?.({finished:true});},stop(){}});
  class Value{constructor(v){this.v=v;}setValue(v){this.v=v;}interpolate(){return this;}toJSON(){return this.v;}}
  const view=name=>props=>React.createElement(name,props,props.children);
  return {started,Animated:{Value,View:view('AnimatedView'),timing:run('timing'),spring:run('spring'),loop:()=>({start(){started.loop++;},stop(){started.loopStop++;}}),sequence:()=>({}),createAnimatedComponent:C=>C},
    Easing:{bezier:()=>x=>x,out:f=>f,quad:x=>x,inOut:f=>f,sin:x=>x},AccessibilityInfo:{isReduceMotionEnabled:async()=>false,addEventListener:()=>({remove(){}})}};})();
const RN={View:primitive('View'),Text:primitive('Text'),Pressable:primitive('Pressable'),TextInput:primitive('TextInput'),
  Platform:{OS:'ios',select:v=>v.ios||v.default},StyleSheet:{create:v=>v},
  Linking:{openSettings(){}},Alert:{alert(){}},
  AppState:{addEventListener:(event,fn)=>{listeners.add(fn);return {remove:()=>listeners.delete(fn)};}},
  useWindowDimensions:()=>({width:390,height:844}),Animated:motion.Animated,Easing:motion.Easing,AccessibilityInfo:motion.AccessibilityInfo,

  PanResponder:{create:()=>({panHandlers:{}})}};
const files={documentDirectory:'file://docs/',cacheDirectory:'file://cache/',EncodingType:{Base64:'base64'},
  makeDirectoryAsync:async()=>{},readDirectoryAsync:async dir=>[...documents.keys()].filter(k=>k.startsWith(dir)&&!k.slice(dir.length).includes('/')).map(k=>k.slice(dir.length)),
  writeAsStringAsync:async(uri,data)=>{if(forceManifestFailure)throw Error('Storage full');documents.set(uri,data);},
  readAsStringAsync:async(uri,options)=>{if(!documents.has(uri))throw Error('File unavailable');const value=documents.get(uri);return options?.encoding==='base64'?Buffer.from(value).toString('base64'):value;},
  getInfoAsync:async uri=>({exists:documents.has(uri),size:documents.has(uri)?Buffer.byteLength(documents.get(uri)):0}),
  deleteAsync:async uri=>{documents.delete(uri);}};
function mockRecorder(){
  const subscribers=new Set();
  const value={uri:null,state:{isRecording:false,durationMillis:0},
    subscribe:fn=>{subscribers.add(fn);return()=>subscribers.delete(fn);},getStatus:()=>value.state,
    set:patch=>{value.state={...value.state,...patch};for(const fn of subscribers)fn();},
    prepareToRecordAsync:async options=>{assert.equal(options.directory,'document');assert.equal(options.ios.outputFormat,'lpcm');value.uri='file://docs/audio-'+recorders.length+'.wav';documents.set(value.uri,'synthetic-pcm');value.set({isRecording:false,durationMillis:0});},
    pause:()=>value.set({isRecording:false}),record:options=>{assert(options.forDuration>0&&options.forDuration<=300);value.set({isRecording:true,durationMillis:1000});},
    stop:async()=>{value.set({isRecording:false,durationMillis:0});}};
  recorders.push(value);return value;
}
const audio={useAudioPlayer:()=>({pause(){},play(){},seekTo(){}}),useAudioPlayerStatus:()=>({playing:false,currentTime:0}),AudioModule:{requestRecordingPermissionsAsync:async()=>{microphonePrompts++;return {...permissions};}},
  setAudioModeAsync:async()=>{},useAudioRecorder:()=>React.useMemo(mockRecorder,[]),
  useAudioRecorderState:recorder=>React.useSyncExternalStore(recorder.subscribe,recorder.getStatus,recorder.getStatus)};
const secure={getItemAsync:async()=>'',setItemAsync:async()=>{},deleteItemAsync:async()=>{}};
const sessions=new Map(),runs=[];
const problems=['project','disagreement','setback'].flatMap(base=>Array.from({length:5},(_,i)=>({id:base+(i?'-'+(i+1):''),title:base,prompt:'Question '+base+' '+(i+1)})));
const fakeDevice={Icon:()=>null,errorText:e=>e?.message||String(e),confirmDelete:(name,action)=>action(),
  rpc:async(name,args={})=>{
    if(name==='transcription_list')return {recordings:structuredClone(records)};
    const row=records.find(r=>r.id===args.id);
    if(name==='transcription_get'){if(holdingGet)return holdingGet.promise;return structuredClone(row);}
    if(name==='transcription_action'){
      assert(row);
      if(args.action==='save'){if(holdingSave)await holdingSave.promise;if(args.revision!==row.revision)throw Error('Revision conflict');row.transcript=args.text;row.revision++;}
      if(args.action==='retry'){row.status='queued';row.error='';}
      if(args.action==='cancel')row.status='cancelled';
      if(args.action==='delete'){records=records.filter(r=>r.id!==row.id);return {deleted:true};}
      return structuredClone(row);
    }
    if(name==='prep_catalog')return {problems:problems};
    if(name==='prep_sessions')return {sessions:[...sessions.values()].map(s=>structuredClone(s))};
    if(name==='prep_create'){const s={id:'prep-'+sessions.size,revision:0,data:{problem_id:args.problem_id,language:'',answer:'',transcript:'',notes:'',code:'',elapsed_seconds:0,canvas:{nodes:[],edges:[]}},feedback:[],updated_at:Date.now()/1000};sessions.set(s.id,s);return structuredClone(s);}
    if(name==='prep_get')return structuredClone(sessions.get(args.id));
    if(name==='prep_save'){const s=sessions.get(args.id);assert.equal(args.revision,s.revision);s.data=structuredClone(args.data);s.revision++;return structuredClone(s);}
    if(name==='agent_start'){const s=sessions.get(args.target_id);const r={id:'run-'+runs.length,target_id:s.id,session_revision:s.revision,kind:'prep',status:'queued'};runs.unshift(r);return structuredClone(r);}
    if(name==='agent_activity')return {runs:structuredClone(runs)};
    if(name==='agent_run')return structuredClone(runs.find(r=>r.id===args.id));
    if(name==='agent_retry'){runs.find(r=>r.id===args.id).status='queued';return {};}
    throw Error('Unexpected RPC '+name);
  },
  uploadResumeFile:async(endpoint,file,progress)=>{
    assert.equal(endpoint,'transcription_upload');uploads.push(structuredClone(file));
    progress({status:'uploading',percent:50});
    if(uploadFailure)throw Error('Upload interrupted. Retry the saved recording.');
    let row=records.find(r=>r.client_id===file.client_id);
    if(!row){row={id:'server-'+records.length,client_id:file.client_id,status:'queued',duration_seconds:1,stage_at:Date.now()/1000,percent:null,error:'',original_transcript:'',transcript:'',revision:0,timings:{transfer_ms:4,queue_ms:0,decode_ms:0,load_ms:0,transcribe_ms:0}};records.push(row);}
    return structuredClone(row);
  }};
const speechListeners=new Set(),phoneSpeech={available:false,last:null,pauses:0,resumes:0,
 capabilities:async()=>({available:phoneSpeech.available,reason:'Controlled speech capability'}),
 addListener:(event,fn)=>{speechListeners.add(fn);return {remove:()=>speechListeners.delete(fn)};},
 start:async(uri,id)=>{phoneSpeech.last={uri,id};documents.set(uri,'synthetic-pcm');},
 pause:async id=>{assert.equal(id,phoneSpeech.last.id);phoneSpeech.pauses++;},
 resume:async id=>{assert.equal(id,phoneSpeech.last.id);phoneSpeech.resumes++;},
 stop:async(id,cancelled)=>{const result={...phoneSpeech.last,id,kind:'finished',duration_ms:2400,text:'My finalized on-device answer.',complete:!cancelled,cancelled};for(const fn of speechListeners)fn(result);return result;}};
const mocks={'react-native':RN,'expo-audio':audio,'expo-modules-core':{requireOptionalNativeModule:()=>phoneSpeech},'expo-file-system/legacy':files,'expo-secure-store':secure,
 'expo-constants':{expoConfig:{extra:{}}},'@jac/mobui':RN,
 '@react-navigation/native':{NavigationContainer:({children})=>children,CommonActions:{},useNavigation:()=>({}),useRoute:()=>({params:{}})},
 '@react-navigation/native-stack':{createNativeStackNavigator:()=>({Navigator:()=>null,Screen:()=>null})}};
const modules=new Map();
function load(filename){
  if(filename.endsWith('.json'))return JSON.parse(fs.readFileSync(filename,'utf8'));
  filename=filename.endsWith('.js')?filename:filename+'.js';if(modules.has(filename))return modules.get(filename).exports;
  const module={exports:{}};modules.set(filename,module);
  const code=babel.transformSync(fs.readFileSync(filename,'utf8'),{filename,babelrc:false,configFile:false,plugins:[req('@babel/plugin-transform-modules-commonjs')]}).code;
  const local=name=>{
    if(name in mocks)return mocks[name];
    if(name==='@jac/runtime')return load(path.join(root,'.jac/mobile-rn/jac-src/client_runtime.js'));
    if(name==='../device.js'||name==='./device.js')return fakeDevice;
    if(name.startsWith('.'))return load(path.resolve(path.dirname(filename),name));return req(name);
  };
  vm.runInThisContext('(function(require,module,exports){'+code+'\n})',{filename})(local,module,module.exports);
  return module.exports;
}
const native=load(path.join(root,'native/audio-recording.js'));
modules.set(path.join(root,'.jac/mobile-rn/jac-src/mobile/audio-recording.js'),{exports:native});
const {Prep}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/components/Prep.js'));
const flush=()=>new Promise(resolve=>setTimeout(resolve,15));
let ui;
const button=label=>ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel===label)[0];
const field=()=>ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel==='Transcript')[0];
async function press(label){assert(button(label),'Missing button: '+label+'; available: '+JSON.stringify(ui.root.findAll(n=>n.type==='Pressable').map(n=>n.props.accessibilityLabel)));await act(async()=>{await button(label).props.onPress();await flush();});}
async function tick(){await act(async()=>{for(const fn of [...intervalFns.values()])fn();await flush();});}
async function mount(owner='owner-a'){await act(async()=>{ui=renderer.create(React.createElement(Prep,{owner}));await flush();});}
async function unmount(){if(ui)await act(async()=>{ui.unmount();await flush();});ui=null;}

const input=label=>ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel===label)[0];
async function edit(label,text){await act(async()=>{input(label).props.onChangeText(text);await flush();});}
function completeCoaching(){const r=runs[0],s=sessions.get(r.target_id);r.status='completed';s.feedback.push({revision:r.session_revision,data:{summary:'Fixture coaching',rubric:[{criterion:'ownership',score:3,feedback:'You described your contribution.'},{criterion:'reflection',score:2,feedback:'Explain what you learned.'}],next_exercises:['Finish with the outcome.'],evidence:[{quote:'I built the dashboard.'}]}});}
async function start(count=3,focus='Mixed questions'){await press('New session');await press('Behavioral');await press(focus);await press(count+' '+(count===1?'question':'questions'));}
async function run(){
 await mount();await start(3);assert.match(JSON.stringify(ui.toJSON()),/Question 1 of 3/);
 permissions.granted=false;await press('Record answer');assert.match(JSON.stringify(ui.toJSON()),/Microphone access is denied/);
 permissions.granted=true;await press('Type instead');await edit('Your answer','I built the dashboard. We shipped on time.');await act(async()=>{await new Promise(r=>setTimeout(r,1050));});assert.equal([...sessions.values()][0].data.answer,'I built the dashboard. We shipped on time.','Draft autosaves before navigation');await press('Review your answer');
 await press('Back to Prep');assert.equal([...sessions.values()][0].data.answer,'I built the dashboard. We shipped on time.');
 await unmount();await mount();await press('Continue session');await press('Mixed questions · 1 of 3');assert.equal(input('Review transcript').props.value,'I built the dashboard. We shipped on time.');
 await press('Get coaching');assert.match(JSON.stringify(ui.toJSON()),/Preparing your coaching/);completeCoaching();await tick();assert.match(JSON.stringify(ui.toJSON()),/What worked/);
 const revision=[...sessions.values()][0].revision;await press('View your answer');await press('Back to Prep');assert.equal([...sessions.values()][0].revision,revision,'Viewing an answer must retain coaching revision');
 await press('Continue session');await press('Mixed questions · 1 of 3');await press('Next question');assert.match(JSON.stringify(ui.toJSON()),/Question 2 of 3/);
 const pulses=motion.started.loop,stops=motion.started.loopStop;await press('Record answer');assert(motion.started.loop>pulses,'Recording pulses while capturing');await press('Pause');assert(motion.started.loopStop>stops,'The recording pulse stops when paused');assert(button('Resume'));await tick();assert(button('Resume'));assert.equal((await native.localRecordings('owner-a'))[0].status,'recording','Pause must not finalize the capture');await press('Resume');
 uploadFailure=true;await press('Finish answer');assert(button('Upload saved answer'),JSON.stringify(ui.toJSON()));const captured=[...sessions.values()][0].data.behavioral.local_id;assert(captured,'Capture attached durably before upload');
 uploadFailure=false;await press('Upload saved answer');assert.equal(uploads.at(-1).client_id,captured);assert.equal([...sessions.values()][0].data.behavioral.recording_id,records[0].id);
 records[0].status='completed';records[0].transcript='I listened and tested our approaches.';await tick();assert.equal(input('Review transcript').props.value,records[0].transcript);
 await edit('Review transcript','My reviewed answer');await tick();assert.equal(input('Review transcript').props.value,'My reviewed answer','Polling preserves edits');
 await press('Get coaching');completeCoaching();await tick();await press('Next question');await press('Type instead');await edit('Your answer','I made a mistake and changed our checks.');await press('Review your answer');await press('Get coaching');completeCoaching();await tick();await press('Finish session');
 assert([...sessions.values()][0].data.behavioral.complete);assert.equal([...sessions.values()][0].data.behavioral.history.length,3);
 await unmount();await mount();await press('Past sessions');await press('Mixed questions · 3 of 3');assert.match(JSON.stringify(ui.toJSON()),/Your coaching/);
 await press('Saved answers');await press('Question 1');assert.match(JSON.stringify(ui.toJSON()),/I built the dashboard/);await press('Back to Prep');assert(button('Return to session'),'Back from a saved answer returns to saved answers');await press('Back to Prep');assert(button('Saved answers'),'Back from saved answers returns to the session');await press('Saved answers');await press('Return to session');await press('Back to Prep');await start(5,'Projects and ownership');assert.equal(new Set([...sessions.values()][1].data.behavioral.plan).size,5);
 await press('Record answer');assert([...sessions.values()][1].data.behavioral.local_id,'Attach recording at start');await act(async()=>{for(const fn of listeners)fn('background');await flush();});await unmount();await mount();await press('Continue session');await press('Projects and ownership · 1 of 5');assert(button('Upload saved answer'),'Background-stopped recording is resumed with its session');await unmount();
 phoneSpeech.available=true;await mount();await press('Start session');assert(button('1 question'));await press('Back to Prep');assert(button('New session'),'Back from an idea-card start returns to Prep');await start(1,'Setbacks and learning');await press('Record answer');
 const appleId=phoneSpeech.last.id;await press('Pause');assert(button('Resume'));assert.equal(phoneSpeech.pauses,1);await tick();assert(button('Resume'));
 await press('Resume');assert.equal(phoneSpeech.resumes,1);assert.equal(phoneSpeech.last.id,appleId,'Resume retains the same Apple capture');
 await press('Finish answer');assert.equal(input('Review transcript').props.value,'My finalized on-device answer.');
 assert.equal((await native.localRecordings('owner-a')).find(r=>r.client_id===appleId).original_transcript,'My finalized on-device answer.');
 assert(motion.started.timing>40&&motion.started.spring>0,'Step transitions, reveals and press feedback must animate: '+JSON.stringify(motion.started));
 await unmount();global.setInterval=realInterval;global.clearInterval=realClear;
 console.log('PASS Prep native: setup, denial, typed save/reopen, revision-attributed coaching, next/completion/history, paused capture, upload retry identity, transcript edit preservation, distinct five-question plan, Apple pause/resume identity and finalized transcript handoff. OS and coaching replies are controlled fixtures.');
}
run().catch(e=>{console.error(e);process.exitCode=1;});
