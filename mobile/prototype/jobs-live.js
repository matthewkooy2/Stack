// Jobs on the real catalog: listings come from `search_jobs`, decisions go to `swipe`. The adapter functions are
// pure (tests/live-jobs.cjs runs them against the live API); `useLiveDeck` owns loading, paging and commits.
import {useCallback,useEffect,useRef,useState} from 'react';
import {AppState} from 'react-native';
import {call,describeError} from './backend';
import {mutate,useLive} from './live-store';
export const UNDO_MS=2400,PAGE_LOW=6;
const COLORS=['lilac','mint','peach'];
export const colorFor=text=>COLORS[Array.from(String(text||'')).reduce((n,c)=>n+c.charCodeAt(0),0)%COLORS.length];
export const clip=(text,size)=>{const value=String(text||'').replace(/\s+/g,' ').trim();return value.length>size?value.slice(0,size-1).replace(/\s+\S*$/,'')+'…':value;};
const day=seconds=>seconds?new Date(seconds*1000).toLocaleDateString(undefined,{month:'short',day:'numeric'}):'';
// Employment label shown on the card; the catalog may say "Permanent", "Intern", or leave it out.
export function typeOf(job){
 const text=[...(job.tags||[]),job.employment_type||'',job.title||''].join(' ').toLowerCase();
 if(/intern|co-?op/.test(text))return 'Internship';
 if(/part[- ]time/.test(text))return 'Part-time';
 if(/contract|temporary/.test(text))return 'Contract';
 if(/permanent|full[- ]time|regular/.test(text)||job.employment_type)return 'Full-time';
 return 'Role';
}
export function levelOf(job){
 const tag=(job.tags||[]).find(t=>/entry|intern|junior|new grad|mid|senior|lead|staff|principal|leadership/i.test(t));
 return tag||job.seniority&&job.seniority!=='Unknown'&&job.seniority||'Open level';
}
export function cardFor(job){
 const highlights=job.highlights||{},work=(highlights.responsibilities||[]).filter(Boolean),needs=(highlights.requirements||[]).filter(Boolean);
 const unit=job.compensation?.unit,paid=job.salary&&!/not listed/i.test(job.salary);
 return {
  id:job.id,company:job.company||'Employer',initial:job.initial||String(job.company||'?')[0].toUpperCase(),title:job.title,
  location:job.location||'Location not listed',mode:job.mode||'',type:typeOf(job),level:levelOf(job),
  pay:job.salary||'Pay not listed',payNote:paid&&unit&&unit!=='unknown'?'per '+unit:(job.posted||'Posting date not listed'),
  color:colorFor(job.company||job.id),posted:job.posted||'Posting date not listed',
  about:clip(work[0]||job.reason||'',320)||'Open the full listing for the employer’s description.',
  work:work.length?work:['The employer’s responsibilities are in the full listing.'],needs:needs.length?needs:['The employer lists no short requirements; see the full listing.'],
  perks:[job.source_name&&'Source: '+job.source_name,job.checked_at&&'Checked '+day(job.checked_at),job.posted,job.timeline?.status&&job.timeline.status!=='unset'?job.timeline.label:''].filter(Boolean),
  url:job.listing_url||job.url||'',raw:job
 };
}
export function factsFor(card){
 const job=card.raw||{},highlights=job.highlights||{};
 const timing=job.timeline?.status&&job.timeline.status!=='unset'?job.timeline.label:'Start date not stated';
 return {
  workplace:[job.mode&&job.mode!=='Unknown'?job.mode:'',job.remote_eligibility].filter(Boolean).join(' · ')||'Workplace not stated',
  experience:card.level==='Open level'?'Experience level not stated':card.level,timing,
  eligibility:job.match?.label||'Review the employer’s requirements',
  skills:clip((highlights.requirements||[])[0]||'',90)||'Requirements are in the full listing',
  sponsorship:'Listing from '+(job.source_name||job.source||'the employer')+(job.checked_at?' · checked '+day(job.checked_at):''),
  tasks:(card.work||[]).slice(0,2).map(t=>clip(t,110)),
  fresh:true
 };
}
// A filter the user never touched leaves the profile's preferences in charge; choosing All/Any clears them.
export function filtersFor(saved,{type,mode}){
 const filters={...(saved?.filters||{})};
 if(type!==undefined)filters.employment_types=type==='All'?[]:[type];
 if(mode!==undefined)filters.modes=mode==='Any'?[]:[mode];
 return filters;
}
export function selectedFilters(saved){
 const f=saved?.filters||{};
 return {type:f.employment_types?.length===1?f.employment_types[0]:'All',mode:f.modes?.length===1?f.modes[0]:'Any'};
}
export const placeholder=cardFor({id:'placeholder',company:'Loading',initial:'·',title:'Loading opportunities',location:'Loading',salary:'Pay not listed',highlights:{}});
export async function searchPage(saved,filters,cursor='',refresh=false){
 const result=await call('search_jobs',{query:saved?.query||'',filters,cursor,refresh});
 return {cards:(result.jobs||[]).map(cardFor),cursor:result.next_cursor||'',total:result.total||0,excluded:result.excluded||[]};
}
export async function fullListing(id){return call('get_job',{id});}
// The deck: loads after the account snapshot, hides what was already decided, pages in more, and holds the latest
// decision for UNDO_MS so Undo can cancel it (the API has no way to reverse a swipe).
export function useLiveDeck(onNotice=()=>{}){
 const account=useLive();
 const [state,setState]=useState({status:'loading',error:'',cards:[],cursor:'',total:0});
 const [filters,setFilters]=useState(null),[held,setHeld]=useState(''),serial=useRef(0),pending=useRef(null),decided=useRef(new Set()),paging=useRef(false);
 const boot=account.boot,saved=boot?.saved_search;
 const settled=useRef(new Set());
 const hide=cards=>cards.filter(c=>!decided.current.has(c.id)&&!(boot?.decisions||[]).some(d=>d.job_id===c.id));
 const load=useCallback(async(override,refresh=false)=>{
  const mine=++serial.current;setState(s=>({...s,status:'loading',error:''}));
  try{
   const active=filtersFor(saved,override||{}),page=await searchPage(saved,active,'',refresh);
   if(mine!==serial.current)return;
   setState({status:'ready',error:'',cards:hide(page.cards),cursor:page.cursor,total:page.total});
  }catch(e){if(mine===serial.current)setState(s=>({...s,status:'error',error:describeError(e)}));}
 },[saved]);
 useEffect(()=>{if(account.status==='ready'&&!settled.current.has('first')){settled.current.add('first');load();}},[account.status]);
 // Changing the profile's role, location or preferences (or the saved search) reloads the deck for them.
 const searchKey=JSON.stringify([boot?.profile?.role,boot?.profile?.location,boot?.profile?.preferences,boot?.saved_search]);
 const lastSearch=useRef(searchKey);
 useEffect(()=>{if(account.status==='ready'&&lastSearch.current!==searchKey){lastSearch.current=searchKey;if(settled.current.has('first'))load();}},[searchKey]);
 useEffect(()=>{if(account.status==='error')setState(s=>({...s,status:'error',error:account.error}));},[account.status,account.error]);
 const more=useCallback(async()=>{
  if(paging.current||!state.cursor)return;paging.current=true;const mine=serial.current;
  try{
   const active=filtersFor(saved,filters||{}),page=await searchPage(saved,active,state.cursor);
   if(mine===serial.current)setState(s=>({...s,cards:[...s.cards,...hide(page.cards).filter(c=>!s.cards.some(x=>x.id===c.id))],cursor:page.cursor}));
  }catch(e){onNotice(describeError(e));}finally{paging.current=false;}
 },[state.cursor,saved,filters]);
 const commit=useCallback(async()=>{
  const p=pending.current;if(!p)return;pending.current=null;clearTimeout(p.timer);setHeld('');
  try{await mutate('swipe',{job_id:p.card.id,action:p.action==='save'?'apply':'pass'});p.done?.(true);}
  catch(e){decided.current.delete(p.card.id);p.done?.(false);onNotice(describeError(e));}
 },[onNotice]);
 // Queues a decision. The previous one is committed first; this one waits for its undo window.
 const decide=useCallback((card,action)=>{
  commit();decided.current.add(card.id);
  const p={card,action};p.timer=setTimeout(commit,UNDO_MS);pending.current=p;setHeld(card.id);
 },[commit]);
 // Cancels the held decision (Undo). Returns the card, or null when it was already committed.
 const undo=useCallback(()=>{const p=pending.current;if(!p)return null;clearTimeout(p.timer);pending.current=null;decided.current.delete(p.card.id);setHeld('');return p.card;},[]);
 useEffect(()=>{
  const sub=AppState.addEventListener('change',s=>{if(s!=='active')commit();});
  return()=>{sub.remove();commit();};
 },[commit]);
 // Choosing filters saves the search (also asking Stack to look again for it) and reloads the deck.
 const applyFilters=useCallback(async next=>{
  setFilters(next);
  try{
   const merged=filtersFor(saved,next);
   await call('save_search',{query:saved?.query||'',filters:merged});
   const mine=++serial.current;setState(s=>({...s,status:'loading',error:''}));
   const page=await searchPage({...saved,filters:merged},merged,'',true);
   if(mine===serial.current)setState({status:'ready',error:'',cards:hide(page.cards),cursor:page.cursor,total:page.total});
  }catch(e){setState(s=>({...s,status:'error',error:describeError(e)}));}
 },[saved]);
 return {...state,held,decide,undo,commit,more,applyFilters,reload:()=>load(filters||undefined),filters:filters||selectedFilters(saved),touched:!!filters};
}
