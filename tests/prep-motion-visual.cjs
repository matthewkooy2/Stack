// Browser QA of the compiled Prep flow (react-native-web preview on 127.0.0.1:8128, synthetic data).
// Samples effective opacity/offset during transitions to prove motion actually runs, checks press feedback and
// reduce-motion, walks the whole flow, and saves screenshots under the SSD build-artifact folder.
// Needs the preview bundle (`node .jac/build-prep-preview.cjs`, defining `global` for react-native-web) and
// `python3 tests/preview_server.py` running.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const out=process.env.PREP_QA_OUT||path.resolve(__dirname,'../.jac/prep-motion-qa');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||path.resolve(__dirname,'../.jac/mobui-tools/node_modules/playwright'));
fs.mkdirSync(out,{recursive:true});
const wait=ms=>new Promise(r=>setTimeout(r,ms));
// Product of ancestor opacities and sum of ancestor x-translations for the element whose own text is `text`.
const effective=(page,text)=>page.evaluate(t=>{
  const el=[...document.querySelectorAll('div,span')].find(e=>e.textContent===t&&e.children.length===0);if(!el)return null;
  let o=1,x=0;for(let n=el;n&&n!==document.body;n=n.parentElement){const cs=getComputedStyle(n);o*=parseFloat(cs.opacity);x+=new DOMMatrix(cs.transform==='none'?undefined:cs.transform).m41;}
  return {o:+o.toFixed(3),x:+x.toFixed(1)};},text);
// Per-frame recorder (requestAnimationFrame), started before the interaction so the first painted frame is captured.
const startTrace=(page,texts)=>page.evaluate(list=>{
  const trace=window.__trace={};const t0=performance.now();for(const t of list)trace[t]=[];
  (function frame(){
    for(const t of list){const el=[...document.querySelectorAll('div,span')].find(e=>e.textContent===t&&e.children.length===0);
      if(el){let o=1,x=0;for(let n=el;n&&n!==document.body;n=n.parentElement){const cs=getComputedStyle(n);o*=parseFloat(cs.opacity);x+=new DOMMatrix(cs.transform==='none'?undefined:cs.transform).m41;}trace[t].push({t:performance.now()-t0,o:+o.toFixed(3),x:+x.toFixed(1)});}}
    if(performance.now()-t0<4000)requestAnimationFrame(frame);
  })();},texts);
