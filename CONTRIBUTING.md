# Contributing

## Build from source

```bash
swift build && swift test     # build + tests (68 tests)
./bundle.sh                   # local .app (self-signed dev identity)
```

Create a one-time `LeaveMyMacAlone Dev` code-signing certificate (`bundle.sh` finds
it automatically) and the Accessibility grant survives rebuilds.

## How it works

- **Unlock:** LocalAuthentication (Touch ID or password).
- **Input blocking:** a CoreGraphics event tap (needs the Accessibility permission).
- **Staying awake:** IOKit power assertions.
- **Updates:** [Sparkle](https://sparkle-project.org), EdDSA-signed.

The app is non-sandboxed, so it ships as a Developer ID–signed, notarized download
rather than through the Mac App Store.
