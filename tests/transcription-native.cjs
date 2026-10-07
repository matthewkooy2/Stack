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
const RN={View:primitive('View'),Text:primitive('Text'),Pressable:primitive('Pressable'),TextInput:primitive('TextInput'),
  Platform:{OS:'ios',select:v=>v.ios||v.default},StyleSheet:{create:v=>v},
  Linking:{openSettings(){}},Alert:{alert(){}},
  AppState:{addEventListener:(event,fn)=>{listeners.add(fn);return {remove:()=>listeners.delete(fn)};}},
  useWindowDimensions:()=>({width:390,height:844}),Animated:{Value:class{},View:primitive('AnimatedView')},
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
    record:options=>{assert.equal(options.forDuration,300);value.set({isRecording:true,durationMillis:1000});},
    stop:async()=>{value.set({isRecording:false,durationMillis:0});}};
  recorders.push(value);return value;
}
const audio={AudioModule:{requestRecordingPermissionsAsync:async()=>{microphonePrompts++;return {...permissions};}},
  setAudioModeAsync:async()=>{},useAudioRecorder:()=>React.useMemo(mockRecorder,[]),
  useAudioRecorderState:recorder=>React.useSyncExternalStore(recorder.subscribe,recorder.getStatus,recorder.getStatus)};
const secure={getItemAsync:async()=>'',setItemAsync:async()=>{},deleteItemAsync:async()=>{}};
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
const mocks={'react-native':RN,'expo-audio':audio,'expo-file-system/legacy':files,'expo-secure-store':secure,
 'expo-constants':{expoConfig:{extra:{}}},'@jac/mobui':RN,
 '@react-navigation/native':{NavigationContainer:({children})=>children,CommonActions:{},useNavigation:()=>({}),useRoute:()=>({params:{}})},
 '@react-navigation/native-stack':{createNativeStackNavigator:()=>({Navigator:()=>null,Screen:()=>null})}};
