// "Prepare & apply" and "Tailor my resume" inside an application, on the real backend. A task is one assistant run
// on the account: Stack reads the form, explains fit, tailors the resume, and fills the form only as far as you
// approve, and submits only after a separate approval. The screens' task vocabulary is mapped from the run; nothing
// here approves, answers or submits on its own.
import {useEffect,useState} from 'react';
import {liveState} from './live-store';
import {latestRun,startRun,useRun,approveRun,respondRun,cancelRun,retryRun,reconcileRun,continueTailoring,availability} from './agent-live';
const STATUS={queued:'queued',running:'running',waiting:'queued',paused:'running',review:'review',needs_input:'needs_input',blocked:'blocked',uncertain:'uncertain',failed:'failed',cancelled:'cancelled',completed:'completed'};
const DOMAIN_FEATURE={application:'applications',resume:'tailoring'};
export const featureFor=kind=>DOMAIN_FEATURE[kind==='resume'?'resume':'application'];
export function taskOf(run,kind,item,tailored=[]){
 if(!run)return null;
 const review=run.review&&run.review.step?run.review:null,tail=review&&review.step==='approve_resume'?review:null;
 const requests=(run.requests||[]).filter(r=>r.key!=='browser'),browser=(run.requests||[]).filter(r=>r.key==='browser').map(r=>r.label);
 const answers=Object.fromEntries(((review&&review.answers)||[]).map(a=>[a.label,a.value]));
 let status=STATUS[run.status]||'running';
 // A run waiting for a resume format is "blocked" for the screen, which offers the format setup.
 const needsFormat=run.status==='needs_input'&&run.needs_resume_review;
 if(needsFormat)status='blocked';
 const done=tailored.find(t=>t.run_id===run.id);
 return {
  id:run.id,kind,status,step:run.step,message:run.message||'',blocker:needsFormat?'format':'',resumeName:run.resume_name||item?.resumeName||'',destination:review?.destination?'https://'+review.destination:item?.sourceUrl||'',
  changes:(tail?.changes||[]).map(c=>({id:c.id,before:c.before,after:c.after,kept:!(tail.rejected||[]).includes(c.id),reason:c.reason,where:c.where})),
  answers,requests,browserRequests:browser,documents:review?.documents||[],notes:review?.notes||[],consequence:review?.consequence||'',title:review?.title||'',
  score:tail?.score||null,receipt:run.artifacts?.submit?.receipt||'',versionId:done?.id||'',approvals:{},
  events:[{label:run.step_label?run.step_label+' · '+(run.message||run.status):(run.message||run.status),at:(run.updated_at||0)*1000}],run
 };
}
export function useApplicationTask({enabled,item,kind}){
 const runKind=kind==='resume'?'resume':'application';
 const [runId,setRunId]=useState('');
 useEffect(()=>{
  if(!enabled)return;
  const found=latestRun(runKind,item.id);setRunId(found&&found.status!=='cancelled'?found.id:'');
 },[enabled,item.id,runKind]);
 const followed=useRun(enabled?runId:'');
 const tailored=liveState().boot?.tailored_resumes||[];
 const task=enabled?taskOf(followed.run?{...followed.run,status:followed.summary?.status||followed.run.status}:null,kind,item,tailored):null;
 return {
  task,error:followed.error,reload:followed.reload,
  availability:()=>availability(featureFor(kind)),
  async start(){const run=await startRun(runKind,item.id);setRunId(run.id);return run;},
  approve:rejected=>approveRun(followed.run,runKind==='resume'||followed.run?.review?.step==='approve_resume'?{rejected}:null),
  respond:values=>respondRun(runId,values,true),
  cancel:()=>cancelRun(runId),retry:()=>retryRun(runId),resume:()=>continueTailoring(runId),
  reconcile:(outcome,evidence)=>reconcileRun(runId,outcome,evidence)
 };
}
