// Shared motion for the Prep workflow. One easing curve and one set of durations keep every step in step.
// Plain createElement (no JSX) so the native test harness can load this module without a JSX transform.
import React,{useEffect,useRef,useState} from 'react';
import {Animated,AccessibilityInfo,Easing,Platform,Pressable,View} from 'react-native';
const h=React.createElement;
// Native-driven where available; react-native-web has no native animated module.
const native=Platform.OS!=='web';
export const MOTION={stage:300,reveal:360,stagger:55,press:90,fade:200,out:140,loop:2000};
const EASE=Easing.bezier(.22,1,.36,1);
// One shared reduce-motion subscription: entrance motion is skipped and loops stop when the person asks for less motion.
let reduced=false;const listeners=new Set();
function setReduced(value){reduced=!!value;listeners.forEach(fn=>fn(reduced));}
try{AccessibilityInfo.isReduceMotionEnabled?.().then(setReduced,()=>{});AccessibilityInfo.addEventListener?.('reduceMotionChanged',setReduced);}catch(e){}
export function useReduced(){
  const [value,setValue]=useState(reduced);
  useEffect(()=>{setValue(reduced);listeners.add(setValue);return()=>listeners.delete(setValue);},[]);
  return value;
}
function useValue(initial){const ref=useRef(null);if(ref.current===null)ref.current=new Animated.Value(initial);return ref.current;}
// Depth orders the setup → answer → coaching path so a page can tell whether the person moved on or back.
const DEPTH={home:0,type:1,continue:1,past:1,legacy:1,focus:2,length:3,question:4,answer:5,recording:5,review:6,processing:7,coaching:8,complete:9,history:9,'saved-answer':10};
function StageInner({dir,style,children}){
  const v=useValue(reduced?1:0);
  useEffect(()=>{
    if(reduced){v.setValue(1);return;}
    const run=Animated.timing(v,{toValue:1,duration:MOTION.stage,easing:EASE,useNativeDriver:native});
    run.start();return()=>run.stop();
  },[]);
  return h(Animated.View,{style:[{flex:1,gap:24},style,{opacity:v.interpolate({inputRange:[0,.6,1],outputRange:[0,1,1]}),transform:[{translateX:v.interpolate({inputRange:[0,1],outputRange:[dir*22,0]})}]}]},children);
}
// A page change remounts the stage so the new page slides in from the side it was reached from.
export function PrepStage({pageKey,step=0,style,children}){
  const prev=useRef({key:pageKey,step,dir:1});
  if(prev.current.key!==pageKey){
    const was=prev.current;
    prev.current={key:pageKey,step,dir:step!==was.step?(step>was.step?1:-1):((DEPTH[pageKey]??4)>=(DEPTH[was.key]??4)?1:-1)};
  }
  return h(StageInner,{key:pageKey,dir:prev.current.dir,style},children);
}
// Content rises into place on mount; `index` staggers siblings.
export function Reveal({index=0,delay=0,rise=14,style,children}){
  const v=useValue(reduced?1:0);
  useEffect(()=>{
    if(reduced){v.setValue(1);return;}
    const run=Animated.timing(v,{toValue:1,duration:MOTION.reveal,delay:40+delay+Math.min(index,8)*MOTION.stagger,easing:EASE,useNativeDriver:native});
    run.start();return()=>run.stop();
  },[]);
  return h(Animated.View,{style:[style,{opacity:v,transform:[{translateY:v.interpolate({inputRange:[0,1],outputRange:[rise,0]})}]}]},children);
}
const AnimatedPressable=Animated.createAnimatedComponent(Pressable);
// Pressable with a soft press-in, a springy release, and a fade (rather than a snap) when it enables or disables.
export function Tap({disabled=false,pressedScale=.97,dim=.45,style,onPressIn,onPressOut,children,...rest}){
  const scale=useValue(1),fade=useValue(disabled?dim:1),first=useRef(true);
  useEffect(()=>{
    if(first.current){first.current=false;return;}
    if(reduced){fade.setValue(disabled?dim:1);return;}
    const run=Animated.timing(fade,{toValue:disabled?dim:1,duration:MOTION.fade,useNativeDriver:native});
    run.start();return()=>run.stop();
  },[disabled]);
  const press=down=>{
    if(reduced){scale.setValue(1);return;}
    (down?Animated.timing(scale,{toValue:pressedScale,duration:MOTION.press,easing:Easing.out(Easing.quad),useNativeDriver:native})
      :Animated.spring(scale,{toValue:1,speed:28,bounciness:8,useNativeDriver:native})).start();
  };
  return h(AnimatedPressable,{...rest,disabled,style:[style,{opacity:fade,transform:[{scale}]}],onPressIn:e=>{press(true);onPressIn?.(e);},onPressOut:e=>{press(false);onPressOut?.(e);}},children);
}
// Small springy pop-in for marks such as a completed day.
export function Pop({delay=0,style,children}){
  const v=useValue(reduced?1:0);
  useEffect(()=>{
    if(reduced){v.setValue(1);return;}
    const run=Animated.spring(v,{toValue:1,delay,speed:14,bounciness:12,useNativeDriver:native});
    run.start();return()=>run.stop();
  },[]);
  return h(Animated.View,{style:[style,{opacity:v.interpolate({inputRange:[0,.4],outputRange:[0,1],extrapolate:'clamp'}),transform:[{scale:v.interpolate({inputRange:[0,1],outputRange:[.5,1]})}]}]},children);
}
// Fades content in and out. `keep` holds the layout space instead of unmounting once hidden.
export function FadeSwitch({show,keep=false,style,children}){
  const v=useValue(show?1:0),held=useRef(children),[mounted,setMounted]=useState(show);
  if(show)held.current=children;
  useEffect(()=>{
    if(show)setMounted(true);
    if(reduced){v.setValue(show?1:0);if(!show)setMounted(false);return;}
    const run=Animated.timing(v,{toValue:show?1:0,duration:show?MOTION.fade:MOTION.out,easing:EASE,useNativeDriver:native});
    run.start(({finished})=>{if(finished&&!show)setMounted(false);});
    return()=>run.stop();
  },[show]);
  if(!keep&&!show&&!mounted)return null;
  return h(Animated.View,{style:[style,{opacity:v}]},held.current);
}
// A soft disc behind an icon; while active, a ring expands from it (recording, working).
export function Halo({active=false,size=88,color='#F6E3BA',ring='#E6D1A0',children}){
  const reduce=useReduced(),v=useValue(0),moving=active&&!reduce;
  useEffect(()=>{
    if(!moving){v.setValue(0);return;}
    const loop=Animated.loop(Animated.timing(v,{toValue:1,duration:MOTION.loop,easing:Easing.out(Easing.quad),useNativeDriver:native}));
    loop.start();return()=>{loop.stop();v.setValue(0);};
  },[moving]);
  const fill={position:'absolute',width:size,height:size,borderRadius:size/2};
  return h(View,{style:{width:size,height:size,alignItems:'center',justifyContent:'center'}},
    moving?h(Animated.View,{pointerEvents:'none',style:[fill,{backgroundColor:ring,opacity:v.interpolate({inputRange:[0,1],outputRange:[.6,0]}),transform:[{scale:v.interpolate({inputRange:[0,1],outputRange:[1,1.75]})}]}]}):null,
    h(View,{style:[fill,{backgroundColor:color}]}),
    // Explicit stacking: on the web an absolutely positioned disc would otherwise paint over its icon.
    h(View,{style:{zIndex:1}},children));
}
// Gentle opacity breathing for "working" states.
export function Breathe({active=true,min=.45,style,children}){
  const reduce=useReduced(),v=useValue(1),moving=active&&!reduce;
  useEffect(()=>{
    if(!moving){v.setValue(1);return;}
    const loop=Animated.loop(Animated.sequence([
      Animated.timing(v,{toValue:min,duration:1300,easing:Easing.inOut(Easing.sin),useNativeDriver:native}),
      Animated.timing(v,{toValue:1,duration:1300,easing:Easing.inOut(Easing.sin),useNativeDriver:native})]));
    loop.start();return()=>{loop.stop();v.setValue(1);};
  },[moving]);
  return h(Animated.View,{style:[style,{opacity:v}]},children);
}
