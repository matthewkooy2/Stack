// Actual generated Jac screen/runtime and native adapter; OS boundaries mocked.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {createRequire}=require('node:module');
const root=path.resolve(__dirname,'..'),req=createRequire(path.join(root,'.jac/mobile-rn/package.json'));
const React=req('react'),renderer=req('react-test-renderer'),babel=req('@babel/core'),{act}=renderer;
globalThis.IS_REACT_ACT_ENVIRONMENT=true;
const intervalFns=new Map(),realInterval=global.setInterval,realClear=global.clearInterval;
global.setInterval=fn=>{const id={};intervalFns.set(id,fn);return id;};global.clearInterval=id=>intervalFns.delete(id);
const documents=new Map(),permissions={granted:true},listeners=new Set(),recorders=[];
let backendPhoneCapability=false,microphonePrompts=0,uploadFailure=false,forceManifestFailure=false,uploads=[],records=[],holdingGet=null,holdingSave=null,holdingContent=null,holdingUpload=null,holdingNativeStop=null,holdingCapabilities=null;
const deferred=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};};
const primitive=name=>props=>React.createElement(name,props,props.children);
const RN={View:primitive('View'),Text:primitive('Text'),Pressable:primitive('Pressable'),TextInput:primitive('TextInput'),
  Switch:primitive('Switch'),Platform:{OS:'ios',select:v=>v.ios||v.default},StyleSheet:{create:v=>v},
  Linking:{openSettings(){}},Alert:{alert(){}},
  AppState:{addEventListener:(event,fn)=>{listeners.add(fn);return {remove:()=>listeners.delete(fn)};}},
  useWindowDimensions:()=>({width:390,height:844}),Animated:{Value:class{},View:primitive('AnimatedView')},
  PanResponder:{create:()=>({panHandlers:{}})}};
const files={documentDirectory:'file://docs/',cacheDirectory:'file://cache/',EncodingType:{Base64:'base64'},
  makeDirectoryAsync:async()=>{},readDirectoryAsync:async dir=>[...documents.keys()].filter(k=>k.startsWith(dir)&&!k.slice(dir.length).includes('/')).map(k=>k.slice(dir.length)),
  writeAsStringAsync:async(uri,data)=>{if(forceManifestFailure)throw Error('Storage full');documents.set(uri,data);},
  readAsStringAsync:async(uri,options)=>{if(options?.encoding==='base64'&&holdingContent)await holdingContent.promise;if(!documents.has(uri))throw Error('File unavailable');const value=documents.get(uri);return options?.encoding==='base64'?Buffer.from(value).toString('base64'):value;},
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
    if(name==='transcription_list')return {recordings:structuredClone(records),client_transcripts:backendPhoneCapability};
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
    if(holdingUpload)await holdingUpload.promise;
    if(uploadFailure)throw Error('Upload interrupted. Retry the saved recording.');
    let row=records.find(r=>r.client_id===file.client_id);
    if(!row){row={id:'server-'+records.length,client_id:file.client_id,status:'queued',duration_seconds:1,stage_at:Date.now()/1000,percent:null,error:'',original_transcript:'',transcript:'',revision:0,timings:{transfer_ms:4,queue_ms:0,decode_ms:0,load_ms:0,transcribe_ms:0}};records.push(row);}
    if(file.local_transcript){row.status='completed';row.transcript=file.local_transcript;row.original_transcript=file.local_transcript;row.revision=1;}
    return structuredClone(row);
  }};
