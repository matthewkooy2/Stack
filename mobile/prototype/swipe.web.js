// Browser (React Native Web) swipe card used by the design preview and screenshot pipeline.
// Same contract as swipe.js: the transform is animated outside React state and only the coarse
// intent is reported.
import React,{useEffect,useRef} from 'react';
import {Animated,PanResponder,AccessibilityInfo} from 'react-native';
import {SWIPE_THRESHOLD,TILT_RANGE,LEAVE_DISTANCE,LEAVE_MS,RETURN_MS,ACTIVATE_DX,intentOf,leavingOf,heldDragOf} from './swipe-intent';
export function SwipeCard({children,spec,disabled,style,a11y}){
 const x=useRef(new Animated.Value(0)).current,latest=useRef({spec,disabled}),reduced=useRef(false),intent=useRef(0),exiting=useRef(0);latest.current={spec,disabled};
 useEffect(()=>{AccessibilityInfo.isReduceMotionEnabled().then(value=>{reduced.current=value;});const sub=AccessibilityInfo.addEventListener('reduceMotionChanged',value=>{reduced.current=value;});return()=>sub.remove();},[]);
 const leaving=leavingOf(spec),heldDrag=heldDragOf(spec),dragging=useRef(false);
 useEffect(()=>{
  if(leaving){if(exiting.current!==(leaving==='save'?1:-1))Animated.timing(x,{toValue:leaving==='save'?LEAVE_DISTANCE:-LEAVE_DISTANCE,duration:reduced.current?0:LEAVE_MS,useNativeDriver:true}).start();}
  else if(!dragging.current){exiting.current=0;intent.current=0;x.stopAnimation();x.setValue(heldDrag);}
 },[leaving,heldDrag]);
 const settle=()=>{Animated.timing(x,{toValue:0,duration:reduced.current?0:RETURN_MS,useNativeDriver:true}).start();if(intent.current!==0){intent.current=0;latest.current.spec.onDrag?.(0,false);}};
 const pan=useRef(PanResponder.create({
  onMoveShouldSetPanResponder:(_,g)=>!latest.current.disabled&&Math.abs(g.dx)>ACTIVATE_DX&&Math.abs(g.dx)>Math.abs(g.dy)*1.5,
  // Once it owns a horizontal swipe the card keeps it; the vertical scroller inside must not take it over.
  onPanResponderTerminationRequest:()=>false,
  onPanResponderMove:(_,g)=>{
   if(exiting.current!==0)return;
   dragging.current=true;x.setValue(g.dx);
   const next=intentOf(g.dx);if(next!==intent.current){intent.current=next;latest.current.spec.onDrag?.(next,false);}
  },
  onPanResponderRelease:(_,g)=>{
   dragging.current=false;if(exiting.current!==0)return;
   if(Math.abs(g.dx)>=SWIPE_THRESHOLD){const direction=g.dx>0?1:-1;exiting.current=direction;Animated.timing(x,{toValue:direction*LEAVE_DISTANCE,duration:reduced.current?0:LEAVE_MS,useNativeDriver:true}).start();latest.current.spec.onSwipe?.(direction>0?'save':'pass');}
   else settle();
  },
  onPanResponderTerminate:()=>{dragging.current=false;settle();}
 })).current;
 return <Animated.View {...a11y} {...pan.panHandlers} style={[style,{transform:[{translateX:x},{rotate:x.interpolate({inputRange:[-TILT_RANGE,0,TILT_RANGE],outputRange:['-9deg','0deg','9deg'],extrapolate:'clamp'})}]}]}>{children}</Animated.View>;
}
