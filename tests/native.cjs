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
async function agentWorker(name,args={}){
 const token=process.env.STACK_AGENT_WORKER_TOKEN||fs.readFileSync(path.join(root,'storage/agents/worker-token'),'utf8').trim();
 const response=await fetch((process.env.STACK_API_URL||'http://127.0.0.1:8000')+'/function/'+name,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token,...args})});
 const r=await response.json();if(!r.ok)throw new Error(JSON.stringify(r));return r.data.result;
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
modules.set(path.join(root,'.jac/mobile-rn/jac-src/mobile/device.js'),{exports:device});
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
async function feedbackTests(){
 const {AgentFeedback}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/components/Feedback.js'));
 let ui,body;const originalFetch=globalThis.fetch;
 try{
  await act(async()=>{ui=renderer.create(React.createElement(AgentFeedback,{runId:'test-run',outputVersion:'test-version'}));});
  const button=label=>ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel===label)[0];
  const note=()=>ui.root.findAll(n=>n.type==='TextInput')[0];
  assert.equal(button('Save agent feedback').props.disabled,true);
  await act(async()=>{button('Mixed').props.onPress();note().props.onChangeText('Helpful, but needs more specifics.');});
  globalThis.fetch=async()=>{throw new Error('Network request failed');};
  await act(async()=>{await button('Save agent feedback').props.onPress();});
  assert.match(JSON.stringify(ui.toJSON()),/Cannot reach Stack/);assert.equal(note().props.value,'Helpful, but needs more specifics.');
  globalThis.fetch=async(url,options)=>{assert.match(url,/\/function\/agent_feedback$/);body=JSON.parse(options.body);return {ok:true,json:async()=>({data:{result:{feedback:[]}}})};};
  await act(async()=>{await button('Save agent feedback').props.onPress();});
  assert.deepEqual(body,{id:'test-run',output_version:'test-version',rating:'mixed',note:'Helpful, but needs more specifics.'});
  assert.match(JSON.stringify(ui.toJSON()),/Feedback saved/);assert.equal(note().props.value,'');assert.equal(button('Save agent feedback').props.disabled,true);
 }finally{globalThis.fetch=originalFetch;if(ui)await act(async()=>ui.unmount());}
 console.log('PASS Agent Feedback: rating/note required, failed-save draft retained, output-linked request, saved confirmation.');
}
async function resumeUnavailableTests(){
 const {ResumeUnavailable}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/components/ResumeUnavailable.js'));
 let ui;
 try{
  await act(async()=>{ui=renderer.create(React.createElement(ResumeUnavailable));});
  assert.match(JSON.stringify(ui.toJSON()),/temporarily unavailable/);
  assert.match(JSON.stringify(ui.toJSON()),/PDF remains saved/);
  assert.equal(ui.root.findAll(n=>n.type==='TextInput').length,0);
 }finally{if(ui)await act(async()=>ui.unmount());}
 console.log('PASS paused resume details: clear status, preserved upload, no editable parser fields.');
}
async function screenTests(){
 // Reuse the actual adapter, with only lifecycle timing replaced by explicit test refreshes.
 // Lifecycle timers are replaced by explicit ticks, so auto-refresh wiring is exercised deterministically.
 const refreshers=new Set();
 const TestLifecycle=({onRefresh})=>{const latest=React.useRef(onRefresh);latest.current=onRefresh;React.useEffect(()=>{const f=()=>latest.current();refreshers.add(f);return()=>refreshers.delete(f);},[]);return null;};
 const screenDevice={...device,Lifecycle:TestLifecycle,PDFView:({uri})=>React.createElement('PDF',{uri})};
 modules.set(path.join(root,'.jac/mobile-rn/jac-src/mobile/device.js'),{exports:screenDevice});
 const {app:App}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/main.js'));
 let ui;
 await act(async()=>{ui=renderer.create(React.createElement(App));await pause();});
 const text=()=>JSON.stringify(ui.toJSON());
 const button=label=>ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel===label)[0];
 const press=async label=>{for(let i=0;i<100&&button(label)?.props.disabled;i++)await act(async()=>{await new Promise(r=>setTimeout(r,100));});const b=button(label);assert.ok(b,'Missing '+label);assert.ok(!b.props.disabled,'Disabled '+label);await act(async()=>{await b.props.onPress();await pause();});};
 const until=async pattern=>{for(let i=0;i<100&&!pattern.test(text());i++)await act(async()=>{await new Promise(r=>setTimeout(r,50));});assert.match(text(),pattern);};
 const tick=async()=>{await act(async()=>{for(const f of [...refreshers])await f();await pause();});};
 const input=label=>ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel===label)[0];
 const labelled=pattern=>ui.root.findAll(n=>n.type==='Pressable'&&pattern.test(n.props.accessibilityLabel||''));
 const field=async(label,value)=>{const f=ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel===label)[0];assert.ok(f,'Missing field '+label);await act(async()=>f.props.onChangeText(value));};
 assert.match(text(),/Your next chapter/);
 await field('Username','ui_'+Date.now());await field('Password','Stack-test-'+Date.now());await press('Get started');
 assert.match(text(),/A little about you/);
 await field('Your name','UI Tester');await field('Target role',marker);await field('Expected graduation (YYYY-MM)','2027-05');await field('Available full-time from (YYYY-MM)','2027-06');
 await press('Experienced');await field('Years of experience in this field','3');await press('Full-time');await press('Part-time');await press('Pay');
 const imported=await device.rpc('import_job_url',{url:fixtureURL});
 const work=await worker('discovery_claim',{preferred_id:fixtureSource});
 assert.equal(work.id,fixtureSource);
 const fixtureJobs=Array.from({length:4},(_,i)=>({id:'job_'+crypto.createHash('sha256').update(fixtureURL+'/'+i).digest('hex').slice(0,32),identity:fixtureURL+'/'+i,canonical_url:fixtureURL+'/'+i,url:'https://jobs.smartrecruiters.com/StackLinkTest/'+marker+i+'?oga=true&trid=keep',title:marker+' Nurse '+i,company:'UI Test Employer',description:'Must be graduating between December 2026 and June 2027.',country:'US',location:'Detroit, MI',locations:['Detroit, MI'],mode:'Remote',employment_type:'Full-time',seniority:'Entry-level',occupation:'Healthcare practitioners',compensation:{min:30,max:40,unit:'hour',currency:'USD',estimated:false},salary:'USD 30–40 / hour',salary_note:'Employer-provided pay',source:'smartrecruiters',source_id:fixtureSource,source_name:'UI test',source_job_id:String(i),attribution:{},posted:'Today',posted_at:Date.now()/1000,checked_at:Date.now()/1000,discovered_at:Date.now()/1000,expires_at:0,snippet:false,requirements:[],qualifications:'',eligibility:'',remote_eligibility:'',initial:'U',color:'#EDF2FF',tags:['Full-time'],reason:'Matches your search filters.',demo:false}));
 await worker('discovery_complete',{id:fixtureSource,lease:work.lease,result:{jobs:fixtureJobs,complete:true}});
 await press('Find my next chapter');assert.match(text(),/Jobs/);
 const savedPrefs=(await device.rpc('bootstrap',{})).profile.preferences;assert.equal(savedPrefs.stage,'Experienced');assert.equal(savedPrefs.years,3);assert.deepEqual(savedPrefs.employment_types,['Full-time','Part-time']);assert.deepEqual(savedPrefs.soft,['salary']);for(let i=0;i<200&&!ui.root.findAll(n=>n.props.testID==='job-swipe-card').length;i++)await act(async()=>{await new Promise(r=>setTimeout(r,100));});assert.match(text(),/Graduation window matches/);assert.match(text(),/Meets your requirements/);assert.match(text(),/✓ Title contains/);await press('Open job');assert.match(openedLinks.at(-1),/^https:\/\/jobs.smartrecruiters.com\/StackLinkTest\//);assert.ok(!openedLinks.at(-1).includes('oga='));assert.ok(openedLinks.at(-1).includes('trid=keep'));const listingLink=openedLinks.at(-1);await press('Full details');await press('Open job');assert.equal(openedLinks.at(-1),listingLink);await press('Open application page');assert.ok(openedLinks.at(-1).includes('oga=true'));assert.match(text(),/Must be graduating between December 2026 and June 2027/);assert.match(text(),/HOW THIS MATCHES YOU/);assert.match(text(),/✓ Graduation timeline: Graduation window matches/);await press('Close job panel');
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
 const apply=button('Save job');await act(async()=>{await Promise.all([apply.props.onPress(),apply.props.onPress()]);});for(let i=0;i<100&&!(await device.rpc('bootstrap',{})).applications.length;i++)await pause();
 // A save is confirmed on screen, starts nothing, and offers optional agent help.
 for(let i=0;i<50&&!/Saved to Applications/.test(text());i++)await act(async()=>{await pause();});
 assert.match(text(),/Saved to Applications/);assert.match(text(),/Nothing was sent to the employer/);
 assert.equal((await device.rpc('bootstrap',{})).agents.runs.length,0);
 assert.ok(labelled(/^Explain my fit/).length&&!labelled(/^Prepare & apply/).length&&button('Build interview plan'));
 assert.equal(labelled(/^Agents: 0 active, 0 need you$/).length,1);
 await press('Build interview plan');await until(/practice sessions to Prep/);
 await press('Applications');assert.match(text(),/UI Test Employer/);
 const card=ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityRole==='button'&&!n.props.accessibilityLabel&&JSON.stringify(n.toJSON?.()||n.findAllByType('Text').map(t=>t.props.children)).includes('UI Test Employer'))[0];
 assert.ok(card,'Application card');await act(async()=>{card.props.onPress();});
 await field('Your notes','UI saved notes');
 const realFetch=globalThis.fetch;globalThis.fetch=async()=>{throw new Error('Network request failed');};
 try{await press('Save notes');assert.match(text(),/Cannot reach Stack/);assert.doesNotMatch(text(),/Saved to your Stack/);}finally{globalThis.fetch=realFetch;}
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
 if(process.env.STACK_TEST_AGENT_CONFIG) await agentScreenTests({ui,text,button,press,field,input,tick,labelled,until});
 await press('Open profile');assert.match(text(),/Your agent connection/);assert.ok(button('Agents: features, rules and activity'));assert.doesNotMatch(text(),/Planned/);await press('Sign out');assert.match(text(),/Create your Stack/);assert.equal(schedules.length,0);
 await act(async()=>ui.unmount());
 console.log('PASS Jac screens: signup, onboarding, apply, application notes, offline save/retry, reminder, filters, rapid repeated input, gestures, deck exhaustion, tab order, technical/behavioral prep guides, avatar profile, PDF upload/preview/cancel, sample preview, sign-out.');
}
async function agentScreenTests({ui,text,button,press,field,input,tick,labelled,until}){
 // Uses a dedicated test API config (never a real one) to bind this account to a local provider;
 // the test plays the worker, so no model, browser, or email is contacted.
 const config=process.env.STACK_TEST_AGENT_CONFIG,owner=(await device.rpc('bootstrap',{})).user_id;
 fs.writeFileSync(config,JSON.stringify({invite_only:false,provider:'codex-cli',local_cli_owner:owner,local_cli_daily_limit:20,action_daily_limits:{send_email:5}}));
 const finish=(work,result)=>agentWorker('agent_finish',{id:work.id,owner:work.owner,lease:work.lease,result});
 const openBadge=async()=>{const badge=labelled(/^Agents: /)[0];assert.ok(badge,'Agents header entry');await act(async()=>{await badge.props.onPress();await new Promise(r=>setTimeout(r,60));});};
 try{
  await press('Jobs');await openBadge();assert.match(text(),/Your agents\./);assert.match(text(),/No tasks are running/);await press('Needs you');assert.match(text(),/Nothing needs you right now/);
  await press('Features');for(const title of ['Networking & follow-ups','Resume tailoring','Job-fit analysis','Profile suggestions','Interview coaching','Code practice runs','Live interviews','Email tracking','Calendar assistant'])assert.ok(text().includes(title),title);
  assert.match(text(),/Meanwhile: /);assert.match(text(),/Your control: /);
  await press('Rules');await act(async()=>{ui.root.findAll(n=>n.type==='Switch')[0].props.onValueChange(true);});
  await press('Model');await press('Send Email');await field('Allowed destination domains','jobs.smartrecruiters.com, example.com');
  await tick();assert.equal(input('Allowed destination domains').props.value,'jobs.smartrecruiters.com, example.com','Refresh must keep unsaved rules');
  await press('Save standing permissions · unsaved changes');assert.match(text(),/Standing permissions saved/);
  await press('Facts');await field('Fact name','email');await field('Your answer','ui-tester@example.com');await press('Save confirmed fact');assert.match(text(),/ui-tester@example.com/);
  await device.rpc('agent_save_facts',{facts:[{key:'resume.project',value:'Completed clinical rotations.',verified:true}]});
  await press('Close details');await tick();

  // Network: saving a selected contact sends nothing; drafting is an explicit request that stops for review.
  await press('Network');await press('Add a contact');await field('Contact name','Casey Rivera');await field('Verified email','casey@example.com');await field('Company','Example');
  await press('Save contact');assert.match(text(),/Nothing was sent/);assert.equal((await device.rpc('agent_activity',{})).runs.length,0);
  await press('Draft outreach for my review');assert.match(text(),/You will review the email/);
  let work=await agentWorker('agent_claim');assert.equal(work.step,'research');await finish(work,{artifact:{summary:'',text:'',url:''}});
  work=await agentWorker('agent_claim');assert.equal(work.step,'draft');await finish(work,{artifact:{subject:'Hello from Stack',body:'Model draft',selected_fact_keys:[],evidence:[]}});
  assert.ok((await agentWorker('agent_claim')).idle,'Send must wait for review');
  await tick();assert.equal(labelled(/^Agents: 0 active, 1 need you$/).length,1);
  await press('Open task Networking outreach · Needs your review');
  await until(/NOTHING IS SHARED UNTIL YOU APPROVE/);assert.match(text(),/To: casey@example.com/);assert.match(text(),/Gmail sending is not connected/);
  assert.equal(input('Email subject').props.value,'Hello from Stack');await field('Email message','My own words');
  await tick();assert.equal(input('Email message').props.value,'My own words','Auto-refresh must keep unsaved edits');
  assert.ok(button('Approve and send').props.disabled,'Cannot approve without Gmail sending');
  await press('Back to tasks');await press('Open task Networking outreach · Needs your review');await until(/Email message/);assert.equal(input('Email message').props.value,'My own words','Reopening keeps edits');
  await press('Don’t do this · cancel task');assert.match(text(),/Cancelled. Nothing was shared/);
  assert.ok((await agentWorker('agent_claim')).idle);await press('Close details');

  // Application tracking remains manual; the independent fit workflow still works.
  await press('Applications');
  const card=ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityRole==='button'&&!n.props.accessibilityLabel&&JSON.stringify(n.findAllByType('Text').map(t=>t.props.children)).includes('UI Test Employer'))[0];
  await act(async()=>{card.props.onPress();});assert.match(text(),/Agent help/);
  assert.ok(!labelled(/^Prepare & apply/).length);
  assert.ok(button('Open application page')&&button('Mark as submitted'));
  await press('Explain my fit');
  work=await agentWorker('agent_claim');assert.equal(work.step,'fit');
  await finish(work,{artifact:{summary:'Clear timeline match.',strengths:['Graduation window matches'],gaps:[],unknowns:[],evidence:[]}});
  await tick();assert.ok((await agentWorker('agent_claim')).idle);
  await press('Close details');
 } finally {
  fs.writeFileSync(config,'{"invite_only":false}');
  // Leave the shared worker queue empty for suites that claim the next global task.
  for(const run of (await device.rpc('agent_activity',{})).runs)if(!['completed','cancelled','failed'].includes(run.status))await device.rpc('agent_cancel',{id:run.id}).catch(()=>{});
 }
 console.log('PASS agent screens: header counts, feature guide, rules draft kept on refresh, facts, contact save without outreach, outreach review/edit persistence/cancel, manual application tracking and standalone job-fit analysis.');
}
async function tailoringScreenTests(){
 const calls=[],refreshers=new Set();let opened='',confirmed=false,failSave=true,failUpload=true,ui;
 const component=(key,label,score)=>({key,label,score,weight:10});
 const scoreBefore={version:1,match:40,quality:70,match_components:[component('skills','Hard skills',35)],quality_components:[component('metrics','Quantified results',60)],missing:[],listed_only:[],keywords:[],stuffed:[],requirements:{},issues:[]};
 const scoreAfter={...scoreBefore,match:55,quality:78,match_components:[component('skills','Hard skills',52)],missing:[{term:'Kubernetes',required:true,supported:false}],listed_only:['Docker'],
  requirements:{years:{min:2},resume_years:1.5},issues:[{kind:'metric',id:'s1.e0.b1',where:'Experience · Analyst',text:'Built a tool',detail:'No number, %, $ or scale'}]};
 const pdfOnly=[{id:'resume',name:'Candidate.pdf',format:{kind:''},details_status:'Needs review'},{id:'latex',name:'Overleaf.pdf',format:{kind:'upload'},details_status:'Not parsed'}];
 let resumes=pdfOnly;const withFormat=kind=>resumes.map(r=>r.id==='resume'?{...r,format:{kind}}:r);
 let run={id:'tailor',kind:'resume',status:'needs_input',title:'Tailor resume',context_label:'Analyst at Example',created_at:1,updated_at:1,step_number:1,step_total:1,steps:['Tailor resume'],step_label:'Tailor resume',explanation:'Stack needs information from you to continue.',message:'',resume_id:'',resume_name:'',needs_resume_review:true,artifacts:{},results_where:'This task',cost_cents:0,subscription_calls:0};
 const review={name:'Candidate.pdf',revision:1,confirmed:false,sections:[{key:'profile',label:'Profile',summary:'Candidate',fields:[{key:'profile.name',label:'Name',value:'Candidate'}]}]};
 const TestLifecycle=({onRefresh})=>{const latest=React.useRef(onRefresh);latest.current=onRefresh;React.useEffect(()=>{const tick=()=>latest.current();refreshers.add(tick);return()=>refreshers.delete(tick);},[]);return null;};
 const rpc=async(name,args)=>{
  calls.push({name,args});
  if(name==='agent_start'||name==='agent_run')return run;
  if(name==='agent_extract_resume')return review;
  if(name==='resume_save_details'){
   if(failSave)throw new Error('Could not save details');
   assert.equal(args.confirm,true);confirmed=true;return {...review,confirmed:true,revision:2};
  }
  if(name==='bootstrap')return {resumes};
  if(name==='upload_resume_source'){assert.equal(args.id,'resume');assert.equal(args.name,'main.tex');if(failUpload)throw new Error('LaTeX error on line 3: Undefined control sequence');resumes=withFormat('upload').map(r=>r.id==='resume'?{...r,processing:{source:{id:'source-job',status:'completed'}}}:r);return {resumes};}
  if(name==='use_resume_template'){assert.ok(confirmed,'Template only after confirmed details');assert.equal(args.template,'jake');resumes=withFormat('builtin').map(r=>r.id==='resume'?{...r,processing:{source:{id:'template-job',status:'completed'}}}:r);return {resumes};}
  if(name==='agent_continue_tailoring'){
   assert.equal(args.id,'tailor');assert.ok(['','resume'].includes(args.resume_id));
   // A task started before any resume existed: Stack attaches the default resume, which is only a PDF.
   if(!run.resume_id){run={...run,resume_id:'resume',resume_name:'Candidate.pdf'};throw new Error('Upload the LaTeX for Candidate.pdf to tailor it.');}
   run={...run,status:'queued',needs_resume_review:false};return run;
  }
  if(name==='score_resume'){assert.equal(args.application_id,'application');throw new Error('PDF-only scoring is temporarily unavailable. Upload your LaTeX source to score this resume.');}
  if(name==='agent_approve'){assert.equal(args.step,'approve_resume');assert.equal(args.review_hash,'h1');assert.deepEqual(args.edits,{rejected:['s1.e0.b0']});const {review:_done,...rest}=run;run={...rest,status:'queued'};return run;}
  throw new Error('Unexpected RPC '+name);
 };
 modules.set(path.join(root,'.jac/mobile-rn/jac-src/mobile/device.js'),{exports:{...device,rpc,uploadResumeFile:async(name,args,onProgress)=>{onProgress({status:'uploading',percent:50});return rpc(name,args);},Lifecycle:TestLifecycle,PDFView:({uri})=>React.createElement('PDF',{uri}),pickLatexSource:async()=>({name:'main.tex',content:'XA=='}),previewDocument:async pdf=>{assert.ok(pdf.content);return 'cache/tailored.pdf';}}});
 const {ResumeAgents,TaskDetail}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/components/Agents.js'));
 const text=()=>JSON.stringify(ui.toJSON());
 const press=async label=>{const b=ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel===label)[0];assert.ok(b,'Missing '+label);assert.ok(!b.props.disabled,'Disabled '+label);await act(async()=>{await b.props.onPress();await pause();});};
 const features=[{key:'tailoring',title:'Tailor resume',state:'ready',summary:'Resume for this job',checks:[]}];
 const job=ready=>({id:'application',demo:false,job:{title:'Analyst',company:'Example'},tailor:{resume_id:'resume',resume_name:'Candidate.pdf',ready}});
 const agents=ready=>React.createElement(ResumeAgents,{applications:[job(ready)],runs:[],features,onOpenTask:id=>{opened=id;},onNavigate:()=>{},resumes,onChanged:()=>{}});
 // A PDF-only resume asks for its LaTeX right under the job; no task starts.
 await act(async()=>{ui=renderer.create(agents(false));});assert.match(text(),/needs its LaTeX/);
 // PDF-only scoring reports its temporary unavailability.
 await press('Score my resume');assert.match(text(),/PDF-only scoring is temporarily unavailable/);
 await press('Tailor for this job');assert.match(text(),/Add the LaTeX for Candidate.pdf/);assert.ok(!calls.some(c=>c.name==='agent_start'));
 await act(async()=>{ui.update(agents(true));});await act(async()=>{ui.unmount();ui=renderer.create(agents(true));});
 await press('Tailor for this job');assert.equal(opened,'tailor');
 // A task paused for LaTeX (for example, started before any resume existed) is labelled and fixed in place.
 await act(async()=>{ui.update(React.createElement(TaskDetail,{id:'tailor',features,webUrl:'',onBack:()=>{},onNavigate:()=>{}}));await pause();});
 const continued=()=>calls.filter(c=>c.name==='agent_continue_tailoring').length-1;
 assert.match(text(),/Needs your LaTeX/);assert.doesNotMatch(text(),/Needs your answers/);
 assert.match(text(),/Your resume is uploaded/);assert.doesNotMatch(text(),/Upload a resume first/);
 await press('Continue tailoring');assert.match(text(),/Upload the LaTeX for Candidate.pdf to tailor it/);assert.doesNotMatch(text(),/Tailoring started/);
 assert.match(text(),/Add the LaTeX for Candidate.pdf/);assert.match(text(),/Nothing has been generated yet/);assert.doesNotMatch(text(),/STACK NEEDS YOUR ANSWERS/);
 // Another resume that already has LaTeX is offered as a one-tap fix.
 assert.ok(ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel==='Use Overleaf.pdf instead · has LaTeX').length);
 // Uploading LaTeX here continues tailoring only once it compiles.
 await press('Upload LaTeX (.tex or Overleaf .zip)');assert.match(text(),/Undefined control sequence/);assert.equal(continued(),0);
 failUpload=false;await press('Upload LaTeX (.tex or Overleaf .zip)');assert.equal(run.status,'queued');assert.equal(continued(),1);
 assert.match(text(),/Tailoring started/);assert.doesNotMatch(text(),/ONE STEP BEFORE TAILORING/);
 // The retired PDF-to-template path cannot be entered from the tailoring UI.
 resumes=pdfOnly;run={...run,status:'needs_input',needs_resume_review:true};await act(async()=>{for(const tick of refreshers)await tick();await pause();});
 assert.match(text(),/Building a template from PDF details is temporarily unavailable/);
 assert.ok(!calls.some(c=>c.name==='agent_extract_resume'||c.name==='resume_save_details'||c.name==='use_resume_template'));
 const original='Original '.repeat(220)+'ORIGINAL END',tailored='Tailored '.repeat(220)+'TAILORED END';
 const changes=[{id:'s1.e0.b0',kind:'rewrite',where:'Experience · Analyst',before:'Built a **tool**.',after:'Built an analysis **tool** for finance.',reason:'Matches the listing.'},
  {id:'omit:s2.e1',kind:'omit',where:'Projects · Game',before:'Game',after:'',reason:'Unrelated to finance.'}];
 const dropped=[{id:'s1.e0.b3',where:'Experience · Analyst',text:'Least relevant detail'}];
 const proposal={summary:'Leads with analysis work',changes,dropped,notes:['Kept a bullet unchanged: the rewrite mentioned kubernetes, which is not in your resume.'],rejected:[],final:false,format:'latex',tex:'\\resumeItem{Built an analysis tool}',pdf:{name:'Tailored resume.pdf',content:'JVBERi0=',pages:1,original_text:original,text:tailored,diff:''}};
 run={...run,status:'review',step_number:2,step_total:2,steps:['Tailor your resume','Approve resume changes'],step_label:'Approve resume changes',
  review:{step:'approve_resume',hash:'h1',title:'Review your tailored resume for Example',score:{before:scoreBefore,after:scoreAfter},summary:'Leads with analysis work',changes,rejected:[],dropped,pages:1,notes:[],consequence:'Stack keeps the changes you accept, rebuilds the PDF in your format, and fits it to one page. Nothing is shared.'},
  artifacts:{tailor:proposal}};
 await act(async()=>{for(const tick of refreshers)await tick();await pause();});
 assert.match(text(),/Review your tailored resume for Example/);assert.match(text(),/CHANGES · 2 OF 2 KEPT/);
 assert.match(text(),/Job match: 40 → 55 \(\+15\)/);assert.match(text(),/Resume quality: 70 → 78 \(\+8\)/);
 await press('Score details');assert.match(text(),/Hard skills 35 → 52/);assert.match(text(),/Missing from your resume \(add only if true\): Kubernetes · required/);
 assert.match(text(),/Only on your skills line: Docker/);assert.match(text(),/asks for 2\+ years; Stack counts about 1.5/);assert.match(text(),/not a prediction of hiring/);await press('Hide score details');
 assert.match(text(),/Built an analysis tool for finance/);assert.match(text(),/LEFT OUT TO FIT ONE PAGE/);assert.match(text(),/Least relevant detail/);
 await press('Preview proposed resume');assert.equal(ui.root.findByType('PDF').props.uri,'cache/tailored.pdf');await press('Close preview');
 await press('Reject');assert.match(text(),/CHANGES · 1 OF 2 KEPT/);
 // The choice survives a refresh of the same review.
 await act(async()=>{for(const tick of refreshers)await tick();await pause();});assert.match(text(),/CHANGES · 1 OF 2 KEPT/);
 await press('Apply the changes I kept');assert.equal(run.status,'queued');
 const {review:_reviewed,...rest}=run;
 run={...rest,status:'completed',artifacts:{tailor:{...proposal,rejected:['s1.e0.b0'],final:true},approve_resume:{summary:'Applied 1 of 2 changes.'}}};
 await act(async()=>{for(const tick of refreshers)await tick();await pause();});
 assert.match(text(),/Your tailored resume/);assert.match(text(),/Rejected · your original stays/);assert.match(text(),/your LaTeX format/);
 assert.match(text(),/not in your resume/);assert.match(text(),/Applied 1 of 2 changes/);
 await press('Original text');assert.match(text(),/ORIGINAL END/);assert.doesNotMatch(text(),/TAILORED END/);
 await press('Tailored text');assert.match(text(),/TAILORED END/);
 await press('LaTeX');assert.match(text(),/resumeItem\{Built an analysis tool\}/);
 await press('Preview tailored resume');assert.equal(ui.root.findByType('PDF').props.uri,'cache/tailored.pdf');assert.doesNotMatch(text(),/TAILORED END/);
 await press('Close preview');assert.equal(ui.root.findAllByType('PDF').length,0);assert.match(text(),/Your tailored resume/);
 await act(async()=>ui.unmount());
 console.log('PASS tailoring screens: LaTeX upload resumes after compilation; PDF detail building and PDF-only scoring unavailable; per-change review, rejection persistence, approval, final PDF and source preview.');
}

