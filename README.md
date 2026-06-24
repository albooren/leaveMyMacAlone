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
   Aç" → listede `LeaveMyMacAlone`'u aç. (Tek izin yeter; Giriş İzleme'ye gerek yok.)

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
Süreç ölünce kiosk modu ve giriş engeli anında kalkar. (Bunun için hedef Mac'te
Sistem Ayarları > Genel > Paylaşım > **Uzaktan Oturum Açma** açık olmalı.)

## Geliştirme
```bash
swift build && swift test     # derle + test
./bundle.sh                   # yerel .app (self-signed dev imzası)
```
Yerel imza için tek seferlik bir `LeaveMyMacAlone Dev` kod imzalama sertifikası
oluşturulursa (`bundle.sh` otomatik bulur), izinler yeniden derlemelerde kalıcı
olur; aksi halde ad-hoc imzada her derlemede TCC izni sıfırlanır.

## Yayın (notarized .dmg)
Ayrıntı: `docs/superpowers/specs/2026-06-24-macos-release-design.md`. Özet:
```bash
export DEVELOPER_ID="Developer ID Application: Adın (TEAMID)"
export NOTARY_PROFILE="lmma-notary"   # önceden: xcrun notarytool store-credentials
./release.sh                          # imzalar, dmg yapar, notarize + staple eder
```

## Gizlilik
Ağ erişimi yok, veri toplama yok. Touch ID/parola için LocalAuthentication,
uyku engelleme için IOKit, giriş engelleme için CoreGraphics event tap — hepsi
yalnız yerel.

## Dürüst sınırlamalar
- Çıplak laptopta **kapağı kapatmak** yine uyutur (donanımsal clamshell).
  Kapağı açık tut veya harici ekran + güç bağla.
- **Güç tuşuna basılı tutmak** donanımdan kapatır (yazılım engelleyemez).
- Sandbox dışıdır (tüketen event tap için gerekir), bu yüzden **Mac App Store'da
  dağıtılamaz**; doğrudan notarized indirme ile dağıtılır.
- Bu, şakacı bir iş arkadaşını durdurur; güvenlik-sınıfı bir kilit değildir.

## Lisans
MIT — bkz. `LICENSE`.
