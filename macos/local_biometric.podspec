Pod::Spec.new do |s|
  s.name             = 'local_biometric'
  s.version          = '0.0.5'
  s.summary          = 'Local Biometric Identity Plugin'
  s.description      = <<-DESC
A robust, efficient, and performant local biometric identity plugin for Flutter.
                       DESC
  s.homepage         = 'https://github.com/devamitkumartiwari/local_biometric'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Amit Kumar Tiwari' => 'https://hireamit.web.app/' }
  s.source           = { :path => '.' }
  s.source_files = '../ios/local_biometric/Sources/local_biometric/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '6.0'
end
