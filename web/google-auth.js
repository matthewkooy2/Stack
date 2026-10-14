// Jac's built-in OAuthSession handles Google identity, PKCE and explicit linking.
// Only a short-lived verifier is kept across navigation; JWTs stay in memory.
const pendingKey='stack.google.signin.v1';
const encode=bytes=>btoa(String.fromCharCode(...bytes)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
export function googleURL(value){
  const url=new URL(value);
  if(url.protocol!=='https:'||url.hostname!=='accounts.google.com'||url.pathname!=='/o/oauth2/v2/auth'||url.username||url.password||url.port)throw new Error('Google sign-in URL is invalid.');
  const scopes=(url.searchParams.get('scope')||'').split(' ').sort().join(' ');
  if(scopes!=='email openid profile'||url.searchParams.getAll('scope').length!==1||url.searchParams.get('code_challenge_method')!=='S256')throw new Error('Google sign-in permissions are invalid.');
  return url.href;
}
export async function beginGoogle(request,invite='',link=false){
  const verifier=encode(crypto.getRandomValues(new Uint8Array(48)));
  const challenge=encode(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
  const result=await request('/sso/google/begin',{challenge,mode:'web'},link);
  if(!result?.ok||!result.state)throw new Error('Google sign-in is unavailable. Please try again.');
  const url=googleURL(result.url);
  sessionStorage.setItem(pendingKey,JSON.stringify({verifier,state:result.state,invite,link,at:Date.now()}));
  location.assign(url);
}
export async function finishGoogle(request){
  if(location.pathname!=='/auth/google')return null;
  const params=new URLSearchParams(location.search);
  history.replaceState(null,'','/');
  let pending;
  try{pending=JSON.parse(sessionStorage.getItem(pendingKey)||'null');}catch{}
  sessionStorage.removeItem(pendingKey);
  if(!pending||Date.now()-pending.at>600000||params.getAll('state').length!==1||params.get('state')!==pending.state)throw new Error('Google sign-in expired or belongs to another tab. Start again.');
  // Empty code on denial also consumes the original state; it cannot be replayed.
  const denied=params.get('error');
  if(params.getAll('code').length>1||params.getAll('error').length>1)throw new Error('Google sign-in callback is invalid.');
  const result=await request('/sso/google/finish',{code:denied?'':params.get('code')||'',state:pending.state,verifier:pending.verifier},false);
  if(denied)throw new Error('Google sign-in was cancelled. You can try again.');
  if(!result?.ok||!result.token)throw new Error(result?.error||'Google sign-in could not finish. Please try again.');
  return {token:result.token,invite:pending.invite,linked:pending.link};
}
