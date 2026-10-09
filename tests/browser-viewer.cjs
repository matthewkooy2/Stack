// Shared native viewer under real React, with synthetic OS/network boundaries.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {createRequire}=require('node:module');
const nativeRequire=createRequire(path.resolve('.jac/mobile-rn/package.json'));
const React=nativeRequire('react'),renderer=nativeRequire('react-test-renderer'),babel=nativeRequire('@babel/core');
const {act}=renderer;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
const primitives=new Map();const primitive=name=>{if(!primitives.has(name))primitives.set(name,props=>name==='Modal'&&!props.visible?null:React.createElement(name,props,props.children));return primitives.get(name);};
let listener;const RN=new Proxy({AppState:{addEventListener:(name,fn)=>{listener=fn;return{remove(){}};}},PanResponder:{create:handlers=>({panHandlers:handlers})}},{get:(target,key)=>target[key]||primitive(key)});
const code=babel.transformSync(fs.readFileSync('native/browser-viewer.js','utf8'),{babelrc:false,configFile:false,plugins:[nativeRequire.resolve('@babel/plugin-transform-modules-commonjs')]}).code;
const moduleFixture={exports:{}};vm.runInThisContext('(function(require,module,exports){'+code+'\n})')(name=>name==='react'?React:RN,moduleFixture,moduleFixture.exports);
const {BrowserViewer,createBrowserStream,browserTaskStatus}=moduleFixture.exports;
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));

async function streamTests(){
 const requests=[],states=[],events=[];
 globalThis.XMLHttpRequest=class{constructor(){requests.push(this);this.headers={};this.responseText='';this.status=0;}open(method,url){this.method=method;this.url=url;}setRequestHeader(k,v){this.headers[k]=v;}send(body){this.body=JSON.parse(body);}abort(){this.aborted=true;this.onabort?.();}};
 const close=createBrowserStream({id:'synthetic-run',origin:'https://stack.example.test/',authorization:'Bearer synthetic',isCurrent:()=>true,onEvent:e=>events.push(e),onState:s=>states.push(s)});
 const r=requests[0];assert.equal(r.url,'https://stack.example.test/browser/stream');assert.equal(r.headers.Authorization,'Bearer synthetic');assert.deepEqual(r.body,{id:'synthetic-run'});
 const packet='data: '+JSON.stringify({control:{mode:'agent'},frame:{image:'synthetic'}})+'\n\n';
 r.status=200;r.responseText=packet.slice(0,13);r.onprogress();assert.equal(events.length,0);
 r.responseText=packet;r.onprogress();assert.equal(events.length,1);
 r.onprogress();assert.equal(events.length,1,'duplicate progress does not duplicate frames');
 r.onload();close();await wait(180);assert.equal(requests.length,1,'closing prevents scheduled reconnect');assert.ok(r.aborted);
 const invalid=[];const stop=createBrowserStream({id:'other',origin:'https://stack.example.test',authorization:'Bearer synthetic',isCurrent:()=>true,onEvent:()=>invalid.push(true),onState:s=>states.push(s)});
 requests[1].status=403;requests[1].onload();stop();assert.equal(invalid.length,0);assert.ok(states.includes('unavailable'));
}

