// Assistant workflows on the real backend. Tailoring, fit, applying, coaching, outreach and LinkedIn review are all
// "runs" with one lifecycle (queued, running, needs input, review, blocked, uncertain, failed, cancelled,
// completed). Stack never starts one on its own and never skips a review; this module only drives the same calls
// the older Agents screens use. A workflow that the operator has not set up (model, browser, Google) is reported
// as unavailable with the reason, not simulated.
import {useEffect,useRef,useState} from 'react';
import {call,describeError} from './backend';
import {liveState,subscribeLive,mutate,refreshLive} from './live-store';
export const TERMINAL=['completed','cancelled','failed'];
export const WAITING=['needs_input','blocked','review','uncertain'];
const boot=()=>liveState().boot;
export const allRuns=()=>boot()?.agents?.runs||[];
export const runsFor=(kind,targetId)=>allRuns().filter(r=>r.kind===kind&&(!targetId||r.target_id===targetId));
export const latestRun=(kind,targetId)=>runsFor(kind,targetId).slice().sort((a,b)=>b.created_at-a.created_at)[0]||null;
export const feature=key=>(boot()?.agents?.features||[]).find(f=>f.key===key)||null;
// What stops a workflow from starting: the unmet checks the person can fix, then those only the operator can.
export function availability(key){
 const f=feature(key);
 if(!f)return {ready:false,message:'Assistant details have not loaded yet.',fixable:[],operator:[]};
 const failing=(f.checks||[]).filter(c=>!c.ok&&!c.optional);
 return {ready:f.state==='ready'||(f.state==='limited'&&!failing.length),state:f.state,title:f.title,message:failing.map(c=>c.fix).filter(Boolean)[0]||(f.state==='ready'?'':f.summary),
  fixable:failing.filter(c=>c.user_fixable),operator:failing.filter(c=>!c.user_fixable),alternative:f.alternative||''};
}
export async function startRun(kind,targetId){
 const run=await call('agent_start',{kind,target_id:targetId});
 refreshLive({quiet:true});
 return run;
}
export const runDetail=id=>call('agent_run',{id});
const act=async(name,args)=>{const run=await call(name,args);refreshLive({quiet:true});return run;};
export const cancelRun=id=>act('agent_cancel',{id});
export const retryRun=id=>act('agent_retry',{id});
export const dismissRun=id=>act('agent_dismiss',{id});
export const approveRun=(run,edits)=>act('agent_approve',{id:run.id,step:run.review.step,review_hash:run.review.hash,edits:edits&&Object.keys(edits).length?edits:null});
export const respondRun=(id,values,reuse=true)=>act('agent_respond',{id,values,reuse});
export const reconcileRun=(id,outcome,evidence)=>act('agent_reconcile',{id,outcome,evidence});
export const continueTailoring=(id,resumeId='')=>act('agent_continue_tailoring',{id,resume_id:resumeId});
// Follows one run: loads its detail and refreshes whenever the account snapshot shows it changed.
export function useRun(id){
 const [state,setState]=useState({run:null,error:'',loading:!!id}),summary=useSummary(id),seen=useRef('');
 const load=async()=>{
  if(!id)return;
  try{const run=await runDetail(id);setState({run,error:'',loading:false});}
  catch(e){setState(s=>({...s,error:describeError(e),loading:false}));}
 };
 useEffect(()=>{seen.current='';setState({run:null,error:'',loading:!!id});},[id]);
 useEffect(()=>{
  const stamp=summary?[summary.status,summary.updated_at].join('|'):'';
  if(id&&stamp!==seen.current){seen.current=stamp;load();}
 },[id,summary?.status,summary?.updated_at]);
 return {...state,summary,reload:load,setRun:run=>setState(s=>({...s,run}))};
}
function useSummary(id){
 const [,tick]=useState(0);
 useEffect(()=>subscribeLive(()=>tick(n=>n+1)),[]);
 return id?allRuns().find(r=>r.id===id)||null:null;
}
// Run status as the task screens name it.
export const uiStatus=run=>run?run.status==='paused'?'running':run.status:'';
