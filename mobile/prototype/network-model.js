import {storage,events,services,clone} from './services';
import {backend,describeError} from './backend';
import {liveState} from './live-store';
import {allRuns} from './agent-live';
import * as remote from './network-live';
// Network-only mock domain model. Mirrors the current Contact / AgentContact distinction.
export const STORAGE_KEY='stack.network.preview.v2';
export const exampleCSV='name,email,relationship,company\nMaya Chen,maya@example.com,Fellow alum,Northstar\nJordan Ellis,jordan@example.com,Met at a meetup,Fieldwork';
export const people=[
 {id:'person-1',name:'Maya Chen',initials:'MC',role:'Product Designer',company:'Northstar',signal:'Fellow alum',color:'lilac',about:'From campus design clubs to building products at Northstar. Happy to share what helped me land my first design role.',detail:'NYU · Class of 2023',topics:'Portfolio reviews · Starting in design'},
 {id:'person-2',name:'Jordan Ellis',initials:'JE',role:'Software Engineer',company:'Fieldwork',signal:'Open to coffee chats',color:'mint',about:'I work on frontend systems at Fieldwork. Always up for talking about internships, side projects, and the first year on a team.',detail:'Boston · Remote',topics:'Engineering internships · Interview prep'},
 {id:'person-3',name:'Sam Rivera',initials:'SR',role:'Brand Strategist',company:'Common Ground',signal:'Fellow alum',color:'peach',about:'I turned a student marketing project into a career in brand strategy. Happy to help you think through your next step.',detail:'NYU · Class of 2022',topics:'Creative careers · Personal projects'},
 {id:'person-4',name:'Priya Shah',initials:'PS',role:'UX Researcher',company:'Forma',signal:'Open to mentoring',color:'lilac',about:'Researcher with a background in psychology. I help early-career researchers build confidence in their process.',detail:'Boston · Hybrid',topics:'Research portfolios · Graduate careers'}
];
const emptyForm=()=>({id:'',name:'',email:'',company:'',relationship:'',source_url:''});
const initial=()=>({contacts:[],contactForm:emptyForm(),csv:backend.live?'':exampleCSV,people:backend.live?{}:Object.fromEntries(people.map(p=>[p.id,{saved:false,notes:'',draft:''}])),reminders:[],reminderForms:{},tasks:[],policy:{limit:0,days:7},linkedin:{form:{url:'',role:''},saved:{url:'',role:''},runs:[]}});
let state=initial();
const listeners=new Set();
function hydrate(){
if(backend.live){listeners.forEach(fn=>fn());return;}
try {const saved=JSON.parse(storage.getItem(STORAGE_KEY)||'null');if(saved?.linkedin?.runs&&saved?.people)state=saved;}catch{}
// Legacy preview tasks did not record recipients; never invent historical recipients.
for(const t of state.tasks)if(!t.recipient){t.recipient={name:'Recipient not recorded',email:''};if(!['sent','uncertain','cancelled'].includes(t.status)){t.status='cancelled';t.error='This older draft has no saved recipient. Create a new draft for review.';}}
// A full reload interrupts mock work. Preserve drafts and expose an honest retry state.
for(const task of state.tasks)if(['generating','sending'].includes(task.status))task.status=task.status==='sending'?'uncertain':'failed';
for(const run of state.linkedin.runs)if(run.status==='scanning')run.status='blocked';

listeners.forEach(fn=>fn());
}
hydrate();events.addEventListener('hydrate',hydrate);
export const snapshot=()=>state;
export const subscribe=fn=>{listeners.add(fn);return()=>listeners.delete(fn)};
export function update(edit){const next=clone(state);edit(next);state=next;if(!backend.live)try{storage.setItem(STORAGE_KEY,JSON.stringify(state))}catch{}listeners.forEach(fn=>fn());if(backend.live)pushLocalEdits();}
export function reset(){state=initial();try{storage.removeItem(STORAGE_KEY)}catch{}listeners.forEach(fn=>fn());}
events.addEventListener('reset',()=>{if(backend.live){state=initial();people.splice(0,people.length);nodeOf={};served={people:{},policy:null};detail.clear();listeners.forEach(fn=>fn());}});
export const newId=()=>services.id();
export const delay=()=>new Promise(resolve=>setTimeout(resolve,750));
export function validateContact(input){
 const c={...input,name:String(input.name||'').trim(),email:String(input.email||'').trim().toLowerCase()};
 if(!c.name||c.name.length>120)throw Error('Enter a name of 120 characters or fewer.');
 if(c.email&&!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(c.email))throw Error('Enter a valid, verified email address.');
 if(c.source_url){try{if(new URL(c.source_url).protocol!=='https:')throw Error();}catch{throw Error('Use an HTTPS research source.')}}
 return {...c,company:String(c.company||'').slice(0,160),relationship:String(c.relationship||'').slice(0,2000),source_url:String(c.source_url||'').slice(0,2000)};
}
// Quoted commas, escaped quotes, embedded newlines, optional/reordered headers, or pasted emails.
export function parseContacts(text){
 if(text.length>200000)throw Error('Import at most 200 KB at a time.');
 const rows=[];let row=[],value='',quoted=false,closed=false;
 for(let i=0;i<=text.length;i++){
  const ch=text[i];
  if(quoted){if(ch===undefined)throw Error('Close the quoted CSV value.');if(ch==='"'){if(text[i+1]==='"'){value+='"';i++;}else{quoted=false;closed=true;}}else value+=ch;continue;}
  if(ch==='"'&&!value.trim()&&!closed){quoted=true;value='';continue;}
  if(ch===','||ch==='\n'||ch===undefined){row.push(value.trim());value='';closed=false;if(ch!==','){if(row.some(Boolean))rows.push(row);row=[];}continue;}
  if(ch==='\r')continue;
  if(closed&&ch.trim())throw Error('Separate quoted CSV fields with commas.');
  value+=ch;
 }
 const headers=(rows[0]||[]).map(v=>v.replace(/^\uFEFF/,'').toLowerCase());
 let contacts;
 if(headers.includes('email')){
  if(new Set(headers).size!==headers.length)throw Error('Use each CSV header only once.');
  contacts=rows.slice(1).map((r,index)=>{if(r.length>headers.length)throw Error(`Row ${index+2} has extra values. Put values containing commas in quotes.`);const c=Object.fromEntries(headers.map((h,i)=>[h,r[i]||'']));return validateContact({...c,selected:false,source:c.source||'User supplied CSV'});});
 }else{
  contacts=[...new Set(text.match(/[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g)||[])].map(email=>validateContact({name:email,email,selected:false,source:'User supplied text'}));
 }
 if(contacts.length>200)throw Error('Import at most 200 contacts at a time.');
 if(!contacts.length)throw Error('No contacts found. Include an email column or paste email addresses.');
 return contacts;
}
export function saveContact(form){
 const c=validateContact(form);
 if(c.email&&state.contacts.some(x=>x.id!==c.id&&x.email===c.email))throw Error('A contact with this email already exists.');
 const id=c.id||newId();
 update(s=>{
  const existing=s.contacts.find(x=>x.id===id);
  if(existing){
   const changed=['name','email','company','relationship','source_url'].some(k=>(existing[k]||'')!==(c[k]||''));
   const recipientChanged=existing.email!==c.email;
   if(changed)for(const t of s.tasks.filter(t=>t.contactId===id&&['generating','review','failed'].includes(t.status))){t.status='cancelled';t.error='Contact details changed. Create a new draft to review the updated recipient and message.';}
   // Form drafts cannot override outreach control state changed since the form opened.
   const control={selected:existing.selected,stopped:existing.stopped,stopReason:existing.stopReason,followups:existing.followups,nextAt:existing.nextAt};
   Object.assign(existing,c,control);
   if(recipientChanged){existing.nextAt=0;existing.followups=0;}
  }else s.contacts.push({...c,id,selected:true,stopped:false,followups:0,nextAt:0});
  s.contactForm=emptyForm();
 });
 return id;
}
export function importContacts(rows){let count=0;update(s=>{for(const row of rows){const c=validateContact(row);if(c.email&&s.contacts.some(x=>x.email===c.email))continue;s.contacts.push({...c,id:newId(),selected:false,stopped:false,followups:0,nextAt:0});count++;}});return count;}
export function saveReminder(targetId,form,now=Date.now()){
 if(!people.some(p=>p.id===targetId))throw Error('Reminder target not found.');
 const title=String(form.title||'').trim(),dueAt=new Date(form.due).getTime();
 if(!title||title.length>160||!Number.isFinite(dueAt)||dueAt<=now)throw Error('Choose a title of up to 160 characters and a future date and time.');
 update(s=>{const old=s.reminders.find(r=>r.id===form.id&&r.targetId===targetId);if(form.id&&!old)throw Error('Reminder not found.');if(old)Object.assign(old,{title,dueAt,done:false});else s.reminders.push({id:newId(),targetId,targetType:'contact',title,dueAt,done:false});delete s.reminderForms[targetId];});
}
export function localDateTime(timestamp){const d=new Date(timestamp);return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}T${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`;}
export function stopContact(id,reply=false){update(s=>{const c=s.contacts.find(c=>c.id===id);if(!c)return;c.stopped=true;c.nextAt=0;c.stopReason=reply?'Reply received':'Stopped by you';for(const t of s.tasks.filter(t=>t.contactId===id&&['generating','review','failed'].includes(t.status)))t.status='cancelled';});}
export function createTask(contactId,followup=false){
 const contact=state.contacts.find(c=>c.id===contactId);
 if(!contact||!contact.selected||contact.stopped||!contact.email)throw Error('Select a contact with a verified email before drafting outreach.');
 const active=state.tasks.find(t=>t.contactId===contactId&&['generating','review','sending','uncertain','failed'].includes(t.status));
 if(active)return active.id;
 if(followup&&(!contact.nextAt||contact.followups>=state.policy.limit))throw Error('No follow-up is scheduled.');
 const id=newId();update(s=>{s.tasks.unshift({id,contactId,recipient:{name:contact.name,email:contact.email},followup,status:'generating',createdAt:Date.now(),subject:'',body:''});if(followup)s.contacts.find(c=>c.id===contactId).nextAt=0;});return id;
}
export async function generateTask(id,fail=false){await delay();update(s=>{const t=s.tasks.find(t=>t.id===id);if(!t||t.status!=='generating')return;const c=s.contacts.find(c=>c.id===t.contactId);if(!c||c.stopped){t.status='cancelled';return;}if(fail){t.status='failed';t.error='The draft could not be generated. Your contact and any edits are safe.';return;}t.subject=t.subject||`${t.followup?'Following up':'A quick hello'}, ${c.name.split(' ')[0]}`;t.body=t.body||`Hi ${c.name.split(' ')[0]},\n\n${t.followup?'Following up on my earlier note. ':''}I’d love to hear about your experience${c.company?' at '+c.company:''}. Would you be open to a brief conversation?\n\nThank you!`;t.status='review';});}
export async function sendTask(id,outcome='normal'){
 const task=state.tasks.find(t=>t.id===id),c=state.contacts.find(c=>c.id===task?.contactId);
 if(!task||task.status!=='review'||!task.subject.trim()||!task.body.trim()||!c?.selected||c.stopped||!c.email||!task.recipient?.email||c.email!==task.recipient.email||c.name!==task.recipient.name||(task.followup&&c.followups>=state.policy.limit))throw Error('This draft is not ready to send.');
 update(s=>{s.tasks.find(t=>t.id===id).status='sending'});await delay();
 update(s=>{const t=s.tasks.find(t=>t.id===id);if(t.status!=='sending')return;if(outcome==='send-error'){t.status='review';t.error='Delivery failed before sending. Review the draft and try again.';return;}if(outcome==='uncertain'){t.status='uncertain';t.error='Delivery could not be confirmed. Check the result before sending again.';return;}finishSend(s,t);});
}
function finishSend(s,t){t.status='sent';t.sentAt=Date.now();delete t.error;const c=s.contacts.find(c=>c.id===t.contactId);if(!c||c.email!==t.recipient?.email)return;if(t.followup)c.followups++;c.nextAt=!c.stopped&&c.followups<s.policy.limit?Date.now()+s.policy.days*86400000:0;}
export function reconcileTask(id,sent){update(s=>{const t=s.tasks.find(t=>t.id===id);if(!t||t.status!=='uncertain')return;const c=s.contacts.find(c=>c.id===t.contactId);if(sent)finishSend(s,t);else{t.status=c.stopped||!c.email||c.email!==t.recipient?.email||c.name!==t.recipient?.name?'cancelled':'review';delete t.error;}});}
export function validateLinkedIn(url){try{const u=new URL(url);if(u.protocol!=='https:'||!['linkedin.com','www.linkedin.com'].includes(u.hostname)||!/^\/in\/[^/]+\/?$/.test(u.pathname))throw Error();return `https://www.linkedin.com${u.pathname.replace(/\/$/,'')}/`;}catch{throw Error('Enter your HTTPS LinkedIn profile URL, like https://www.linkedin.com/in/your-name/.')}}
export function startLinkedIn(){const url=validateLinkedIn(state.linkedin.form.url),role=state.linkedin.form.role.trim();const current=state.linkedin.runs.find(r=>r.url===url&&r.role===role&&!['complete','cancelled'].includes(r.status));if(current)return current.id;const id=newId();update(s=>{s.linkedin.saved={url,role};s.linkedin.form={url,role};s.linkedin.runs.unshift({id,url,role,status:'signin',createdAt:Date.now(),approved:false,rewrites:{headline:'Computer science student | Building accessible web interfaces with React',about:'I’m a computer science student building accessible web interfaces with React. In the campus web club, I contribute to a student events site.',experience:'Contributed React components to the campus web club’s student events site.'},included:{headline:true,about:true,experience:true}});});return id;}
export async function analyzeLinkedIn(id,fail=false){update(s=>{const r=s.linkedin.runs.find(r=>r.id===id);r.status='scanning';r.capturedAt=r.capturedAt||Date.now();});await delay();update(s=>{const r=s.linkedin.runs.find(r=>r.id===id);if(r?.status==='scanning')r.status=fail?'blocked':'complete';});}

events.addEventListener('hydrate',()=>{try{const saved=JSON.parse(storage.getItem(STORAGE_KEY));if(saved?.linkedin)state=saved;}catch{}listeners.forEach(fn=>fn());});

// ---- Live: the account is the source of truth for contacts, outreach tasks, reminders and rules. ----
let nodeOf={},served={people:{},policy:null},settings=null,timer=null;
const detail=new Map();
const set=edit=>{const next=clone(state);edit(next);state=next;listeners.forEach(fn=>fn());};
// Form edits to a sample person (saved, notes, draft) and to the follow-up rules are sent to the account shortly after.
function pushLocalEdits(){
 clearTimeout(timer);
 timer=setTimeout(async()=>{
  try{
   for(const [id,v] of Object.entries(state.people)){
    const mine=JSON.stringify([!!v.saved,v.notes||'',v.draft||'']);
    if(nodeOf[id]&&served.people[id]!==undefined&&served.people[id]!==mine){served.people[id]=mine;await remote.saveSamplePerson(nodeOf[id],!!v.saved,v.draft||'',v.notes||'');}
   }
   const rules=JSON.stringify(state.policy);
   if(settings&&served.policy!==null&&served.policy!==rules){served.policy=rules;await remote.savePolicy(settings,state.policy);}
  }catch(e){liveError=describeError(e);listeners.forEach(fn=>fn());}
 },700);
}
export let liveError='';
// Pulls everything this screen shows from the account. Safe to call often (it follows the account snapshot).
export async function syncLive(){
 const boot=liveState().boot;if(!boot)return;
 try{
  const [contacts,rules]=await Promise.all([remote.loadContacts(),remote.loadPolicy()]);
  settings=rules.settings;
  nodeOf=Object.fromEntries((boot.contacts||[]).map(c=>[c.person_id,c.id]));
  const byNode=Object.fromEntries((boot.contacts||[]).map(c=>[c.id,c.person_id]));
  people.splice(0,people.length,...(boot.people||[]).map(remote.personFrom));
  const personState=Object.fromEntries((boot.contacts||[]).map(c=>[c.person_id,{saved:!!c.saved,notes:c.notes||'',draft:c.draft||(boot.people.find(p=>p.id===c.person_id)||{}).draft||''}]));
  for(const [id,v] of Object.entries(personState))if(!(id in served.people)||served.people[id]===JSON.stringify([!!state.people[id]?.saved,state.people[id]?.notes||'',state.people[id]?.draft||'']))served.people[id]=JSON.stringify([v.saved,v.notes,v.draft]);
  const runs=remote.outreachRuns(),tasks=[];
  for(const run of runs){
   const key=run.id+'|'+run.status+'|'+run.updated_at;let full=detail.get(run.id);
   if(!full||full.key!==key){try{full={key,value:await remote.runDetail(run.id)};detail.set(run.id,full);}catch{full={key,value:null};}}
   tasks.push(remote.taskFrom(run,contacts,full.value));
  }
  const linkedinRuns=[];
  for(const run of allRuns().filter(r=>r.kind==='linkedin')){
   const key=run.id+'|'+run.status+'|'+run.updated_at;let full=detail.get(run.id);
   if(!full||full.key!==key){try{full={key,value:await remote.runDetail(run.id)};detail.set(run.id,full);}catch{full={key,value:null};}}
   linkedinRuns.push(remote.linkedinRunFrom(run,full.value,boot.profile));
  }
  const keepLocal=Object.fromEntries(state.tasks.map(t=>[t.id,t]));
  const reminders=(boot.reminders||[]).filter(r=>r.target_type==='contact').map(r=>({id:r.id,targetId:byNode[r.target_id]||r.target_id,targetType:'contact',title:r.title,dueAt:r.due_at*1000,done:!!r.done}));
  const linkedin=(boot.profile?.linkedin_url||boot.profile?.linkedin_target_role)?{url:boot.profile.linkedin_url||'',role:boot.profile.linkedin_target_role||''}:{url:'',role:''};
  served.policy=JSON.stringify(rules.policy);
  set(s=>{
   s.contacts=contacts;s.reminders=reminders;s.policy=state.policy&&settings&&served.policy===JSON.stringify(state.policy)?state.policy:rules.policy;
   s.policy=rules.policy;
   s.tasks=tasks.map(t=>keepLocal[t.id]&&keepLocal[t.id].status==='review'&&t.status==='review'&&(keepLocal[t.id].subject!==t.subject||keepLocal[t.id].body!==t.body)&&keepLocal[t.id].edited?{...t,subject:keepLocal[t.id].subject,body:keepLocal[t.id].body,edited:true}:t);
   for(const [id,v] of Object.entries(personState))s.people[id]=s.people[id]&&JSON.stringify([!!s.people[id].saved,s.people[id].notes||'',s.people[id].draft||''])!==served.people[id]?s.people[id]:v;
   s.linkedin.saved=linkedin;if(!s.linkedin.form.url&&!s.linkedin.form.role)s.linkedin.form={...linkedin};
   s.linkedin.runs=linkedinRuns.map(r=>{const old=s.linkedin.runs.find(x=>x.id===r.id);return old&&old.report?{...r,rewrites:{...r.rewrites,...old.rewrites},included:{...r.included,...old.included}}:r;});
  });
  liveError='';
 }catch(e){liveError=describeError(e);listeners.forEach(fn=>fn());}
}
const contactsNow=()=>state.contacts;
async function replaceContacts(list){set(s=>{s.contacts=list;});}
export async function saveContactLive(form){
 const c=validateContact(form);
 if(c.email&&state.contacts.some(x=>x.id!==c.id&&x.email===c.email))throw Error('A contact with this email already exists.');
 const existing=state.contacts.find(x=>x.id===c.id);
 const list=await remote.saveContactRemote({...c,id:c.id},existing);
 await replaceContacts(list);set(s=>{s.contactForm=emptyForm();});
 return c.id||(list.find(x=>x.email===c.email&&c.email)||list.find(x=>x.name===c.name)||{}).id;
}
export async function importContactsLive(rows){
 const before=state.contacts.length,list=await remote.importRemote(rows.map(validateContact));
 await replaceContacts(list);return Math.max(0,list.length-before);
}
export async function stopContactLive(id){await replaceContacts(await remote.stopRemote(id));}
export async function saveReminderLive(targetId,form,now=Date.now()){
 if(!nodeOf[targetId])throw Error('Reminder target not found.');
 const title=String(form.title||'').trim(),dueAt=new Date(form.due).getTime();
 if(!title||title.length>160||!Number.isFinite(dueAt)||dueAt<=now)throw Error('Choose a title of up to 160 characters and a future date and time.');
 const {call}=await import('./backend');
 const old=state.reminders.find(r=>r.id===form.id&&r.targetId===targetId);
 await call('save_reminder',{id:old?old.id:'',target_type:'contact',target_id:nodeOf[targetId],title,due_at:Math.floor(dueAt/1000)});
 const {refreshLive}=await import('./live-store');await refreshLive({quiet:true});await syncLive();
 set(s=>{delete s.reminderForms[targetId];});
}
export async function createTaskLive(contactId,followup=false){
 const contact=state.contacts.find(c=>c.id===contactId);
 if(!contact||!contact.selected||contact.stopped||!contact.email)throw Error('Select a contact with a verified email before drafting outreach.');
 const active=state.tasks.find(t=>t.contactId===contactId&&['generating','review','sending','uncertain','failed'].includes(t.status));
 if(active)return active.id;
 if(followup)throw Error('Stack prepares each follow-up for your review when it is due; none is waiting for this contact.');
 const gate=remote.outreachAvailability();
 if(!gate.ready)throw Error(gate.message||'Outreach drafts are not set up for your account yet.');
 const run=await remote.startOutreach(contactId);
 await syncLive();return run.id;
}
export async function sendTaskLive(id){
 const task=state.tasks.find(t=>t.id===id);
 if(!task||task.status!=='review'||!task.subject.trim()||!task.body.trim())throw Error('Review the subject and message before approving.');
 set(s=>{s.tasks.find(t=>t.id===id).status='sending';});
 try{await remote.approveRun({id,review:{step:'send',hash:task.hash}},{subject:task.subject,body:task.body});}
 catch(e){set(s=>{const t=s.tasks.find(t=>t.id===id);t.status='review';t.error=describeError(e);});throw e;}
 await syncLive();
}
export async function reconcileTaskLive(id,sent){
 await remote.reconcileRun(id,sent?'confirmed':'not_sent',sent?'You confirmed in Stack that this email was sent.':'You confirmed in Stack that nothing was sent.');
 await syncLive();
}
export async function retryTaskLive(id){await remote.retryRun(id);await syncLive();}
