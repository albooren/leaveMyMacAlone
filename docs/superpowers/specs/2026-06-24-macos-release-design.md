# Tasarım: macOS Yayını (doğrudan notarized dağıtım)

**Tarih:** 2026-06-24
**Durum:** Onaylandı (uygulama planı bekliyor)

## Amaç & kapsam

LeaveMyMacAlone'u **App Store dışında**, indirilebilir, **notarize edilmiş bir
`.dmg`** olarak yayınlanabilir hale getirmek. Apple Developer Program hesabı
mevcut. Mac App Store kapsam dışı (sandbox zorunlu; uygulamanın çekirdeği olan
tüketen `CGEventTap` + kiosk giriş engelleme sandbox'ta yasak — `entitlements`
zaten `app-sandbox = false`).

## Kararlar

- **Shell hattını genişlet:** yeni bir `release.sh` (Developer ID imza + hardened
  runtime + `notarytool` + `stapler` + `.dmg`). Mevcut `bundle.sh` (self-signed)
  yerel geliştirme için kalır. Xcode projesine göç YOK.
- **v1 YAGNI:** otomatik güncelleme (Sparkle), CI, indirme sitesi, Intel/universal
  binary kapsam dışı (gerekirse sonra).

## İş kalemleri

`[SEN]` = Apple kimliği/sanat gerektiren, senin yapacağın · `[BEN]` = kod/script ile yapılacak

### 1. İmza & Notarization
- **[SEN]** Developer ID Application sertifikası oluştur (Xcode → Settings →
  Accounts → Manage Certificates). Sonuç: `security find-identity -v -p codesigning`
  çıktısında "Developer ID Application: …" görünür; Team ID atanır.
- **[SEN]** `notarytool` kimliği: app-specific password (appleid.apple.com) **veya**
  App Store Connect API key. `xcrun notarytool store-credentials` ile bir profil
  (örn. `lmma-notary`) olarak kaydet.
- **[BEN]** `release.sh`:
  1. `swift build -c release` + `.app` montajı (bundle.sh ile aynı düzen + `.lproj`).
  2. `codesign --force --options runtime --timestamp --entitlements … --sign "Developer ID Application: …"`.
  3. `.dmg` oluştur (aşağıda).
  4. `xcrun notarytool submit "<dmg>" --keychain-profile "lmma-notary" --wait`.
  5. `xcrun stapler staple "<dmg>"` (ve `.app`).
  6. `spctl --assess --type open --context context:primary-signature` ile doğrula.
  - İmza kimliği env'den okunur (`DEVELOPER_ID`, `NOTARY_PROFILE`); yoksa anlamlı hata.

### 2. Paketleme
- **[BEN]** `.dmg` üretimi: `hdiutil` ile Applications kısayollu, sürükle-bırak
  düzenli salt-okunur sıkıştırılmış dmg (ek bağımlılık yok).
- **[BEN]** App ikonu: önce **placeholder** `.icns` üret (kilit/kalkan temalı,
  `sips`/`iconutil` ile programatik). Info.plist'e `CFBundleIconFile` ekle.
- **[SEN]** (opsiyonel) gerçek ikon sanatını ver → placeholder'ı değiştiririm.

### 3. Metadata & cila
- **[BEN]** Info.plist: `CFBundleIconFile`, `LSApplicationCategoryType =
  public.app-category.utilities`. (Versiyon 1.0.0, `NSFaceIDUsageDescription` mevcut.)
- **[BEN]** README'yi güncelle: **mevcut hâli yanlış** — "hem Erişilebilirlik hem
  Giriş İzleme" (artık tek izin: Erişilebilirlik) ve "her açtığında anında
  kilitlenir" (otomatik-kilit kaldırıldı). İndirme/kurulum + ilk-çalıştırma
  (Erişilebilirlik izni) talimatları ekle.
- **[BEN]** `LICENSE` (MIT) + kısa gizlilik notu (ağ yok, veri toplama yok;
  LocalAuthentication/IOKit/event tap yalnız yerel).

### 4. Doğrulama
- **[BEN]** `release.sh` "smoke" kontrolü: imza/dmg adımları sözdizimi + dev
  sertifikasıyla kuru-deneme (notarization hariç) çalışır.
- **[SEN]** Gerçek notarization'ı kendi kimliğinle çalıştır; **temiz bir Mac'te**
  dmg'yi indir → Gatekeeper engellemeden aç → Erişilebilirlik onboarding → kilit/aç.

## Kapsam dışı (v1)
Mac App Store; Sparkle otomatik güncelleme; CI imzalı build; indirme sitesi;
Intel/universal binary.

## Riskler / notlar
- Notarization adımları yalnız geçerli Developer ID + notary kimliğiyle uçtan uca
  çalışır; `release.sh` doğru komutlarla hazır olur ama tam akış sende koşar.
- Self-signed dev kimliği (`LeaveMyMacAlone Dev`) yerel TCC kalıcılığı için kalır;
  release ayrı Developer ID ile imzalanır.
