// Native Jac OAuthSession creates server-side PKCE and a one-time poll secret.
// No Google token or Stack JWT passes through Safari or a deep-link URL.
const pendingKey='stack.google.pending.v1';
let attempt=0;
export function googleURL(value){
  const url=new URL(value);
  if(url.protocol!=='https:'||url.hostname!=='accounts.google.com'||url.pathname!=='/o/oauth2/v2/auth'||url.username||url.password||url.port)throw new Error('Google sign-in URL is invalid.');
  if((url.searchParams.get('scope')||'').split(' ').sort().join(' ')!=='email openid profile'||url.searchParams.getAll('scope').length!==1||url.searchParams.get('code_challenge_method')!=='S256')throw new Error('Google sign-in permissions are invalid.');
  return url.href;
}
export async function cancelGoogle(store){attempt++;await store.deleteItemAsync(pendingKey);}
export async function pendingGoogle(store){
  try{return JSON.parse(await store.getItemAsync(pendingKey)||'null');}catch{return null;}
}
export async function beginGoogle(request,store,openURL,invite='',link=false){
  const observed=++attempt;
  // In native mode Jac generates the actual verifier/challenge on the server.
  const result=await request('/sso/google/begin',{challenge:'A'.repeat(43),mode:'native'},link);
  if(observed!==attempt)throw new Error('Google sign-in was cancelled.');
  if(!result?.ok||!result.poll)throw new Error('Google sign-in is unavailable.');
  const url=googleURL(result.url);
  const pending={poll:result.poll,invite,link,at:Date.now()};
  await store.setItemAsync(pendingKey,JSON.stringify(pending));
  if(observed!==attempt){await store.deleteItemAsync(pendingKey);throw new Error('Google sign-in was cancelled.');}
  try{await openURL(url);}catch{await store.deleteItemAsync(pendingKey);throw new Error('Could not open Google sign-in.');}
  if(observed!==attempt){await store.deleteItemAsync(pendingKey);throw new Error('Google sign-in was cancelled.');}
  return pending;
}
export async function waitGoogle(request,store,pending,isActive=()=>true,delay=ms=>new Promise(resolve=>setTimeout(resolve,ms))){
  const observed=attempt;
  while(Date.now()-pending.at<600000){
    if(observed!==attempt)throw new Error('Google sign-in was cancelled.');
    if(isActive()){
      const result=await request('/sso/google/poll',{poll:pending.poll},false);
      if(observed!==attempt)throw new Error('Google sign-in was cancelled.');
      if(result?.ok&&result.token){await store.deleteItemAsync(pendingKey);return {...result,invite:pending.invite,linked:pending.link};}
      if(result?.error){await store.deleteItemAsync(pendingKey);throw new Error('Google sign-in was cancelled or could not finish. Try again.');}
    }
    await delay(2500);
  }
  await store.deleteItemAsync(pendingKey);
  throw new Error('Google sign-in expired. Please try again.');
}
