Pod::Spec.new do |s|
  s.name             = 'local_biometric'
  s.version          = '1.0.0'
  s.summary          = 'Local Biometric Identity Plugin'
  s.description      = <<-DESC
A robust, efficient, and performant local biometric identity plugin for Flutter.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'local_biometric/Sources/local_biometric/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
