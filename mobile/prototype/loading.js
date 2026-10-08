import {useSyncExternalStore} from 'react';
let mode='normal',screen='Jobs',provider='google',version=0;
const listeners=new Set();
export const subscribePreviewLoading=fn=>{listeners.add(fn);return()=>listeners.delete(fn);};
export const subscribeAuthLoading=subscribePreviewLoading;
export function setReviewMode(value){mode=value;version++;listeners.forEach(fn=>fn());}
export function setReviewScreen(value){screen=value;version++;listeners.forEach(fn=>fn());}
export function setReviewProvider(value){provider=value;version++;listeners.forEach(fn=>fn());}
export const getReviewMode=()=>mode;
export const getReviewScreen=()=>screen;
export function useReviewState(){useSyncExternalStore(subscribePreviewLoading,()=>version);return {mode,screen,provider};}
export const resumeLoadingSnapshot=()=>mode==='loading'&&screen==='Resume';
export const prepLoadingSnapshot=()=>mode==='loading'&&screen==='Prep';
export const networkLoadingSnapshot=()=>mode==='loading'&&screen==='Network';
export const applicationsLoadingSnapshot=()=>mode==='loading'&&screen==='Applications';
export const jobsLoadingSnapshot=()=>mode==='loading'&&screen==='Jobs';