// End to end against a real API and agent worker (see docs/RESUME_TAILORING.md): the real screens, a real
// Codex/Claude subscription call, and real Tectonic compiles. Only the phone's file picker is simulated,
// returning real fixture files. The job is saved before any resume exists, as a new user would.
async function tailoringEndToEnd(){
 const configPath=process.env.STACK_E2E_AGENT_CONFIG;assert.ok(configPath,'Set STACK_E2E_AGENT_CONFIG to the isolated API agent config');
 const refreshers=new Set();
 const TestLifecycle=({onRefresh})=>{const latest=React.useRef(onRefresh);latest.current=onRefresh;React.useEffect(()=>{const f=()=>latest.current();refreshers.add(f);return()=>refreshers.delete(f);},[]);return null;};
 files.readAsStringAsync=async uri=>fs.readFileSync(uri).toString('base64');files.getInfoAsync=async uri=>({size:fs.existsSync(uri)?fs.statSync(uri).size:50});
 const pick=(file,name)=>{pickerResult={canceled:false,assets:[{uri:path.join(root,file),name,size:fs.statSync(path.join(root,file)).size}]};};
 // The adapter copies the file-system module when it loads, so load a fresh one that reads the picked files.
 modules.delete(path.join(root,'native/device.js'));const device=load(path.join(root,'native/device.js'));
 modules.set(path.join(root,'.jac/mobile-rn/jac-src/mobile/device.js'),{exports:{...device,Lifecycle:TestLifecycle,PDFView:({uri})=>React.createElement('PDF',{uri})}});
 const {app:App}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/main.js'));
 let ui;await act(async()=>{ui=renderer.create(React.createElement(App));await pause();});
 const text=()=>JSON.stringify(ui.toJSON());
 const buttons=label=>ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel===label);
 const tap=async b=>{for(let i=0;i<600&&b.props.disabled;i++)await act(async()=>{await new Promise(r=>setTimeout(r,100));});assert.ok(!b.props.disabled,'Disabled '+b.props.accessibilityLabel);await act(async()=>{await b.props.onPress();await pause();});};
 const press=async(label,index=0)=>{const b=buttons(label).at(index);assert.ok(b,'Missing '+label+'\nSCREEN: '+visible());await tap(b);};
 const field=async(label,value)=>{const f=ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel===label)[0];assert.ok(f,'Missing field '+label);await act(async()=>f.props.onChangeText(value));};
 // What the user can read, for failure messages.
 const visible=()=>ui.root.findAll(n=>n.type==='Text').map(n=>[].concat(n.props.children).filter(c=>typeof c==='string'||typeof c==='number').join('')).filter(Boolean).join(' | ');
 const until=async(pattern,seconds,label)=>{for(let i=0;i<seconds&&!pattern.test(text());i++){await act(async()=>{for(const f of [...refreshers])await f();await new Promise(r=>setTimeout(r,1000));});}
  assert.match(text(),pattern,label+'\nSCREEN: '+visible());};
 const step=m=>console.log('  · '+m);

 await field('Username','e2e_'+Date.now());await field('Password','Stack-test-'+Date.now());await press('Get started');
 await field('Your name','E2E Tester');await field('Target role',marker);await field('Expected graduation (YYYY-MM)','2027-05');await field('Available full-time from (YYYY-MM)','2027-06');
 await press('Experienced');await field('Years of experience in this field','2');await press('Full-time');
 const owner=(await device.rpc('bootstrap',{})).user_id;
 fs.writeFileSync(configPath,JSON.stringify({invite_only:false,provider:process.env.STACK_E2E_PROVIDER||'codex-cli',local_cli_owner:owner,local_cli_daily_limit:50}));
 await device.rpc('agent_save_policy',{policy:{enabled:true,expires_at:Date.now()/1000+3600,actions:['model'],domains:[],daily_limits:{},followup_limit:0,followup_days:7,analyze_top_matches:false}});
 await device.rpc('import_job_url',{url:fixtureURL});const work=await worker('discovery_claim',{preferred_id:fixtureSource});
 const now=Date.now()/1000,jobIds=[0,1].map(i=>'job_'+crypto.createHash('sha256').update(fixtureURL+'/'+i).digest('hex').slice(0,32));
 const descriptions=['Build REST APIs in Python and Flask, work with PostgreSQL, and write React front ends. Experience with data pipelines is a plus.','Own data pipelines and analytics in Python and SQL, and present findings to stakeholders.'];
 await worker('discovery_complete',{id:fixtureSource,lease:work.lease,result:{complete:true,jobs:[0,1].map(i=>({id:jobIds[i],identity:fixtureURL+'/'+i,canonical_url:fixtureURL+'/'+i,url:'https://jobs.lever.co/stacke2e/'+marker+i,title:marker+[' Software Engineer',' Data Engineer'][i],company:'E2E Employer',
  description:descriptions[i],country:'US',location:'Detroit, MI',locations:['Detroit, MI'],mode:'Remote',employment_type:'Full-time',seniority:'Entry-level',occupation:'Software',compensation:{},salary:'Pay not listed',salary_note:'',source:'smartrecruiters',source_id:fixtureSource,source_name:'E2E',source_job_id:String(i),attribution:{},posted:'Today',posted_at:now,checked_at:now,discovered_at:now,expires_at:0,snippet:false,requirements:[],qualifications:'',eligibility:'',remote_eligibility:'',initial:'E',color:'#EDF2FF',tags:['Full-time'],reason:'E2E',demo:false}))}});
 await press('Find my next chapter');
 for(let i=0;i<200&&!ui.root.findAll(n=>n.props.testID==='job-swipe-card').length;i++)await act(async()=>{await new Promise(r=>setTimeout(r,100));});
 await press('Save job');await until(/Saved to Applications/,20,'Job saved');step('job saved before any resume exists');
 const firstTitle=(await device.rpc('bootstrap',{})).applications.find(a=>!a.demo).job.title;

 await press('Resume');
 pick('tests/fixtures/synthetic-resume.pdf','Candidate.pdf');await press('Upload PDF resume');await until(/Candidate.pdf/,20,'PDF uploaded');
 assert.match(text(),/TAILORING FORMAT/);assert.match(text(),/No LaTeX yet/);assert.ok(buttons('Upload LaTeX (.tex or Overleaf .zip)').length,'Resume card offers a LaTeX upload');
 assert.match(text(),/Upload the LaTeX for Candidate.pdf/,'Readiness names the missing LaTeX');assert.doesNotMatch(text(),/"Ready"/,'Tailoring is not shown as ready');
 assert.match(text(),/Resume: Candidate.pdf · needs its LaTeX/);step('PDF only: readiness and the job both say LaTeX is needed');
 await press('Score my resume');await until(/SCORE FOR THIS JOB · YOUR PDF/,30,'Job-row score from the PDF');
 assert.match(visible(),/Job match: \d+/);assert.match(visible(),/Resume quality: \d+/);step('scored the PDF for the job without a model: '+visible().match(/Job match: \d+/)[0]);

 await press('Tailor for this job');
 assert.match(text(),/Add the LaTeX for Candidate.pdf/);assert.equal((await device.rpc('agent_activity',{})).runs.length,0,'No task is started without LaTeX');
 assert.equal(buttons('Upload LaTeX (.tex or Overleaf .zip)').length,2,'Card and the tailoring panel both offer upload');
 const fixture='tests/fixtures/linebreak-skills-resume.tex',fixtureTex=fs.readFileSync(path.join(root,fixture),'utf8');
 const broken=path.join('tests/fixtures','.e2e-broken.tex');fs.writeFileSync(path.join(root,broken),fixtureTex.replace('\\section{Projects}','\\section{Projects}\\undefinedmacro'));
 try{pick(broken,'broken.tex');await press('Upload LaTeX (.tex or Overleaf .zip)',-1);}finally{fs.unlinkSync(path.join(root,broken));}
 await until(/could not compile/i,120,'Compile error shown');assert.equal((await device.rpc('agent_activity',{})).runs.length,0,'A failed compile starts nothing');step('broken LaTeX: error shown, nothing started');
 pick(fixture,'main.tex');await press('Upload LaTeX (.tex or Overleaf .zip)',-1);
 await until(/Tailor resume|Working|Queued/,180,'Tailoring task opened');step('LaTeX uploaded from the tailoring panel; task started and opened');
 const run=(await device.rpc('agent_activity',{})).runs[0];assert.equal(run.kind,'resume');
 await until(/Review your tailored resume/,600,'Model proposal ready for review');
 assert.match(visible(),/SCORE FOR THIS JOB · WITH EVERY CHANGE/);const reviewScore=visible().split('WITH EVERY CHANGE | ')[1].split(' | ')[0];assert.match(reviewScore,/^Job match: \d+/);
 const proposed=(await device.rpc('agent_run',{id:(await device.rpc('agent_activity',{})).runs[0].id})).artifacts.tailor.score;
 assert.ok(proposed.before.match!=null&&proposed.after.match!=null&&proposed.after.quality!=null,JSON.stringify(proposed));
 assert.match(text(),/CHANGES · \d+ OF \d+ KEPT/);assert.doesNotMatch(text(),/STACK NEEDS YOUR ANSWERS|ONE STEP BEFORE TAILORING/);
 const proposal=(await device.rpc('agent_run',{id:run.id})).artifacts.tailor;
 assert.equal(proposal.format,'latex');assert.equal(proposal.pdf.pages,1);assert.ok(Buffer.from(proposal.pdf.content,'base64').subarray(0,5).toString()==='%PDF-');
 const moved=(kind)=>proposal.score.after[kind+'_components'].filter(c=>{const b=proposal.score.before[kind+'_components'].find(x=>x.key===c.key);return !b||b.score!==c.score;}).map(c=>c.label+' '+(proposal.score.before[kind+'_components'].find(x=>x.key===c.key)||{}).score+'→'+c.score);
 step('proposal: '+proposal.changes.length+' changes ('+proposal.changes.map(c=>c.kind).join(', ')+'), '+proposal.pdf.pages+' page; '+reviewScore+', quality '+proposal.score.before.quality+' → '+proposal.score.after.quality+' ['+moved('match').concat(moved('quality')).join('; ')+']');
 await press('Apply the changes I kept');
 await until(/Preview tailored resume/,300,'Final PDF built');
 const done=await device.rpc('agent_run',{id:run.id});
 assert.equal(done.status,'completed');assert.ok(done.artifacts.tailor.final);assert.equal(done.artifacts.tailor.pdf.pages,1);
 const finalTex=done.artifacts.tailor.tex;
 assert.ok(finalTex.startsWith(fixtureTex.split('\\begin{document}')[0]),'Preamble unchanged');
 assert.equal(finalTex.slice(finalTex.indexOf('\\section{Technical Skills}')).split('\\\\[3pt]').length-1,3,'Skill line breaks kept');
 for(const label of ['Languages:','Frameworks \\& Runtimes:','Data \\& ML:','Platforms \\& Tools:'])assert.ok(finalTex.includes('\\textbf{'+label+'}'),'Skill label kept: '+label);
 assert.ok(finalTex.indexOf('Harbor Logistics')<finalTex.indexOf('Lakeside Analytics'),'Experience keeps date order');
 step('approved: final one-page PDF, preamble, skill layout and Experience order unchanged');

 // The approved resume is saved under Resume → Tailored resumes, labelled with its job and checked by the parser.
 await press('Open Tailored resumes');await until(/Tailored for E2E Employer/,20,'Tailored resume listed on arrival');
 assert.match(visible(),/YOUR UPLOADS/);assert.match(visible(),/Tailored for E2E Employer/);assert.ok(visible().includes(firstTitle),'Saved job title shown');
 assert.match(visible(),/PDF parser checks are temporarily unavailable/);


 // A task that paused because its resume lost its LaTeX (as when a preview switch replaced the data) is fixed from the task.
 const workerPid=Number(process.env.STACK_E2E_WORKER_PID);assert.ok(workerPid,'Set STACK_E2E_WORKER_PID');
 const state=await device.rpc('bootstrap',{}),resumeId=state.resumes[0].id;
 const saved=new Set(state.applications.map(a=>a.job_id));const second=jobIds.find(j=>!saved.has(j));
 const app=(await device.rpc('swipe',{job_id:second,action:'apply'})).applications.find(a=>a.job_id===second);
 process.kill(workerPid,'SIGSTOP');let pausedRun;
 try{pausedRun=await device.rpc('agent_start',{kind:'resume',target_id:app.id});await device.rpc('use_resume_template',{id:resumeId,template:''});}
 finally{process.kill(workerPid,'SIGCONT');}
 for(let i=0;i<60&&!(await device.rpc('agent_run',{id:pausedRun.id})).needs_resume_review;i++)await new Promise(r=>setTimeout(r,1000));
 assert.ok((await device.rpc('agent_run',{id:pausedRun.id})).needs_resume_review,'Worker paused the task for LaTeX');
 await tap(ui.root.findAll(n=>n.type==='Pressable'&&/^Agents: /.test(n.props.accessibilityLabel||''))[0]);await until(/Needs you \(\d+\)/,20,'Hub shows a task needing you');
 await tap(ui.root.findAll(n=>n.type==='Pressable'&&/^Needs you/.test(n.props.accessibilityLabel||''))[0]);
 await until(/Needs your LaTeX/,20,'Paused task is labelled as needing LaTeX');assert.doesNotMatch(visible(),/Needs your answers/);
 await tap(ui.root.findAll(n=>n.type==='Pressable'&&/^Open task .* · Needs your LaTeX$/.test(n.props.accessibilityLabel||''))[0]);
 await until(/Add the LaTeX for Candidate.pdf/,30,'Paused task offers the LaTeX upload');assert.doesNotMatch(visible(),/STACK NEEDS YOUR ANSWERS/);
 pick(fixture,'main.tex');await press('Upload LaTeX (.tex or Overleaf .zip)',-1);
 await until(/Review your tailored resume/,600,'Paused task continued to a proposal');step('paused task: LaTeX uploaded from the task, tailoring continued');
 await press('Apply the changes I kept');await until(/Preview tailored resume/,300,'Final PDF built');
 const resumed=await device.rpc('agent_run',{id:pausedRun.id});assert.equal(resumed.status,'completed');assert.equal(resumed.artifacts.tailor.pdf.pages,1);
 // Saved resumes explicitly report that parser checks are unavailable.
 let both=[];for(let i=0;i<30;i++){both=(await device.rpc('bootstrap',{})).tailored_resumes;if(both.length===2&&both.every(x=>x.parse.checks))break;await new Promise(r=>setTimeout(r,1000));}
 assert.equal(both.length,2);assert.ok(both.every(x=>x.parse.available===false&&x.parse.total===0),JSON.stringify(both.map(x=>x.parse)));
 assert.equal(new Set(both.map(x=>x.job_title)).size,2,'Second job saved separately');
 console.log('PASS tailoring end to end: both paths, '+(done.subscription_calls+resumed.subscription_calls)+' model calls, one-page PDFs from your LaTeX.');
}

