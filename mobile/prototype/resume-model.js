import {formatOf} from './resume-library';
export {formatOf} from './resume-library';
import {PDFDocument,rgb,StandardFonts,PDFName,PDFArray,decodePDFRawStream} from 'pdf-lib';
import {services} from './services';



export const jobs=[{id:'northstar',role:'Product Design Intern',company:'Northstar',skills:['Figma','prototyping','user research']},{id:'linear',role:'UX Design Intern',company:'Linear',skills:['accessibility','interaction design','Figma']}];
export function applicationTailoredResume(task,item,resume){
 const details={...task.original,experience:task.changes.map(c=>c.kept?c.after:c.before).join('\n')};
 return {id:'tailored-'+task.id,name:item.company+' · Tailored resume',kind:'tailored',tailored:true,
  confirmed:true,isDefault:false,sample:true,application_id:item.id,sourceId:String(resume.id),
  sourceName:resume.name,sourceDetails:{...task.original},details,createdAt:Date.now(),
  format:tailorSource(resume,details),job:{id:String(item.id),company:item.company,role:item.role},
  changes:task.changes,task:null};
}
export const normalize=s=>String(s||'').normalize('NFC').replace(/\s+/g,' ').trim();
const tex=s=>String(s||'').replace(/[\\{}%$&#_^~]/g,c=>({'\\':'\\textbackslash{}','~':'\\textasciitilde{}','^':'\\textasciicircum{}'}[c]||'\\'+c));
export function latex(r){const f=formatOf(r);if(f?.kind==='upload')return f.source;const classic=f?.template==='classic';return `\\documentclass[11pt]{article}\n\\usepackage[utf8]{inputenc}\n\\usepackage[T1]{fontenc}\n\\usepackage[margin=1in]{geometry}\n${classic?'\\renewcommand{\\familydefault}{\\sfdefault}\n':''}\\begin{document}\n${classic?'':'\\begin{center}\n'}{\\LARGE ${tex(r.details.name)}}\\par\n${[r.details.email,r.details.location].filter(Boolean).map(tex).join(' \\quad ')}\\par\n${classic?'':'\\end{center}\n'}${['experience','education','skills'].map(k=>`\\section*{${k[0].toUpperCase()+k.slice(1)}}\n${r.details[k].split('\n').map(tex).join('\\par\n')}\n`).join('')}\\end{document}\n`;}
export async function makePdf(r){const doc=await PDFDocument.create();const classic=formatOf(r)?.template==='classic';const font=await doc.embedFont(classic?StandardFonts.Helvetica:StandardFonts.TimesRoman);const supported=new Set(font.getCharacterSet());const all=Object.values(r.details).join('\n');for(const c of all){if(!/\s/.test(c)&&!supported.has(c.codePointAt(0)))throw Error(`PDF font cannot render “${c}”. Choose another format or use your LaTeX source; no content was removed.`);}
 let page,y;const start=()=>{page=doc.addPage([612,792]);y=738;};start();const write=(text,size=11)=>{const max=508;for(const raw of String(text||'').split('\n')){let line='';for(const word of raw.split(/\s+/)){const candidate=line?line+' '+word:word;if(font.widthOfTextAtSize(candidate,size)<=max){line=candidate;continue;}if(line){draw(line,size);line='';}for(const c of word){if(font.widthOfTextAtSize(line+c,size)>max){draw(line,size);line='';}line+=c;}}draw(line,size);} };const draw=(line,size)=>{if(y<54)start();page.drawText(line,{x:52,y,size,font,color:rgb(.12,.17,.25)});y-=size*1.55;};
 write(r.details.name,20);write([r.details.email,r.details.location].filter(Boolean).join(' · '));y-=12;for(const k of ['experience','education','skills']){if(!r.details[k])continue;if(y<90)start();write(k.toUpperCase(),12);write(r.details[k]);y-=12;}doc.setTitle(r.name);return {bytes:await doc.save(),pages:doc.getPageCount()};}
// Extract the text operators emitted by this mock document writer on both platforms.
// External resume parsing remains simulated, as in the source prototype.
export async function readPdf(bytes){
 const doc=await PDFDocument.load(bytes);let text='';
 const win={128:'€',130:'‚',131:'ƒ',132:'„',133:'…',134:'†',135:'‡',136:'ˆ',137:'‰',138:'Š',139:'‹',140:'Œ',145:'‘',146:'’',147:'“',148:'”',149:'•',150:'–',151:'—',152:'˜',153:'™',154:'š',155:'›',156:'œ',159:'Ÿ'};
 for(const page of doc.getPages()){
  let streams=page.node.lookup(PDFName.of('Contents'));
  streams=streams instanceof PDFArray?streams.asArray().map(r=>doc.context.lookup(r)):[streams];
  for(const stream of streams){if(!stream)continue;const data=decodePDFRawStream(stream).decode();const operators=Array.from(data,b=>String.fromCharCode(b)).join('');
   for(const m of operators.matchAll(/<([0-9a-f]+)>\s*Tj/gi)){for(let i=0;i<m[1].length;i+=2){const n=parseInt(m[1].slice(i,i+2),16);text+=win[n]||String.fromCharCode(n);}text+=' ';}
  }
 }
 return {text:normalize(text),pages:doc.getPageCount()};
}
export function compareText(details,text,baseline=''){const compact=s=>normalize(s).replace(/\s/g,'');const got=compact(text);const original=compact(baseline);return Object.entries(details).flatMap(([key,value])=>{const lines=String(value||'').split('\n').map(normalize).filter(Boolean);return (lines.length?lines:['']).map((line,i)=>({label:`${key}${lines.length>1?' · line '+(i+1):''}`,ok:!!line&&got.includes(compact(line)),detail:!line?'Not provided':got.includes(compact(line))?'Read from PDF':`Not recovered: ${line}`,alsoOriginal:!!line&&!got.includes(compact(line))&&!!original&&!original.includes(compact(line))}));});}
export function score(details,job){const text=normalize(Object.values(details).join(' ')).toLowerCase();const missing=job.skills.filter(s=>!text.includes(s.toLowerCase()));const filled=Object.values(details).filter(v=>v.trim()).length;return {match:Math.round((job.skills.length-missing.length)/job.skills.length*100),quality:Math.round(filled/6*75+(details.experience.length>40?25:0)),missing,components:[['Required skills',job.skills.length-missing.length,job.skills.length],['Confirmed fields',filled,6]],issues:details.experience.length<40?['Add evidence of your work in Experience.']:[]};}
export function propose(r,job){const changes=[];const exp=r.details.experience;const rewrite=exp.replace('Built and tested','Designed and tested');if(rewrite!==exp)changes.push({id:'wording',key:'experience',kind:'Wording',before:exp,after:rewrite,reason:'Use a direct design verb without adding a claim.'});const before=r.details.skills;const sorted=before.split(',').map(s=>s.trim()).filter(Boolean).sort((a,b)=>Number(job.skills.some(s=>s.toLowerCase()===b.toLowerCase()))-Number(job.skills.some(s=>s.toLowerCase()===a.toLowerCase()))).join(', ');if(sorted!==before)changes.push({id:'order',key:'skills',kind:'Reorder',before,after:sorted,reason:'Put skills named in the listing first.'});const lines=exp.split('\n');const unique=[...new Set(lines)];if(unique.length!==lines.length)changes.push({id:'trim',key:'experience',kind:'Trim',before:rewrite,after:unique.join('\n').replace('Built and tested','Designed and tested'),reason:'Remove repeated lines; no unique experience is dropped.'});return changes;}
export function applyChanges(details,changes,rejected){const next={...details};for(const c of changes){if(rejected.includes(c.id))continue;if(c.id==='trim'&&rejected.includes('wording'))next[c.key]=c.after.replace('Designed and tested','Built and tested');else next[c.key]=c.after;}return next;}
export function download(data,name,type){return services.exportFile(data,name,type);}

export function tailorSource(resume,details){const f=formatOf(resume);if(f?.kind!=='upload')return f;let source=f.source;for(const key of Object.keys(details)){if(details[key]===resume.details[key])continue;const before=resume.details[key],after=details[key];const candidates=[[tex(before),tex(after)],[before,after],[before.split('\n').map(tex).join('\\par\n'),after.split('\n').map(tex).join('\\par\n')]];const match=candidates.find(([a])=>a&&source.includes(a));if(!match)throw Error('The uploaded source does not match the confirmed '+key+'. Keep the original wording, or select a built-in format before tailoring.');source=source.replace(match[0],match[1]);}return {...f,source};}
