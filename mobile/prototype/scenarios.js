import {useEffect} from 'react';
import {storage,events} from './services';
import {setReviewMode} from './loading';
import {sampleResume,createTask,ensurePlan,APP_KEY,PREP_KEY} from './application-store';
import {saveLibrary} from './resume-library';
import {propose,applicationTailoredResume} from './resume-model';
import * as network from './network-model';
let current={},revision=0;const applied=new Set();const listeners=new Set();
export const scenarioRevision=()=>revision;
export const subscribeScenarios=fn=>{listeners.add(fn);return()=>listeners.delete(fn);};
export const currentScenario=()=>current;
export function useScenario(area,apply){useEffect(()=>{if(__DEV__&&current.area===area.split('/')[0]&&!applied.has(area)){applied.add(area);apply(current);}},[]);}
const scenario=(area,label,params={})=>({id:area+'/'+label,area,label,...params});
export const scenarios=[
 ...["Needs you","Activity","Features","Email & calendar","Rules","Facts"].map(page=>scenario("Agents",page,{page})),
 ...['deck','filters','details','menu','exhausted'].map(page=>scenario('Jobs',page,{page})),
 ...['list','search','filters','calendar','detail','Explain my fit','Tailor my resume','Prepare & apply','Follow-ups','Build interview plan'].map(page=>scenario('Applications',page,{page})),
 ...['queued','running','review','needs_input','blocked','failed','uncertain','cancelled','completed'].map(status=>scenario('Applications','Task · '+status,{page:'Prepare & apply',status,step:status==='uncertain'?'submit':'approve_resume'})),
 ...['fill','submit'].map(step=>scenario('Applications','Approval · '+step,{page:'Prepare & apply',status:'review',step})),
 scenario('Applications','Missing tailoring format',{page:'Tailor my resume',status:'blocked',blocker:'format'}),
 scenario('Applications','Tailoring complete',{page:'Tailor my resume',status:'completed'}),
 ...['home','choose','upload','templates','processing','fields','review','preview'].map(page=>scenario('Resume',page,{page})),
 ...[0,1,2,3].map(step=>scenario('Resume','Wizard · '+['Personal','Experience','Education','Skills'][step],{page:'fields',step})),
 ...['agents','format','manage','profile','changes','files','complete'].map(view=>scenario('Resume','Tools · '+view,{page:'preview',view})),
 ...['empty','agent-error','compile-error','parser-error','offline','unavailable'].map(state=>scenario('Resume','Scenario · '+state,{page:'preview',view:state==='compile-error'?'format':state==='parser-error'?'files':'agents',state})),
 scenario('Resume','Tailored library',{page:'home',category:'Tailored'}),scenario('Resume','Empty library',{page:'home',empty:true}),
 ...['home','contacts','add','import','contact','discover','person','followups','linkedin','profiles'].map(page=>scenario('Network',page,{page})),
 ...['generating','review','sending','sent','failed','uncertain','cancelled'].map(status=>scenario('Network','Outreach · '+status,{page:'draft',status})),
 ...['signin','scanning','blocked','expired','cancelled','complete'].map(status=>scenario('Network','LinkedIn · '+status,{page:'linkedinTask',status})),
 ...['setup','scan-error','browser-error','draft-error','send-error','uncertain'].map(state=>scenario('Network','Scenario · '+state,{page:state.includes('browser')||state.includes('scan')?'linkedinTask':'contact',state})),
 ...['linkedin','github','portfolio'].map(platform=>scenario('Network','Public profile · '+platform,{page:'profiles',platform})),
 scenario('Network','Empty contacts',{page:'contacts',empty:true}),
 scenario('Prep','Library'),scenario('Prep','Behavioral',{track:'Behavioral'}),scenario('Prep','Technical',{track:'Technical'}),
 scenario('Prep','Technical exercise',{track:'Technical',question:'two-sum'}),
 ...['ready','recording','evaluating','feedback','review'].map(phase=>scenario('Prep','Interview · '+phase,{track:'Behavioral',question:'project',phase})),
 scenario('Prep','Interview settings',{track:'Behavioral',question:'project',settings:true}),
 scenario('Prep','Job plan',{plan:true}),scenario('Prep','Job practice',{plan:true,practice:true}),
 ...['Jobs','Applications','Network','Resume','Prep','Profile','Edit profile','Agents'].map(area=>scenario(area,'Loading',{mode:'loading'}))
];
export function selectScenario(value){
 if(!__DEV__)return;
 current={...value};applied.clear();setReviewMode(value.mode||'normal');
 const resume={...sampleResume,format:{kind:'builtin',template:'jake',status:'completed'},isDefault:true};
 if(value.area==='Resume'||value.area==='Applications'||value.plan){
  if(value.blocker==='format')resume.format=null;
  const item={id:1,company:'Northstar',initial:'N',role:'Associate Product Designer',location:'New York · Hybrid',pay:'$75–90k',status:'Interview',next:'Portfolio chat · Oct 8, 10:30 AM ET',note:'Bring two projects.',color:'lilac',resume_id:resume.id};
  const task={...createTask(item,resume,resume.details,value.page==='Tailor my resume'?'resume':'application'),status:value.status||'review',step:value.step||'approve_resume',answers:{name:resume.details.name,email:resume.details.email,authorization:'Confirmed sample answer'},due:Date.now()+60000,message:'Simulated connection interrupted. Review and retry.',blocker:value.blocker||'',resumeFrom:'queued'};
  item[value.page==='Tailor my resume'?'tailorTask':'task']=task;
  const tailored=applicationTailoredResume({...task,original:resume.details},item,resume);
  resume.task={status:value.view==='complete'?'completed':'review',job:{id:'northstar',role:'Product Design Intern',company:'Northstar',skills:['Figma','prototyping','user research']},changes:propose(resume,{skills:['Figma','prototyping','user research']}),rejected:[],versionId:tailored.id};
  saveLibrary(value.empty?[]:[resume,tailored]);storage.setItem(APP_KEY,JSON.stringify([item]));
  if(value.plan){ensurePlan(item);storage.setItem('stack.prep.handoff.v2','1');}else storage.removeItem('stack.prep.handoff.v2');
 }
 if(value.area==='Prep'&&!value.plan)storage.removeItem('stack.prep.handoff.v2');
 if(value.area==='Network'){
  network.reset();
  if(!value.empty){
   const id=network.saveContact({name:'Maya Chen',email:'maya@example.com',company:'Northstar',relationship:'Fellow alum'});
   network.update(s=>{s.contacts.find(c=>c.id===id).selected=true;s.linkedin.form={url:'https://www.linkedin.com/in/sample/',role:'Product Designer'};s.policy={limit:2,days:7};});
   current.contactId=id;
   if(value.page==='draft'){const taskId=network.createTask(id);network.update(s=>{const t=s.tasks.find(t=>t.id===taskId);Object.assign(t,{status:value.status||'review',subject:'A quick hello, Maya',body:'Hi Maya, I would love to learn about your design experience at Northstar. Would you be open to a brief conversation?',error:value.status==='failed'?'Draft failed. Please retry.':undefined});});current.taskId=taskId;}
   if(value.page==='linkedinTask'){const runId=network.startLinkedIn();network.update(s=>{s.linkedin.runs.find(r=>r.id===runId).status=value.status||'signin';});current.runId=runId;}
  }
 }
 revision++;listeners.forEach(fn=>fn());events.emit('stack-data-changed');
}