async function browserKeyboardTests(){
 let ui,release,hold=false;
 const frame={image:'fixture-frame',width:430,height:780,url:'https://www.linkedin.com/login'};
 const requestBrowser=async()=>hold?new Promise(resolve=>{release=()=>resolve(frame);}):frame;
 const button=label=>ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel===label)[0];
 const input=()=>ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel==='Private browser input')[0];
 try {
  await act(async()=>{ui=renderer.create(React.createElement(device.AgentBrowser,{id:'keyboard-test',interactive:true,requestBrowser}));await pause();});
  for(const fullScreen of [false,true]){
   if(fullScreen)await act(async()=>button('Full screen').props.onPress());
   const original=input();
   await act(async()=>input().props.onChangeText('partially-typed'));
   hold=true;
   await act(async()=>{button('Refresh browser').props.onPress();await pause();});
   assert.ok(button('Refresh browser').props.disabled,'Snapshot is still in flight');
   assert.notEqual(input().props.editable,false,'In-flight screen refresh must not disable the login input');
   assert.equal(input(),original,'Screen refresh must not replace the native input');
   await act(async()=>input().props.onChangeText('continued-during-refresh'));
   await act(async()=>input().props.onSubmitEditing());
   assert.equal(input().props.value,'continued-during-refresh','A busy connection must not discard unsent login input');
   hold=false;
   await act(async()=>{release();release=null;await pause();});
   assert.equal(input(),original);
   assert.equal(input().props.value,'continued-during-refresh','Receiving a frame preserves local typing');
  }
 } finally {
  await act(async()=>{if(release)release();if(ui)ui.unmount();});
 }
 console.log('PASS browser input: remains mounted and editable during pending snapshots; typing and unsent input survive refreshes in embedded and full-screen views.');
}
async function linkedinScreenTests(){
 const calls=[],refreshers=new Set();let ui,opened='',failStart=true,failBrowser=true,expiredBrowser=false,storedLinkedInUrl='';
 let run={id:'linkedin',kind:'linkedin',status:'needs_input',title:'LinkedIn profile review',context_label:'Candidate',created_at:1,updated_at:1,step_number:1,step_total:2,steps:['Sign in and read your profile','Analyze recruiter appeal'],step_label:'Sign in and read your profile',explanation:'Sign in and confirm your profile.',message:'',requests:[{key:'browser',label:'Sign in through the browser.'}],artifacts:{},results_where:'This task',cost_cents:0,subscription_calls:0};
 const Lifecycle=({onRefresh})=>{const latest=React.useRef(onRefresh);latest.current=onRefresh;React.useEffect(()=>{const tick=()=>latest.current();refreshers.add(tick);return()=>refreshers.delete(tick);},[]);return null;};
 const rpc=async(name,args)=>{
  calls.push({name,args});
  if(name==='agent_linkedin_start'){if(failStart)throw new Error('Browser worker unavailable');return run;}
  if(name==='agent_linkedin_profile'){if(args.url!==undefined)storedLinkedInUrl=args.url;return {url:storedLinkedInUrl};}
  if(name==='agent_run')return run;
  if(name==='agent_browser'){if(failBrowser)throw new Error('Browser connection failed');if(args.event.type==='reopen')expiredBrowser=false;if(expiredBrowser)return {expired:true};return {image:'fixture-jpeg',width:430,height:780,url:'https://www.linkedin.com/login'};}
  if(name==='agent_retry'){run={...run,status:'queued'};return run;}
  if(name==='agent_respond'){assert.deepEqual(args.values,[]);run={...run,status:'queued'};return run;}
  throw new Error('Unexpected RPC '+name);
 };
 modules.set(path.join(root,'.jac/mobile-rn/jac-src/mobile/device.js'),{exports:{...device,rpc,Lifecycle}});
 const {LinkedInProfile}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/components/LinkedInProfile.js'));
 const {TaskDetail}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/components/Agents.js'));
 const text=()=>JSON.stringify(ui.toJSON());
 const button=label=>ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel===label)[0];
 const press=async label=>{const b=button(label);assert.ok(b,'Missing '+label);assert.ok(!b.props.disabled,'Disabled '+label);await act(async()=>{await b.props.onPress();await pause();});};
 const field=async(label,value)=>{const f=ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel===label)[0];assert.ok(f,'Missing '+label);await act(async()=>f.props.onChangeText(value));};
 const features=[{key:'linkedin',kinds:['linkedin'],title:'LinkedIn profile review',state:'ready',summary:'Analyze your profile',checks:[]}];
 await act(async()=>{ui=renderer.create(React.createElement(LinkedInProfile,{features,runs:[],onOpenTask:id=>{opened=id;},onNavigate:()=>{}}));});
 assert.ok(button('Review my LinkedIn profile').props.disabled);
 await field('Your LinkedIn profile URL','https://www.linkedin.com/in/candidate/');await field('Target role (optional)','Product designer');
 await press('Save profile details');assert.equal(storedLinkedInUrl,'https://www.linkedin.com/in/candidate/');
 await press('Review my LinkedIn profile');assert.match(text(),/Browser worker unavailable/);
 assert.match(text(),/https:\/\/www.linkedin.com\/in\/candidate\//);
 failStart=false;await press('Review my LinkedIn profile');assert.equal(opened,'linkedin');
 assert.deepEqual(calls.at(-1),{name:'agent_linkedin_start',args:{url:'https://www.linkedin.com/in/candidate/',target_role:'Product designer'}});
 await act(async()=>{ui.update(React.createElement(TaskDetail,{id:'linkedin',features,webUrl:'https://stack.example.com',onBack:()=>{},onNavigate:()=>{}}));await pause();});
 assert.match(text(),/Browser connection failed/);assert.ok(!text().includes('Opening the agent’s browser'),'Failure must not look like ongoing loading');
 failBrowser=false;await press('Refresh browser');
 assert.equal(openedLinks.length,0,'Phone stays in the exact agent browser');
 const privateInput=()=>ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel==='Private browser input')[0];
 assert.equal(privateInput().props.secureTextEntry,true);
 assert.equal(ui.root.findAll(n=>n.type==='TextInput').length,1,'Only a transient private input, no credential facts');
 const page=button('Agent browser page');
 await act(async()=>page.props.onLayout({nativeEvent:{layout:{width:215}}}));
 await act(async()=>{await button('Agent browser page').props.onPress({nativeEvent:{locationX:100,locationY:150}});await pause();});
 assert.deepEqual(calls.at(-1),{name:'agent_browser',args:{id:'linkedin',event:{type:'click',x:200,y:300}}});
 await field('Private browser input','synthetic-private-value');await press('Type in browser');
 assert.equal(privateInput().props.value,'');
 assert.deepEqual(calls.at(-1).args.event,{type:'text',text:'synthetic-private-value'});
 await press('Open LinkedIn sign-in');assert.equal(calls.at(-1).args.event.type,'login');
 expiredBrowser=true;await press('Refresh browser');assert.match(text(),/This browser session ended/);assert.ok(!text().includes('Opening the agent’s browser'));assert.equal(ui.root.findAll(n=>n.type==='TextInput').length,0);
 await press('Open browser again');assert.ok(button('Agent browser page'));
 await press('Full screen');assert.ok(button('Close full screen'));await press('Close full screen');
 await press('I’m signed in · Analyze my profile');assert.equal(run.status,'queued');
 assert.ok(button('Agent browser page').props.disabled,'Watch-only while the agent is working');
 assert.equal(ui.root.findAll(n=>n.type==='TextInput').length,0);
 assert.ok(!JSON.stringify(calls.filter(c=>c.name==='agent_respond')).includes('synthetic-private-value'));

 run={...run,status:'needs_input',step_number:2,requests:[],message:'The model response could not be validated against its sources.',artifacts:{linkedin_scan:{sections:{intro:'Candidate'}}}};
 await act(async()=>{for(const tick of refreshers)await tick();await pause();});
 assert.match(text(),/ANALYSIS PAUSED/);assert.ok(!text().includes('STACK NEEDS YOUR ANSWERS'));assert.equal(ui.root.findAll(n=>n.type==='TextInput').length,0);
 await press('Retry analysis');assert.equal(run.status,'queued');assert.ok(run.artifacts.linkedin_scan);
 run={...run,status:'blocked'};
 await act(async()=>{for(const tick of refreshers)await tick();await pause();});
 await press('Retry analysis');assert.equal(calls.at(-1).name,'agent_retry');assert.ok(run.artifacts.linkedin_scan);
 run={...run,status:'completed',step_number:2,artifacts:{linkedin_review:{summary:'Clarify your impact.',profile_url:'https://www.linkedin.com/in/candidate/',captured_at:1,strengths:['Relevant work.'],findings:[{priority:'high',section:'about',weakness:'Generic positioning',quote:'I build tools.',why_it_matters:'Recruiters need your focus.',recommendation:'Name your audience.'}],rewrites:[{section:'headline',text:'Product designer | Building tools'}],questions:['What impact did you have?'],limitations:'Only visible text was captured.',unread_sections:['skills']}}};
 await act(async()=>{for(const tick of refreshers)await tick();await pause();});
 for(const expected of ['Generic positioning','I build tools.','Name your audience.','Product designer | Building tools','Sections not read: skills'])assert.ok(text().includes(expected),expected);
 assert.ok(ui.root.findAll(n=>n.type==='Text'&&n.props.selectable===true).length>0,'Rewrites can be copied');
 await act(async()=>{ui.update(React.createElement(LinkedInProfile,{key:'reopen-saved',features,runs:[],onOpenTask:()=>{},onNavigate:()=>{}}));await pause();});
 assert.equal(ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel==='Your LinkedIn profile URL')[0].props.value,storedLinkedInUrl);
 storedLinkedInUrl='';
 await act(async()=>{ui.update(React.createElement(LinkedInProfile,{key:'other-account',features,runs:[],onOpenTask:()=>{},onNavigate:()=>{}}));await pause();});
 assert.equal(ui.root.findAll(n=>n.type==='TextInput'&&n.props.accessibilityLabel==='Your LinkedIn profile URL')[0].props.value,'','Another account must not see the previous URL');
 await act(async()=>ui.unmount());
 console.log('PASS LinkedIn screens: URL/role, failure preserves form, starts task, browser handoff, no credential fact fields, resume, findings and copyable rewrites.');
}
async function linkedinWebTests(){
 let ui,events=[],calls=[];
 let run={id:'linkedin-web',kind:'linkedin',status:'needs_input',step:'linkedin_scan',title:'LinkedIn profile review',context_label:'Candidate',explanation:'Sign in to continue.',message:'Confirm this is your profile.',steps:['Sign in and read your profile','Analyze recruiter appeal'],requests:[{key:'browser',label:'Sign in'}],artifacts:{},results_where:'This task'};
 const compiled=path.join(root,'.jac/client/workspace/compiled/web');
 const transport=load(path.join(root,'web/transport.js'));
 const rpc=async(name,args)=>{
  calls.push({name,args});
  if(name==='agent_settings')return {activity:{runs:[]}};
  if(name==='prep_catalog')return {problems:[]};
  if(name==='prep_sessions')return {sessions:[]};
  if(name==='agent_events')return {events:[],interviews:[]};
  if(name==='bootstrap')return {applications:[],agents:{features:[]}};
  if(name==='agent_linkedin_profile')return {url:''};
  if(name==='agent_linkedin_start'||name==='agent_run')return run;
  if(name==='agent_browser'){events.push(args.event);return {private_login:true,url:'https://www.linkedin.com/login',image:'fixture',width:1100,height:800};}
  if(name==='agent_respond'){assert.deepEqual(args.values,[]);run={...run,status:'completed',step:'linkedin_review',artifacts:{linkedin_review:{summary:'Make impact clearer.',findings:[{section:'about',priority:'high',weakness:'Generic language',quote:'I build tools.',why_it_matters:'Recruiters need detail.',recommendation:'Name your audience.'}],rewrites:[{section:'headline',text:'Software engineer | Building tools'}],questions:['Which audience?'],limitations:'Visible text only.',unread_sections:['skills']}}};return run;}
  throw new Error('Unexpected RPC '+name);
 };
 modules.set(path.join(compiled,'transport.js'),{exports:{...transport,rpc,login:async()=>{},oauthResult:()=>({}),Poll:()=>null}});
 modules.set(path.join(compiled,'style.css'),{exports:{}});
 const {app:App}=load(path.join(compiled,'main.js'));
 // This suite also loads native bindings; select DOM rendering for the web screen.
 globalThis.__jacRenderer__={create:(tag,props,children)=>React.createElement(tag,props,...children)};
 const text=()=>JSON.stringify(ui.toJSON());
 const press=async label=>{const b=ui.root.findAll(n=>n.type==='button'&&n.children.join('')===label)[0];assert.ok(b,'Missing '+label);assert.ok(!b.props.disabled);await act(async()=>{await b.props.onClick();await pause();});};
 const field=async(label,value)=>{const row=ui.root.findAll(n=>n.type==='label'&&n.children[0]===label)[0];assert.ok(row,'Missing '+label);await act(async()=>row.findByType('input').props.onChange({target:{value}}));};
 await act(async()=>{ui=renderer.create(React.createElement(App));await pause();});
 await field('Username','fixture');await field('Password','fixture');await press('Continue');await press('Network');
 await field('Your LinkedIn profile URL','https://www.linkedin.com/in/candidate/');await field('Target role (optional)','Engineer');await press('Review my LinkedIn profile');
 assert.ok(calls.some(c=>c.name==='agent_linkedin_start'&&c.args.target_role==='Engineer'));
 await press('Open same browser session');assert.match(text(),/linkedin.com\/login/);
 assert.equal(ui.root.findAll(n=>n.type==='input'&&n.props['aria-label']==='Type into selected browser field').length,0);
 const keyboard=ui.root.findAll(n=>n.type==='textarea'&&n.props['aria-label']==='Task browser keyboard')[0];assert.ok(keyboard);assert.equal(keyboard.props.autoComplete,'off');
 for(const label of ['Tab','Enter','Backspace'])assert.equal(ui.root.findAll(n=>n.type==='button'&&n.children.join('')===label).length,0);
 assert.equal(ui.root.findAll(n=>n.type==='input'&&n.props.type==='file').length,0);
 const inputEvent={currentTarget:{value:'temporary-login-input'}};
 await act(async()=>{keyboard.props.onInput(inputEvent);keyboard.props.onKeyDown({key:'Enter',preventDefault(){}});await pause();});assert.equal(inputEvent.currentTarget.value,'');assert.deepEqual(events.slice(-2),[{type:'text',text:'temporary-login-input'},{type:'key',key:'Enter'}]);
 await press('Analyze my profile');
 for(const expected of ['Generic language','Name your audience.','Software engineer | Building tools','Sections not read: skills'])assert.ok(text().includes(expected),expected);
 assert.equal(ui.root.findAll(n=>n.type==='textarea'&&n.props['aria-label']==='Task browser keyboard').length,0,'Handoff closes after analysis');
 await act(async()=>ui.unmount());
 console.log('PASS LinkedIn web: login, Network entry, task start, direct typing with ordered Enter, no uploads, resume, findings/rewrites, closed handoff.');
}
(async()=>{if(process.env.STACK_TEST_REMOVAL_UI==='1'){await resumeUnavailableTests();await tailoringScreenTests();await uploadLifecycleTests();return;}if(process.env.STACK_TEST_UPLOAD_UI==='1'){await uploadLifecycleTests();await tailoringScreenTests();return;}if(process.env.STACK_TEST_LINKEDIN_UI==='1'){await browserKeyboardTests();await linkedinScreenTests();return;}if(process.env.STACK_TEST_LINKEDIN_WEB==='1'){await linkedinWebTests();return;}if(process.env.STACK_TEST_TAILOR_E2E==='1'){await tailoringEndToEnd();return;}if(process.env.STACK_TEST_TAILOR_UI==='1'){await tailoringScreenTests();return;}try{await notificationTests();await gestureTests();await feedbackTests();await resumeUnavailableTests();await screenTests();}finally{await worker('discovery_manage',{id:fixtureSource,action:'purge'}).catch(()=>{});}})().catch(e=>{console.error(e);process.exitCode=1;});

