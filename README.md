# AppDNA SDK for iOS

The official iOS SDK for [AppDNA](https://appdna.ai) — the growth console for subscription apps.

> ⚠️ **Proprietary software.** A Commercial Agreement with AppDNA AI, Inc. is required to use this SDK. See [LICENSE](./LICENSE) and [NOTICE.md](./NOTICE.md).
>
> **Migrating from MIT-licensed v1.0.59 or earlier?** See [DEPRECATION_NOTICE.md](./DEPRECATION_NOTICE.md). MIT versions stop receiving server support after **15 May 2026**.

## What it does

AppDNA gives you a single drop-in SDK for the growth surfaces every subscription app needs:

- **Analytics & events** — track user behavior with batched, offline-resilient delivery.
- **Experiments & feature flags** — server-driven A/B tests with deterministic variant assignment.
- **Paywalls** — render console-designed paywall layouts with native StoreKit 2 + RevenueCat / Adapty bridges.
- **Onboarding flows** — multi-step onboarding with form inputs, async hooks, conditional branching, and rich media.
- **Surveys & feedback** — NPS, CSAT, free text, multi-choice with scheduling and frequency caps.
- **In-app messages** — modal, banner, fullscreen messages with audience targeting.
- **Push notifications** — rich content, action buttons, deep links, and delivery analytics.
- **Web entitlements & deep links** — server-validated entitlements and deferred deep linking.

## Requirements

- iOS 16.0+
- Swift 5.9+
- Xcode 15+

## Installation

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/appdna-ai-inc/appdna-sdk-ios.git
```

Set the dependency rule to **Up to Next Major Version** starting from `1.0.63`.

Or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/appdna-ai-inc/appdna-sdk-ios.git", from: "1.0.63")
]
```

### CocoaPods

```ruby
pod 'AppDNASDK', '~> 1.0.66'
```

## Quick start

In your `AppDelegate` or `App` struct:

```swift
import AppDNASDK

AppDNA.configure(apiKey: "YOUR_API_KEY")
```

Track an event:

```swift
AppDNA.track("subscription_viewed", properties: ["plan_id": "premium_monthly"])
```

Identify a user (after sign-in):

```swift
AppDNA.identify(userId: "user-123", traits: ["plan": "premium"])
```

Present a paywall:

```swift
AppDNA.presentPaywall(id: "default") { result in
    switch result {
    case .purchased: print("Purchased")
    case .dismissed: print("Dismissed")
    case .failed(let error): print("Failed: \(error)")
    }
}
```

## Documentation

Full integration guide, configuration reference, and API docs at **[docs.appdna.ai/sdks/ios](https://docs.appdna.ai/sdks/ios/installation)**.

## Support

- Technical questions: [support@appdna.ai](mailto:support@appdna.ai)
- Sales / commercial: [sales@appdna.ai](mailto:sales@appdna.ai)
- Licensing: [legal@appdna.ai](mailto:legal@appdna.ai)

## License

⚠️ **The AppDNA SDK is proprietary software, not open source.** This repository is publicly visible for marketing, evaluation, and reference purposes only.

**You may NOT** download, install, run, modify, or use the SDK without a Commercial Agreement with AppDNA AI, Inc. See [LICENSE](./LICENSE) and [NOTICE.md](./NOTICE.md) for the full terms.

**You MAY** view the source on GitHub and read the documentation at <https://docs.appdna.ai> for evaluation purposes.

To use the SDK in your application, sign up at <https://appdna.ai> (self-serve) or contact <sales@appdna.ai> (enterprise).

**Existing customers**: your Terms of Service or Statement of Work governs your use of the SDK.

**Versions before v1.0.60** were distributed under the MIT License — see [DEPRECATION_NOTICE.md](./DEPRECATION_NOTICE.md) for the migration timeline (deadline: **15 May 2026**).

---

© 2026 AppDNA AI, Inc. All rights reserved. "AppDNA" and the AppDNA logo are trademarks of AppDNA AI, Inc.
