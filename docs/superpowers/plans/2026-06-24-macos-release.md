# macOS Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make LeaveMyMacAlone shippable as a notarized, directly-distributed `.dmg`: a placeholder app icon, corrected docs/license, and a `release.sh` that signs with Developer ID, builds a DMG, notarizes, and staples.

**Architecture:** Keep the SwiftPM + shell pipeline. A new `release.sh` reuses `bundle.sh`'s `.app` assembly, then re-signs with Developer ID + hardened runtime + secure timestamp, packages a DMG via `hdiutil`, and notarizes with `xcrun notarytool` + `stapler`. The self-signed `bundle.sh` path stays for local dev.

**Tech Stack:** bash, `codesign`, `hdiutil`, `xcrun notarytool`/`stapler`, `sips`/`iconutil`, Swift (icon render), AppKit.

## Global Constraints

- Distribution: direct (outside the App Store); the app is intentionally non-sandboxed (`Resources/LeaveMyMacAlone.entitlements` has `app-sandbox = false`).
- Bundle id: `com.alperenkisi.leavemymacalone`. App name: `LeaveMyMacAlone`. Min macOS: 14.0.
- No new third-party dependencies; macOS built-in tools only.
- `[SEN]` items are OUT OF SCOPE for this plan (done by the user with their Apple credentials): creating the Developer ID Application cert, `notarytool store-credentials`, real icon art, running notarization, clean-Mac testing.
- Notarization steps in `release.sh` only run end-to-end with the user's valid Developer ID + notary profile; this plan verifies only what is possible without them (build, assemble, icon, DMG layout, `bash -n`).

---

### Task 1: Placeholder app icon + Info.plist + bundle integration

**Files:**
- Create: `scripts/make-icon.sh`
- Create (generated): `Resources/AppIcon.icns`
- Modify: `Resources/Info.plist` (add `CFBundleIconFile`, `LSApplicationCategoryType`)
- Modify: `bundle.sh` (copy the icon into the bundle)

**Interfaces:**
- Produces: `Resources/AppIcon.icns`; bundle has `Contents/Resources/AppIcon.icns`; Info.plist references `AppIcon`.

- [ ] **Step 1: Create the icon generator script**

Create `scripts/make-icon.sh`:

```bash
#!/usr/bin/env bash
# Generate a placeholder AppIcon.icns (lock-shield glyph on a dark rounded square).
# Replace Resources/AppIcon.icns with real artwork later; re-run to regenerate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
PNG="${WORK}/icon-1024.png"

# 1) Render a 1024x1024 base PNG with Swift/AppKit.
cat > "${WORK}/render.swift" <<'SWIFT'
import AppKit
let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let inset = s * 0.06
let body = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset),
                        xRadius: s * 0.22, yRadius: s * 0.22)
let grad = NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
                               NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1)])!
grad.draw(in: body, angle: -90)
if let base = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let sym = base.withSymbolConfiguration(cfg) {
        let w = sym.size.width, h = sym.size.height
        sym.draw(in: NSRect(x: (s - w)/2, y: (s - h)/2, width: w, height: h))
    }
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swift "${WORK}/render.swift" "${PNG}"

# 2) Build the iconset (all required sizes) and compile to .icns.
ICONSET="${WORK}/AppIcon.iconset"
mkdir -p "${ICONSET}"
for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz"           "${PNG}" --out "${ICONSET}/icon_${sz}x${sz}.png"     >/dev/null
    sips -z "$((sz*2))" "$((sz*2))" "${PNG}" --out "${ICONSET}/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${ROOT}/Resources/AppIcon.icns"
rm -rf "${WORK}"
echo "Wrote ${ROOT}/Resources/AppIcon.icns"
```

- [ ] **Step 2: Generate the icon**

Run: `chmod +x scripts/make-icon.sh && ./scripts/make-icon.sh`
Expected: `Wrote .../Resources/AppIcon.icns`; `file Resources/AppIcon.icns` reports `Mac OS X icon`.

- [ ] **Step 3: Reference the icon + category in Info.plist**

In `Resources/Info.plist`, add these keys inside the top-level `<dict>` (next to `CFBundleExecutable`):

```xml
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
```

