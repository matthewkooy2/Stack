// Prototype disclosures baked into the shared view templates. With real data they would be false ("Sample job",
// "Simulated…"), so live builds hide or reword them here; mock builds are untouched. Anything that changes
// with the data is a template slot instead and is supplied by its controller.
import {backend} from './backend';
const hidden=new Set([
 'Sample opportunity for design review.',
 'Sample wording only. Your original stays unchanged.',
 'Prototype',
 'Simulated video',
 'Demo',
 'Simulated browser and sample profile · No LinkedIn account is accessed.',
 'This preview simulates the private browser. No credentials are requested.',
 'Demo transcript · Not recorded speech',
]);
const reworded=new Map([
 [' saved in this preview session.',' saved to your Applications.'],
 ['Prototype: files stay in your browser. Parsing is simulated with sample details.','Your PDF is stored privately in your Stack account and read by its resume parser.'],
 ['Simulated extraction · sample information','Read from your PDF · check every field'],
 ['Sample listing and employer URL · ','Employer listing · '],
 ['Local reminders · No emails or notifications are sent.','Reminders on your account · Your iPhone alerts you when notifications are allowed. No emails are sent.'],
 ['. Preparation is simulated, including on active demos.','.'],
 ['Sample employer listing','Employer listing'],
 ['Sample listing · Evidence-based mock result','Computed by Stack from your resume and this listing · no AI model'],
 ['A solid foundation','Your coaching'],
 ['Approve & simulate send','Approve & send'],
 ['Fictional sample report · Captured ','Captured '],
 ['Email approved and delivery simulated. Any next follow-up will need a separate approval.','Email approved and sent. Any next follow-up will need a separate approval.'],
 ['Confirm the simulated result before retrying. This prevents duplicate email.','Confirm what happened before retrying. This prevents duplicate email.'],
 ['Compare the sample listing with facts you confirmed. A resume is optional.','Compare this listing with the confirmed details of your resume.'],
 ['I confirm these facts for this prototype.','I confirm these facts are accurate.'],
]);
// Disclaimers about sample data or simulation, matched by their opening words.
const hiddenStarts=['Mock document preview.','Add missing skills only if true. These simplified prototype','Saved jobs and agent work are simulated','Preview reflects the changes currently kept.','This prototype inspects the main document only','PDFs use a paginated preview layout.','Simulated import ·','Simulated media for this prototype.','Demo transcript ·','Sample employer destination.','Simulated workflow ·','There will be no automatic retry. This is a simulated outcome.'];
export const copyHidden=text=>backend.live&&typeof text==='string'&&(hidden.has(text)||hiddenStarts.some(p=>text.startsWith(p)));
export const copyText=text=>backend.live&&reworded.has(text)?reworded.get(text):text;
export function soleText(children){
 const items=Array.isArray(children)?children.flat(Infinity).filter(c=>c!==null&&c!==undefined&&c!==false&&c!==''):[children];
 return items.length===1&&typeof items[0]==='string'?items[0]:undefined;
}
// Rewords every plain-text child of an element (a paragraph can mix text with data slots).
export function copyChildren(children){
 if(!backend.live)return children;
 if(typeof children==='string')return copyText(children);
 return Array.isArray(children)?children.map(c=>typeof c==='string'?copyText(c):c):children;
}