const modules=new Map();
function load(filename){
  filename=filename.endsWith('.js')?filename:filename+'.js';if(modules.has(filename))return modules.get(filename).exports;
  const module={exports:{}};modules.set(filename,module);
  const code=babel.transformSync(fs.readFileSync(filename,'utf8'),{filename,babelrc:false,configFile:false,plugins:[req('@babel/plugin-transform-modules-commonjs')]}).code;
  const local=name=>{
    if(name in mocks)return mocks[name];
    if(name==='@jac/runtime')return load(path.join(root,'.jac/mobile-rn/jac-src/client_runtime.js'));
    if(name==='../device.js')return fakeDevice;
    if(name.startsWith('.'))return load(path.resolve(path.dirname(filename),name));return req(name);
  };
  vm.runInThisContext('(function(require,module,exports){'+code+'\n})',{filename})(local,module,module.exports);
  return module.exports;
}
const native=load(path.join(root,'native/audio-recording.js'));
modules.set(path.join(root,'.jac/mobile-rn/jac-src/mobile/audio-recording.js'),{exports:native});
const {Transcription}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/components/Transcription.js'));
const flush=()=>new Promise(resolve=>setTimeout(resolve,15));
let ui;
const button=label=>ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel===label)[0];
const field=()=>ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel==='Transcript')[0];
async function press(label){assert(button(label),'Missing button: '+label+'; available: '+JSON.stringify(ui.root.findAll(n=>n.type==='Pressable').map(n=>n.props.accessibilityLabel)));await act(async()=>{await button(label).props.onPress();await flush();});}
async function tick(){await act(async()=>{for(const fn of [...intervalFns.values()])fn();await flush();});}
async function mount(owner='owner-a'){await act(async()=>{ui=renderer.create(React.createElement(Transcription,{owner}));await flush();});}
async function unmount(){if(ui)await act(async()=>{ui.unmount();await flush();});ui=null;}
async function run(){
  await mount();assert.equal(microphonePrompts,0,'Permission requested only by Record');
  permissions.granted=false;await press('Record');assert.match(JSON.stringify(ui.toJSON()),/Microphone access is denied/);assert.equal(uploads.length,0);
  permissions.granted=true;await press('Record');assert(button('Stop and transcribe'));assert.equal((await native.localRecordings('owner-a'))[0].status,'recording');
  await press('Stop and transcribe');assert.equal(uploads.length,1);assert.equal(records[0].status,'queued');
  assert.equal((await native.localRecordings('owner-a'))[0].server_id,records[0].id);
  assert.equal((await native.localRecordings('owner-a'))[0].duration_ms,1000);
  await unmount();await mount();assert(button('Queued · 1 seconds'),'Saved job reopens without upload');assert.equal(uploads.length,1);
  await press('Queued · 1 seconds');
  records[0]={...records[0],status:'completed',original_transcript:'Original answer.',transcript:'Original answer.',revision:1,percent:100};await tick();
  assert.equal(field().props.value,'Original answer.');
  let resolve;holdingGet={promise:new Promise(r=>{resolve=r;})};await tick();
  await act(async()=>{field().props.onChangeText('Edited answer.');});
  await act(async()=>{resolve(structuredClone(records[0]));holdingGet=null;await flush();});
  assert.equal(field().props.value,'Edited answer.','Pending poll preserves newly typed text');
  let resolveSave,saving;holdingSave={promise:new Promise(r=>{resolveSave=r;})};
  await act(async()=>{saving=button('Save transcript').props.onPress();await flush();});
  await act(async()=>{field().props.onChangeText('Latest edit.');});
  await act(async()=>{resolveSave();holdingSave=null;await saving;await flush();});
  assert.equal(field().props.value,'Latest edit.','Save response preserves newer typing');
  assert.equal(records[0].transcript,'Edited answer.');await press('Save transcript');
  assert.equal(records[0].transcript,'Latest edit.');assert.equal(records[0].original_transcript,'Original answer.');
  await press('Record');uploadFailure=true;await press('Stop and transcribe');assert(button('Upload saved recording'));
  const retryId=uploads.at(-1).client_id;await unmount();await mount();uploadFailure=false;await press('Upload saved recording');assert.equal(uploads.at(-1).client_id,retryId);
  assert.equal(records.length,2);assert.equal(uploads.length,3);
  await press('Record');await act(async()=>{for(const fn of listeners)fn('background');await flush();});await tick();
  assert.equal(recorders.at(-1).getStatus().isRecording,false);assert(button('Upload saved recording'));
  await unmount();await mount('owner-b');assert.equal((await native.localRecordings('owner-b')).length,0);
  assert(!button('Upload saved recording'),'Another owner cannot see local audio');await unmount();
  const row=(await native.localRecordings('owner-a'))[0];forceManifestFailure=true;
  await assert.rejects(native.saveLocalRecording('owner-a',{...row,status:'uploaded'}),/Storage full/);forceManifestFailure=false;
  assert.equal((await native.localRecordings('owner-a'))[0].client_id,row.client_id,'Previous manifest survives failed save');
  await assert.rejects(native.localRecordings('../owner'),/Sign in/);
  console.log('PASS native: permission denial, Record/Stop, durable files/timer, reopen without upload, retry same audio, owner isolation, interruption and edit/poll race.');
}
async function runInterview(){
  const {Interview}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/components/Interview.js'));
  const oldRpc=fakeDevice.rpc,answers=[];let failSave=true,holdingInterviewSave=null,holdingInterviewGet=null;
  const session={id:'native-interview',revision:0,run:{},data:{job:{title:'SQL Tools Engineer'},status:'active',pending:'',turns:[],analysis:{},coaching:{},questions:[{question:'Describe your SQL project.'},{question:'Describe a tradeoff.'}]}};
  const other={id:'other-native-interview',revision:1,run:{},data:{job:{title:'Other role'},status:'active',pending:'',turns:[],analysis:{},coaching:{},questions:[{question:'A different role question.'}]}};
  const feedback='Explain how you checked the result; distinguish observations from assumptions.';
  fakeDevice.rpc=async(name,args={})=>{
    if(name==='bootstrap')return{applications:[{id:'role-one',job:{title:'SQL Tools Engineer',company:'Fixture team'}}]};
    if(name==='interview_sessions')return{sessions:session.revision?[structuredClone(session),structuredClone(other)]:[]};
    if(name==='interview_get'){if(holdingInterviewGet)await holdingInterviewGet;return structuredClone(args.id===other.id?other:session);}
    if(name==='interview_create')return structuredClone(session);
    if(name==='interview_answer'){
      answers.push(structuredClone(args));if(failSave){failSave=false;throw Error('Connection lost');}
      if(holdingInterviewSave)await holdingInterviewSave;
      assert.equal(args.revision,session.revision);
      const row=records.find(r=>r.id===args.recording_id);if(args.recording_id)assert.equal(row.status,'completed');
      session.data.turns.push({answer:args.answer,original:row?row.original_transcript:args.answer,recording_id:args.recording_id,question:session.data.questions[session.data.turns.length]});session.revision++;
      session.data.analysis[String(session.data.turns.length)]={strength:'Verification',improvement:feedback,focus_quote:args.answer};
      if(session.data.turns.length===1){session.run={id:'native-analysis',status:'needs_input',message:'Model reply invalid; answer saved.'};session.data.analysis={};}
    }else if(name==='agent_respond'){
      assert.deepEqual(args,{id:'native-analysis',values:[],reuse:false});session.run={};session.data.analysis['1']={strength:'Verification',improvement:feedback,focus_quote:session.data.turns[0].answer};return{};
    }else if(name==='interview_continue'){
      if(args.action==='followup')session.data.questions.splice(session.data.turns.length,0,{question:'How did you verify your result?'});
      if(args.action==='finish')session.data.status='finished';
      if(args.action==='analyze'&&session.data.status==='finished')session.data.coaching={text:'<img src=x onerror=alert(1)> Plain prose {broken JSON. Partial coaching:',summary:'<img src=x onerror=alert(1)> Plain prose {broken JSON. Partial coaching:'};
      session.revision++;
    }else if(name==='interview_correct'){
      session.data.turns[args.index].answer=args.answer;session.data.analysis={};session.data.coaching={};session.revision++;
    }else return oldRpc(name,args);
    return structuredClone(session);
  };
  const answerField=()=>ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel==='Review your answer')[0];
  records=[{id:'spoken-native',status:'completed',duration_seconds:1,transcript:'Reviewed spoken answer.',original_transcript:'Original spoken answer.',revision:1,timings:{},stage_at:0}];
  try{
    await act(async()=>{ui=renderer.create(React.createElement(Interview,{owner:'owner-a'}));await flush();});
    await press('SQL Tools Engineer · Fixture team');await press('Start job interview');
    await act(async()=>{answerField().props.onChangeText('Typed draft while transcript runs.');});
    permissions.granted=false;await press('Record');assert.equal(answerField().props.value,'Typed draft while transcript runs.');permissions.granted=true;
    await press('Completed · 1 seconds');await act(async()=>{field().props.onChangeText('Reviewed spoken correction.');});
    assert(button('Use reviewed transcript in interview').props.disabled,'Unsaved transcript cannot be handed off');
    await press('Save transcript');await press('Use reviewed transcript in interview');assert.equal(answerField().props.value,'Typed draft while transcript runs.');
    await press('Use recorded transcript');assert.equal(answerField().props.value,'Reviewed spoken correction.');
    await press('Save reviewed answer and analyze');assert.equal(answerField().props.value,'Reviewed spoken correction.');
    let releaseSave,saving;holdingInterviewSave=new Promise(resolve=>{releaseSave=resolve;});
    await act(async()=>{saving=button('Save reviewed answer and analyze').props.onPress();await flush();});
    assert.equal(answerField().props.editable,false,'Pending save freezes answer input');assert.equal(button('Use reviewed transcript in interview').props.disabled,true,'Pending save freezes recorder handoff');assert.equal(field().props.editable,false,'Pending save freezes nested transcript edits');
    await act(async()=>{releaseSave();holdingInterviewSave=null;await saving;await flush();});assert.equal(answers[0].client_id,answers[1].client_id);assert.equal(answers[1].recording_id,'spoken-native');
    assert.equal(session.data.turns[0].original,'Original spoken answer.');await press('Retry local Qwen');assert.match(JSON.stringify(ui.toJSON()),/Answer coaching/);
    await press('Ask answer follow-up');await act(async()=>{answerField().props.onChangeText('I compared the write overhead.');});await press('Save reviewed answer and analyze');
    await act(async()=>{answerField().props.onChangeText('An unrelated unsaved draft.');});await press('Correct answer 2');
    const corrected=ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel==='Corrected answer')[0];await act(async()=>{corrected.props.onChangeText('I explained the write overhead.');});await press('Save transcript correction');
    assert.equal(answerField().props.value,'An unrelated unsaved draft.','Correction preserves current draft');await act(async()=>{answerField().props.onChangeText('');});
    let releaseOpen,opening;holdingInterviewGet=new Promise(resolve=>{releaseOpen=resolve;});
    await act(async()=>{opening=button('Other role · 0 answers · active').props.onPress();await flush();});
    assert.equal(answerField().props.editable,false,'Pending saved-session load freezes answer input');assert.equal(button('Start job interview').props.disabled,true,'Pending saved-session load freezes actions');
    await act(async()=>{releaseOpen();holdingInterviewGet=null;await opening;await flush();});assert.equal(answerField().props.value,'');assert.match(JSON.stringify(ui.toJSON()),/A different role question/);
    await press('SQL Tools Engineer · 2 answers · active');
    session.data.analysis['2']={text:'Successful plain answer coaching.'};await press('Finish interview');await press('Get final coaching');const rendered=JSON.stringify(ui.toJSON());assert(rendered.includes('<img src=x onerror=alert(1)> Plain prose {broken JSON. Partial coaching:'));
    await unmount();await act(async()=>{ui=renderer.create(React.createElement(Interview,{owner:'owner-a'}));await flush();});await press('SQL Tools Engineer · 2 answers · finished');assert.match(JSON.stringify(ui.toJSON()),/Final coaching/);assert.match(JSON.stringify(ui.toJSON()),/Original spoken answer/);
    console.log('PASS native interview: compiled recorder handoff/review/draft preservation, recording ID/original, connection retry identity, two answers/correction/four scores/feedback/reopen. OS and API/model replies are controlled fixtures.');
  }finally{fakeDevice.rpc=oldRpc;await unmount();}
}
run().then(runInterview).catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{await unmount();global.setInterval=realInterval;global.clearInterval=realClear;});
