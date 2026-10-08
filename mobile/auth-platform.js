import {AppState,Linking} from 'react-native';
import * as SecureStore from 'expo-secure-store';
import {createAuthSession} from './auth-session';
import config from './auth-config.json';
export const realAuthEnabled=config.mode==='google-test';
// Live data additionally publishes the signed-in product API; mock data keeps every feature local.
export const liveData=realAuthEnabled&&config.data==='live';
export const authSession=realAuthEnabled?createAuthSession({origin:config.origin,store:SecureStore,openURL:url=>Linking.openURL(url),isActive:()=>AppState.currentState==='active',features:liveData}):null;
