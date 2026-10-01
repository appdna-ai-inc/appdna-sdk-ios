Pod::Spec.new do |s|
  s.name             = 'AppDNASDK'
  s.version          = '1.0.82'
  s.summary          = 'AppDNA iOS SDK — analytics, experiments, paywalls, onboarding, billing, push, and more.'
  s.description      = <<-DESC
Native iOS SDK for AppDNA providing analytics, remote configuration, feature flags,
experiments, paywalls, onboarding flows, surveys, web entitlements, and deferred deep links.
                       DESC
  s.homepage         = 'https://appdna.ai'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'AppDNA' => 'hello@appdna.ai' }
  s.source           = { :git => 'https://github.com/appdna-ai-inc/appdna-sdk-ios.git', :tag => "v#{s.version}" }
  # SPEC-497 B6 — the ObjC launch hook that installs the notification proxy. A `.m` with no public
  # header, so nothing in it reaches the module's umbrella header. This file and
  # Sources/AppDNASDK/AppDNASDK.podspec must stay byte-identical (check:native-pins).
  # Sources/AppDNANotificationExtension is the extension-safe Notification Service Extension helper; it is
  # also published alone as the AppDNANotificationExtension pod (AppDNANotificationExtension.podspec) for the
  # extension target. Compiled into this module here, so the app registers push button categories
  # through the same code as the extension.
  s.source_files     = ['Sources/AppDNASDK/**/*.swift', 'Sources/AppDNANotificationExtension/**/*.swift', 'Sources/AppDNASDKLoader/**/*.m']
  s.resource_bundles = { 'AppDNASDK' => ['Sources/AppDNASDK/PrivacyInfo.xcprivacy'] }
  s.platform         = :ios, '16.0'
  s.swift_version    = '5.9'

  s.dependency 'KeychainAccess', '~> 4.2'
  s.dependency 'FirebaseFirestore', '>= 11.0', '< 13.0'

  # SPEC-495 — the bundled interactive map tier. 🔴 THE PODSPEC NEEDS THIS TOO, AND FORGETTING IT IS
  # NOT A SUBTLE FAILURE: the React Native example host consumes AppDNASDK through CocoaPods, so
  # `import GoogleMaps` in MapInteractive.swift failed there with "no such module" while the SwiftPM
  # build was perfectly green. Same version line as Package.swift on purpose — CocoaPods publishes
  # GoogleMaps only up to 9.4.0, so 9.4 is the highest both channels can share.
  s.dependency 'GoogleMaps', '~> 9.4'

  # SPEC-495 — 🔴 STATIC, and this is the line that actually fixes the link.
  #
  # GoogleMaps ships as a STATIC xcframework. Under `use_frameworks!` (dynamic) — which every RN and
  # Flutter host ends up on, because Firebase is not optional here — CocoaPods builds this pod as a
  # DYNAMIC framework, and a dynamic framework has to resolve its own symbols at its own link step.
  # CocoaPods will not link a static dependency into it. So the build failed here, every time:
  #
  #     Undefined symbols for architecture arm64
  #     > Symbol: _OBJC_CLASS_$_GMSCameraPosition
  #     > Referenced from: in MapInteractive.o
  #
  # `MapInteractive.o` is the tell, and I read past it twice: the step that fails is THIS POD'S link,
  # not the app's, so naming GoogleMaps in the app target could never have fixed it. Declaring the
  # pod static removes that link step entirely — the objects go into the app, which links GoogleMaps
  # alongside them. It is the same mechanism every Firebase pod uses, and for the same reason.
  s.static_framework = true

  s.frameworks = 'UIKit', 'StoreKit', 'Foundation'
end