async function uploadLifecycleTests(){
 const originalXHR=globalThis.XMLHttpRequest,originalFetch=globalThis.fetch;
 let pending,calls=[],reports=[];
 const state={resumes:[{id:'resume',name:'Candidate.pdf',created_at:1,processing:{pdf:{id:'pdf-job',status:'queued',timings:{}}}}]};
 class XHR{
  constructor(){this.upload={};this.headers={};pending=this;}
  open(method,url){this.method=method;this.url=url;}
  setRequestHeader(key,value){this.headers[key]=value;}
  send(body){this.body=body;calls.push(JSON.parse(body));}
  respond(value=state){this.status=200;this.responseText=JSON.stringify({data:{result:value}});this.onload();}
 }
 globalThis.XMLHttpRequest=XHR;
 globalThis.fetch=async(url,options)=>{reports.push({url,body:JSON.parse(options.body)});return {ok:true,status:200,json:async()=>({data:{result:{saved:true}}})};};
 await storage.setItemAsync('stack.session.v1','upload-session');await device.restoreSession();
 try{
  const progress=[];
  let result=device.uploadResumeFile('upload_resume',{name:'Candidate.pdf',content:'JVBERi0='},p=>progress.push(p));
  assert.equal(pending.timeout,20000,'Do not fix processing by raising request timeouts');
  assert.equal(pending.headers.Authorization,'Bearer upload-session');
  pending.upload.onprogress({loaded:50,total:100,lengthComputable:true});assert.equal(progress.at(-1).percent,50);
  pending.upload.onprogress({loaded:100,total:100,lengthComputable:true});assert.equal(progress.at(-1).status,'uploading','100% transfer does not imply server acceptance');
  pending.respond();result=await result;assert.equal(result.resumes[0].processing.pdf.status,'queued');
  assert.equal(progress.at(-1).status,'saved');assert.ok(reports.some(r=>r.body.job_id==='pdf-job'));
  const failed=device.uploadResumeFile('upload_resume',{name:'Candidate.pdf',content:'JVBERi0='});pending.ontimeout();await assert.rejects(failed,/Reopen Stack/);
  const retry=device.uploadResumeFile('upload_resume',{name:'Candidate.pdf',content:'JVBERi0='});pending.respond();await retry;
  assert.deepEqual(calls.at(-1),calls.at(-2),'Retry retains the same uploaded bytes');
  const stale=device.uploadResumeFile('upload_resume',{name:'Candidate.pdf',content:'JVBERi0='});await device.signOut();pending.respond();await assert.rejects(stale,/Session changed/);
  let ui,completed=0;
  const show=processing=>React.createElement(device.ResumeProcessing,{resumeId:'resume',kind:'source',processing,onCompleted:()=>completed++});
  await act(async()=>{ui=renderer.create(show({id:'source-job',status:'queued',timings:{queue_ms:1234}}));});
  assert.match(JSON.stringify(ui.toJSON()),/You can close Stack/);assert.match(JSON.stringify(ui.toJSON()),/Queue 1.23s/);
  await act(async()=>{ui.unmount();});
  await act(async()=>{ui=renderer.create(show({id:'source-job',status:'compiling'}));});assert.match(JSON.stringify(ui.toJSON()),/Compiling LaTeX/);
  await act(async()=>{ui.update(show({id:'source-job',status:'failed',error:'Package download failed'}));});assert.match(JSON.stringify(ui.toJSON()),/Package download failed/);
  assert.ok(ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel==='Retry LaTeX processing').length);
  await act(async()=>{ui.update(show({id:'source-job',status:'completed'}));});assert.equal(completed,1);
  await act(async()=>{ui.update(show({id:'source-job',status:'completed'}));});assert.equal(completed,1,'Refresh must not continue tailoring twice');
  await act(async()=>ui.unmount());
 }finally{globalThis.XMLHttpRequest=originalXHR;globalThis.fetch=originalFetch;}
 console.log('PASS uploads: byte progress, unchanged timeout, durable acceptance, lost-response retry, sign-out guard, reopen status, failure/retry UI, completion once.');
}