async function viewerTests(){
 const requests=[];let receive,state,closed=0,opened=0,failInput=false;
 const initialFrame={image:'synthetic',width:100,height:200,capture_id:'fixture-context',sequence:1,url:'https://application.example.test/form'};
 const now=()=>Date.now()/1000;
 const openStream=(id,onEvent,onState)=>{assert.equal(id,'application-run');opened++;receive=onEvent;state=onState;return()=>closed++;};
 const requestBrowser=async(name,args)=>{
  requests.push({name,args});
  if(name==='agent_browser_control')return{control:{mode:args.action==='take'?'user':args.action==='stop'?'stopping':'agent',generation:args.generation+1,instance:'fixture-worker',controller:args.action==='take'?args.controller:'',sequence:0}};
  if(failInput)throw new Error('Synthetic lost response');
  return {...initialFrame,sequence:requests.length+2};
 };
 let root,task={id:'application-run',status:'needs_input',step_label:'Sign in and read your profile',step_number:1,step_total:2,message:'Sign in, then resume.'};
 const component=()=>React.createElement(BrowserViewer,{id:'application-run',task,requestBrowser,openStream});
 const poll=async next=>{task={...task,...next};await act(async()=>{root.update(component());});};
 await act(async()=>{root=renderer.create(component());});
 const press=label=>root.root.findByProps({accessibilityLabel:label}).props.onPress();
 await act(async()=>{press('Open browser');});assert.equal(opened,1);
 await act(async()=>{state('connected');receive({control:{mode:'agent',generation:0,instance:'fixture-worker',controller:'',sequence:0},server_time:now(),observed_at:now(),frame:initialFrame});});
 const status=()=>root.root.findByProps({accessibilityLabel:'Task status'}).props.children;
 assert.equal(status(),'Your input is needed','agent ownership does not mean the task is running');
 await act(async()=>{await press('Take control');});
 assert.equal(requests[0].args.instance,'fixture-worker');assert.equal(requests[0].args.generation,0);
 let canvas=root.root.findByProps({accessibilityLabel:'Live remote browser'});
 await act(async()=>{canvas.props.onLayout({nativeEvent:{layout:{width:200,height:400}}});canvas.props.onPanResponderGrant({nativeEvent:{locationX:100,locationY:200}});canvas.props.onPanResponderRelease({}, {dx:0,dy:0});await wait(5);});
 assert.deepEqual([requests[1].args.event.x,requests[1].args.event.y],[50,100]);assert.equal(requests[1].args.event.sequence,1);
 await act(async()=>{root.root.findByProps({accessibilityLabel:'Remote browser keyboard'}).props.onChangeText('abc');await wait(130);});
 assert.equal(requests[2].args.event.type,'text');assert.equal(requests[2].args.event.text,'abc');assert.equal(requests[2].args.event.sequence,2);
 await act(async()=>{await press('Resume agent');});assert.equal(requests[3].args.action,'resume');
 await poll({status:'queued',message:'Browser returned to the agent.',retry_at:0});
 assert.equal(status(),'Queued for the agent');
 await poll({status:'running',message:'Working on linkedin_scan'});
 assert.equal(status(),'Agent is working');
 await act(async()=>{receive({control:{mode:'agent',generation:2,instance:'fixture-worker',controller:'',sequence:0},server_time:now(),observed_at:now(),frame:{...initialFrame,sequence:5,progress:'Opening your profile'}});});
 assert.equal(root.root.findByProps({accessibilityLabel:'Browser progress'}).props.children,'Browser progress: Opening your profile');
 const retryAt=now()+30;
 await poll({status:'queued',message:'Browser operation failed. Review the session or resume the task.',retry_at:retryAt});
 assert.match(status(),/^Retrying in (29|30)s$/);
 assert.equal(root.root.findByProps({accessibilityLabel:'Browser progress'}).props.children,'Last browser progress: Opening your profile','cached progress must not look like current work');
 assert.ok(root.root.findAllByType('Text').some(n=>n.props.children===task.message),'polled adapter error is visible in the modal');
 assert.equal(browserTaskStatus(task,retryAt+1).label,'Retry is due; waiting for the agent');
 await act(async()=>{receive({control:{mode:'user',generation:1,instance:'fixture-worker',controller:requests[0].args.controller,sequence:2},server_time:now(),observed_at:now(),frame:{...initialFrame,sequence:1}});});
 assert.equal(root.root.findByProps({accessibilityLabel:'Remote browser keyboard'}).props.editable,false,'late control event cannot restore an old controller');
 await act(async()=>{await press('Take control');});
 failInput=true;
 await act(async()=>{root.root.findByProps({accessibilityLabel:'Remote browser keyboard'}).props.onChangeText('lost');await wait(130);});
 const owner=requests[0].args.controller;
 await act(async()=>{state('connected');receive({control:{mode:'user',generation:3,instance:'fixture-worker',controller:owner,sequence:0},server_time:now(),observed_at:now(),frame:{...initialFrame,sequence:20}});});
 assert.equal(root.root.findByProps({accessibilityLabel:'Remote browser keyboard'}).props.editable,false,'heartbeat must not unlock unconfirmed input');
 assert.equal(root.root.findAllByProps({accessibilityLabel:'Resume agent'}).length,0);
 await act(async()=>{await press('Take control');});failInput=false;
 assert.equal(root.root.findByProps({accessibilityLabel:'Remote browser keyboard'}).props.editable,true,'new generation recovers uncertain input');
 await poll({status:'cancelled',message:'Cancelled',retry_at:0});
 assert.equal(status(),'Task cancelled');
 assert.ok(!status().includes('Retrying'),'cancellation removes retry display');
 await act(async()=>{press('Close');});assert.equal(closed,1);assert.equal(requests.length,7,'closing never stops or resumes a task');
 await act(async()=>{root.unmount();});
}

