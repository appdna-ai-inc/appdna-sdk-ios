Pod::Spec.new do |s|
  s.name             = 'AppDNANotificationExtension'
  s.version          = '1.0.83'
  s.summary          = 'AppDNA Notification Service Extension helper — push images and action buttons.'
  s.description      = <<-DESC
The extension-safe part of the AppDNA iOS SDK for a Notification Service Extension target: downloads a
push's image and registers its action-button category before the notification is shown. No
dependencies and application-extension-only API, so it links into the extension on its own.
                       DESC
  s.homepage         = 'https://appdna.ai'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'AppDNA' => 'hello@appdna.ai' }
  s.source           = { :git => 'https://github.com/appdna-ai-inc/appdna-sdk-ios.git', :tag => "v#{s.version}" }
  s.source_files     = ['Sources/AppDNANotificationExtension/**/*.swift']
  # The extension links only this pod, so it ships this pod's privacy manifest (UserDefaults, CA92.1).
  s.resource_bundles = { 'AppDNANotificationExtension' => ['Sources/AppDNANotificationExtension/PrivacyInfo.xcprivacy'] }
  s.platform         = :ios, '16.0'
  s.swift_version    = '5.9'
  s.frameworks       = 'UIKit', 'UserNotifications', 'Foundation'
  s.pod_target_xcconfig = { 'APPLICATION_EXTENSION_API_ONLY' => 'YES' }
end
