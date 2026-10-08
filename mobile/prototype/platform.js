// Native device adapter. Browser preview uses platform.web.js with the same API.
import React,{useEffect,useState} from 'react';
import {AppState,Text,View,Share} from 'react-native';
import * as Documents from 'expo-document-picker';
import {File,Paths} from 'expo-file-system';
import * as Clipboard from 'expo-clipboard';
import Pdf from 'react-native-pdf';
import {configureServices,flushStorage} from './services';
import {configureDocumentSurface} from './controls';
import {realAuthEnabled,liveData} from '../auth-platform';
const store=new File(Paths.document,liveData?'stack-ui-live-local.json':realAuthEnabled?'stack-ui-oauth-demo.json':'stack-ui-mock.json');
const bytesToBase64=bytes=>{const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';let out='';for(let i=0;i<bytes.length;i+=3){const n=(bytes[i]<<16)|((bytes[i+1]||0)<<8)|(bytes[i+2]||0);out+=alphabet[n>>>18]+alphabet[(n>>>12)&63]+(i+1<bytes.length?alphabet[(n>>>6)&63]:'=')+(i+2<bytes.length?alphabet[n&63]:'=');}return out;};
export function DocumentSurface({uri,label}){const [error,setError]=useState('');return <View style={{height:520}}>{error?<Text accessibilityRole="alert">{error}</Text>:<Pdf source={{uri}} style={{flex:1}} trustAllCerts={false} onError={()=>setError('Preview unavailable. Reattach the document and try again.')} accessibilityLabel={label||'Resume PDF'}/>}</View>;}
export async function preparePlatform(){
 let initial={};try{if(store.exists)initial=JSON.parse(await store.text());}catch{}
 configureServices({
  deferSave:true,
  save(values){store.write(JSON.stringify(values));},
  copy:Clipboard.setStringAsync,
  async pick({accept}){
   const result=await Documents.getDocumentAsync({type:accept?.includes('pdf')?'application/pdf':'*/*',copyToCacheDirectory:true});if(result.canceled)return null;
   const a=result.assets[0],source=new File(a.uri),file=new File(Paths.document,`stack-import-${Date.now()}-${a.name.replace(/[^a-zA-Z0-9. -]/g,'_')}`);source.copy(file);return {...a,uri:file.uri,text:()=>file.text(),arrayBuffer:()=>file.arrayBuffer(),slice:(start,end)=>({text:async()=>String.fromCharCode(...(await file.bytes()).slice(start,end))})};
  },
  async exportFile(data,name,type){const file=new File(Paths.cache,name.replace(/[^a-zA-Z0-9. -]/g,'_'));file.write(typeof data==='string'?data:new Uint8Array(data));await Share.share({url:file.uri,title:name});},
  fileUri:file=>file.uri,releaseFile:()=>{}
 },initial);configureDocumentSurface(DocumentSurface);
 AppState.addEventListener('change',state=>{if(state!=='active')flushStorage();});
}
export function PdfPreview({data,uri}){return <DocumentSurface uri={uri||'data:application/pdf;base64,'+bytesToBase64(data)}/>;}
