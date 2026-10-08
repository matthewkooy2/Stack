// Maps the backend's resume model onto what the screens edit. Pure functions, no imports, tested against real
// parsed resumes (tests/live-resume.cjs).
//
// The backend keeps a parsed resume as flat text values keyed like "profile.name" or "workExperiences.1.jobTitle".
// The screens edit six fields. name, email and location map one-to-one. Experience, education and skills are
// shown as text and written back only when the person changed that text, so everything else the parser found
// (phone, links, summary, projects, extra details, GPA, dates) is never lost by an unrelated edit.
export const EMPTY_DETAILS={name:'',email:'',location:'',experience:'',education:'',skills:''};
export const REPEATED_LIMIT=20;
const SEP=' · ';
const bullet=/^\s*[•\-–*]\s*/;
const records=(values,section)=>{
 const indexes=[...new Set(Object.keys(values).filter(k=>k.startsWith(section+'.')).map(k=>Number(k.split('.')[1])))].sort((a,b)=>a-b);
 return indexes.map(i=>{const read=f=>String(values[section+'.'+i+'.'+f]||'').trim();return {index:i,read};});
};
const lines=text=>String(text||'').split('\n').map(l=>l.replace(bullet,'').trim()).filter(Boolean);
// A year or year range such as "Jun 2022 – Aug 2023", so a missing title or company cannot shift a date into its place.
const looksDate=text=>/^(?:[A-Za-z]{3,9}\.?\s+)?(?:19|20)\d{2}(?:\s*[–-]\s*(?:(?:[A-Za-z]{3,9}\.?\s+)?(?:19|20)\d{2}|present|current))?$/i.test(String(text).trim());
function workBlock({read}){
 const head=[read('jobTitle'),read('company')].filter(Boolean);
 if(read('date'))head.push(read('date'));
 return [head.join(SEP),...lines(read('descriptions'))].filter(Boolean).join('\n');
}
function educationBlock({read}){
 const head=[read('degree'),read('school')].filter(Boolean);
 if(read('date'))head.push(read('date'));
 if(read('gpa'))head.push('GPA '+read('gpa'));
 return [head.join(SEP),...lines(read('descriptions'))].filter(Boolean).join('\n');
}
export function detailsOf(values={}){
 return {
  name:String(values['profile.name']||'').trim(),email:String(values['profile.email']||'').trim(),location:String(values['profile.location']||'').trim(),
  experience:records(values,'workExperiences').map(workBlock).filter(Boolean).join('\n\n'),
  education:records(values,'educations').map(educationBlock).filter(Boolean).join('\n\n'),
  skills:String(values['skills.descriptions']||'').trim()
 };
}
const blocksOf=text=>String(text||'').split(/\n\s*\n/).map(b=>b.trim()).filter(Boolean).slice(0,REPEATED_LIMIT);
function parseWork(block){
 const [head,...rest]=block.split('\n'),parts=head.split(SEP).map(p=>p.trim()).filter(Boolean),out={jobTitle:'',company:'',date:'',descriptions:rest.map(l=>l.replace(bullet,'').trim()).filter(Boolean).join('\n')};
 const names=[];for(const part of parts){if(names.length<2&&!(names.length&&looksDate(part)))names.push(part);else out.date=out.date?out.date+SEP+part:part;}
 [out.jobTitle,out.company]=[names[0]||'',names[1]||''];
 return out;
}
function parseEducation(block){
 const [head,...rest]=block.split('\n'),parts=head.split(SEP).map(p=>p.trim()).filter(Boolean),out={degree:'',school:'',date:'',gpa:'',descriptions:rest.map(l=>l.replace(bullet,'').trim()).filter(Boolean).join('\n')};
 const names=[];
 for(const part of parts){
  if(/^gpa\b/i.test(part))out.gpa=part.replace(/^gpa\s*:?\s*/i,'').trim();
  else if(names.length<2&&!(names.length&&looksDate(part)))names.push(part);
  else out.date=out.date?out.date+SEP+part:part;
 }
 [out.degree,out.school]=[names[0]||'',names[1]||''];
 return out;
}
function replaceSection(values,section,parsed){
 const next={};
 for(const [key,value] of Object.entries(values))if(!key.startsWith(section+'.'))next[key]=value;
 parsed.forEach((record,i)=>{for(const [field,value] of Object.entries(record))if(value)next[section+'.'+i+'.'+field]=value;});
 return next;
}
// Applies edited details on top of the stored values, touching only the parts whose text changed.
export function valuesFrom(details,base={}){
 const before=detailsOf(base),d={...EMPTY_DETAILS,...details};
 let values={...base};
 const set=(key,value)=>{const text=String(value||'').trim();if(text)values[key]=text;else delete values[key];};
 if(d.name!==before.name)set('profile.name',d.name);
 if(d.email!==before.email)set('profile.email',d.email);
 if(d.location!==before.location)set('profile.location',d.location);
 if(d.skills!==before.skills)set('skills.descriptions',d.skills);
 if(d.experience.trim()!==before.experience)values=replaceSection(values,'workExperiences',blocksOf(d.experience).map(parseWork));
 if(d.education.trim()!==before.education)values=replaceSection(values,'educations',blocksOf(d.education).map(parseEducation));
 return values;
}
// "sections" (the review the backend returns) back to the flat value map.
export function valuesOfSections(sections=[]){
 const values={};
 for(const section of sections)for(const field of section.fields||[])if(field.value!==undefined&&field.value!=='')values[field.key]=field.value;
 return values;
}
export const equalValues=(a,b)=>{const ka=Object.keys(a||{}).sort(),kb=Object.keys(b||{}).sort();return ka.length===kb.length&&ka.every((k,i)=>k===kb[i]&&String(a[k]).trim()===String(b[k]).trim());};
// The Resume library as the screens read it: originals (uploaded PDFs) and tailored versions, from one snapshot.
// `reviews` holds parsed details by resume id; a resume still being parsed simply has empty details.
const formatFrom=r=>{
 const f=r.format||{},job=r.processing?.source;
 if(f.kind)return {kind:f.kind,template:f.template||'jake',status:'completed',file:f.file||'',label:f.label||'',pages:f.pages||0,summary:f.summary||{},skipped:f.skipped||[]};
 if(job&&['queued','running'].includes(job.status))return {kind:'upload',template:'jake',status:'running',file:job.name||''};
 if(job?.status==='failed')return {kind:'upload',template:'jake',status:'failed',file:job.name||'',message:job.message||''};
 return null;
};
export function libraryFrom(boot,reviews={}){
 if(!boot)return [];
 const originals=(boot.resumes||[]).map(r=>({
  id:r.id,name:r.name,kind:'upload',confirmed:r.details_status==='Confirmed',isDefault:boot.selected_resume===r.id,
  details:reviews[r.id]?detailsOf(reviews[r.id].values):{...EMPTY_DETAILS},size:r.size,createdAt:(r.created_at||0)*1000,
  processing:r.processing?.pdf||null,parsed:!!reviews[r.id]?.sections?.length,blobId:'resume:'+r.id,format:formatFrom(r)
 }));
 const tailored=(boot.tailored_resumes||[]).map(t=>({
  id:t.id,name:t.name,kind:'tailored',tailored:true,confirmed:true,isDefault:false,details:{...EMPTY_DETAILS},
  sourceId:'',sourceName:t.source_name||'Original resume',application_id:t.application_id,createdAt:(t.created_at||0)*1000,
  job:{id:t.application_id,role:t.job_title||'Saved application',company:t.company||''},pages:t.pages||0,
  format:{kind:t.format==='builtin'?'builtin':'upload',template:'jake',status:'completed'},blobId:'tailored:'+t.id,
  parse:(t.parse?.checks||[]).map(c=>({label:c.label,ok:!!c.ok,detail:c.detail||'',alsoOriginal:!!c.also_original})),parseError:t.parse?.error||'',score:t.score||null
 }));
 return [...originals,...tailored];
}