- [ ] **Step 4: Copy the icon into the bundle**

In `bundle.sh`, after the line `cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"`, add:

```bash
# App icon.
cp "${ROOT}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
```

- [ ] **Step 5: Rebuild and verify the icon is embedded**

Run: `./bundle.sh && ls -1 LeaveMyMacAlone.app/Contents/Resources/AppIcon.icns && /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" LeaveMyMacAlone.app/Contents/Info.plist`
Expected: the `.icns` path is listed and `AppIcon` prints. (Finder may cache the old icon; `LeaveMyMacAlone.app` shows the new icon after re-copy.)

- [ ] **Step 6: Commit**

```bash
git add scripts/make-icon.sh Resources/AppIcon.icns Resources/Info.plist bundle.sh
git commit -m "feat: placeholder app icon + Info.plist icon/category"
```

---

### Task 2: Correct the README + add a LICENSE

**Files:**
- Modify: `README.md` (fix stale permission/auto-lock text; add download/install)
- Create: `LICENSE`

**Interfaces:** none (docs).

- [ ] **Step 1: Rewrite README.md**

Replace the entire contents of `README.md` with:

```markdown
# Leave My Mac Alone

Sen masandan uzaklaşırken Mac arkada çalışmaya devam etsin, ama kimse
klavye/fareye dokunup müdahale edemesin. Kilitleyince ekran uyumaz, üzerine
ayarlanabilir koyulukta bir kilit katmanı düşer; açmak için Touch ID / parola
gerekir.

## Gereksinimler
- macOS 14+ (macOS 26 üzerinde geliştirildi/doğrulandı), Apple Silicon
- Yalnızca **Erişilebilirlik (Accessibility)** izni (giriş engelleme için)

## Kurulum (kullanıcı)
1. `LeaveMyMacAlone.dmg`'yi indir, aç, uygulamayı **Applications**'a sürükle.
2. Uygulamayı çalıştır. Menü çubuğunda kalkan simgesi belirir (otomatik kilitlenmez).
3. İlk çalıştırmada **Erişilebilirlik izni** istenir: "Erişilebilirlik Ayarlarını
   Aç" → listede `LeaveMyMacAlone`'u aç.

## Kullanım
- **Kilitle:** menü çubuğu simgesi > **Şimdi Kilitle**, veya kısayol **⌃⌥⌘L**.
- **Aç:** kilit ekranındaki **Kilidi Aç** butonu, ya da **Space / Enter** → Touch ID
  (veya parola).
- **Koyuluk:** menü çubuğu simgesi > kaydırıcı (kilitli değilken ayarla; değer
  kalıcıdır). Sürüklerken canlı önizleme görünür.
- **Kilitliyken uyku:** menü çubuğu > "Kilitliyken uykuyu engelle" anahtarı.
- **Çıkış:** menü çubuğu simgesi > Çıkış.

## Donarsa kurtarma (SSH kill switch)
Başka bir cihazdan:
```bash
ssh <kullanıcı>@<mac-ip> 'killall LeaveMyMacAlone'
```
(Bunun için hedef Mac'te Sistem Ayarları > Genel > Paylaşım > **Uzaktan Oturum
Açma** açık olmalı.)

## Geliştirme
```bash
swift build && swift test     # derle + test
./bundle.sh                   # yerel .app (self-signed dev imzası)
```

## Yayın (notarized .dmg)
Bkz. `docs/superpowers/specs/2026-06-24-macos-release-design.md`. Özet:
```bash
export DEVELOPER_ID="Developer ID Application: Adın (TEAMID)"
export NOTARY_PROFILE="lmma-notary"   # önceden: xcrun notarytool store-credentials
./release.sh                          # imzalar, dmg yapar, notarize + staple eder
```

## Gizlilik
Ağ erişimi yok, veri toplama yok. Touch ID/parola için LocalAuthentication,
uyku engelleme için IOKit, giriş engelleme için CoreGraphics event tap — hepsi
yalnız yerel.

## Lisans
MIT — bkz. `LICENSE`.
```

- [ ] **Step 2: Add a LICENSE (MIT)**

Create `LICENSE`:

