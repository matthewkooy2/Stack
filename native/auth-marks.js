// Provider artwork follows Google Identity and Apple's sign-in design resources.
// https://developers.google.com/identity/branding-guidelines
// https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple
import React from 'react';
import Svg, {Path} from 'react-native-svg';
import {Icon} from './device.js';

export function AuthMark({provider, size=20}) {
  if (provider === 'stack') return React.createElement(Icon, {name:'layers', size, color:'#111111'});
  if (provider === 'apple') return React.createElement(Svg, {width:size, height:size, viewBox:'0 0 24 24', accessibilityElementsHidden:true},
    React.createElement(Path, {fill:'#111111', d:'M17.05 12.54c.03 3.16 2.77 4.21 2.8 4.23-.02.07-.44 1.5-1.45 2.99-.88 1.29-1.79 2.58-3.23 2.61-1.41.03-1.86-.84-3.48-.84-1.61 0-2.12.81-3.45.87-1.38.05-2.43-1.4-3.32-2.68-1.81-2.63-3.19-7.43-1.33-10.67.92-1.61 2.57-2.63 4.36-2.65 1.36-.03 2.65.92 3.48.92.83 0 2.39-1.14 4.03-.97.69.03 2.63.28 3.88 2.12-.1.06-2.32 1.35-2.29 4.07zM14.39 4.6c.74-.9 1.24-2.15 1.11-3.39-1.07.04-2.37.71-3.14 1.61-.69.8-1.29 2.08-1.13 3.3 1.19.09 2.41-.61 3.16-1.52z'}));
  return React.createElement(Svg, {width:size, height:size, viewBox:'0 0 48 48', accessibilityElementsHidden:true},
    React.createElement(Path, {fill:'#4285F4',d:'M43.61 24.46c0-1.36-.12-2.66-.35-3.92H24v7.43h11c-.47 2.4-1.91 4.43-4.08 5.8v4.82h6.6c3.86-3.56 6.09-8.81 6.09-14.13z'}),
    React.createElement(Path, {fill:'#34A853',d:'M24 44c5.5 0 10.11-1.82 13.48-4.94l-6.6-5.1c-1.83 1.23-4.17 1.97-6.88 1.97-5.31 0-9.81-3.59-11.42-8.43H5.76v5.26C9.11 39.42 16.02 44 24 44z'}),
    React.createElement(Path, {fill:'#FBBC05',d:'M12.58 27.5A12 12 0 0 1 12 24c0-1.21.2-2.38.58-3.5v-5.26H5.76A19.92 19.92 0 0 0 4 24c0 3.23.77 6.29 2.14 8.99l6.44-5.49z'}),
    React.createElement(Path, {fill:'#EA4335',d:'M24 12.07c3 0 5.69 1.03 7.81 3.05l5.86-5.86C34.1 5.93 29.5 4 24 4 16.02 4 9.11 8.58 5.76 15.24l6.82 5.26c1.61-4.84 6.11-8.43 11.42-8.43z'}));
}

// Franklin's auth adapter owns provider sessions; this screen only initiates it.
export async function authenticateSocial(provider) {
  const adapter = await import('./device.js');
  const authenticateProvider = adapter['authenticateProvider'];
  if (typeof authenticateProvider !== 'function') {
    throw new Error(`${provider === 'apple' ? 'Apple' : 'Google'} sign-in isn't available yet. Please continue with Stack.`);
  }
  return authenticateProvider(provider);
}
