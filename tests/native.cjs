// Runs the actual Jac-generated screens/runtime and native adapter under React.
// Native OS boundaries are mocked; this does not certify iPhone delivery or layout.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {createRequire} = require('node:module');
const root = path.resolve(__dirname,'..');
const crypto=require('node:crypto');
const marker='UINativeProof'+Date.now();
const fixtureURL='https://example.com/'+marker;
const fixtureSource='career:'+crypto.createHash('sha256').update(fixtureURL).digest('hex').slice(0,32);
async function worker(name,args={}){
 const response=await fetch((process.env.STACK_API_URL||'http://127.0.0.1:8000')+'/function/'+name,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:fs.readFileSync(path.join(root,'storage/discovery/worker-token'),'utf8').trim(),...args})});
 const r=await response.json();if(r.data?.result?.error||!r.ok)throw new Error(JSON.stringify(r));return r.data.result;
}

const nativeRequire = createRequire(path.join(root,'.jac/mobile-rn/package.json'));
const React = nativeRequire('react');
const renderer = nativeRequire('react-test-renderer');
const babel = nativeRequire('@babel/core');
const {act} = renderer;
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
globalThis.__JAC_API_BASE_URL__ = process.env.STACK_API_URL || 'http://127.0.0.1:8000';
const openedLinks=[];
const saved = new Map(); let schedules=[], grants=false, prompts=0, scheduleCalls=0, pickerResult={canceled:true};
const notifications = {
 setNotificationHandler(){}, getPermissionsAsync:async()=>({granted:grants,canAskAgain:true}),
 requestPermissionsAsync:async()=>{prompts++;return {granted:grants};},
 getAllScheduledNotificationsAsync:async()=>schedules,
 cancelAllScheduledNotificationsAsync:async()=>{schedules=[];},dismissAllNotificationsAsync:async()=>{},
 cancelScheduledNotificationAsync:async id=>{schedules=schedules.filter(x=>x.identifier!==id);},
 scheduleNotificationAsync:async n=>{scheduleCalls++;schedules.push(n);return n.identifier;},
 SchedulableTriggerInputTypes:{DATE:'date'}, getLastNotificationResponseAsync:async()=>null,
 addNotificationResponseReceivedListener:()=>({remove(){}}),
};
const storage = {getItemAsync:async k=>saved.get(k),setItemAsync:async(k,v)=>saved.set(k,v),deleteItemAsync:async k=>saved.delete(k)};
const files={cacheDirectory:'cache/',EncodingType:{Base64:'base64'},getInfoAsync:async()=>({size:50}),readAsStringAsync:async()=>fs.readFileSync(path.join(root,'tests/fixtures/blank.pdf')).toString('base64'),deleteAsync:async()=>{},makeDirectoryAsync:async()=>{},writeAsStringAsync:async()=>{}};
const primitives=new Map();
const primitive=name=>{if(!primitives.has(name))primitives.set(name,props=>name==='Modal'&&!props.visible?null:React.createElement(name,props,props.children));return primitives.get(name);};
const RN = new Proxy({
 StyleSheet:{create:x=>x}, Linking:{openSettings(){},openURL:async url=>{openedLinks.push(url);}},Alert:{alert(){}},Platform:{OS:'ios',select:x=>x.ios||x.default},
 AppState:{currentState:'active',addEventListener:()=>({remove(){}})},useWindowDimensions:()=>({width:390,height:844}),
 Animated:{Value:class{setValue(){} interpolate(){return 0;}},View:'View',timing:()=>({start:cb=>cb?.()}),spring:()=>({start(){}})},
 PanResponder:{create:x=>({panHandlers:x})},
}, {get:(target,key)=>target[key]||primitive(key)});
const mocks={
 'react-native':RN,'expo-secure-store':storage,'expo-notifications':notifications,'expo-document-picker':{getDocumentAsync:async()=>pickerResult},
 'expo-file-system/legacy':files,'expo-constants':{expoConfig:{extra:{}}},'@react-native-community/datetimepicker':'DateTimePicker','react-native-pdf':'PDF',
 'lucide-react-native':new Proxy({}, {get:(_,k)=>k==='__esModule'?false:()=>null}),
 '@react-navigation/native':{NavigationContainer:({children})=>children,CommonActions:{},useNavigation:()=>({}),useRoute:()=>({})},
 '@react-navigation/native-stack':{createNativeStackNavigator:()=>({})},
};
const modules = new Map();
function load(filename){
 filename=path.resolve(filename);
 if(modules.has(filename))return modules.get(filename).exports;
 const module={exports:{}};modules.set(filename,module);
 const code=babel.transformSync(fs.readFileSync(filename,'utf8'),{filename,babelrc:false,configFile:false,plugins:[nativeRequire.resolve('@babel/plugin-transform-modules-commonjs')]}).code;
 const localRequire=name=>{
   if(name in mocks)return mocks[name];
   if(name==='@jac/runtime')return load(path.join(root,'.jac/mobile-rn/jac-src/client_runtime.js'));
   if(name==='@jac/mobui')return load(path.join(root,'.jac/mobile-rn/jac-src/client_mobui.js'));
   if(name.endsWith('.png'))return {uri:name};
   if(name.startsWith('.'))return load(path.resolve(path.dirname(filename),name));
   return nativeRequire(name);
 };
 vm.runInThisContext('(function(require,module,exports){'+code+'\n})',{filename})(localRequire,module,module.exports);
 return module.exports;
}
const device=load(path.join(root,'native/device.js'));
const pause=()=>new Promise(resolve=>setTimeout(resolve,30));
async function notificationTests(){
 await storage.setItemAsync('stack.session.v1','test-token');await device.restoreSession();
 const state={user_id:'a',profile:{notifications:true},reminders:[{id:'r1',target_id:'j1',target_type:'application',title:'Follow up',due_at:Date.now()/1000+3600}]};
 await device.reconcileNotifications(state);assert.equal(prompts,0);assert.equal(schedules.length,0);
 assert.match(await device.reconcileNotifications(state,true),/Enable notifications/);assert.equal(prompts,1);
 grants=true;await device.reconcileNotifications(state);await device.reconcileNotifications(state);
 assert.equal(schedules.length,1);assert.equal(scheduleCalls,1);
 state.reminders[0].title='New title';await device.reconcileNotifications(state);assert.equal(schedules.length,1);assert.equal(schedules[0].content.body,'New title');
 state.reminders[0].due_at+=3600;await device.reconcileNotifications(state);assert.equal(schedules.length,1);assert.equal(schedules[0].content.data.due_at,state.reminders[0].due_at);
 state.reminders[0].done=true;await device.reconcileNotifications(state);assert.equal(schedules.length,0);
 state.reminders[0].done=false;state.user_id='b';await device.reconcileNotifications(state);assert.equal(schedules[0].content.data.user_id,'b');
 state.profile.notifications=false;await device.reconcileNotifications(state);assert.equal(schedules.length,0);
 state.profile.notifications=true;await device.reconcileNotifications(state);await device.signOut();assert.equal(schedules.length,0);assert.equal(saved.size,0);
 assert.equal(await device.pickResume(),null);
 pickerResult={canceled:false,assets:[{uri:'cache/large.pdf',name:'large.pdf',size:10485761}]};await assert.rejects(device.pickResume(),/10 MB/);
 pickerResult={canceled:true};
 console.log('PASS native: permission denial, idempotent scheduling, edits, reschedule, completion, account switch, sign-out, picker cancel/size.');
}
async function gestureTests(){
 let ui,actions=[];const make=(id,disabled=false)=>React.createElement(device.SwipeSurface,{cardId:id,disabled,onSwipe:async action=>actions.push(action)},React.createElement('Text',null,'Card'));
 await act(async()=>{ui=renderer.create(make('a'));});
 const card=()=>ui.root.findAll(n=>n.props.testID==='job-swipe-card')[0];
 assert.equal(card().props.onMoveShouldSetPanResponderCapture(null,{dx:60,dy:5}),true);
 assert.equal(card().props.onMoveShouldSetPanResponderCapture(null,{dx:5,dy:60}),false);
 await act(async()=>{card().props.onPanResponderRelease(null,{dx:140,dy:0,vx:1});await pause();});
 assert.deepEqual(actions,['apply']);
 await act(async()=>{card().props.onPanResponderRelease(null,{dx:140,dy:0,vx:1});});assert.equal(actions.length,1);
 await act(async()=>{ui.update(make('b'));});
 await act(async()=>{card().props.onPanResponderRelease(null,{dx:-130,dy:0,vx:-1});await pause();});assert.deepEqual(actions,['apply','pass']);
 await act(async()=>{ui.update(make('c',true));});assert.equal(card().props.onMoveShouldSetPanResponderCapture(null,{dx:140,dy:0}),false);
 await act(async()=>ui.unmount());console.log('PASS real swipe responder: capture, vertical scroll, left/right, duplicate release, disabled state.');
}
async function screenTests(){
 // Reuse the actual adapter, with only lifecycle timing replaced by explicit test refreshes.
 const screenDevice={...device,Lifecycle:()=>null,PDFView:({uri})=>React.createElement('PDF',{uri})};
 modules.set(path.join(root,'.jac/mobile-rn/jac-src/mobile/device.js'),{exports:screenDevice});
 const {app:App}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/main.js'));
 let ui;
 await act(async()=>{ui=renderer.create(React.createElement(App));await pause();});
 const text=()=>JSON.stringify(ui.toJSON());
 const button=label=>ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel===label)[0];
 const press=async label=>{for(let i=0;i<100&&button(label)?.props.disabled;i++)await act(async()=>{await new Promise(r=>setTimeout(r,100));});const b=button(label);assert.ok(b,'Missing '+label);assert.ok(!b.props.disabled,'Disabled '+label);await act(async()=>{await b.props.onPress();await pause();});};
 const field=async(label,value)=>{const f=ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel===label)[0];assert.ok(f,'Missing field '+label);await act(async()=>f.props.onChangeText(value));};
 assert.match(text(),/Your next chapter/);
 await field('Username','ui_'+Date.now());await field('Password','Stack-test-'+Date.now());await press('Get started');
 assert.match(text(),/A little about you/);
 await field('Your name','UI Tester');await field('Target role',marker);await field('Expected graduation (YYYY-MM)','2027-05');await field('Available full-time from (YYYY-MM)','2027-06');
 await press('Experienced');await field('Years of experience in this field','3');await press('Full-time');await press('Part-time');await press('Pay');
 const imported=await device.rpc('import_job_url',{url:fixtureURL});
 const work=await worker('discovery_claim',{preferred_id:fixtureSource});
 assert.equal(work.id,fixtureSource);
 const fixtureJobs=Array.from({length:4},(_,i)=>({id:'job_'+crypto.createHash('sha256').update(fixtureURL+'/'+i).digest('hex').slice(0,32),identity:fixtureURL+'/'+i,canonical_url:fixtureURL+'/'+i,url:fixtureURL+'/'+i,title:marker+' Nurse '+i,company:'UI Test Employer',description:'Must be graduating between December 2026 and June 2027.',country:'US',location:'Detroit, MI',locations:['Detroit, MI'],mode:'Remote',employment_type:'Full-time',seniority:'Entry-level',occupation:'Healthcare practitioners',compensation:{min:30,max:40,unit:'hour',currency:'USD',estimated:false},salary:'USD 30–40 / hour',salary_note:'Employer-provided pay',source:'career',source_id:fixtureSource,source_name:'UI test',source_job_id:String(i),attribution:{},posted:'Today',posted_at:Date.now()/1000,checked_at:Date.now()/1000,discovered_at:Date.now()/1000,expires_at:0,snippet:false,requirements:[],qualifications:'',eligibility:'',remote_eligibility:'',initial:'U',color:'#EDF2FF',tags:['Full-time'],reason:'Matches your search filters.',demo:false}));
 await worker('discovery_complete',{id:fixtureSource,lease:work.lease,result:{jobs:fixtureJobs,complete:true}});
 await press('Find my next chapter');assert.match(text(),/Jobs/);
 const savedPrefs=(await device.rpc('bootstrap',{})).profile.preferences;assert.equal(savedPrefs.stage,'Experienced');assert.equal(savedPrefs.years,3);assert.deepEqual(savedPrefs.employment_types,['Full-time','Part-time']);assert.deepEqual(savedPrefs.soft,['salary']);for(let i=0;i<200&&!ui.root.findAll(n=>n.props.testID==='job-swipe-card').length;i++)await act(async()=>{await new Promise(r=>setTimeout(r,100));});assert.match(text(),/Graduation window matches/);assert.match(text(),/Meets your requirements/);assert.match(text(),/✓ Title contains/);await press('Open job');assert.ok(openedLinks.at(-1).startsWith(fixtureURL));await press('Full details');assert.match(text(),/Must be graduating between December 2026 and June 2027/);assert.match(text(),/HOW THIS MATCHES YOU/);assert.match(text(),/✓ Graduation timeline: Graduation window matches/);await press('Close job panel');
 await press('Filter jobs');await press('Remote');await press('Confirmed timeline matches only');await press('Has posting date');await press('Best match');await press('Show opportunities');assert.match(text(),/UI Test Employer/);assert.match(text(),/Posted within 24 hours/);const savedFilters=(await device.rpc('bootstrap',{})).saved_search.filters;assert.equal(savedFilters.has_posting_date,true);assert.equal(savedFilters.sort,'relevance');assert.equal(savedFilters.timeline,'confirmed');
 // Search-level changes are labeled as overrides of the profile and can be reset.
 assert.deepEqual(savedFilters.modes,['Remote']);assert.match(text(),/This search changes your profile’s work arrangement/);assert.match(text(),/✓ Remote/);
 await press('Use profile settings');assert.doesNotMatch(text(),/This search changes your profile/);assert.deepEqual((await device.rpc('bootstrap',{})).saved_search.filters,{});
 await press('Filter jobs');await press('Any');await press('Confirmed timeline matches only');await press('Include unknown dates');await press('Newest first');await press('Show opportunities');
 // A slow/failed save must advance immediately, keep gestures usable, then restore the card.
 const currentCard=()=>ui.root.findAll(n=>n.type===device.SwipeSurface)[0]?.props.cardId;
 const originalCard=currentCard(), originalFetch=globalThis.fetch;let rejectSwipe,pendingSwipe;
 globalThis.fetch=(url,...args)=>String(url).includes('/function/swipe')?new Promise((resolve,reject)=>{rejectSwipe=reject;}):originalFetch(url,...args);
 try{
  await act(async()=>{pendingSwipe=button('Pass').props.onPress();await pause();});
  assert.notEqual(currentCard(),originalCard,'Deck must advance before the server replies');assert.equal(button('Pass').props.disabled,false);
  await act(async()=>{rejectSwipe(new Error('Network request failed'));await pendingSwipe;await pause();});
  assert.equal(currentCard(),originalCard,'Failed swipe must restore its card');assert.match(text(),/Not saved/);
 }finally{globalThis.fetch=originalFetch;}
 const apply=button('Ready to apply');await act(async()=>{await Promise.all([apply.props.onPress(),apply.props.onPress()]);});for(let i=0;i<100&&!(await device.rpc('bootstrap',{})).applications.length;i++)await pause();
 await press('Applications');assert.match(text(),/UI Test Employer/);
 const card=ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityRole==='button'&&!n.props.accessibilityLabel&&JSON.stringify(n.toJSON?.()||n.findAllByType('Text').map(t=>t.props.children)).includes('UI Test Employer'))[0];
 assert.ok(card,'Application card');await act(async()=>{card.props.onPress();});
 await field('Your notes','UI saved notes');
 const realFetch=globalThis.fetch;globalThis.fetch=async()=>{throw new Error('Network request failed');};
 try{await press('Save notes');assert.match(text(),/Cannot reach your Mac/);assert.doesNotMatch(text(),/Saved to your Stack/);}finally{globalThis.fetch=realFetch;}
 await press('Save notes');assert.match(text(),/Saved to your Stack/);
 await press('Add follow-up reminder');await field('Reminder title','UI follow up');await press('Save reminder');assert.match(text(),/UI follow up/);assert.equal(schedules.length,1);
 await press('Close details');await press('Network');assert.match(text(),/Alex/);await press('Saved');assert.match(text(),/Your circle starts here/);await press('Discover');
 await press('Resume');assert.match(text(),/Add your resume/);await press('Upload PDF resume');assert.doesNotMatch(text(),/Your resume is saved privately/);
 pickerResult={canceled:false,assets:[{uri:'cache/test.pdf',name:'test.pdf',size:400}]};await press('Upload PDF resume');assert.match(text(),/Your resume is saved privately/);await press('Preview resume');assert.match(text(),/PDF preview/);await press('Close details');
 await press('Explore a sample');assert.match(text(),/Tailoring preview/);await press('Close details');
 await press('Jobs');for(let i=0;i<100&&!ui.root.findAll(n=>n.props.testID==='job-swipe-card').length;i++)await act(async()=>{await new Promise(r=>setTimeout(r,100));});await act(async()=>{ui.root.findAll(n=>n.props.testID==='job-swipe-card')[0].props.onPanResponderRelease(null,{dx:140,dy:0,vx:1});await pause();});await press('Pass');await press('Pass');assert.match(text(),/No confirmed timeline matches/);
 assert.deepEqual(ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityRole==='tab').map(n=>n.props.accessibilityLabel),['Network','Applications','Jobs','Resume','Prep']);
 await press('Prep');assert.match(text(),/Find a pair/);await press('Show practice guide');assert.match(text(),/previously seen values/);await press('Next question');assert.match(text(),/Balanced brackets/);assert.doesNotMatch(text(),/Push opening brackets/);
 await press('Behavioral');assert.match(text(),/Tell your project story/);await press('Show practice guide');assert.match(text(),/your work from the team's work/);await press('Next question');assert.match(text(),/Work through disagreement/);
 await press('Open profile');assert.match(text(),/Muse/);assert.match(text(),/Planned/);await press('Sign out');assert.match(text(),/Create your Stack/);assert.equal(schedules.length,0);
 await act(async()=>ui.unmount());
 console.log('PASS Jac screens: signup, onboarding, apply, application notes, offline save/retry, reminder, filters, rapid repeated input, gestures, deck exhaustion, tab order, technical/behavioral prep guides, avatar profile, PDF upload/preview/cancel, sample preview, sign-out.');
}
(async()=>{try{await notificationTests();await gestureTests();await screenTests();}finally{await worker('discovery_manage',{id:fixtureSource,action:'purge'}).catch(()=>{});}})().catch(e=>{console.error(e);process.exitCode=1;});
