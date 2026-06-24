# 🛡️ Leave My Mac Alone

> Masandan kalktığında Mac'in çalışmaya devam etsin, ama kimse klavye/fareye dokunamasın.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple)
![License](https://img.shields.io/badge/license-MIT-blue)
[![Latest release](https://img.shields.io/github/v/release/albooren/leaveMyMacAlone?label=indir&color=success)](https://github.com/albooren/leaveMyMacAlone/releases/latest)

LeaveMyMacAlone, menü çubuğunda yaşayan küçük bir macOS aracı. Kilitlediğinde
ekran uyumaz; üzerine ayarlanabilir koyulukta bir kilit katmanı düşer ve
klavye/fare girişleri engellenir. Açmak için **Touch ID veya parola** gerekir —
arkadaki işin (indirme, render, build…) kesintisiz sürer.

## ✨ Özellikler
- 🔒 **Tek tuşla kilit** — menüden "Şimdi Kilitle" veya **⌃⌥⌘L** kısayolu.
- 👆 **Touch ID / parola** ile aç (Kilidi Aç butonu, ya da Space/Enter).
- 🌗 **Ayarlanabilir koyuluk** — hafif tülden tam karartmaya; sürüklerken canlı önizleme.
- ☕ **Uyumaz** — kilitliyken ekranı/sistemi uyanık tutar (isteğe bağlı kapatılır).
- 🪶 **Tek izin** — yalnızca Erişilebilirlik (Giriş İzleme gerekmez).
- 🧰 **Menü çubuğu uygulaması** — Dock'u kirletmez, açılışta otomatik kilitlemez.
- 🆘 **SSH kill switch** — donarsa uzaktan `killall` ile kurtarma.
- 🌍 Türkçe + İngilizce arayüz (sistem diline göre).

## 📦 Kurulum
1. [Releases](https://github.com/albooren/leaveMyMacAlone/releases/latest)'tan
   **`LeaveMyMacAlone.dmg`**'yi indir, aç, uygulamayı **Applications**'a sürükle.
2. Çalıştır → menü çubuğunda kalkan simgesi belirir.
3. İlk açılışta **Erişilebilirlik izni** istenir: "Erişilebilirlik Ayarlarını Aç"
   → listede `LeaveMyMacAlone`'u aç. (Notarize'lı olduğu için Gatekeeper engellemez.)

## 🎛️ Kullanım
| Eylem | Nasıl |
|---|---|
| **Kilitle** | Menü > Şimdi Kilitle · veya **⌃⌥⌘L** |
| **Aç** | Kilidi Aç butonu / **Space** / **Enter** → Touch ID veya parola |
| **Koyuluk** | Menü > kaydırıcı (açıkken ayarla; kalıcı) |
| **Kilitliyken uyku** | Menü > "Kilitliyken uykuyu engelle" anahtarı |
| **Çıkış** | Menü > Çıkış |

## 🆘 Donarsa kurtarma
Başka bir cihazdan:
```bash
ssh <kullanıcı>@<mac-ip> 'killall LeaveMyMacAlone'
```
(Hedef Mac'te Sistem Ayarları > Genel > Paylaşım > **Uzaktan Oturum Açma** açık olmalı.)

## 🛠️ Geliştirme
```bash
swift build && swift test     # derle + test (22 test)
./bundle.sh                   # yerel .app (self-signed dev imzası)
```
Tek seferlik bir `LeaveMyMacAlone Dev` kod imzalama sertifikası oluşturursan
(`bundle.sh` otomatik bulur), Erişilebilirlik izni yeniden derlemelerde kalıcı olur.

## 🚀 Yayın (notarized .dmg)
Ayrıntı: [`docs/superpowers/specs/2026-06-24-macos-release-design.md`](docs/superpowers/specs/2026-06-24-macos-release-design.md).
```bash
export DEVELOPER_ID="Developer ID Application: Adın (TEAMID)"
export NOTARY_PROFILE="lmma-notary"   # önceden: xcrun notarytool store-credentials
./release.sh                          # imzalar → dmg → notarize → staple
```

## ⚠️ Dürüst sınırlamalar
- Çıplak laptopta **kapağı kapatmak** yine uyutur (donanımsal clamshell). Kapağı
  açık tut veya harici ekran + güç bağla.
- **Güç tuşuna basılı tutmak** donanımdan kapatır (yazılım engelleyemez).
- Sandbox dışı olduğu için **Mac App Store'da değildir**; doğrudan notarized
  indirme ile dağıtılır.
- Şakacı bir iş arkadaşını durdurur; askeri sınıf bir kilit değildir.

## 🔐 Gizlilik
Ağ erişimi yok, veri toplama yok. Touch ID/parola için LocalAuthentication, uyku
engelleme için IOKit, giriş engelleme için CoreGraphics event tap — hepsi yalnız
yerel.

## 📄 Lisans
[MIT](LICENSE) © 2026 Alperen Kişi
