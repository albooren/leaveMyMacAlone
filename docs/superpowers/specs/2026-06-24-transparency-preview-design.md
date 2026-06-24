# Tasarım: Saydamlık Canlı Önizleme

**Tarih:** 2026-06-24
**Durum:** Onaylandı (uygulama planı bekliyor)

## Amaç

Kullanıcı kilit ekranının kararma (opaklık) düzeyini menü çubuğu panelindeki
slider'dan ayarlıyor, ama sonucu ancak Mac'i kilitleyince görebiliyor. Bu özellik,
**kilitlemeden**, slider ayarlanırken kilit ekranının kararmasını gerçek ekran
üzerinde canlı olarak önizletir.

## Karar

Tam ekran, **canlı**, **kilitlemeyen** önizleme. Ekranda yalnızca kararma (dim) +
küçük bir "Önizleme" etiketi gösterilir (kilit rozeti/saat/buton gösterilmez;
bunlar opaklıktan etkilenmez). Önizleme panel açıkken görünür, panel kapanınca
normale döner. Girişi asla engellemez.

## Yaklaşım

Kilit makinesinden (event tap / kiosk / sleep guard) **bağımsız**, tek-sorumluluklu
yeni bir bileşen: `PreviewOverlayController`. Önizleme penceresinin SwiftUI içeriği
doğrudan `AppSettingsStore.overlayOpacity`'yi gözler; böylece slider oynadıkça
kararma ekstra kablolama olmadan canlı güncellenir.

Reddedilen alternatif: `ShieldController`'a "önizleme modu" eklemek — pencere
makinesini paylaşırdı ama kilit yaşam döngüsüyle karışma riski taşıyordu ve
ShieldController'a kilit-dışı sorumluluk yüklerdi.

## Bileşenler

### `PreviewOverlayController` (yeni — `Sources/LeaveMyMacAlone/PreviewOverlayController.swift`)
- `@MainActor`, `AppSettingsStore`'a referans tutar.
- `start()`: her `NSScreen` için bir önizleme penceresi açar:
  - Kenarlıksız (`.borderless`), `backgroundColor = .clear`, `isOpaque = false`.
  - `ignoresMouseEvents = true` (tıklamalar alttaki uygulamalara/panele geçer).
  - Pencere seviyesi: panelin (`.popUpMenu`) **hemen altı** → `.popUpMenu` rawValue − 1.
    Böylece panel ve slider hep üstte/tıklanabilir, önizleme menü çubuğu ile
    uygulamaların üstünde görünür.
  - `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`.
  - İçerik: `NSHostingView(rootView: PreviewDimView(store: store))`.
- `stop()`: tüm önizleme pencerelerini `orderOut` eder ve referansları bırakır.
- Tap / kiosk / sleep guard / state machine ile **hiç** etkileşmez — yalnızca görsel.
- Çoklu ekran: pencereler `start()` anındaki ekranlara göre kurulur (kısa ömürlü
  önizleme için dinamik ekran-değişimi takibi gerekmez).

### `PreviewDimView` (yeni SwiftUI view, aynı dosyada)
- `@ObservedObject var store: AppSettingsStore`.
- Gövde: `Color.black.opacity(store.overlayOpacity).ignoresSafeArea()` +
  üstte ortada küçük bir **"Önizleme"** kapsül etiketi (`.ultraThinMaterial`,
  beyaz metin, `lock.shield` ikonu).
- Store @Published olduğu için slider oynadıkça opaklık canlı güncellenir.

### `MenuBarController` (mevcut — değişiklik)
- Bir `PreviewOverlayController` örneği tutar (store ile kurulur).
- `openPanel()` sonunda → `preview.start()`.
- `closePanel()` başında → `preview.stop()`.
- "Şimdi Kilitle" akışı zaten `closePanel()` → `onLockNow()` sırasıyla çalışıyor;
  yani önizleme, gerçek shield gelmeden önce durur. Çakışma yok.

## Veri akışı

```
SwiftUI Slider → store.overlayOpacity (@Published)
                 ├─ panel: "%NN" etiketi (mevcut)
                 ├─ store.onOpacityChange → AppController → shield.setOpacity
                 │     (yalnızca kilitliyken görünür; kilitli değilken zararsız)
                 └─ PreviewDimView: Color.black.opacity(...) (yeni, canlı)
```

## Yaşam döngüsü / kenar durumlar

- Önizleme = panel yaşam döngüsü: panel her kapanış yolundan (dış tıklama, Escape,
  butonlar) `closePanel()` geçtiği için `stop()` daima çağrılır → hayalet dim kalmaz.
- Önizleme asla girişi engellemez (`ignoresMouseEvents = true`); kilitlemez.
- "Şimdi Kilitle" / "Çıkış": önce `closePanel()` (stop), sonra eylem.
- Kilitliyken bu yol erişilemez (kiosk menü çubuğunu gizler), dolayısıyla önizleme
  ile gerçek kilit aynı anda olamaz.

## Kapsam dışı (YAGNI)

- Önizleme sırasında kilit rozeti/saat/buton/animasyon gösterimi.
- Önizleme için ayrı bir "Önizle" butonu veya basılı-tut modu.
- Önizleme sırasında dinamik ekran ekleme/çıkarma takibi.

## Test

- Mantık parçası minimal; özellik UI ağırlıklı.
- Mevcut 17 test korunur (değişmez).
- Manuel doğrulama: paneli aç → slider oynat → ekran canlı kararır + "Önizleme"
  etiketi görünür; slider'ı bırak → o düzeyde kalır; paneli kapat → ekran normale
  döner; bu sırada başka uygulamalara tıklanabilir (engellenmez).
