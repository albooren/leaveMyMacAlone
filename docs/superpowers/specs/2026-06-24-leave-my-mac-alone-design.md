# Leave My Mac Alone — Tasarım (Spec)

**Tarih:** 2026-06-24
**Durum:** Onaylandı (brainstorming → spec)

## Amaç & tehdit modeli

Kullanıcı masasından uzaklaşırken Mac arkada (örn. Claude Code) çalışmaya **devam etsin**, ama fiziksel olarak masaya gelen **şakacı iş arkadaşları** klavye/fareye dokunup müdahale **edemesin**. Ekran uyumasın; üzerinde **saydam** bir kilit katmanı dursun; dokununca **Touch ID / parola** ile açılsın.

**Dürüst kapsam:** Sıradan fiziksel müdahaleyi durdurur. Kararlı saldırganı (donanım reset, ağ üzerinden erişim, başka makineden saldırı) durdurmayı hedeflemez.

## Onaylanmış kararlar

| Karar | Seçim |
|---|---|
| Kilit gücü | **Maksimum**: kiosk modu + CGEventTap + force-quit kilidi |
| Kurtarma yolu | **SSH kill switch** (`killall LeaveMyMacAlone`), Remote Login açık |
| Görsel ton | **Ayarlanabilir saydamlık** (menü çubuğundan, kalıcı) |
| Yaşam döngüsü | **Anında kilit** + menü çubuğu + global kısayol (⌃⌥⌘L) |

## Mimari

Native macOS uygulaması, iki katman:

- **`LeaveMyMacAloneCore`** — saf, test edilebilir Swift kütüphanesi (UI/sistem bağımlılığı yok):
  - `LockState` durum makinesi (`unlocked` → `locked` → `authenticating` → `unlocked`/`locked`)
  - `Settings` (saydamlık `0.0…0.85` clamp, UserDefaults soyutlaması arkasında)
  - HotKey yapılandırma ayrıştırma
  - `swift test` ile birim testli (hedef: %80+ kapsam saf mantıkta)
- **`LeaveMyMacAlone`** — AppKit + SwiftUI çalıştırılabilir, menü çubuğu uygulaması (`LSUIElement = true`):
  - Pencereler, event tap, güç sertifikaları, Touch ID, menü çubuğu
  - Manuel doğrulama listesiyle (UI/sistem katmanı birim testlenemez)

**Build:** Swift Package Manager + `scripts/bundle.sh` (imzalı `.app` üretir). Xcode GUI ve Homebrew gerekmez; tamamen CLI'dan kurulabilir.

**İsimlendirme:** Ürün "Leave My Mac Alone"; çalıştırılabilir `LeaveMyMacAlone`; bundle id `com.alperenkisi.leavemymacalone`; SSH kurtarma `killall LeaveMyMacAlone`.

## Bileşenler

| Bileşen | Katman | Sorumluluk |
|---|---|---|
| `LockState` | Core | Kilit durum makinesi + geçiş kuralları |
| `Settings` | Core | Saydamlık değeri (clamp) + kalıcılık soyutlaması |
| `HotKeyConfig` | Core | ⌃⌥⌘L modifikatör/keycode tanımı |
| `AppDelegate` | App | NSApplication önyükleme, accessory mod, bileşen kurulumu |
| `ShieldController` | App | Her `NSScreen` için `CGShieldingWindowLevel()` seviyesinde saydam pencere; `didChangeScreenParameters` ile yeniden kurar |
| `OverlayView` (SwiftUI) | App | Ayarlı opaklıkta tül + 🔒 rozet + canlı saat |
| `InputBlocker` | App | `CGEventTap` (session-level, active): kilitliyken klavye+fare olaylarını yutar; ilk olayda açma akışını tetikler; `kIOHIDEventTapDisabledByTimeout` yeniden etkinleştirme |
| `KioskMode` | App | `NSApp.presentationOptions`: process switching/force quit/session termination kapalı, Dock+menü gizli; geri alma |
| `SleepGuard` | App | IOKit güç sertifikaları (display sleep + system idle sleep engelle); bırakma |
| `Authenticator` | App | `LAContext.deviceOwnerAuthentication` → Touch ID, başarısızsa otomatik parola |
| `ReLockHotKey` | App | Carbon `RegisterEventHotKey` ⌃⌥⌘L global kilit |
| `MenuBarController` | App | `NSStatusItem` + popover: saydamlık kaydıracı, "Şimdi Kilitle", "Çıkış" |

