# Leave My Mac Alone

Sen masandan uzaklaşırken Mac arkada çalışmaya devam etsin, ama kimse
klavye/fareye dokunup müdahale edemesin. Çalıştırınca ekran uyumaz, üzerine
saydam bir kilit katmanı düşer; açmak için Touch ID / parola gerekir.

## Gereksinimler
- macOS 14+ (macOS 26 üzerinde geliştirildi/doğrulandı), Apple Silicon
- Xcode Command Line Tools (Swift 6.2)
- SSH ile kurtarma için: Sistem Ayarları > Genel > Paylaşım > **Uzaktan Oturum
  Açma (Remote Login)** açık olmalı (kilit donarsa makineyi kurtarmak için).

## Kurulum
```bash
./bundle.sh
open .            # LeaveMyMacAlone.app oluşur; Applications'a taşıyabilirsin
```

## İlk çalıştırma (bir kez)
1. `LeaveMyMacAlone.app`'i çalıştır.
2. İzin uyarısı çıkar. Sistem Ayarları > Gizlilik ve Güvenlik bölümünden
   **hem Erişilebilirlik (Accessibility) hem Giriş İzleme (Input Monitoring)**
   listesine `LeaveMyMacAlone`'u ekle ve aç.
3. Menü çubuğundaki kalkan simgesinden **"Şimdi Kilitle"** ile kilitle.

İzinler verildikten sonra, uygulamayı her açtığında **anında kilitlenir**.

## Kullanım
- **Kilitle:** uygulamayı aç (otomatik), menü çubuğundan "Şimdi Kilitle", veya
  global kısayol **⌃⌥⌘L**.
- **Aç:** kilit ekranına dokun/klavyeye bas → Touch ID (veya parola).
- **Saydamlık:** menü çubuğu simgesi > kaydıracı (kilitliyken değil, açıkken
  ayarla; değer kalıcıdır).
- **Çıkış:** menü çubuğu simgesi > "Çıkış".

## Donarsa kurtarma (SSH kill switch)
Başka bir cihazdan:
```bash
ssh <kullanıcı>@<mac-ip> 'killall LeaveMyMacAlone'
```
Süreç ölünce kiosk modu ve giriş engeli anında kalkar.

## Dürüst sınırlamalar
- Çıplak laptopta **kapağı kapatmak** yine uyutur (donanımsal clamshell).
  Kapağı açık tut veya harici ekran + güç bağla.
- **Güç tuşuna basılı tutmak** donanımdan kapatır (yazılım engelleyemez).
- **Ad-hoc imza** nedeniyle her `./bundle.sh` (yeniden derleme) sonrası
  Accessibility/Input Monitoring iznini tekrar vermen gerekebilir. Bir kez
  derleyip çok kez çalıştırırsan sorun olmaz.
- Bu, şakacı bir iş arkadaşını durdurur; güvenlik-sınıfı bir kilit değildir.
