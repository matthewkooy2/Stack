// Resume tailoring on the real backend (a "resume" run). The screens keep their own task vocabulary; this maps a
// run onto it. Nothing is shared with an employer here: the person reviews every change, and only then does the
// server rebuild the PDF in their own LaTeX format and save it under Tailored.
import {useEffect,useState} from 'react';
import {liveState} from './live-store';
import {latestRun,startRun,useRun,approveRun,cancelRun,retryRun,continueTailoring,availability} from './agent-live';
import {call} from './backend';
// The backend's score summary in the shape the Score card shows.
export function scoreView(summary){
 if(!summary||summary.match===undefined)return null;
 const components=[...(summary.match_components||[]),...(summary.quality_components||[])].map(c=>[c.label,c.score,100]);
 const missing=(summary.missing||[]).filter(m=>!m.supported).map(m=>m.term);
 const issues=(summary.issues||[]).map(i=>[i.where,i.detail||i.kind].filter(Boolean).join(': '));
 return {match:summary.match,quality:summary.quality,components,missing,issues,raw:summary};
}
const STATUS={queued:'queued',running:'running',waiting:'queued',paused:'running',review:'review',needs_input:'blocked',blocked:'blocked',uncertain:'failed',failed:'failed',cancelled:'cancelled',completed:'completed'};
export function taskFrom(run,tailored){
 if(!run)return null;
 const review=run.review&&run.review.step==='approve_resume'?run.review:null,done=tailored?.find(t=>t.run_id===run.id);
 return {
  id:run.id,status:STATUS[run.status]||'running',message:run.message||'',step:run.step,
  needsFormat:!!run.needs_resume_review,changes:review?.changes||[],rejected:review?.rejected||[],notes:review?.notes||[],summary:review?.summary||'',
  dropped:review?.dropped||[],pages:review?.pages||0,score:review?.score||null,versionId:done?.id||'',run
 };
}
export function useTailor({enabled,jobId}){
 const [runId,setRunId]=useState('');
 useEffect(()=>{
  if(!enabled||!jobId){setRunId('');return;}
  const found=latestRun('resume',jobId);setRunId(found&&found.status!=='cancelled'?found.id:'');
 },[enabled,jobId]);
 const followed=useRun(enabled?runId:'');
 const tailored=liveState().boot?.tailored_resumes||[];
 const task=enabled?taskFrom(followed.run?{...followed.run,status:followed.summary?.status||followed.run.status}:null,tailored):null;
 return {
  task,error:followed.error,
  async start(applicationId){const run=await startRun('resume',applicationId);setRunId(run.id);return run;},
  approve:(rejected)=>approveRun(followed.run,{rejected}),
  cancel:()=>cancelRun(runId),retry:()=>retryRun(runId),resume:()=>continueTailoring(runId),
  reload:followed.reload,availability:()=>availability('tailoring')
 };
}
// The proposed (all changes applied) PDF, for previewing before approval.
export async function proposedPdf(run){
 const detail=run.artifacts?run:await call('agent_run',{id:run.id});
 const pdf=detail.artifacts?.tailor?.pdf;
 return pdf?.content?{uri:'data:application/pdf;base64,'+pdf.content,pages:pdf.pages||1}:null;
}
