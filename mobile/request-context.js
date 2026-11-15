import {Platform} from 'react-native';
import Constants from 'expo-constants';

export const expoContext = {
  platform: 'expo-' + Platform.OS,
  device: Platform.constants?.Model ?? Platform.constants?.interfaceIdiom ?? Platform.OS,
  os: Platform.OS + ' ' + (Platform.constants?.osVersion ?? Platform.constants?.Release ?? Platform.Version),
  version: Constants.expoConfig?.version,
  build: Constants.nativeBuildVersion ?? Constants.expoConfig?.ios?.buildNumber
    ?? Constants.expoConfig?.android?.versionCode ?? 'development',
};
