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
    sips -z "$sz" "$sz"             "${PNG}" --out "${ICONSET}/icon_${sz}x${sz}.png"     >/dev/null
    sips -z "$((sz*2))" "$((sz*2))" "${PNG}" --out "${ICONSET}/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${ROOT}/Resources/AppIcon.icns"
rm -rf "${WORK}"
echo "Wrote ${ROOT}/Resources/AppIcon.icns"
