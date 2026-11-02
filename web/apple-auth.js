// Apple's official popup SDK returns an identity proof; Stack verifies it server-side.
// Apple credentials never enter Stack, and no Apple or Stack token is persisted here.
const sdkURL = 'https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js';
let loading, active = false;
export function appleRedirectURI(value) {
 const url = new URL(value);
 if (url.protocol !== 'https:' || !url.hostname.includes('.') || url.hostname === 'localhost'
     || url.hostname.endsWith('.localhost') || /^\d+\.\d+\.\d+\.\d+$/.test(url.hostname)
     || url.hostname.includes(':') || url.username || url.password || url.search || url.hash || url.pathname !== '/auth/apple') {
  throw new Error('Apple sign-in needs a registered HTTPS return URL ending in /auth/apple.');
 }
 return url.href;
}
function loadSDK() {
 if (window.AppleID?.auth) return Promise.resolve(window.AppleID);
 if (!loading) {
  loading = new Promise((resolve, reject) => {
   const script = document.createElement('script');
   const fail = () => { clearTimeout(timer); script.remove(); loading = null; reject(new Error('Apple sign-in could not load. Check your connection and try again.')); };
   const timer = setTimeout(fail, 15000);
   script.src = sdkURL; script.async = true;
   script.onerror = fail;
   script.onload = () => { if (!window.AppleID?.auth) { fail(); return; } clearTimeout(timer); resolve(window.AppleID); };
   document.head.appendChild(script);
  });
 }
 return loading;
}
export async function beginApple(request) {
 if (active) throw new Error('Apple sign-in is already open.');
 active = true;
 try {
  const challenge = (await request('/function/auth_apple_web_begin', {}, false))?.result;
  if (!challenge?.ok || !challenge.state || !challenge.nonce || !challenge.client_id) {
   throw new Error(challenge?.error || 'Apple sign-in is unavailable. Try again.');
  }
  const redirectURI = appleRedirectURI(challenge.redirect_uri);
  const apple = await loadSDK();
  apple.auth.init({clientId: challenge.client_id, redirectURI, state: challenge.state, nonce: challenge.nonce, usePopup: true});
  const response = await apple.auth.signIn();
  const proof = response?.authorization;
  if (proof?.state !== challenge.state || typeof proof?.id_token !== 'string' || !proof.id_token) {
   throw new Error('Apple sign-in did not match this request. Try again.');
  }
  const result = (await request('/function/auth_apple_finish', {state: challenge.state, identity_token: proof.id_token}, false))?.result;
  if (!result?.ok || !result.token) throw new Error(result?.error || 'Apple sign-in could not finish. Try again.');
  return result;
 } catch (error) {
  if (['user_cancelled_authorize', 'popup_closed_by_user'].includes(error?.error)) throw new Error('Apple sign-in was cancelled. You can try again.');
  if (error?.error === 'popup_blocked_by_browser') throw new Error('Allow the Apple sign-in popup, then try again.');
  throw error;
 } finally { active = false; }
}
