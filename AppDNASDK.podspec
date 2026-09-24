Pod::Spec.new do |s|
  s.name             = 'AppDNASDK'
  s.version          = '1.0.80'
  s.summary          = 'AppDNA iOS SDK — analytics, experiments, paywalls, onboarding, billing, push, and more.'
  s.description      = <<-DESC
Native iOS SDK for AppDNA providing analytics, remote configuration, feature flags,
experiments, paywalls, onboarding flows, surveys, web entitlements, and deferred deep links.
                       DESC
  s.homepage         = 'https://appdna.ai'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'AppDNA' => 'hello@appdna.ai' }
  s.source           = { :git => 'https://github.com/appdna-ai-inc/appdna-sdk-ios.git', :tag => "v#{s.version}" }
  s.source_files     = 'Sources/AppDNASDK/**/*.swift'
  s.resource_bundles = { 'AppDNASDK' => ['Sources/AppDNASDK/PrivacyInfo.xcprivacy'] }
  s.platform         = :ios, '16.0'
  s.swift_version    = '5.9'

  s.dependency 'KeychainAccess', '~> 4.2'
  s.dependency 'FirebaseFirestore', '>= 11.0', '< 13.0'

  s.frameworks = 'UIKit', 'StoreKit', 'Foundation'
end
