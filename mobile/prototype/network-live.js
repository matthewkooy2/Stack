// Network on the real account: contacts you add, outreach drafts that wait for your approval, follow-up rules, and
// the LinkedIn profile review. Mappers are pure; the async functions call the account. People under Discover come
// from Stack's catalog of sample people (the backend has no real discovery), saved with notes and drafts.
import {call} from './backend';
import {startRun,runDetail,approveRun,cancelRun,retryRun,reconcileRun,allRuns,availability} from './agent-live';
export const contactFrom=c=>({id:c.id,name:c.name||'',email:c.email||'',company:c.company||'',relationship:c.relationship||'',source_url:c.source_url||'',role:c.role||'',
 selected:!!c.selected,stopped:!!c.stopped,stopReason:c.stopped?'Stopped':'',followups:c.followups||0,nextAt:(c.next_at||0)*1000});
// Run status as the draft screen names it.
const TASK={queued:'generating',running:'generating',waiting:'generating',paused:'generating',review:'review',needs_input:'failed',blocked:'failed',uncertain:'uncertain',failed:'failed',cancelled:'cancelled',completed:'sent'};
export function taskFrom(run,contacts,detail){
 const contact=contacts.find(c=>c.id===run.target_id)||{name:'Recipient not recorded',email:''};
 const review=(detail||run).review&&(detail||run).review.step==='send'?(detail||run).review:null,draft=(detail?.artifacts||{}).draft||{};
 const followup=/follow-up/i.test(run.title||'')||!!review?.followup;
 return {id:run.id,contactId:run.target_id,recipient:{name:contact.name,email:review?.to||contact.email},followup,status:TASK[run.status]||'generating',createdAt:(run.created_at||0)*1000,
  subject:review?.subject||draft.subject||'',body:review?.body||draft.body||'',error:['failed','uncertain','blocked','needs_input'].includes(run.status)?(review?.blocked||run.message||''):review?.blocked||'',
  hash:review?.hash||'',sentAt:run.status==='completed'?(run.updated_at||0)*1000:0,live:true};
}
export const outreachRuns=()=>allRuns().filter(r=>r.kind==='network');
export const personFrom=p=>({id:p.id,name:p.name,initials:p.initials,role:p.role,company:p.company,signal:p.signal,color:p.color==='#ECE9FF'?'lilac':p.color==='#E1F2ED'?'mint':'peach',
 about:p.bio,detail:p.reason,topics:p.reason,draft:p.draft});
const toCsv=rows=>{
 const q=v=>/[",\n]/.test(v)?'"'+String(v).replace(/"/g,'""')+'"':String(v||'');
 return ['name,email,company,relationship,source_url',...rows.map(r=>[r.name,r.email,r.company,r.relationship,r.source_url].map(q).join(','))].join('\n');
};
export async function loadContacts(){return ((await call('agent_contacts')).contacts||[]).map(contactFrom);}
export async function loadPolicy(){const s=await call('agent_settings');return {settings:s,policy:{limit:s.policy?.followup_limit??0,days:s.policy?.followup_days??7}};}
export async function savePolicy(settings,policy){
 const next={...(settings.policy||{}),followup_limit:policy.limit,followup_days:policy.days};
 return call('agent_save_policy',{policy:next});
}
export async function saveContactRemote(form,existing){
 const data={name:form.name,email:form.email,company:form.company,relationship:form.relationship,source_url:form.source_url,role:form.role||'',selected:existing?existing.selected:true};
 const result=await call('agent_save_contact',{data,id:form.id||''});
 return (result.contacts||[]).map(contactFrom);
}
export async function importRemote(rows){return ((await call('agent_import_contacts',{content:toCsv(rows)})).contacts||[]).map(contactFrom);}
export async function stopRemote(id){return ((await call('agent_stop_contact',{id})).contacts||[]).map(contactFrom);}
export const outreachAvailability=()=>availability('networking');
export const startOutreach=contactId=>startRun('network',contactId);
export {runDetail,approveRun,cancelRun,retryRun,reconcileRun};
// Sample people (Discover): saved state, notes and drafts live on the account.
export const saveSamplePerson=(id,saved,draft,notes)=>call('save_contact',{id,saved,draft,notes});
export const linkedinAvailability=()=>availability('linkedin');
export const saveLinkedInTarget=(url,role)=>call('agent_linkedin_profile',{url,target_role:role});
export const startLinkedInRun=(url,role)=>call('agent_linkedin_start',{url,target_role:role});

// A LinkedIn review run as the screens list it. `report` is the model's review of the captured profile, kept as the
// server returned it (findings with their quoted text, strengths, rewrites with evidence, questions).
const LI={queued:'signin',running:'signin',waiting:'signin',paused:'signin',needs_input:'blocked',blocked:'blocked',uncertain:'blocked',failed:'blocked',cancelled:'cancelled',completed:'complete'};
export function linkedinRunFrom(run,detail,profile={}){
 const review=detail?.artifacts?.linkedin_review,scanning=['running','queued'].includes(run.status)&&run.step==='linkedin_review';
 const rewrites={},evidence={},included={};
 for(const r of review?.rewrites||[]){const key=r.section==='intro'?'headline':r.section;rewrites[key]=r.text;evidence[key]=((r.evidence||[])[0]||{}).quote||'';included[key]=true;}
 return {id:run.id,url:profile.linkedin_url||'',role:profile.linkedin_target_role||'',status:scanning?'scanning':LI[run.status]||'signin',createdAt:(run.created_at||0)*1000,capturedAt:(run.updated_at||0)*1000,
  confirmed:true,approved:false,rewrites,included,error:run.message||'',
  report:review?{strengths:review.strengths||[],questions:review.questions||[],evidence,
   findings:(review.findings||[]).map(f=>({label:f.priority[0].toUpperCase()+f.priority.slice(1)+' priority · '+f.section[0].toUpperCase()+f.section.slice(1),quote:f.quote,advice:f.recommendation+(f.why_it_matters?' '+f.why_it_matters:'')}))}:null};
}
