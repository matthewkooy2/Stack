// Pure mappers between backend records and screen shapes, on payloads shaped like the backend's own views.
//   node tests/live-mapping.cjs
const assert=require('node:assert/strict'),fs=require('fs'),path=require('path');
(async()=>{
 // network-live imports the backend boundary, so exercise its pure mappers through a small shim.
 const shim=src=>src.replace(/^import .*$/gm,'').replace(/export \{[^}]*\};?/g,'');
 const nl=await import('data:text/javascript;base64,'+Buffer.from('const call=()=>{},startRun=()=>{},runDetail=()=>{},approveRun=()=>{},cancelRun=()=>{},retryRun=()=>{},reconcileRun=()=>{},allRuns=()=>[],availability=()=>({});'+shim(fs.readFileSync(path.resolve(__dirname,'../mobile/prototype/network-live.js'),'utf8'))).toString('base64'));
 const contacts=[{id:'k1',name:'Maya Chen',email:'maya@example.com',selected:true,followups:1,next_at:1800000000}].map(nl.contactFrom);
 assert.equal(contacts[0].nextAt,1800000000000);assert.equal(contacts[0].stopped,false);
 // An outreach run waiting for review becomes a draft task with the recipient the server will email.
 const task=nl.taskFrom({id:'r1',target_id:'k1',status:'review',title:'Networking outreach',created_at:1,updated_at:2},contacts,{review:{step:'send',to:'maya@example.com',subject:'Hello',body:'Hi Maya',hash:'h1'},artifacts:{}});
 assert.equal(task.status,'review');assert.equal(task.subject,'Hello');assert.equal(task.hash,'h1');assert.equal(task.recipient.email,'maya@example.com');
 assert.equal(nl.taskFrom({id:'r2',target_id:'k1',status:'uncertain',message:'No receipt'},contacts,null).status,'uncertain');
 assert.equal(nl.taskFrom({id:'r3',target_id:'k1',status:'completed',updated_at:5},contacts,null).status,'sent');
 // A finished LinkedIn review keeps its findings, quotes and rewrites.
 const li=nl.linkedinRunFrom({id:'l1',status:'completed',step:'linkedin_review',created_at:1,updated_at:2},{artifacts:{linkedin_review:{strengths:['Clear project'],questions:['What did you own?'],findings:[{section:'intro',priority:'high',quote:'Student',weakness:'Vague',why_it_matters:'Recruiters skim.',recommendation:'Name your focus.'}],rewrites:[{section:'intro',text:'CS student | React',evidence:[{quote:'Student'}]}]}}},{linkedin_url:'https://www.linkedin.com/in/x',linkedin_target_role:'Engineer'});
 assert.equal(li.status,'complete');assert.equal(li.rewrites.headline,'CS student | React');assert.equal(li.report.findings[0].label,'High priority · Intro');
 assert.equal(nl.linkedinRunFrom({id:'l2',status:'running',step:'linkedin_scan'},null,{}).status,'signin');
 assert.equal(nl.linkedinRunFrom({id:'l3',status:'running',step:'linkedin_review'},null,{}).status,'scanning');
 // Tailoring/application tasks.
 const tl=await import('data:text/javascript;base64,'+Buffer.from('const liveState=()=>({boot:null}),latestRun=()=>null,startRun=()=>{},useRun=()=>{},approveRun=()=>{},respondRun=()=>{},cancelRun=()=>{},retryRun=()=>{},reconcileRun=()=>{},continueTailoring=()=>{},availability=()=>({}),useState=()=>[],useEffect=()=>{};'+shim(fs.readFileSync(path.resolve(__dirname,'../mobile/prototype/task-live.js'),'utf8'))).toString('base64'));
 const t1=tl.taskOf({id:'a',status:'review',step:'approve_resume',review:{step:'approve_resume',changes:[{id:'c1',before:'a',after:'b'},{id:'c2',before:'c',after:'d'}],rejected:['c2']}},'resume',{},[]);
 assert.equal(t1.status,'review');assert.deepEqual(t1.changes.map(c=>c.kept),[true,false]);
 const t2=tl.taskOf({id:'b',status:'needs_input',step:'tailor',needs_resume_review:true},'resume',{},[]);assert.equal(t2.status,'blocked');assert.equal(t2.blocker,'format');
 const t3=tl.taskOf({id:'c',status:'needs_input',step:'inspect',requests:[{key:'email',label:'Email'},{key:'browser',label:'Pick a choice'}]},'application',{},[]);
 assert.equal(t3.status,'needs_input');assert.deepEqual(t3.requests.map(r=>r.key),['email']);assert.deepEqual(t3.browserRequests,['Pick a choice']);
 const t4=tl.taskOf({id:'d',status:'review',step:'fill',review:{step:'fill',destination:'boards.greenhouse.io',answers:[{label:'Email',value:'a@b.co'}],documents:[{name:'Resume.pdf'}]}},'application',{},[]);
 assert.equal(t4.answers.Email,'a@b.co');assert.equal(t4.destination,'https://boards.greenhouse.io');
 console.log('PASS live mapping: contacts, outreach, LinkedIn, tailoring and application tasks.');
})().catch(e=>{console.error(e);process.exit(1);});
