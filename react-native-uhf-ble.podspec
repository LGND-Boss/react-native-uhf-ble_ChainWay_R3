require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-uhf-ble"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.license      = package["license"]
  s.authors      = package["author"]
  s.platforms    = { :ios => "11.0" }
  s.source       = { :git => "", :tag => "#{s.version}" }
  s.source_files = "ios/**/*.{h,m,mm}"
  s.frameworks   = "CoreBluetooth"
  s.dependency   "React-Core"
end
