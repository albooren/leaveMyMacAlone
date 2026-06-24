# QA Denetim Raporu — "Leave My Mac Alone" (kilit uygulaması güvenilirlik/güvenlik)

**Tarih:** 2026-06-24
**Tetikleyen olay:** Cihaz kilitlendi → `Cmd+Tab` yapılınca parola girme penceresi tıklanamaz oldu → zorla yeniden başlatma gerekti.
**Yöntem:** 7 hata boyutunda çok-ajanlı adversaryal QA denetimi → bulguların gerçek kaynağa karşı doğrulanması → sentez. 64 bulgu üretildi; kritik/yüksek olanlar kod ile (`dosya:satır`) teyit edildi.

## Sonuç sınıfları
- **STRAND** — kullanıcı kendi makinesinden kilitlenir, zorla yeniden başlatma dışında yerel kurtarma yok.
- **BYPASS** — yoldan geçen, kilide rağmen makineyle etkileşime girer (uygulamanın amacını boşa çıkarır).
- **DEADLOCK** — uygulama çıkamadığı bir durumda takılır.
- **DEGRADED** — kabul edilebilir ama kötü davranış (kozmetik/UX, veri kaybı riski).

## Mimari kök gerçek (raporun tamamının dayanağı)
**Kilidi açma ve girişi yutma TEK bir mekanizmaya bağlı: `InputBlocker` event tap.**
- Kilit açma yalnızca tap'in `onFirstInteraction` callback'i ile tetiklenir (`AppController.lock`).
- Giriş yutma yalnızca tap'in `nil` döndürmesiyle olur (`InputBlocker.handle`).
- Kalkan pencereleri (eskiden) yalnızca görseldi; tıklama/klavye için **hiçbir** kilit-açma bağlantısı yoktu (`OverlayView.contentShape` yorumu boştaydı).
- `.authenticating` durumunda tap **duraklatılır** (`inputBlocker.pause`).
- `KioskMode`'un `.disableProcessSwitching`/`.disableForceQuit` vb. yalnızca **uygulamamız aktifken** geçerli. LAContext parola sayfası **ayrı bir sürecte** açılınca uygulamamız resign-active olur → tüm kiosk kısıtlamaları **düşer** → `Cmd+Tab`, Spotlight, Force Quit vb. yeniden çalışır.
- (Eskiden) ⌃⌥⌘L re-lock `machine.lock()` ile yalnızca `.unlocked`'ta çalışıyordu → `.authenticating`'de **no-op**.

**Sonuç:** `.authenticating` penceresinde tap duraklı + kiosk düşmüş + kalkan inert + hotkey no-op → yaşadığın olay dahil bir **strand sınıfı**. Aşağıdaki kardeş bulguların çoğu aynı kökten doğar.

---

## 1) QA TEST MATRİSİ (tekilleştirilmiş, temaya göre)

### Tema A — Auth penceresi kaçışları (`.authenticating` sırasında tap duraklı + kiosk düşmüş)