```
MIT License

Copyright (c) 2026 Alperen Kişi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Commit**

```bash
git add README.md LICENSE
git commit -m "docs: correct README for current behaviour; add MIT LICENSE"
```

---

### Task 3: release.sh (Developer ID sign + DMG + notarize + staple)

**Files:**
- Create: `release.sh`

**Interfaces:**
- Consumes: `bundle.sh` (assembles the `.app`), `Resources/LeaveMyMacAlone.entitlements`.
- Produces: `LeaveMyMacAlone.dmg` (notarized + stapled when run with valid credentials).

- [ ] **Step 1: Create release.sh**

Create `release.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="LeaveMyMacAlone"
BUNDLE_ID="com.alperenkisi.leavemymacalone"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${ROOT}/${APP_NAME}.app"
DMG="${ROOT}/${APP_NAME}.dmg"

# Required credentials (set by you; see the release design spec):
#   DEVELOPER_ID   e.g. "Developer ID Application: Alperen Kişi (TEAMID)"
#   NOTARY_PROFILE the notarytool keychain profile name you created with
#                  `xcrun notarytool store-credentials`.
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile name}"

# 1) Build + assemble the .app via the dev bundler, signing with the Developer ID.
echo "==> Assembling app (Developer ID)"
SIGN_IDENTITY="${DEVELOPER_ID}" "${ROOT}/bundle.sh"

# 2) Re-sign with hardened runtime + secure timestamp (required for notarization).
echo "==> Signing for notarization"
codesign --force --deep --options runtime --timestamp \
    --entitlements "${ROOT}/Resources/${APP_NAME}.entitlements" \
    --identifier "${BUNDLE_ID}" \
    --sign "${DEVELOPER_ID}" \
    "${APP}"
codesign --verify --strict --verbose=2 "${APP}"

# 3) Build a compressed DMG with an Applications drop target.
echo "==> Building DMG"
STAGE="$(mktemp -d)"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}"
rm -rf "${STAGE}"

# 4) Notarize the DMG, then staple the ticket to both the DMG and the app.
echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG}"
xcrun stapler staple "${APP}"

# 5) Verify Gatekeeper would accept it.
echo "==> Verifying"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}" || true
codesign -dvv "${APP}" 2>&1 | grep -iE "Authority=|TeamIdentifier="
echo "Done: ${DMG}"
```

- [ ] **Step 2: Make it executable and syntax-check**

Run: `chmod +x release.sh && bash -n release.sh && echo "syntax OK"`
Expected: `syntax OK`.

- [ ] **Step 3: Smoke-check the credential guard**

Run: `(unset DEVELOPER_ID NOTARY_PROFILE; ./release.sh) 2>&1 | head -1`
Expected: it fails fast with `Set DEVELOPER_ID to your 'Developer ID Application: …' identity` (proves the guard works without touching signing).

- [ ] **Step 4: Commit**

```bash
git add release.sh
git commit -m "build: add release.sh (Developer ID sign + DMG + notarize + staple)"
```

---

## Self-Review

**1. Spec coverage:**
- release.sh (Developer ID sign + notarytool + stapler + dmg) → Task 3. ✓
- DMG → Task 3 Step 3. ✓
- App icon (.icns) + Info.plist `CFBundleIconFile` → Task 1. ✓
- `LSApplicationCategoryType` → Task 1 Step 3. ✓
- README update (single permission, no auto-lock, download/install) → Task 2 Step 1. ✓
- LICENSE (MIT) + privacy note → Task 2 (LICENSE) + README "Gizlilik". ✓
- bundle.sh copies icon → Task 1 Step 4. ✓
- `[SEN]` items (Developer ID cert, notarytool creds, real icon, run notarization, clean-Mac test) → explicitly out of scope (Global Constraints); README documents the run command. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/uncoded steps. Every script and file body is complete.

**3. Type/name consistency:** `AppIcon.icns` / `CFBundleIconFile = AppIcon`, `DEVELOPER_ID`/`NOTARY_PROFILE`, `LeaveMyMacAlone.app`/`LeaveMyMacAlone.dmg`, `com.alperenkisi.leavemymacalone` are used identically across the icon script, Info.plist, bundle.sh, release.sh, and README. ✓
