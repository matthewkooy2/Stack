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
   if(name==='@jac/runtime')return load(path.join(root,process.env.STACK_TEST_LINKEDIN_WEB==='1'?'.jac/client/workspace/compiled/client_runtime.js':'.jac/mobile-rn/jac-src/client_runtime.js'));
   if(name==='@jac/mobui')return load(path.join(root,'.jac/mobile-rn/jac-src/client_mobui.js'));
   if(name.endsWith('.png'))return {uri:name};
   if(name.startsWith('.'))return load(path.resolve(path.dirname(filename),name));
   if(process.env.STACK_TEST_LINKEDIN_WEB==='1'&&name!=='react') {try{return require(require.resolve(name,{paths:[path.join(root,'.jac/client/configs')]}));}catch{}}
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
 assert.ok(labelled(/^Explain my fit/).length&&labelled(/^Prepare & apply/).length&&button('Build interview plan'));
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
 fs.writeFileSync(config,JSON.stringify({provider:'codex-cli',local_cli_owner:owner,local_cli_daily_limit:20,action_daily_limits:{browser_fill:5,send_email:5}}));
 const finish=(work,result)=>agentWorker('agent_finish',{id:work.id,owner:work.owner,lease:work.lease,result});
 const openBadge=async()=>{const badge=labelled(/^Agents: /)[0];assert.ok(badge,'Agents header entry');await act(async()=>{await badge.props.onPress();await new Promise(r=>setTimeout(r,60));});};
 try{
  await press('Jobs');await openBadge();assert.match(text(),/Your agents\./);assert.match(text(),/No tasks are running/);await press('Needs you');assert.match(text(),/Nothing needs you right now/);
  await press('Features');for(const title of ['Application assistant','Networking & follow-ups','Resume tailoring','Job-fit analysis','Profile suggestions','Interview coaching','Code practice runs','Live interviews','Email tracking','Calendar assistant'])assert.ok(text().includes(title),title);
  assert.match(text(),/Meanwhile: /);assert.match(text(),/Your control: /);
  await press('Rules');await act(async()=>{ui.root.findAll(n=>n.type==='Switch')[0].props.onValueChange(true);});
  await press('Model');await press('Browser Fill');await press('Send Email');await field('Allowed destination domains','jobs.smartrecruiters.com, example.com');
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

  // Application: explicit start; answers and documents are reviewed before anything is shared.
  await press('Applications');
  const card=ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityRole==='button'&&!n.props.accessibilityLabel&&JSON.stringify(n.findAllByType('Text').map(t=>t.props.children)).includes('UI Test Employer'))[0];
  await act(async()=>{card.props.onPress();});assert.match(text(),/Agent help/);assert.match(text(),/approve submission separately/);
  await press('Prepare & apply');assert.match(text(),/Prepare & apply started/);
  work=await agentWorker('agent_claim');assert.equal(work.step,'inspect');
  await finish(work,{artifact:{adapter:'lever',schema_hash:'s',fields:[{label:'Email',type:'email',tag:'input',key:'email',required:true,name:'email',id:'email',options:[],value:''},{label:'Resume',type:'file',tag:'input',key:'answer:resume',required:true,name:'resume',id:'resume',options:[],value:''}]}});
  work=await agentWorker('agent_claim');assert.equal(work.step,'fit');await finish(work,{artifact:{summary:'Clear timeline match.',strengths:['Graduation window matches'],gaps:[],unknowns:[],evidence:[]}});
  const blank=fs.readFileSync(path.join(root,'tests/fixtures/blank.pdf')).toString('base64');
  work=await agentWorker('agent_claim');assert.equal(work.step,'tailor');await finish(work,{artifact:{summary:'Reordered',ordered_fact_keys:[],suggested_edits:['Lead with clinical rotations'],evidence:[],pdf:{name:'Tailored resume.pdf',content:blank,pages:1,diff:'+ Clinical rotations'}}});
  assert.ok((await agentWorker('agent_claim')).idle,'Fill must wait for review');
  await tick();assert.match(text(),/Prepare & apply · Needs your review/);
  await press('Open task Prepare & apply · Needs your review');
  await until(/ANSWERS STACK WILL ENTER/);assert.match(text(),/Email: ui-tester@example.com/);assert.match(text(),/Tailored resume.pdf/);assert.match(text(),/Step 4 of 5/);
  await press('Preview the resume that will be uploaded');assert.ok(ui.root.findAll(n=>n.type==='PDF').length);await press('Close preview');
  await press('Approve sharing these answers');assert.match(text(),/Approved/);
  work=await agentWorker('agent_claim');assert.equal(work.step,'fill');
  await finish(work,{needs_input:true,message:'Complete these missing application answers.',requests:[{key:'answer:start',label:'Earliest start date'}]});
  await tick();await until(/STACK NEEDS YOUR ANSWERS/);await field('Earliest start date','June 2027');
  await tick();assert.equal(input('Earliest start date').props.value,'June 2027');
  await press('Save answers and resume');assert.match(text(),/resumes automatically/);
  assert.equal((await device.rpc('agent_activity',{})).attention,0);
  await press('Back to tasks');await press('Close details');
 } finally {
  fs.writeFileSync(config,'{}');
  // Leave the shared worker queue empty for suites that claim the next global task.
  for(const run of (await device.rpc('agent_activity',{})).runs)if(!['completed','cancelled','failed'].includes(run.status))await device.rpc('agent_cancel',{id:run.id}).catch(()=>{});
 }
 console.log('PASS agent screens: header counts, feature guide, rules draft kept on refresh, facts, contact save without outreach, outreach review/edit persistence/cancel, application review of answers and documents, PDF preview, approval, answer requests.');
}
async function tailoringScreenTests(){
 const calls=[],refreshers=new Set();let opened='',confirmed=false,failSave=true,ui;
 let run={id:'tailor',kind:'resume',status:'needs_input',title:'Tailor resume',context_label:'Analyst at Example',created_at:1,updated_at:1,step_number:1,step_total:1,steps:['Tailor resume'],step_label:'Tailor resume',explanation:'Resume details need review.',message:'',resume_id:'resume',needs_resume_review:true,artifacts:{},results_where:'This task',cost_cents:0,subscription_calls:0};
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
  if(name==='agent_respond'){assert.ok(confirmed,'Do not resume before explicit confirmation');run={...run,status:'queued',needs_resume_review:false};return run;}
  throw new Error('Unexpected RPC '+name);
 };
 modules.set(path.join(root,'.jac/mobile-rn/jac-src/mobile/device.js'),{exports:{...device,rpc,Lifecycle:TestLifecycle,PDFView:({uri})=>React.createElement('PDF',{uri}),previewDocument:async pdf=>{assert.ok(pdf.content);return 'cache/tailored.pdf';}}});
 const {ResumeAgents,TaskDetail}=load(path.join(root,'.jac/mobile-rn/jac-src/mobile/components/Agents.js'));
 const text=()=>JSON.stringify(ui.toJSON());
 const press=async label=>{const b=ui.root.findAll(n=>n.type==='Pressable'&&n.props.accessibilityLabel===label)[0];assert.ok(b,'Missing '+label);assert.ok(!b.props.disabled,'Disabled '+label);await act(async()=>{await b.props.onPress();await pause();});};
 const features=[{key:'tailoring',title:'Tailor resume',state:'ready',summary:'Resume for this job',checks:[]}];
 await act(async()=>{ui=renderer.create(React.createElement(ResumeAgents,{applications:[{id:'application',demo:false,job:{title:'Analyst',company:'Example'}}],runs:[],features,onOpenTask:id=>{opened=id;},onNavigate:()=>{}}));});
 await press('Tailor for this job');assert.equal(opened,'tailor');
 await act(async()=>{ui.update(React.createElement(TaskDetail,{id:'tailor',features,webUrl:'',onBack:()=>{},onNavigate:()=>{}}));await pause();});
 assert.match(text(),/No tailored PDF has been generated/);assert.doesNotMatch(text(),/STACK NEEDS YOUR ANSWERS/);
 await press('Review resume details');assert.match(text(),/Candidate.pdf/);assert.match(text(),/Profile/);
 await press('Confirm and continue tailoring');assert.match(text(),/Could not save details/);assert.ok(!calls.some(c=>c.name==='agent_respond'));
 failSave=false;await press('Confirm and continue tailoring');assert.equal(run.status,'queued');assert.doesNotMatch(text(),/Review your resume first/);
 const original='Original '.repeat(220)+'ORIGINAL END',tailored='Tailored '.repeat(220)+'TAILORED END';
 run={...run,status:'completed',artifacts:{tailor:{summary:'Reordered for this job',suggested_edits:['Verify a measurable result.'],pdf:{name:'Tailored.pdf',content:'JVBERi0=',order_changed:true,original_text:original,text:tailored}}}};
 await act(async()=>{for(const tick of refreshers)await tick();await pause();});
 assert.match(text(),/Suggested edits/);assert.match(text(),/not applied/);
 await press('Original text');assert.match(text(),/ORIGINAL END/);assert.doesNotMatch(text(),/TAILORED END/);
 await press('Tailored text');assert.match(text(),/TAILORED END/);
 await press('Preview tailored resume');assert.equal(ui.root.findByType('PDF').props.uri,'cache/tailored.pdf');assert.doesNotMatch(text(),/TAILORED END/);
 await press('Close preview');assert.equal(ui.root.findAllByType('PDF').length,0);assert.match(text(),/Your tailored resume/);
 await act(async()=>ui.unmount());
 console.log('PASS tailoring screens: opens task, inline structured review, save failure does not resume, explicit confirmation resumes, complete comparison text, suggestions separated, PDF preview and return.');
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
 await press('Save profile URL');assert.equal(storedLinkedInUrl,'https://www.linkedin.com/in/candidate/');
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
 const text=()=>JSON.stringify(ui.toJSON());
 const press=async label=>{const b=ui.root.findAll(n=>n.type==='button'&&n.children.join('')===label)[0];assert.ok(b,'Missing '+label);assert.ok(!b.props.disabled);await act(async()=>{await b.props.onClick();await pause();});};
 const field=async(label,value)=>{const row=ui.root.findAll(n=>n.type==='label'&&n.children[0]===label)[0];assert.ok(row,'Missing '+label);await act(async()=>row.findByType('input').props.onChange({target:{value}}));};
 await act(async()=>{ui=renderer.create(React.createElement(App));await pause();});
 await field('Username','fixture');await field('Password','fixture');await press('Continue');await press('Network');
 await field('Your LinkedIn profile URL','https://www.linkedin.com/in/candidate/');await field('Target role (optional)','Engineer');await press('Review my LinkedIn profile');
 assert.ok(calls.some(c=>c.name==='agent_linkedin_start'&&c.args.target_role==='Engineer'));
 await press('Open same browser session');assert.match(text(),/linkedin.com\/login/);
 const privateInput=ui.root.findAll(n=>n.type==='input'&&n.props['aria-label']==='Type into selected browser field')[0];assert.equal(privateInput.props.type,'password');
 assert.equal(ui.root.findAll(n=>n.type==='input'&&n.props.type==='file').length,0);
 const inputEvent={key:'Enter',currentTarget:{value:'temporary-login-input'}};
 await act(async()=>{privateInput.props.onKeyDown(inputEvent);await pause();});assert.equal(inputEvent.currentTarget.value,'');assert.deepEqual(events.at(-1),{type:'text',text:'temporary-login-input'});
 await press('Analyze my profile');
 for(const expected of ['Generic language','Name your audience.','Software engineer | Building tools','Sections not read: skills'])assert.ok(text().includes(expected),expected);
 assert.equal(ui.root.findAll(n=>n.type==='input'&&n.props['aria-label']==='Type into selected browser field').length,0,'Handoff closes after analysis');
 await act(async()=>ui.unmount());
 console.log('PASS LinkedIn web: login, Network entry, task start, masked browser handoff, no uploads, resume, findings/rewrites, closed handoff.');
}
(async()=>{if(process.env.STACK_TEST_LINKEDIN_WEB==='1'){await linkedinWebTests();return;}if(process.env.STACK_TEST_LINKEDIN_UI==='1'){await browserKeyboardTests();await linkedinScreenTests();return;}if(process.env.STACK_TEST_TAILOR_UI==='1'){await tailoringScreenTests();return;}try{await notificationTests();await gestureTests();await screenTests();}finally{await worker('discovery_manage',{id:fixtureSource,action:'purge'}).catch(()=>{});}})().catch(e=>{console.error(e);process.exitCode=1;});
