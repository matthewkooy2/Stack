// Applications on the real account. Pure adapters from the backend's application, job and reminder records to
// the shapes the Applications screens already render. No imports: tests/live/applications.cjs runs these on
// real API responses.
const COLORS=['lilac','mint','peach'];
const colorFor=text=>COLORS[Array.from(String(text||'')).reduce((n,c)=>n+c.charCodeAt(0),0)%COLORS.length];
const day=seconds=>new Date(seconds*1000).toLocaleDateString(undefined,{month:'short',day:'numeric'});
const clip=(text,size)=>{const v=String(text||'').replace(/\s+/g,' ').trim();return v.length>size?v.slice(0,size-1).replace(/\s+\S*$/,'')+'…':v;};
const plain=text=>String(text||'').replace(/<[^>]*>/g,' ').replace(/&nbsp;| /g,' ').replace(/&amp;/g,'&');
// Short excerpts of what the employer wrote: the role's duties and its requirements, from the listing's own
// section headings and sentences (the same idea as the server's card excerpts; nothing is invented).
export function highlightsOf(job){
 const responsibilities=[],requirements=[];let section='';
 for(const raw of plain((job.description||'')+'\n'+(job.qualifications||'')).split('\n')){
  const line=raw.replace(/^[\s•\-*]+/,'').trim();if(!line)continue;
  const lower=line.toLowerCase().replace(/:$/,'');
  if(line.length<85&&/^(what you(?:.ll| will) do|(?:key |your )?responsibilities|the role|your (?:role|impact)|job description|position purpose)$/.test(lower)){section='role';continue;}
  if(line.length<85&&/^((?:(?:required|preferred|minimum|basic) )?(?:qualifications|requirements|experience)|what you(?:.ll| will) (?:need|bring)|who you are|about you)$/.test(lower)){section='requirements';continue;}
  if(line.length<85&&/^(benefits|about (?:us|the company)|compensation|equal opportunity)/.test(lower)){section='';continue;}
  for(const sentence of line.split(/(?<=[.!?])\s+(?=[A-Z])/)){
   if(sentence.length<28||/equal opportunity|without regard|reasonable accommodation|privacy notice|recruitment scam/i.test(sentence))continue;
   const text=clip(sentence,230);
   if(section==='requirements'||/\b(years? (?:of )?(?:professional )?experience|bachelor|master.s degree|must have|proficien|experience (?:with|in)|knowledge of|familiarity with)\b/i.test(sentence)){if(!requirements.includes(text))requirements.push(text);}
   else if(section==='role'||/^(?:you (?:will|would)|you.ll|build|design|develop|implement|collaborate|work (?:with|on)|deliver|maintain|support|lead|manage|provide|perform|assist|responsible for)\b/i.test(sentence)){if(!responsibilities.includes(text))responsibilities.push(text);}
  }
 }
 return {responsibilities:responsibilities.slice(0,4),requirements:requirements.slice(0,4)};
}
// What the Job details section shows. `requirements` pairs a key with its text, as the section lists them.
export function listingOf(job={}){
 const found=highlightsOf(job),active=job.active!==false&&!job.stale;
 return {
  responsibilities:found.responsibilities.length?found.responsibilities:[clip(plain(job.description),230)||'See the employer listing for the duties.'],
  requirements:(found.requirements.length?found.requirements:['See the employer listing for requirements.']).map((text,i)=>['req'+i,text]),
  description:clip(plain(job.description),420)||'The employer listing has the full description.',
  url:job.listing_url||job.url||'',source:job.source_name||job.source||'Employer listing',experience:job.seniority&&job.seniority!=='Unknown'?job.seniority:'Not stated',active
 };
}
const nextText=(a,reminder)=>{
 if(reminder)return 'Follow-up · '+new Date(reminder.due_at*1000).toLocaleDateString(undefined,{month:'short',day:'numeric'});
 return {'Ready to apply':'Ready when you are','Submitted':'Waiting to hear back','Assessment':'Complete the assessment','Interview':'Prepare for your interview','Rejected':'Application closed'}[a.status]||'Check your application for the next step';
};
const isoLocal=seconds=>{const d=new Date(seconds*1000),p=n=>String(n).padStart(2,'0');return `${d.getFullYear()}-${p(d.getMonth()+1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;};
export function reminderOf(r){return {id:r.id,title:r.title,when:isoLocal(r.due_at),dueAt:r.due_at,done:!!r.done,target_id:r.target_id};}
export function itemOf(a,reminders=[]){
 const job=a.job||{},mine=reminders.filter(r=>r.target_type==='application'&&r.target_id===a.id);
 const upcoming=mine.filter(r=>!r.done).sort((x,y)=>x.due_at-y.due_at)[0];
 const when=a.status==='Ready to apply'||!a.status?'Saved '+day(a.created_at):(a.history||[]).length?'Updated '+day(a.history[a.history.length-1].at):'Saved '+day(a.created_at);
 return {
  id:a.id,jobId:a.job_id,company:job.company||'Employer',initial:job.initial||String(job.company||'?')[0].toUpperCase(),role:job.title||'Saved job',
  location:[job.location,job.mode&&job.mode!=='Unknown'?job.mode:''].filter(Boolean).join(' · ')||'Location not listed',pay:job.salary||'Pay not listed',
  status:a.status||'Ready to apply',date:when,next:nextText(a,upcoming),note:a.notes||'',color:colorFor(job.company||a.id),resume_id:a.resume_id||'',
  resolvedResumeId:a.tailor?.resume_id||'',resumeReady:!!a.tailor?.ready,
  history:(a.history||[]).map(h=>({status:h.status,date:new Date(h.at*1000).toLocaleString(),source:h.source||'',evidence:h.evidence})),
  reminders:mine.map(reminderOf),sourceUrl:job.listing_url||job.url||'',listing:job,real:true
 };
}
export const itemsOf=boot=>(boot?.applications||[]).filter(a=>!a.demo).map(a=>itemOf(a,boot.reminders||[]));
// The deterministic score as the fit screen lists it: what the listing asks for and what the resume shows.
export function fitOf(score,resumeName){
 const s=score.score||score,checks=[];
 const years=s.requirements?.years;
 if(years)checks.push({requirement:years.min+'+ years of experience'+(years.required?' (required)':''),result:s.requirements.resume_years>=years.min?'Supported':'Not evidenced',listingQuote:years.quote,quote:'Your resume shows about '+Math.round(s.requirements.resume_years*10)/10+' years.',source:resumeName});
 for(const m of s.missing||[])if(!m.supported)checks.push({requirement:m.term+(m.required?' (required)':''),result:'Not evidenced',listingQuote:'The listing asks for '+m.term+'.',quote:'',source:resumeName});
 for(const k of (s.keywords||[]).filter(k=>k.found).slice(0,6))checks.push({requirement:k.term,result:'Supported',listingQuote:'The listing mentions '+k.term+'.',quote:'Found in your resume.',source:resumeName});
 const unknowns=[];
 if(!s.requirements?.education)unknowns.push('The listing does not state an education requirement.');
 unknowns.push('Work authorization, sponsorship and the employer’s final criteria need confirmation with the employer.');
 const parts=(s.match_components||[]).map(c=>c.label+' '+c.score+'%').join(' · ');
 return {at:Date.now(),source:resumeName,fingerprint:'live',checks,unknowns,
  summary:`Job match ${s.match}/100 · resume quality ${s.quality}/100. ${parts?parts+'. ':''}Computed by Stack from your resume and the listing, with no AI model. This is not a hiring prediction.`,raw:s};
}