const readTrace=(page,text)=>page.evaluate(t=>window.__trace[t],text);
const reachedAt=(frames,level)=>frames.find(f=>f.o>=level)?.t;
const scaleOf=(page,label)=>page.evaluate(l=>{const el=document.querySelector('[aria-label="'+l+'"]');return el?+new DOMMatrix(getComputedStyle(el).transform==='none'?undefined:getComputedStyle(el).transform).a.toFixed(3):null;},label);
const shot=(page,name)=>page.locator('#root').screenshot({path:path.join(out,name+'.png')});
async function session(browser,reducedMotion){
  const context=await browser.newContext({viewport:{width:430,height:910},deviceScaleFactor:1,reducedMotion:reducedMotion?'reduce':'no-preference'});
  const page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error'&&!/microphone|getUserMedia|Failed to load resource/i.test(m.text()))errors.push(m.text());});
  await page.goto('http://127.0.0.1:8128');return {page,errors,context};
}
const button=(page,name)=>page.getByRole('button',{name,exact:true});
async function run(){
  const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  try{await walk(browser);}finally{await browser.close();}
}
async function walk(browser){
  // ── Motion on ────────────────────────────────────────────────────────────────
  let {page,errors,context}=await session(browser,false);
  await button(page,'New session').waitFor();await wait(900);
  assert.equal((await effective(page,'Prep')).o,1,'home settles fully visible');
  // Press feedback: shrink while held, restore when released off the control.
  await startTrace(page,['Choose your session type']);
  await button(page,'New session').click();await page.getByText('Choose your session type').waitFor();
  await shot(page,'01-type-entering');await wait(700);
  const enter=await readTrace(page,'Choose your session type'),opening=enter[0],settled=enter.at(-1);
  assert(enter.length>=6,'the step is animated over several frames, not snapped: '+enter.length);
  assert(opening.o<0.7&&opening.x>6,'forward step starts faded and offset to the right: '+JSON.stringify(opening));
  assert.deepEqual({o:settled.o,x:settled.x},{o:1,x:0},'step settles fully visible and in place');
  assert(enter.every((f,i)=>i===0||f.o>=enter[i-1].o-0.001),'opacity only rises while entering');
  const done=enter.find(f=>f.o===1&&f.x===0);assert(done&&done.t-enter[0].t<600,'transition settles briskly: '+(done&&Math.round(done.t-enter[0].t))+'ms');
  console.log('type step: '+enter.length+' frames, settled in '+Math.round(done.t-enter[0].t)+'ms');
  const target=await button(page,'Behavioral').boundingBox();
  await page.mouse.move(target.x+target.width/2,target.y+target.height/2);await page.mouse.down();await wait(250);
  const held=await scaleOf(page,'Behavioral');assert(held<0.995,'held option is pressed in: '+held);
  await page.mouse.move(5,5);await page.mouse.up();await wait(700);
  assert.equal(await scaleOf(page,'Behavioral'),1,'option springs back after release');
  // Staggered list: later rows start later than earlier rows.
  await startTrace(page,['Mixed questions','Setbacks and learning']);
  await button(page,'Behavioral').click();await page.getByText('Choose your focus').waitFor();await wait(130);await shot(page,'02-focus-cascade');await wait(700);
  const firstRow=await readTrace(page,'Mixed questions'),lastRow=await readTrace(page,'Setbacks and learning');
  assert(reachedAt(lastRow,0.5)-reachedAt(firstRow,0.5)>60,'options cascade in order: '+JSON.stringify({first:reachedAt(firstRow,0.5),last:reachedAt(lastRow,0.5)}));
  await button(page,'Mixed questions').click();await page.getByText('Choose your session length').waitFor();await wait(700);await shot(page,'03-length');
  // Back slides the previous step in from the left.
  await startTrace(page,['Choose your focus']);
  await page.getByRole('button',{name:'Back to Prep'}).click();await page.getByText('Choose your focus').waitFor();await wait(700);
  const backEnter=await readTrace(page,'Choose your focus');assert(backEnter[0].x<-6,'backward step starts offset to the left: '+JSON.stringify(backEnter[0]));
  await button(page,'Mixed questions').click();await page.getByText('Choose your session length').waitFor();await wait(700);
  await button(page,'3 questions').click();await button(page,'Type instead').waitFor();await wait(900);await shot(page,'04-question');
  await button(page,'Type instead').click();
  await page.getByRole('textbox',{name:'Your answer'}).fill('I built the dashboard and worked with two teammates on the API. We shipped the project on time.');
  await wait(1100);await shot(page,'05-answer');
  await button(page,'Review your answer').click();await page.getByText('Review your answer',{exact:true}).waitFor();await wait(700);
  await startTrace(page,['What worked','Try next']);
  await button(page,'Get coaching').click();
  await page.getByText('Preparing your coaching').waitFor({timeout:3000}).catch(()=>{});await shot(page,'06-processing');
  await page.getByText('Your coaching',{exact:true}).waitFor({timeout:8000});await wait(150);await shot(page,'07-coaching-entering');await wait(1300);await shot(page,'08-coaching');
  const worked=await readTrace(page,'What worked'),tryNext=await readTrace(page,'Try next');
  assert(reachedAt(tryNext,0.5)-reachedAt(worked,0.5)>15,'coaching sections reveal in order: '+JSON.stringify({worked:reachedAt(worked,0.5),tryNext:reachedAt(tryNext,0.5)}));
  // Finish through the remaining questions so the completion step and the weekly mark are exercised.
  for(let i=0;i<2;i++){
    await button(page,'Next question').click();await button(page,'Type instead').waitFor();await wait(500);
    await button(page,'Type instead').click();await page.getByRole('textbox',{name:'Your answer'}).fill('Another answer about ownership number '+i+'. I changed my mind after the data.');await wait(1100);
    await button(page,'Review your answer').click();await button(page,'Get coaching').waitFor();await wait(300);await button(page,'Get coaching').click();await page.getByText('Your coaching',{exact:true}).waitFor({timeout:8000});await wait(900);
  }
  await button(page,'Finish session').click();await page.getByText('Session complete').waitFor();await wait(800);await shot(page,'09-complete');
  await button(page,'Back to Prep').last().click();await page.getByText(/practice days? this week/).waitFor();await wait(1500);await shot(page,'10-home-after-practice');
  assert.match(await page.locator('#root').innerText(),/1 practice day this week/);
  assert.deepEqual(errors,[],'no browser runtime errors with motion on');
  await context.close();
  // ── Reduce motion ────────────────────────────────────────────────────────────
  ({page,errors,context}=await session(browser,true));
  await button(page,'New session').waitFor();await wait(300);
  await startTrace(page,['Choose your session type','Technical']);
  await button(page,'New session').click();await page.getByText('Choose your session type').waitFor();await wait(600);
  const calm=await readTrace(page,'Choose your session type'),calmOption=await readTrace(page,'Technical');
  assert.deepEqual({o:calm[0].o,x:calm[0].x},{o:1,x:0},'reduce motion shows the step immediately: '+JSON.stringify(calm[0]));
  assert.equal(calmOption[0].o,1,'reduce motion skips the cascade');
  assert.deepEqual(errors,[],'no browser runtime errors with reduce motion');
  await context.close();
  console.log('PASS Prep motion visual: eased forward/back steps, option cascade, press-in and release, coaching reveal, completion and weekly mark, reduce-motion, no runtime errors. Screenshots in '+out);
}
run().catch(e=>{console.error(e);process.exitCode=1;});