async function controlFeedbackTests(){
 let root,receive,state,pending;
 const requests=[];
 const openStream=(id,onEvent,onState)=>{
  receive=onEvent;state=onState;return()=>{};
 };
 const requestBrowser=(name,args)=>{
  requests.push({name,args});
  return new Promise((resolve,reject)=>{pending={resolve,reject,args};});
 };
 await act(async()=>{
  root=renderer.create(React.createElement(BrowserViewer,{
   id:'feedback-run',requestBrowser,openStream
  }));
 });
 const button=label=>root.root.findByProps({accessibilityLabel:label});
 await act(async()=>{button('Open browser').props.onPress();});
 await act(async()=>{
  state('connected');
  receive({
   control:{mode:'agent',generation:0,instance:'feedback-worker',sequence:0},
   server_time:Date.now()/1000,observed_at:Date.now()/1000
  });
 });

 const cases=[
  ['take','Take control','Taking control…'],
  ['resume','Resume agent','Resuming agent…'],
  ['stop','Stop task','Stopping task…']
 ];
 for(const [action,label,loading] of cases){
  for(const fail of [true,false]){
   const before=requests.length;
   const handler=button(label).props.onPress;
   let first,duplicate;
   await act(async()=>{
    first=handler();
    duplicate=handler();
   });
   assert.equal(requests.length,before+1,'duplicate taps send one request');
   assert.equal(pending.args.action,action);
   assert.equal(button(loading).props.disabled,true);
   assert.deepEqual(button(loading).props.accessibilityState,{
    disabled:true,busy:true
   });
   assert.ok(root.root.findAllByType('Text').some(
    node=>node.props.children===loading
   ),'pending action is visible');

   await act(async()=>{
    if(fail)pending.reject(new Error('Synthetic control failure'));
    else pending.resolve({control:{
     mode:action==='take'?'user':action==='resume'?'agent':'stopped',
     generation:pending.args.generation+1,
     instance:'feedback-worker',
     controller:action==='take'?pending.args.controller:'',
     sequence:0
    }});
    await Promise.all([first,duplicate]);
   });
   assert.equal(root.root.findAllByProps({
    accessibilityLabel:loading
   }).length,0,'pending label clears after settlement');
   if(fail){
    assert.equal(button(label).props.disabled,false,'failed action can be retried');
    assert.ok(root.root.findAllByType('Text').some(
     node=>node.props.children==='Synthetic control failure'
    ),'failure is visible');
   }else{
    assert.equal(root.root.findAllByProps({
     accessibilityRole:'alert'
    }).length,0,'successful retry clears the error');
   }
  }
 }
 await act(async()=>{root.unmount();});
}

(async()=>{await streamTests();await viewerTests();await controlFeedbackTests();console.log('Native stream and shared viewer tests passed.');})().catch(e=>{console.error(e);process.exitCode=1;});
