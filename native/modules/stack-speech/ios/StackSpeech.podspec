Pod::Spec.new do |s|
  s.name = 'StackSpeech'
  s.version = '0.1.0'
  s.summary = 'Stack on-device speech and durable microphone capture'
  s.description = s.summary
  s.license = { :type => 'MIT' }
  s.author = 'Stack'
  s.homepage = 'https://github.com/matthewkooy2/Stack'
  s.platforms = { :ios => '16.4' }
  s.swift_version = '5.9'
  s.source = { :git => 'https://github.com/matthewkooy2/Stack.git' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.frameworks = 'Speech', 'AVFoundation'
  s.source_files = '**/*.swift'
end
