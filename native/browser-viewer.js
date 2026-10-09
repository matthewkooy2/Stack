// Shared remote browser surface. Control authority lives on the server.
import React,{useEffect,useRef,useState} from 'react';
import {AppState,View,Text,Pressable,Image,Modal,TextInput,PanResponder} from 'react-native';

export function createBrowserStream({id,origin,authorization,isCurrent,onEvent,onState}) {
  let xhr=null,timer=null,closed=false,attempt=0;
  const connect=()=>{
    if(closed||!isCurrent())return;
    onState(attempt?'reconnecting':'connecting');attempt++;
    const request=new XMLHttpRequest();xhr=request;let cursor=0,tail='';
    request.open('POST',origin.replace(/\/$/,'')+'/browser/stream');
    request.setRequestHeader('Content-Type','application/json');
    request.setRequestHeader('Authorization',authorization);
    request.timeout=35000;
    const read=()=>{
      if(closed||xhr!==request||!isCurrent())return;
      if(request.status&&request.status!==200)return;
      const raw=request.responseText||'';tail+=raw.slice(cursor);cursor=raw.length;
      if(tail.length>1024*1024){request.abort();return;}
      let end;
      while((end=tail.indexOf('\n\n'))>=0){
        const chunk=tail.slice(0,end);tail=tail.slice(end+2);
        if(chunk.startsWith('data: ')){
          try {const value=JSON.parse(chunk.slice(6));onState('connected');onEvent(value);}
          catch {onState('invalid');request.abort();return;}
        }
      }
    };
    const finish=()=>{
      if(closed||xhr!==request)return;
      if(request.status===401||request.status===403){onState('unavailable');closed=true;return;}
      onState('reconnecting');timer=setTimeout(connect,request.status===200?150:Math.min(5000,500*attempt));
    };
    request.onprogress=read;request.onload=()=>{read();finish();};
    request.onabort=finish;
    request.onerror=request.ontimeout=finish;
    request.send(JSON.stringify({id}));
  };
  connect();
  return ()=>{closed=true;clearTimeout(timer);xhr?.abort();};
}

export function browserTaskStatus(task={},now=Date.now()/1000) {
  const labels={running:'Agent is working',queued:'Queued for the agent',needs_input:'Your input is needed',paused:'Task paused',review:'Waiting for approval',uncertain:'Check what happened',blocked:'Task blocked',cancelled:'Task cancelled',failed:'Task failed',completed:'Task completed'};
  const retry=task.status==='queued'&&Number.isFinite(task.retry_at)&&task.retry_at>0;
  const remaining=retry?Math.max(0,Math.ceil(task.retry_at-now)):0;
  return {label:retry?(remaining?`Retrying in ${remaining}s`:'Retry is due; waiting for the agent'):labels[task.status]||'Waiting for task status',
    stage:task.step_label?(task.step_total>1?`Step ${task.step_number} of ${task.step_total} · ${task.step_label}`:task.step_label):'',
    message:task.message||'',explanation:task.explanation||''};
}