## Akış

1. **Çalıştır** → anında: güç sertifikaları aç → her ekrana saydam pencere → kiosk modu → event tap aktif (tüm girişi yut). Durum: `locked`.
2. **Biri dokunur** (klavye/fare) → tap ilk olayı yakalar → tap geçici kapanır → `authenticating` → Touch ID/parola sheet'i.
   - **Başarılı** → overlay kalkar, sertifikalar bırakılır, kiosk geri alınır → `unlocked`, menü çubuğunda bekler.
   - **İptal/başarısız** → tap tekrar aktif → `locked`.
3. **Tekrar kilitle**: menü çubuğundan veya ⌃⌥⌘L → adım 1.
4. **Kurtarma (donma)**: başka cihazdan `ssh kullanıcı@mac 'killall LeaveMyMacAlone'` → süreç ölür, kiosk + tap anında kalkar (sistem presentationOptions'ı süreç ölünce geri alır).

**Kritik incelik:** Event tap tüm girişi yuttuğundan açma ekranını da tap yönetir (overlay penceresi tıklama beklemez). LAContext parola sheet'i klavye girişi gerektirdiğinden, kimlik doğrulama süresince tap **geçici kapatılır** (güvenli sistem sheet'i en üstte; bu pencere kabul edilebilir risk). Saydamlık kaydıracı **kilitliyken değil**, menü çubuğundan ayarlanır ve `UserDefaults`'a kaydedilir; overlay her zaman güncel değeri render eder.

## Hata yönetimi

- **Accessibility izni yoksa** event tap kurulamaz → kullanıcıya açık uyarı + izin yönlendirmesi; girişi-engellemenin zayıfladığını **sessizce geçme**. Kiosk + overlay yine devreye girer.
- Güç sertifikası hatası → logla, devam et (kritik değil; overlay yine korur).
- Touch ID yoksa → otomatik parola; o da yoksa → SSH kaçış yolu (dokümante).
- Ekran parametreleri değişirse → shielding pencerelerini yeniden kur.

## Test stratejisi

- **Birim (otomatik, `swift test`):** `LockState` geçişleri, saydamlık clamp (0.0–0.85), `Settings` kalıcılık (enjekte edilmiş store ile), `HotKeyConfig` ayrıştırma.
- **Manuel doğrulama listesi (planda adım adım):** Cmd+Tab / Cmd+Opt+Esc / Spotlight / ekran görüntüsü engellendi mi; Touch ID açıyor mu; iptal sonrası tekrar kilitleniyor mu; çoklu ekran kapanıyor mu; SSH kill switch çalışıyor mu; uyku engelleniyor mu; menü çubuğu saydamlık kaydıracı kalıcı mı.

## Dürüst sınırlamalar

- **Kapağı kapatmak** (çıplak laptop) yine uyutur — donanımsal (clamshell). Azaltma: kapağı açık tut veya harici ekran + güç.
- **Güç tuşuna basılı tutmak** = donanım kapanışı — yazılımla engellenemez.
- **Ad-hoc imzalama** her *yeniden derlemede* Accessibility iznini tekrar istetebilir (normal *yeniden açmada* değil).
- Maksimum kiosk seçenek kombinasyonu çalışma zamanında doğrulanır; geçersiz kombinasyon riskine karşı bilinen-iyi bitmask kullanılır ve event tap birincil zorlayıcıdır (kiosk azaltılsa bile koruma sürer).

## Kapsam dışı (YAGNI)

- Otomatik "iş bitince aç" (deadman) — yok.
- Ağ/uzaktan kilit, çoklu kullanıcı, profil yönetimi — yok.
- Notarization / App Store dağıtımı — kişisel kullanım, ad-hoc imza yeterli.
