# AppDNA iOS host app

The iOS counterpart of `packages/appdna-sdk-android/sample`. It exists so an iOS render change can
be **walked on a device and operated**, which CLAUDE.md Rules 23 and 24 require and which this
platform could not do at all before — every iOS parity claim read "unproven" for want of something
to launch.

## Running it

```bash
# build, install, auto-present a surface and bring back a frame
npx tsx scripts/sdk-host-ios.ts \
  --paywall <id> \
  --base-url https://<your-tunnel> \
  --api-key <sdk key> \
  --shot /tmp/frame.jpg

# or drive it with taps, from inside the simulator
npx tsx scripts/sdk-host-ios.ts --uitest
```

The driver generates the Xcode project with XcodeGen, builds against the LOCAL SDK package (so a
branch build is what runs), installs on the booted simulator and launches with arguments.

## The simulator does have a tap

It has no tap verb exposed to a shell on another machine — no `simctl` verb, no `idb`, `osascript`
blocked — which is what every "iOS unproven" note has been about. A **UI test runs inside the
simulator** and taps, swipes, types and scrolls like a finger. It just needs an application target
to attach to, which is what this is. `AppDNAHostUITests` proves the tap is dispatched and handled.

`-appdnaAutoPresent <surface>` exists for screenshot walks that do not want a test runner in the
way: the app presents the surface itself, a fixed delay after launch, so a shell can screenshot it.

## 🔴 Nothing real is committed here

`packages/appdna-sdk-ios/**` is force-pushed to the PUBLIC SDK mirror. So:

| what | where it comes from |
|---|---|
| the SDK api key | `--api-key`, a launch argument |
| the API base URL | `--base-url`, a build setting into `AppDNABaseURLOverride` |
| the surface ids | `--paywall` / `--onboarding` / `--survey` / `--screen` |
| `GoogleService-Info-AppDNA.plist` | fetched from the Firebase Management API at run time and written into the BUILT `.app` |

The repo carries placeholders (`demo_paywall`, `appdna_sandbox_demo_key`). The Firebase client
config belongs to the project's own `ai.appdna.appdnaSdkExample` iOS app, which exists for this
purpose — never a customer's app id, which would also put this host's installations into their
metrics.

## The generated project is not committed

`AppDNAHost.xcodeproj` is regenerated from `project.yml` on every run. An `.xcodeproj` is a large
machine-written blob that nobody can review in a diff; `project.yml` is sixty lines that anybody
can. The sync deliberately skips any `.xcodeproj` directory for the same reason.
