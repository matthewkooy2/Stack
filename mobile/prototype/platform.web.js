// OS-only browser adapter; screen source remains the same Jac view tree.
import React,{useEffect,useRef,useState} from 'react';
import {View,Text} from 'react-native';
import {getDocument,GlobalWorkerOptions} from 'pdfjs-dist/build/pdf.mjs';
import {configureServices} from './services';
import {configureDocumentSurface} from './controls';
GlobalWorkerOptions.workerSrc='/pdf.worker.min.mjs';
const fileDatabase=new Promise((resolve,reject)=>{const request=indexedDB.open('stack-mobui-files',1);request.onupgradeneeded=()=>request.result.createObjectStore('files');request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);});
async function fileTransaction(mode,run){const db=await fileDatabase;return new Promise((resolve,reject)=>{const transaction=db.transaction('files',mode),request=run(transaction.objectStore('files'));transaction.oncomplete=()=>resolve(request.result);transaction.onerror=()=>reject(transaction.error);});}
export async function preparePlatform(){
 let initial={};try{initial=JSON.parse(localStorage.getItem('stack.mobui.mock.v1')||'{}');}catch{}
 configureServices({save:values=>localStorage.setItem('stack.mobui.mock.v1',JSON.stringify(values)),copy:text=>navigator.clipboard.writeText(text),
  storeFile:(id,file)=>fileTransaction('readwrite',store=>store.put(file,id)),
  loadFile:async id=>{const file=await fileTransaction('readonly',store=>store.get(id));if(file)file.uri=URL.createObjectURL(file);return file;},
  pick:({accept})=>new Promise(resolve=>{const input=document.createElement('input');input.type='file';input.accept=accept||'';input.oncancel=()=>resolve(null);input.onchange=()=>{const file=input.files[0];if(file)file.uri=URL.createObjectURL(file);resolve(file||null);};input.click();}),
  exportFile(data,name,type){const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([data],{type}));a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);},
  fileUri:file=>file.uri||URL.createObjectURL(file),releaseFile:()=>{}
 },initial);configureDocumentSurface(DocumentSurface);
}
export function DocumentSurface({uri,label}){return <PdfPreview uri={uri} label={label}/>;}
export function PdfPreview({data,uri,label}){
 const host=useRef(null),[error,setError]=useState('');
 useEffect(()=>{let live=true;const task=getDocument(data?{data:data.slice()}:uri);(async()=>{try{const doc=await task.promise;for(let i=1;i<=doc.numPages;i++){const page=await doc.getPage(i);if(!live)return;const viewport=page.getViewport({scale:1});const canvas=document.createElement('canvas');canvas.width=viewport.width;canvas.height=viewport.height;canvas.style.width='100%';canvas.setAttribute('aria-label',`${label||'PDF'} page ${i}`);host.current?.appendChild(canvas);await page.render({canvasContext:canvas.getContext('2d'),viewport}).promise;}}catch(e){if(live)setError('Preview unavailable. Reattach the PDF and retry.');}})();return()=>{live=false;task.destroy();host.current?.replaceChildren();};},[data,uri]);
 return <View>{error?<Text accessibilityRole="alert">{error}</Text>:null}<div ref={host}/></View>;
}
