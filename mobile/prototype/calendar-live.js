// The Applications calendar on the real account: applications by the day they were saved or updated, interviews
// found in your email invitations, and follow-up reminders. Connecting Google Calendar is the optional consent that
// lets Stack read invitations and (only after you approve) add events; it is separate from sign-in.
import {useEffect,useState} from 'react';
import {Linking} from 'react-native';
import {call,describeError} from './backend';
import {useLive} from './live-store';
export const dayKey=d=>d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');
const timeRange=(start,end)=>{
 const f=d=>d.toLocaleTimeString(undefined,{hour:'numeric',minute:'2-digit'});
 return f(start)+(end?'–'+f(end):'');
};
// Pure: the three calendar maps from a snapshot, its interviews and the connection list.
export function calendarOf(boot,interviews=[]){
 const activity={},events={},add=(map,key,value)=>{(map[key]=map[key]||[]).push(value);};
 for(const a of boot?.applications||[]){
  if(a.demo)continue;
  const label=(a.job?.company||'Employer')+' · '+(a.job?.title||'Saved job');
  // One entry per application per day: a later change that day (such as Submitted) names the entry.
  const days=new Map([[dayKey(new Date(a.created_at*1000)),label]]);
  for(const h of a.history||[])days.set(dayKey(new Date(h.at*1000)),label+' · '+h.status);
  for(const [day,text] of days)add(activity,day,text);
 }
 for(const r of boot?.reminders||[]){
  if(r.target_type!=='application')continue;
  const app=(boot.applications||[]).find(a=>a.id===r.target_id),d=new Date(r.due_at*1000);
  add(events,dayKey(d),{title:r.title+(r.done?' (done)':''),company:app?.job?.company||'Follow-up',time:timeRange(d)});
 }
 for(const i of interviews){
  if(!i.start?.dateTime||i.status==='cancelled')continue;
  const start=new Date(i.start.dateTime),end=i.end?.dateTime?new Date(i.end.dateTime):null,app=(boot?.applications||[]).find(a=>a.id===i.application_id);
  add(events,dayKey(start),{title:i.summary||'Interview',company:app?.job?.company||'Interview',time:timeRange(start,end)});
 }
 return {activity,events};
}
export const streakOf=(activity,today)=>{let n=0;const d=new Date(today);while((activity[dayKey(d)]||[]).length){n++;d.setDate(d.getDate()-1);}return n;};
export function useCalendar(enabled){
 const account=useLive(),[state,setState]=useState({interviews:[],connected:false,error:'',loading:enabled});
 useEffect(()=>{
  if(!enabled||account.status!=='ready')return;
  let current=true;
  Promise.all([call('agent_events'),call('agent_settings')]).then(([events,settings])=>{
   if(current)setState({interviews:events.interviews||[],connected:(settings.connections||[]).some(c=>c.provider==='google'&&c.state==='connected'&&(c.scopes||[]).some(s=>/calendar/i.test(s))),error:'',loading:false});
  }).catch(e=>{if(current)setState(s=>({...s,error:describeError(e),loading:false}));});
  return()=>{current=false;};
 },[enabled,account.loadedAt]);
 const {activity,events}=calendarOf(account.boot,state.interviews);
 return {...state,activity,events,today:dayKey(new Date()),
  async connect(){
   try{const r=await call('agent_google_start',{capabilities:['calendar']});if(r.url)await Linking.openURL(r.url);else throw new Error(r.error||'Google Calendar could not be connected.');}
   catch(e){setState(s=>({...s,error:describeError(e)}));}
  }};
}
