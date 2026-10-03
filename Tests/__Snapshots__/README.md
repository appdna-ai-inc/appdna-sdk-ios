# iOS Visual Goldens

Committed PNG snapshots produced by `pointfreeco/swift-snapshot-testing` and reviewed during PR.

## What lives here

Snapshot files written by `assertSnapshot(of: view, as: .image)` calls inside iOS XCTest cases that exercise rendered SwiftUI surfaces. Each PNG is the reference output a renderer must match; PR diff tools render them inline so reviewers see pixel changes during code review.

## When to add a golden

Add a new committed snapshot in the **same PR** that introduces or modifies a renderer surface. The initial set is 12 surfaces:

1. Paywall hero (light)
2. Paywall hero (dark)
3. Onboarding welcome step
4. Onboarding form step (text + select inputs)
5. Survey single-choice
6. Survey CSAT (1–5 scale)
7. In-app message — banner
8. In-app message — modal
9. In-app message — fullscreen
10. In-app message — tooltip
11. Push notification preview
12. Paywall plan-select pressed state (also covers error banner via shared chrome)

## How to (re)record

```bash
cd packages/appdna-sdk-ios
# Re-record all goldens in a target test class:
xcodebuild test \
  -scheme AppDNASDK-Package \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -only-testing:AppDNASDKTests/VisualSnapshotTests \
  RECORD_SNAPSHOTS=YES
```

Then `git add Tests/__Snapshots__/` and commit. Reviewer eyes-on the PNG diff in the PR. CI re-runs the same test class without `RECORD_SNAPSHOTS` and fails on byte-level deltas.

## CI

Runs in `.github/workflows/sdk-visual-regression.yml` (job `ios-visual`). Currently gated `if: ${{ false }}` until the first batch of goldens lands.