| ID | Başlık | Şiddet | Repro | Beklenen / Gerçek | Sınıf |
|---|---|---|---|---|---|
| A1 | **Cmd+Tab ile auth sırasında geçiş (YAŞANAN HATA)** | Kritik | Kilitle → girişe dokun (.authenticating) → Cmd+Tab | Beklenen: geçilemez. Gerçek: arka plan uygulaması öne gelir, parola sayfası tıklanamaz, ⌃⌥⌘L no-op → zorla restart | strand + bypass |
| A2 | Cmd+Space, Cmd+Opt+Esc, Mission Control/F3, Cmd+`` ` ``, hot corner, Launchpad auth sırasında çalışır | Yüksek | Kilitle → dokun → ilgili kısayol | Hepsi engelli olmalı; tap duraklı + kiosk düşmüş olduğundan hepsi tetiklenir | bypass |
| A3 | Cmd+Opt+Esc → uygulamamızı Force Quit | Yüksek | A2 → Force Quit penceresinden LeaveMyMacAlone'u sonlandır | Erişilemez olmalı; süreç ölür, OS kiosk'u geri verir → kalıcı açık | bypass |
| A4 | Cmd+Q/Cmd+H, ekran görüntüsü, Notification/Control Center, Siri, Dock auto-reveal | Orta | Kilitle → dokun → ilgili eylem | Engelli olmalı; quit/hide/yakalama/panel mümkün | bypass / degraded |
| A5 | ⌃⌥⌘L re-lock auth sırasında yapısal no-op (tek klavye kurtarma aracı) | Yüksek | .authenticating'de ⌃⌥⌘L | Panik re-lock olmalı; sessizce reddedilir | strand (katkı) |
| A6 | Auth başarısızlığı sonrası tap re-arm edilir ama kiosk yeniden assert edilmez | Orta | Kilitle → dokun → iptal/yanlış parola | Tam kilit durumu dönmeli; kiosk düşmüş kalabilir | degraded |

### Tema B — Auth devamlılığı (continuation) çözülmezse

| ID | Başlık | Şiddet | Repro | Beklenen / Gerçek | Sınıf |
|---|---|---|---|---|---|
| B1 | LAContext completion hiç tetiklenmezse sonsuz `.authenticating` | Yüksek | securityagent öldür / sayfa donar | Zaman aşımı/kurtarma olmalı; continuation askıda, tap kalıcı duraklı | strand / deadlock |
| B2 | Parola/biyometri hiç yoksa kalıcı re-lock döngüsü | Orta | Hiç parola/Touch ID yokken kilitle → dokun | Yerel kaçış olmalı; `canEvaluatePolicy` false → anında re-lock döngüsü (yalnız SSH kurtarır) | strand (SSH şart) |
| B3 | Biyometrik lockout düz başarısızlık sayılır | Düşük | 5+ kez yanlış Touch ID | Parola yoluna zorlanmalı; false döner → döngü | degraded |

### Tema C — Pencere düzeyi / çoklu ekran

| ID | Başlık | Şiddet | Repro | Beklenen / Gerçek | Sınıf |
|---|---|---|---|---|---|
| C1 | Auth sırasında ekran hot-plug: yeni ekran kapsız + tap duraklı | Orta | Kilitle → dokun → ikinci ekran tak | Yeni ekran kaplı/engelli olmalı; `rebuildWindows` önce tümünü `orderOut` eder, bildirim gecikmeli → kısa pencere | bypass (dar) + görsel ifşa |
| C2 | Hot-plug auth sayfasından key window'u çalar | Orta | Kilitle → dokun → ekran tak/çıkar | Sayfa key kalmalı; `makeKeyAndOrderFront` key çalar | degraded |
| C3 | Ardışık ekran-parametre bildirimleri: debounce yok → titreşim | Düşük | Sidecar/AirPlay/dock toggle | Stabil kaplama; her bildirim tam teardown+rebuild (race değil, debounce eksik) | degraded |
| C4 | `hide()` sonrası kuyruktaki bildirim hayalet kalkan yaratır | Düşük | Auth başarısı anında ekran değişimi | Kalkan gitmeli; kuyruktaki iş pencereyi yeniden kurabilir, tıkları yutar | degraded |
| C5 | Fullscreen-Space uygulaması kalkan dışında kalabilir (sürüm bağımlı) | Düşük | App fullscreen → kilitle | Tüm Space'ler kaplı; `collectionBehavior` garanti etmez | bypass (belirsiz) |
| C6 | Kalkanın auth sayfasının altında olduğu varsayımı doğrulanmamış | Düşük | — | Sayfa kalkanın üstünde olmalı; runtime'da z-order test edilmez (sürüm bağımlı) | strand (varsayımsal) |

### Tema D — Güç / uyku / oturum

| ID | Başlık | Şiddet | Repro | Beklenen / Gerçek | Sınıf |
|---|---|---|---|---|---|
| D1 | Uyandıktan sonra tap ölü kalır ama uygulama `.locked` sanır | Yüksek (sürüm bağımlı) | Kilitle → kapak kapat / Apple menü > Uyku → uyandır → yaz | Giriş engelli/auth tetikli olmalı; `didWakeNotification` observer'ı yok | bypass |
| D2 | `.authenticating` sırasında kapak kapatma → uyandıktan sonra strand | Yüksek (sürüm bağımlı) | Kilitle → dokun → kapak kapat → uyandır | Temiz `.locked`'a dönmeli; continuation çözülmezse A1-sınıfı strand | strand |
| D3 | Sistem kilit ekranı/loginwindow dönüşünde kiosk/state yeniden doğrulanmaz | Düşük | Kilitle → Ctrl+Cmd+Q → login → dön | Kalkan/kiosk geri gelmeli; `sessionDidBecomeActive` observer'ı yok | bypass (zayıf) |
| D4 | Logout/restart/shutdown auth sırasında engelsiz | Düşük | Kilitle → dokun → Apple menü > Yeniden Başlat | Engelli; auth'ta `disableSessionTermination` düşer (tehdit modeli dışı) | degraded |
| D5 | Fast User Switching dönüşünde kiosk düşmüş kalır | Düşük | Kilitle → kullanıcı değiştir → dön | Kiosk yeniden assert; consuming tap FUS'u atlatır → kalan açık kozmetik | degraded |

### Tema E — Tap yaşam döngüsü

| ID | Başlık | Şiddet | Repro | Beklenen / Gerçek | Sınıf |
|---|---|---|---|---|---|
| E1 | `handle()` içinde tap reinstall başarısızlığı sessizce yutulur | Yüksek | Sistem tap'i disable + reinstall başarısız (izin kaybı) | Fail-safe açılma; `handle()` `installTap()` sonucunu yok sayar → kalkan açık, giriş akar, açılamaz | strand + bypass |
| E2 | Auth pause penceresinde sistem-tetikli `tapDisabledByTimeout` tap'i sessizce yeniden açar | Orta | .authenticating'de sistem tap'i toggle ederse | Pause korunmalı; duraklı tap yeniden canlanıp tıklanamaz-sayfa hatasını üretir | strand (katkı) |
| E3 | Kilitliyken izin iptali izlenmiyor (watchdog yok) | Orta | Kilitle → Input Monitoring iptal | Tespit + fail-safe; yalnızca bir olay gelirse fark edilir | bypass / degraded |
| E4 | `start()` önceden var olan (muhtemelen ölü) tap için success döner | Düşük | Re-lock yolu | Canlılık doğrulanmalı; `guard eventTap == nil` doğrulamaz | bypass (dar) |
| E5 | Auth-fail `resume()` fail-safe'i Mac'i açar (yoldan geçenin yanlış parolası kalkanı düşürebilir) | Orta | Kilitle → dokun → yanlış parola + resume fail | Kilitli kalmalı; tasarım gereği fail-safe-to-unlocked (bypass yüzeyi) | bypass (tasarım) |

### Tema F — İzin / ilk çalıştırma / paketleme

| ID | Başlık | Şiddet | Repro | Beklenen / Gerçek | Sınıf |
|---|---|---|---|---|---|
| F1 | Kısmi-izin yolu uyarı gösterir ama yeniden kontrol etmez | Düşük | İzinsiz başlat → izin ver | Otomatik kilit/yeniden-arm; TCC observer'ı yok, "Şimdi Kilitle" gerekir | degraded |
| F2 | `bundle.sh` ad-hoc imza: her rebuild'de cdhash değişir → TCC reset | Düşük | İzin ver → düzenle → tekrar bundle | İzin korunmalı; cdhash değişir (GÜVENLİ yol, strand değil) | degraded |
| F4 (pozitif) | `lock()` tap-install başarısızlığında rollback **tam ve doğru sıralı** | — | Tap install'ı başarısız yap | DOĞRULANDI: her alt sistem geri alınır, alert kiosk-disengage sonrası → Ayarlar erişilebilir | (regresyon testi ekle) |

### Tema G — META

| ID | Başlık | Şiddet | Açıklama | Sınıf |
|---|---|---|---|---|
| G1 | **Hiçbir tek kurtarma kanalı TÜM durumlarda çalışmıyordu** | Kritik | Kalkan tıklaması bağlı değildi; ⌃⌥⌘L .authenticating'de no-op; tap auth'ta duraklı; menü kiosk'ta gizli → her yerel kanalın öldüğü bir durum vardı (yalnız SSH garanti) | strand (sistemik) |

---

## 2) ÖNLEYİCİ TEDBİRLER

> ⚠️ Güvenlik uygulaması: yanlış "düzeltme" kullanıcıyı daha kötü strand edebilir. Sıralama **fail-safe** ve **evrensel kurtarma**yı öne alır.

### ✅ UYGULANDI (bu branşta — `fix/lock-strand-recovery`)

**M1 — Kalkana tap-bağımsız kilit-açma jesti.** `KeyableWindow.mouseDown/rightMouseDown/otherMouseDown` → `onInteract` → AppController. `.locked`'ta tap zaten tıkları yutar, bu yüzden bu yalnızca tap yutmuyorken (auth/ölü) tetiklenir — tam da kurtarma gerektiği anda. Adresler: A1, G1, ve tap'in erişilemez olduğu her strand.
- Dosyalar: `ShieldController.swift`, `AppController.swift`.

**M2 — Durumdan-bağımsız panik re-lock (⌃⌥⌘L).** `.unlocked`→kilitle; `.authenticating`→`panicRelock()` (in-flight auth'u iptal et → temiz `.locked`); `.locked`→no-op. Adresler: A5, B1, A1.
- Dosyalar: `AppController.handleHotKey/panicRelock`, `Authenticator.cancel`.

**M4 — Auth watchdog (60s).** `.authenticating` çözülmeden 60s geçerse otomatik fail-safe → temiz `.locked`. Adresler: B1, D2 (continuation hiç çözülmese bile çıkış garanti).
- Dosyalar: `AppController.startWatchdog`.

**Epoch tabanlı auth orkestrasyonu.** Her auth denemesi bir epoch alır; iptal/re-present sonrası eski LAContext callback'i epoch uyuşmazsa yok sayılır → çift-geçiş/yarış yok. Re-present (kalkana tıkla, `.authenticating`'de) eski sayfayı geçersiz kılıp yenisini öne getirir.
- Dosyalar: `Authenticator` (`@MainActor`, `activeContext`, `cancel()`), `AppController.startAuth/finishAuth`.

**Doğrulama:** `swift build` ✅, `swift test` ✅ (14 test). Sistem davranışı bu ortamda çalıştırılamadı — **cihazda manuel test gerekir** (§4 kontrol listesi).

### ⏳ ÖNERİLEN SONRAKİ ADIMLAR (uygulanmadı — riske göre sıralı)

**M3 — Auth sırasında tam pause yerine KISITLI tap.** `inputBlocker.pause()` yerine tap'i canlı tut; `handle()` düz yazmayı parola sayfasına GEÇİR, ama uygulama/Space geçişi + launcher kombolarını (Cmd+Tab, Cmd+`` ` ``, Cmd+Space, Cmd+Opt+Esc, F3/F4, Ctrl+arrow, hot corner) YUT. Cmd+Tab deliğini ve A2/A3/A4 bypass'ını **kapatan asıl düzeltme**.
- ⚠️ **EN RİSKLİ:** yanlış filtre parola girişini bozarsa strand yaratır → M1/M2 fail-safe yerinde olduğu için artık kurtarılabilir, ama yine de cihazda dikkatli test ister. macOS sürümleri arası kombo eşlemesi kırılgan.

