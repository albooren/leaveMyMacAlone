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

## 🆘 Donarsa kurtarma (SSH kill switch)
Kilit takılırsa **başka bir cihazdan** uygulamayı öldürerek kurtar — arkadaki
işin/oturumun kesilmeden (zorla restart'tan farkı bu):
```bash
ssh <kullanıcı>@<mac-ip> 'killall LeaveMyMacAlone'
```

**Ön koşul (Mac'te, tek sefer):** Sistem Ayarları > Genel > Paylaşım >
**Uzaktan Oturum Açma (Remote Login)** → AÇ.
(Terminal'den `systemsetup -setremotelogin on` Tam Disk Erişimi ister; en kolayı
yukarıdaki GUI anahtarı.)

### 📱 iPhone'dan tek dokunuş (Kısayollar)
Donmadan **önce** kur:
1. **Kısayollar** uygulaması → yeni kısayol → **"SSH Üzerinden Betik Çalıştır"** eylemi.
2. Doldur:
   - **Sunucu:** Mac'in IP'si (örn. `192.168.1.x`) veya yerel adı (`<bilgisayar-adı>.local`)
   - **Kapı:** `22`
   - **Kullanıcı:** Mac kullanıcı adın
   - **Kimlik Doğrulama:** Parola → Mac giriş parolan (ya da SSH anahtarı)
   - **Betik:** `killall LeaveMyMacAlone`
3. Adını "Mac Kilidini Aç" koy; Ana Ekran / Eylem Düğmesi / Siri'ye ekle.

Mac donduğunda kısayola dokun (aynı Wi-Fi'de) → kilit ölür, Mac açılır.

> **İpuçları:** iPhone ile Mac **aynı ağda** olmalı. IP değişebilir → router'da
> DHCP rezervasyonu yap ya da `.local` adını kullan. Evden uzakta da erişmek için
> **Tailscale** gibi ücretsiz bir VPN kurabilirsin.
>
> **Son çare:** SSH yoksa, **güç tuşunu basılı tutmak** Mac'i donanımdan yeniden
> başlatır (yazılım engelleyemez) — ama arkadaki işin de gider.

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
