# Contributing

## Build from source

```bash
swift build && swift test     # build + tests (needs a full Xcode for XCTest)
./bundle.sh                   # local .app (self-signed dev identity)
```

Create a one-time `LeaveMyMacAlone Dev` code-signing certificate (`bundle.sh` finds
it automatically) and the Accessibility grant survives rebuilds.

## How it works

- **Unlock:** inside the shield. Touch ID through `LAAuthenticationView`, the password
  through OpenDirectory. The system auth prompt is avoided on purpose: it runs in another
  process, so the app would lose the foreground and with it every kiosk protection.
- **Input blocking:** a CoreGraphics event tap (needs the Accessibility permission).
- **Staying awake:** IOKit power assertions.
- **Updates:** [Sparkle](https://sparkle-project.org), EdDSA-signed.

The app is non-sandboxed, so it ships as a Developer ID–signed, notarized download
rather than through the Mac App Store.

## End-to-end lock tests

Unit tests can't prove that a lock holds, so `scripts/e2e/run.sh` drives a throwaway copy
on the real screen and tries the known ways around it. Run it from a terminal that has
Accessibility permission. Your screen locks for a few seconds at a time and clears by itself.

```bash
scripts/e2e/run.sh                      # every scenario, debug build
LMMA_E2E_RELEASE=1 scripts/e2e/run.sh   # release build with hardened runtime
```

The `wrong-password` scenario sends one wrong password for your account, which counts as
a failed login. Touch ID and your real password can't be automated: after changing the
unlock flow, unlock once by hand with each.