**M5/M6 — Wake/sleep observer'ları.** `didWakeNotification`/`willSleepNotification`: wake'te `.locked` ise tap canlılığını doğrula + gerekirse re-arm + kiosk re-assert; sleep'te `.authenticating`'i proaktif temizle. Adresler: D1, D2, D3, E3. `InputBlocker.isLive()` public gerekir.

**M7/M8 — Diff-tabanlı `rebuildWindows()` + debounce + active-guard.** Global teardown yerine ekran setini diff'le (yeni ekle, gideni kaldır), 50-100ms debounce, `isShown` guard. Adresler: C1, C2, C3, C4.

**M9/M10 — Stabil self-signed imza + ilk-çalıştırma izin yeniden-kontrolü.** `hasRequiredPermissions()` hard-gate'i canlı-tap sonucuna dayandır (dosyanın kendi yorumuyla tutarlı). Adresler: F1, F2.

**Regresyon:** F4 için `start()` false dönünce rollback'i assert eden entegrasyon testi (alt sistemler için protokol-DI refactor gerekir).

---

## 3) macOS-SÜRÜM BAĞIMLI / DÜZELTİLMEYECEK

**Sürüm bağımlı (düzelt ama varsayımı cihazda doğrula):** D1, D2 (LAContext'in uyku davranışı dokümante değil), C5, C6, D3/D4/D5 (consuming tap .locked'da duraklamadığından gerçek etkileşim-bypass'ı zayıf).

**False-positive — düzeltilmeyecek:**
- `missing-input-monitoring-usage-string`: Input Monitoring / Accessibility için Info.plist usage-string anahtarı yok; dialoglar tamamen sistem-üretimi.
- `sleepguard-not-reasserted-on-wake`: IOPMAssertion süreç ömrü boyunca powerd'de kalır; uyku canlı assertion'ı iptal etmez (IOKit semantiği).
- `runloop-source-tied-to-lock-thread`: tüm install/teardown main runloop'ta; hipotetik gelecek-kırılganlığı, shipped kodda strand/bypass yok.

---

## 4) CİHAZDA MANUEL DOĞRULAMA KONTROL LİSTESİ

**Uygulanan düzeltmeler (M1/M2/M4) için:**
- [ ] **A1 reprosu:** Kilitle → girişe dokun (.authenticating) → Cmd+Tab → **kalkana tıkla** → parola sayfası yeniden öne gelmeli (strand YOK).
- [ ] **A5/M2:** .authenticating'de **⌃⌥⌘L** → temiz `.locked`'a dönmeli, tap yeniden yutmalı (yeni dokunuş auth açar).
- [ ] **B1/M4:** Auth sayfasını açık bırak, 60s bekle → otomatik `.locked`'a dönmeli.
- [ ] Normal yol bozulmadı: dokun → Touch ID açıyor; parola fallback yazılabiliyor; iptal sonrası tekrar kilitleniyor.
- [ ] Kalkana tıklama normal (.locked) durumda gereksiz yere auth açmıyor (tap tıkları yutmalı).

**Genel regresyon:**
- [ ] SSH `killall LeaveMyMacAlone` hâlâ kurtarıyor.
- [ ] Çoklu ekran kapanıyor; uyku (idle) engelleniyor; menü çubuğu saydamlık kaydırıcısı kalıcı.

**M3 uygulanırsa (sonraki adım):** A2 listesindeki her kısayolu auth sırasında dene (hepsi etkisiz olmalı) + parola/Touch ID kabul ediliyor.

---

**En kritik tek mesaj:** Kilit-açma ve girişi-yutma tek bir mekanizmaya (event tap) bağlıydı ve kalkan kurtarma için ölü ağırlıktı. **M1 (kalkana tıkla-kurtar) tek başına tüm strand sınıfını kırar** ve en riskli düzeltme olan M3'ten önce gelir ki M3 bozulsa bile kullanıcı asla strand olmasın.