const speechListeners=new Set();
const phoneSpeech={available:false,fail:false,complete:true,last:null,
 capabilities:async()=>{if(holdingCapabilities)await holdingCapabilities.promise;return {available:phoneSpeech.available,reason:phoneSpeech.available?'On-device English transcription ready.':'PC transcription will be used.'};},
 addListener:(name,fn)=>{speechListeners.add(fn);return {remove:()=>speechListeners.delete(fn)};},
 start:async(uri,id)=>{if(phoneSpeech.fail)throw Error('Speech preparation failed');phoneSpeech.last={uri,id};documents.set(uri,'synthetic-pcm');},
 stop:async(id,cancelled)=>{const result={...phoneSpeech.last,id,kind:'finished',duration_ms:2400,text:'Final on-device answer.',complete:phoneSpeech.complete&&!cancelled,cancelled,message:cancelled?'Recording cancelled. Audio was kept.':''};if(holdingNativeStop)await holdingNativeStop.promise;for(const fn of speechListeners)fn(result);return result;}};
function speechProgress(text){for(const fn of speechListeners)fn({...phoneSpeech.last,kind:'progress',duration_ms:1200,text});}
const mocks={'expo-modules-core':{requireOptionalNativeModule:()=>phoneSpeech},'react-native':RN,'expo-audio':audio,'expo-file-system/legacy':files,'expo-secure-store':secure,
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
async function press(label){assert(button(label),'Missing button: '+label);await act(async()=>{await button(label).props.onPress();await flush();});}
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
  phoneSpeech.available=true;await mount();const oldUploads=uploads.length;
  await press('Record');
  await act(async()=>{speechProgress('Provisional answer');await flush();});
  assert(!ui.root.findAll(n=>n.type==='Text'&&n.props.accessibilityLabel==='Live transcript').length,'Toggle off hides live text');
  const toggle=ui.root.findAll(n=>n.type==='Switch')[0];
  await act(async()=>{toggle.props.onValueChange(true);speechProgress('Revised provisional answer');await flush();});
  assert.match(JSON.stringify(ui.toJSON()),/Revised provisional answer/);
  await press('Stop and transcribe');assert.equal(uploads.length,oldUploads,'Legacy backend must not enqueue a duplicate PC transcription');
  assert.equal(field().props.value,'Final on-device answer.');
  await act(async()=>{field().props.onChangeText('Reviewed on-device answer.');});await press('Save transcript');
  const nativeRow=(await native.localRecordings('owner-a')).find(r=>r.status==='completed');
  assert.equal(nativeRow.original_transcript,'Final on-device answer.');assert.equal(nativeRow.transcript,'Reviewed on-device answer.');
  await assert.rejects(native.savePhoneTranscript('owner-b',nativeRow,'Wrong owner',1),/Reopen/);
  await assert.rejects(native.savePhoneTranscript('owner-a',nativeRow,'Stale edit',1),/changed/);
  await unmount();await mount();await press('Open phone transcript');assert.equal(field().props.value,'Reviewed on-device answer.');await unmount();
  backendPhoneCapability=true;await mount();await press('Record');await press('Stop and transcribe');
  assert.equal(uploads.at(-1).local_transcript,'Final on-device answer.');assert.equal(records.at(-1).status,'completed');await unmount();
  phoneSpeech.complete=false;await mount();await press('Record');const beforeFailure=uploads.length;await press('Stop and transcribe');
  assert.equal(uploads.length,beforeFailure+1);assert(!uploads.at(-1).local_transcript);assert.equal(records.at(-1).status,'queued');await unmount();
  phoneSpeech.complete=true;await mount();await press('Record');const beforeCancel=uploads.length;await press('Cancel recording');
  assert.equal(uploads.length,beforeCancel);assert((await native.localRecordings('owner-a')).some(r=>r.cancelled));await unmount();
  phoneSpeech.fail=true;await mount();await press('Record');assert.equal(recorders.at(-1).state.isRecording,true,'Native preparation failure falls back to durable Expo capture');await press('Cancel recording');await unmount();phoneSpeech.fail=false;
  await mount();await press('Record');await act(async()=>{for(const fn of listeners)fn('background');await flush();});await tick();
  assert((await native.localRecordings('owner-a')).some(r=>r.status==='completed'));assert.equal(uploads.length,beforeCancel);await unmount();
  // A pending native Stop or file read must not begin an upload after account change.
  await mount('stop-race-owner');await press('Record');const stopGate=holdingNativeStop=deferred();let stopping;
  const beforeStopRace=uploads.length;
  await act(async()=>{stopping=button('Stop and transcribe').props.onPress();await flush();});
  await unmount();await mount('next-stop-owner');
  await act(async()=>{holdingNativeStop=null;stopGate.resolve();await stopping;await flush();});
  assert.equal(uploads.length,beforeStopRace,'Unmount during native finalization cannot upload as next owner');await unmount();
  await mount('read-race-owner');await press('Record');const contentGate=holdingContent=deferred();let reading;
  const beforeReadRace=uploads.length;
  await act(async()=>{reading=button('Stop and transcribe').props.onPress();await flush();});
  await unmount();await mount('next-read-owner');
  await act(async()=>{holdingContent=null;contentGate.resolve();await reading;await flush();});
  assert.equal(uploads.length,beforeReadRace,'Unmount during file read cannot upload as next owner');await unmount();
  // Save before sync, and keep the editor read-only during the network operation.
  backendPhoneCapability=false;await mount('sync-race-owner');await press('Record');await press('Stop and transcribe');
  backendPhoneCapability=true;await tick();
  const staleSync=button('Sync phone transcript').props.onPress;
  await act(async()=>{field().props.onChangeText('Edit before sync.');});
  assert.equal(button('Sync phone transcript').props.disabled,true);
  const beforeDirtySync=uploads.length;await act(async()=>{await staleSync();await flush();});
  assert.equal(uploads.length,beforeDirtySync,'Even a stale Sync handler refuses dirty edits');
  await press('Save transcript');const staleEdit=field().props.onChangeText;
  const uploadGate=holdingUpload=deferred();let syncing;
  await act(async()=>{syncing=button('Sync phone transcript').props.onPress();await flush();});
  assert.equal(field(),undefined,'Editor is read-only while sync is pending');
  await act(async()=>{staleEdit('Must not replace synced text');holdingUpload=null;uploadGate.resolve();await syncing;await flush();});
  assert.equal(field().props.value,'Edit before sync.');assert.equal(records.at(-1).transcript,'Edit before sync.');await unmount();
  // Temporary storage failures stop the microphone and retry the final manifest.
  await mount('manifest-failure-owner');await press('Record');const failedId=phoneSpeech.last.id;
  forceManifestFailure=true;await press('Stop and transcribe');assert(button('Record'),'Final manifest failure must not leave recording UI stuck');
  forceManifestFailure=false;await press('Record');
  const recovered=(await native.localRecordings('manifest-failure-owner')).find(r=>r.client_id===failedId);
  assert.equal(recovered.status,'completed');assert.equal(recovered.original_transcript,'Final on-device answer.');
  await press('Cancel recording');await unmount();
  // A capability lookup resolving after unmount cannot start the microphone.
  await mount('capability-race-owner');const capabilityGate=holdingCapabilities=deferred();const previousNative=phoneSpeech.last;let starting;
  await act(async()=>{starting=button('Record').props.onPress();await flush();});await unmount();
  await act(async()=>{holdingCapabilities=null;capabilityGate.resolve();await starting;await flush();});
  assert.equal(phoneSpeech.last,previousNative,'Unmount during capability lookup cannot start native capture');
  console.log('PASS regressions: account switch during finalization/file read, dirty sync, edits during sync, final manifest retry, and unmount during capability lookup.');
  console.log('PASS on-device: hidden/live toggle, final transcript, durable reopen/edit/original, legacy backend, supported backend, recognition failure PC fallback, cancellation, preparation failure and interruption.');
  console.log('PASS native: permission denial, Record/Stop, durable files/timer, reopen without upload, retry same audio, owner isolation, interruption and edit/poll race.');
}
run().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{await unmount();global.setInterval=realInterval;global.clearInterval=realClear;});