export function BrowserViewer({id,task={},requestBrowser,openStream,onChanged}) {
  const [open,setOpen]=useState(false),[frame,setFrame]=useState(null),[control,setControl]=useState({mode:'agent',generation:0}),[connection,setConnection]=useState('connecting'),[error,setError]=useState(''),[busy,setBusy]=useState(false),[pendingAction,setPendingAction]=useState(''),[age,setAge]=useState(Infinity);
  const keyboard=useRef(null),input=useRef(''),flushTimer=useRef(null),chain=useRef(Promise.resolve()),sequence=useRef(0),epoch=useRef(0),alive=useRef(false),stopStream=useRef(null),receipt=useRef(null),layout=useRef({width:1,height:1}),local=useRef(null),safe=useRef(true);
  const actionPending=useRef(false);
  const controller=useRef('viewer-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2));
  const [now,setNow]=useState(()=>Date.now()/1000);
  const taskStatus=browserTaskStatus(task.id===id?task:{},Math.max(now,Date.now()/1000));
  const owned=control.mode==='user'&&control.controller===controller.current;
  local.current={id,control,owned,open,connection,age,requestBrowser,onChanged};
  const disconnect=()=>{stopStream.current?.();stopStream.current=null;};
  const connect=()=>{
    disconnect();setConnection('connecting');
    stopStream.current=openStream(id,event=>{
      if(!alive.current)return;
      const current=local.current;
      if(event.control){
        if(event.control.instance===current.control.instance&&event.control.generation<current.control.generation)return;
        if(event.control.instance!==current.control.instance){sequence.current=0;setFrame(null);}
        if(event.control.instance!==current.control.instance||event.control.generation!==current.control.generation){epoch.current++;input.current='';keyboard.current?.clear();}
        sequence.current=Math.max(sequence.current,event.control.sequence||0);
        setControl(event.control);
      }
      if(event.frame?.image)setFrame(previous=>event.frame.capture_id!==previous?.capture_id||event.frame.sequence>=(previous?.sequence||0)?event.frame:previous);
      receipt.current={at:Date.now(),age:Math.max(0,(event.server_time-(event.observed_at||0))*1000)};
      setAge(receipt.current.age);
      if(event.control?.revoked||event.control?.mode==='stopped')setFrame(null);
      if(event.control?.mode==='stopped'){disconnect();setConnection('stopped');local.current.onChanged?.();}
    },state=>{if(alive.current)setConnection(state);});
  };
  useEffect(()=>{
    if(!open)return;
    alive.current=true;connect();
    const app=AppState.addEventListener('change',state=>{
      if(state==='active')connect();else{disconnect();epoch.current++;input.current='';keyboard.current?.clear();setConnection('background');}
    });
    const timer=setInterval(()=>{setAge(receipt.current?receipt.current.age+Date.now()-receipt.current.at:Infinity);setNow(Date.now()/1000);},500);
    return()=>{alive.current=false;disconnect();clearInterval(timer);clearTimeout(flushTimer.current);epoch.current++;input.current='';keyboard.current?.clear();};
  },[open,id]);
  const canInput=owned&&connection==='connected'&&age<5000&&safe.current;
  const send=event=>{
    const current=local.current,observed=epoch.current;
    if(!current.owned||!safe.current||current.connection!=='connected'||current.age>=5000)return;
    const generation=current.control.generation;
    chain.current=chain.current.catch(()=>{}).then(async()=>{
      if(!alive.current||epoch.current!==observed||!safe.current)return;
      const result=await current.requestBrowser('agent_browser',{id:current.id,event:{...event,generation,instance:current.control.instance,controller:controller.current,sequence:++sequence.current}});
      if(!alive.current||epoch.current!==observed)return;
      if(result.error)throw new Error(result.error);
      if(result.image)setFrame(previous=>result.capture_id!==previous?.capture_id||result.sequence>=(previous?.sequence||0)?result:previous);setError('');
    }).catch(e=>{if(alive.current&&epoch.current===observed){safe.current=false;setError('Input was not confirmed. Take control again before continuing.');setConnection('unconfirmed');input.current='';keyboard.current?.clear();}});
    return chain.current;
  };
  const flush=()=>{clearTimeout(flushTimer.current);const text=input.current;input.current='';keyboard.current?.clear();if(text)send({type:'text',text});};
  const action=async name=>{
    if(actionPending.current)return;
    actionPending.current=true;setBusy(true);setPendingAction(name);setError('');
    try {
      if(name==='resume'){flush();await chain.current;if(!safe.current)throw new Error('Reconnect to confirm your last input before resuming.');}
      else {epoch.current++;input.current='';keyboard.current?.clear();}
      const result=await requestBrowser('agent_browser_control',{id,action:name,generation:local.current.control.generation,instance:local.current.control.instance,controller:controller.current});
      if(result.error)throw new Error(result.error);
      if(result.control){setControl(result.control);sequence.current=result.control.sequence||0;if(name==='take')safe.current=true;}
      if(name!=='stop'||result.control?.mode==='stopped')onChanged?.();
      if(name==='stop'&&!result.control)setConnection('stopping');
    }catch(e){setError(e.message||'Control could not be confirmed. Reconnect before continuing.');}
    finally{actionPending.current=false;setBusy(false);setPendingAction('');}
  };
  const point=(x,y)=>{
    const value=frame;if(!value)return null;
    const scale=Math.min(layout.current.width/value.width,layout.current.height/value.height);
    const px=(x-(layout.current.width-value.width*scale)/2)/scale,py=(y-(layout.current.height-value.height*scale)/2)/scale;
    return px>=0&&py>=0&&px<value.width&&py<value.height?{x:px,y:py}:null;
  };
  const gesture=useRef({x:0,y:0});
  const responder=PanResponder.create({
    onStartShouldSetPanResponder:()=>canInput,
    onMoveShouldSetPanResponder:()=>canInput,
    onPanResponderGrant:e=>{gesture.current={x:e.nativeEvent.locationX,y:e.nativeEvent.locationY};},
    onPanResponderRelease:(e,g)=>{
      if(!canInput)return;flush();
      if(Math.abs(g.dy)>12||Math.abs(g.dx)>12){send({type:'scroll',dy:-g.dy*2});}
      else{const p=point(gesture.current.x,gesture.current.y);if(p){send({type:'click',...p});keyboard.current?.focus();}}
    },onPanResponderTerminationRequest:()=>false,
  });
  const button=(label,handler,disabled=false,danger=false,processing=false)=>React.createElement(Pressable,{accessibilityRole:'button',accessibilityLabel:label,accessibilityState:{disabled,busy:processing},onPress:handler,disabled,style:{paddingVertical:13,paddingHorizontal:18,borderRadius:24,backgroundColor:disabled?'#E5E7EB':danger?'#FEE2E2':'#111827'}},React.createElement(Text,{style:{color:disabled?'#6B7280':danger?'#B91C1C':'white',fontWeight:'600'}},label));
  const pendingLabel={take:'Taking control…',resume:'Resuming agent…',stop:'Stopping task…'}[pendingAction];
  const status=pendingLabel|| (control.mode==='pausing'?'Pausing agent…':control.mode==='stopping'?'Stopping task…':control.mode==='stopped'?'Task stopped':connection==='unavailable'?'Browser unavailable':connection==='unconfirmed'||!safe.current?'Input unconfirmed':connection!=='connected'?'Reconnecting…':age>=5000?'Waiting for a fresh view…':owned?'You have control':control.mode==='user'?'Another viewer has control':'Agent has browser control');
  return React.createElement(View,{style:{gap:10}},
    button('Open browser',()=>setOpen(true)),
    React.createElement(Modal,{visible:open,animationType:'slide',presentationStyle:'fullScreen',onRequestClose:()=>setOpen(false)},
      React.createElement(View,{style:{flex:1,backgroundColor:'#F9FAFB',paddingTop:54,paddingBottom:28,paddingHorizontal:16,gap:12}},
        React.createElement(View,{style:{flexDirection:'row',alignItems:'center',justifyContent:'space-between'}},React.createElement(Text,{style:{fontSize:18,fontWeight:'700',color:'#111827'}},'Browser'),button('Close',()=>setOpen(false))),
        React.createElement(Text,{accessibilityLiveRegion:'polite',style:{color:'#4B5563'}},status),
        React.createElement(View,{accessibilityLiveRegion:'polite',style:{gap:4}},
          React.createElement(Text,{accessibilityLabel:'Task status',style:{color:'#111827',fontWeight:'600'}},taskStatus.label),
          taskStatus.stage?React.createElement(Text,{style:{color:'#4B5563'}},taskStatus.stage):null,
          taskStatus.message?React.createElement(Text,{style:{color:'#4B5563'}},taskStatus.message):null,
          taskStatus.explanation&&taskStatus.explanation!==taskStatus.message?React.createElement(Text,{style:{color:'#6B7280',fontSize:12}},taskStatus.explanation):null,
          frame?.progress?React.createElement(Text,{accessibilityLabel:'Browser progress',style:{color:'#6B7280',fontSize:12}},(task.status==='running'&&connection==='connected'&&age<5000?'Browser progress: ':'Last browser progress: ')+frame.progress):null),
        frame?.url?React.createElement(Text,{numberOfLines:1,style:{color:'#6B7280',fontSize:12}},frame.url):null,
        React.createElement(View,{...responder.panHandlers,onLayout:e=>{layout.current=e.nativeEvent.layout;},accessibilityLabel:'Live remote browser',style:{flex:1,minHeight:240,backgroundColor:'white',borderRadius:16,overflow:'hidden',borderWidth:1,borderColor:'#E5E7EB'}},
          frame?.image?React.createElement(Image,{source:{uri:'data:image/jpeg;base64,'+frame.image},resizeMode:'contain',style:{width:'100%',height:'100%',opacity:connection==='connected'&&age<5000?1:.55}}):React.createElement(Text,{style:{padding:24,color:'#6B7280'}},'Opening the task’s browser…')),
        error?React.createElement(Text,{accessibilityRole:'alert',style:{color:'#B91C1C'}},error):null,
        owned?React.createElement(Text,{style:{color:'#6B7280',fontSize:12}},'Tap a field to type. Swipe the page to scroll. Closing this view leaves the agent paused.'):null,
        React.createElement(TextInput,{ref:keyboard,accessibilityLabel:'Remote browser keyboard',editable:canInput,secureTextEntry:true,maxLength:8000,autoCapitalize:'none',autoCorrect:false,autoComplete:'off',textContentType:'none',style:{position:'absolute',width:1,height:1,opacity:0,bottom:90,left:16},
          onChangeText:text=>{input.current=text;clearTimeout(flushTimer.current);flushTimer.current=setTimeout(flush,100);},
          onKeyPress:e=>{if(e.nativeEvent.key==='Backspace'){if(input.current)input.current=input.current.slice(0,-1);else send({type:'key',key:'Backspace'});}},onSubmitEditing:()=>{flush();send({type:'key',key:'Enter'});}}),
        owned?React.createElement(View,{style:{flexDirection:'row',gap:8}},button('Keyboard',()=>keyboard.current?.focus(),!canInput),button('Tab',()=>{flush();send({type:'key',key:'Tab'});},!canInput),button('Enter',()=>{flush();send({type:'key',key:'Enter'});},!canInput)):null,
        React.createElement(View,{style:{flexDirection:'row',justifyContent:'center',gap:10}},
          owned&&safe.current?button(pendingAction==='resume'?'Resuming agent…':'Resume agent',()=>action('resume'),busy||connection!=='connected'||!safe.current,false,pendingAction==='resume'):button(pendingAction==='take'?'Taking control…':'Take control',()=>action('take'),busy||connection!=='connected'||!['agent','user'].includes(control.mode),false,pendingAction==='take'),
          button(pendingAction==='stop'?'Stopping task…':'Stop task',()=>action('stop'),busy||['stopping','stopped'].includes(control.mode),true,pendingAction==='stop')),
        !['connected','stopped'].includes(connection)||age>=5000?button('Reconnect',()=>{epoch.current++;input.current='';keyboard.current?.clear();connect();},busy):null)));
}
