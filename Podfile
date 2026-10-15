platform :ios, '12.0'

target 'Oxy Feed' do
  # Comment this line if you're not using Swift and don't want to use dynamic frameworks
  use_frameworks!

  swift_version = '4.0'

  # Pods for MessageGroups
  pod 'Texture', :path => 'Components/Texture'
  pod 'NMessenger', :path => 'Components/nMessenger'
  #pod 'Chatto', :path => 'Components/Chatto'
  #pod 'ChattoAdditions', :path => 'Components/Chatto'
  pod 'LoremIpsum', '= 1.0.0'
  pod 'MWPhotoBrowser', :path => 'Components/MWPhotoBrowser'
  pod 'DOCheckboxControl'
  pod 'SDCAlertView', :path => 'Components/SDCAlertView'
  pod 'TTTAttributedLabel', :path => 'Components/TTTAttributedLabel'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '12.0'
      config.build_settings['SWIFT_VERSION'] = '4.0'
      config.build_settings['OTHER_CFLAGS'] = '$(inherited) -Wno-incompatible-block-pointer-types -Wno-incompatible-function-pointer-types'
    end
  end
end
