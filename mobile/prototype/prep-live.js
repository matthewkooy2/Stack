// Prep on the real account. Practice lives in the account's practice sessions (one per question, or per question and
// job for a job's plan). The question text and guides stay bundled editorial content; what you write, how long you
// practiced and the coaching you receive are saved server-side. Coaching is a model task, so it is offered only
// when the account has it set up, and otherwise says why.
import {useEffect,useState} from 'react';
import {call,backend,describeError} from './backend';
import {events} from './services';
import {startRun,availability,runDetail,latestRun} from './agent-live';
let sessions=[],catalogCache=null,status='idle',error='';
const listeners=new Set();
const notify=()=>listeners.forEach(fn=>fn());
const catalogId=id=>({debugging:'debug-endpoint'})[id]||id;
export const bundledId=id=>({'debug-endpoint':'debugging'})[id]||id;
export const sessionsNow=()=>sessions;
export async function loadSessions(){
 if(!backend.live)return;
 status=sessions.length?status:'loading';notify();
 try{sessions=(await call('prep_sessions')).sessions;status='ready';error='';}
 catch(e){status='error';error=describeError(e);}
 notify();
}
export function usePrepSessions(){
 const [,tick]=useState(0);
 useEffect(()=>{const fn=()=>tick(n=>n+1);listeners.add(fn);return()=>{listeners.delete(fn);};},[]);
 useEffect(()=>{if(backend.live&&status==='idle')loadSessions();},[]);
 return {sessions,status,error,reload:loadSessions};
}
events.addEventListener('reset',()=>{sessions=[];catalogCache=null;status='idle';error='';notify();});
export const sessionFor=(questionId,applicationId='')=>sessions.find(s=>s.data.problem_id===catalogId(questionId)&&(s.data.application_id||'')===applicationId)||null;
export const doneIds=()=>[...new Set(sessions.filter(s=>(s.data.elapsed_seconds||0)>0&&!s.data.application_id).map(s=>bundledId(s.data.problem_id)))];
async function catalog(){if(!catalogCache)catalogCache=(await call('prep_catalog')).problems;return catalogCache;}
const place=s=>{sessions=[s,...sessions.filter(x=>x.id!==s.id)];notify();};
// Creates the practice session for a question when it is first saved, then saves the given fields to it.
export async function saveSession(questionId,patch,applicationId=''){
 let s=sessionFor(questionId,applicationId);
 if(!s){
  const problem=(await catalog()).find(p=>p.id===catalogId(questionId));
  if(!problem)throw new Error('This practice question is not available on your account.');
  const made=await call('prep_create',{problem_id:problem.id,language:(problem.languages||[])[0]||'',application_id:applicationId});
  s={id:made.id,data:made.data,revision:made.revision};place(s);
 }
 const attempt=async current=>{
  const saved=await call('prep_save',{id:current.id,revision:current.revision,data:{...current.data,...patch}});
  const next={id:saved.id,data:saved.data,revision:saved.revision,results:saved.results,feedback:saved.feedback};place(next);return next;
 };
 try{return await attempt(s);}
 catch(e){
  if(!/changed on another device/i.test(String(e.message)))throw e;
  await loadSessions();const fresh=sessionFor(questionId,applicationId);if(!fresh)throw e;return attempt(fresh);
 }
}
export const coachingAvailability=()=>availability('coaching');
export async function startCoaching(session){return startRun('prep',session.id);}
export const coachingRun=session=>session?latestRun('prep',session.id):null;
export {runDetail};
// The rubric the coach returned, in the shape the feedback page shows.
export function reviewFrom(run,fallback={}){
 const coach=run?.artifacts?.coach;
 if(!coach)return null;
 const rubric=coach.rubric||[],sorted=rubric.slice().sort((a,b)=>b.score-a.score),best=sorted[0],worst=sorted[sorted.length-1];
 const average=rubric.length?rubric.reduce((n,r)=>n+r.score,0)/rubric.length:0;
 const quote=(coach.evidence||[]).find(e=>e.quote||e.text);
 return {
  score:Math.round(average*25),metrics:rubric.map(r=>[r.criterion,r.score*25]),
  strength:best?best.criterion:'Your answer',evidence:quote?'“'+(quote.quote||quote.text)+'”':'',explanation:best?.feedback||coach.summary||'',
  improvement:worst?worst.criterion:'Keep practicing',coach:worst?.feedback||coach.summary||'',
  retry:(coach.next_exercises||[])[0]||(coach.followup_questions||[])[0]||fallback.retry||''
 };
}
// A job's interview plan: practice sessions chosen from the listing (and your recent feedback), created on the
// account. Returns the plan rows the screens list, with each session's saved notes and whether it was practiced.
export async function planFor(applicationId){
 const [plan,catalog_]=await Promise.all([call('prep_for_application',{application_id:applicationId}),catalog()]);
 await loadSessions();
 return (plan.plan||[]).map(item=>{
  const problem=catalog_.find(p=>p.id===item.problem_id)||{},session=sessions.find(s=>s.id===item.session_id);
  return {session_id:item.session_id,problem_id:item.problem_id,questionId:bundledId(item.problem_id),title:item.title||problem.title,language:item.language||'',
   reason:item.reason||'',prompt:problem.prompt||item.prompt||'',minutes:problem.minutes||item.minutes||15,notes:session?.data.notes||'',
   done:(session?.data.elapsed_seconds||0)>0,application_id:applicationId};
 });
}
export async function savePlanSession(row,patch){
 const s=sessions.find(x=>x.id===row.session_id);
 if(!s)throw new Error('This practice session is no longer on your account. Rebuild the plan.');
 const saved=await call('prep_save',{id:s.id,revision:s.revision,data:{...s.data,...patch}});
 place({id:saved.id,data:saved.data,revision:saved.revision,results:saved.results,feedback:saved.feedback});
 return saved;
}
