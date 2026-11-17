# Native arayüz kontrolü

0.8.0; üç bölgeli çalışma alanı ve sade kontroller, kalıcı açık/koyu/sistem tercihi, klavye ile hızlı açma, gerçek ses seviyeleri ve Hareketi Azalt desteği. Önceki görsel seçeneklerin özgün dosyaları mevcut olmadığı için piksel eşleşmesi iddia edilmez.

## Kanıtlar

- Üretimdeki RootView doğrudan NSHostingView ile, gerçek arşivden bağımsız sentetik toplantılarla çizildi. HTML kopyası kullanılmadı.
- Her iki temada 1280×850, 900×680 ve en küçük pencere boyutu 900×620 kontrol edildi. Sağ panel dar pencerede kaldırılıyor, ayrıntı düğmesi kalıyor.
- Hızlı açma, ayarlar, başlangıç ve yeni toplantı ekranları da iki temada çizildi: toplam 14 PNG.
- İlk kontrolde dar yeni-toplantı ekranında kayıt düğmesi fazla aşağıdaydı. Mikrofon/dil seçimi açılır ayrıntıya taşındı. Yeniden alınan 900×620 görüntülerinde Kaydı başlat ve Sesimi kontrol et ilk görünümde yer alıyor.
- Yazı hiyerarşisi, satır kırılması, boşluklar, çerçeveler, tema kontrastı ve kalıcı oynatıcı görsel olarak incelendi. İkonlar yerel SF Symbols; gösterilen ses seviyeleri yalnız kayıtçının gerçek ölçümleridir.
- Birden fazla ses grubunun tek doğrulanmış kişiye ait olması, aynı isimli farklı kişilerin birleştirilmemesi, kullanılmayan kişinin katılımcı sayılmaması ve güçlü profil eşleşmeleri dört davranış testiyle kontrol edildi.
- Kayıt/pending/mikrofon denemesi sırasında toplantı değiştirme koruması, iş sürerken yeni toplantı/içe aktarma engeli, kaynaklara gitme, geçmişe dönme ve mevcut kaydetme API’leri kaynak üzerinden kontrol edildi.

Yerel görüntü üretimi masaüstünü yakalamaz, görünür pencere açmaz, mikrofon kaydı veya model çıkarımı yapmaz. Arşiv ve kayıt kontrolleri gerçek kullanıcı verileriyle denenmedi. Klavye/fare etkileşimi, gerçek ses kaydı ve uygulama içinden kurulum bu görsel testin kanıtı değildir.

## Tekrarlama

Projenin normal swift test komutuyla testleri derleyin; ardından yeni bir çıktı klasörü verin:

```sh
python3 Scripts/render-workspace.py --output-dir /tmp/meetingdesk-ui-review
```

Betik en fazla 60 saniye çalışır, yalnız açıkça seçilmiş görsel testi çalıştırır ve kaynak/örnek veri özetlerini rapora kaydeder. Örnek veri Tests/MeetingDeskTests/WorkspaceFixtures altındadır. Normal CI’da bu test isteğe bağlı olduğu için atlanır.

Görsel yerleşim sonucu: geçti. Canlı kullanıcı kabulü ayrıca değerlendirilir.

## 0.9.0 ek kontrolleri

- 544 testlik Swift paketinde hata bulunmadı; bu Mac’te 8 donanım/isteğe bağlı kontrol atlandı. Paketleme için 22 test geçti. Yerel ses çıkışı bulunmadığı için dijital sessizlikle kısa parçanın otomatik bitmesi testi burada atlandı; oynatma penceresi, kanal, eski kaynak ve dosya sınırları ayrı davranış testleriyle kontrol edildi. Bu bir canlı mikrofon/kurulum kanıtı değildir.
- Gerçek kullanıcı tarafından seçilmiş iki arşiv yalnız Mac’te, salt okunur yeniden oynatma kontrolünden geçti. Zaman geri sıçramaları sıfırlandı, özgün segmentlerin saklandığı ve dosya özetlerinin değişmediği doğrulandı. Özel içerik bu depoya eklenmedi veya ağa gönderilmedi.
- 16 sentetik yerel görüntü incelendi: önceki 14 görünüm ve iki temada gerçek TranscriptWorkspaceView. İlk görsel kontrolde hatırlatma kartının içerik haritasına yerleşmesi ve bağımsız transkriptin şeffaf arka plan/etiket sorunları bulundu; kart ana nota taşındı, görünümün tema/etiketleri düzeltildi ve tekrar çizildi.
- Kayıt başlatma en küçük pencerede görünür; hatırlatma ayrıntıları varsayılan kapalıdır. Akıcı görünümde her ufak parça için büyük bir kart çizilmez. Kaynak filtresi ve özgün parçaları açma kontrolleri korunur.
- Mouse/klavye ile canlı etkileşim, yeni ASR çıktısının kelime doğruluğu ve uygulama içinden kurulum bu kontrolle kanıtlanmış sayılmaz.


## 0.10.1 kaydırma kontrolü

- Düzenli CoreAudio/pencere sorguları ana iş parçacığından utility görevine taşındı. Yavaş sorgu sırasında ana iş parçacığının çalışması, eski sonucun durdurma/yeniden başlatma/askıya alma sonrasında yayımlanmaması ve sorguların üst üste binmemesi kontrollü testlerle doğrulandı.
- Arşivde her başlık/satır ayrı lazy öğedir. Hover durumu satırın içinde kalır. Sıralama, filtreler, kararlı kimlikler ve büyük geçmişin düzleştirilmesi davranış testleriyle kontrol edildi.
- 660 Swift testi: 13 donanım/isteğe bağlı kontrol atlandı, hata yok. 22 paketleme testi geçti. 16 sentetik yerel görüntü iki temada üretildi; dar ana ekran görsel olarak incelendi.
- İsteğe bağlı kaydırma tanısı gerçek RootView ve TranscriptWorkspaceView bileşenlerini gizli, sahip olunan NSWindow içinde kullanır. 10 sentetik toplantı ve toplantı başına 2.000 segmentle gerçek NSScrollView yer değiştirmesi doğrulanır. Transkriptin hazırlanması/gruplanması kaydırmada tekrar çalışmadı. Büyük transkriptte çizim maliyeti devam edebilir; bu kontrol tam akıcılık garantisi değildir.
- Metin seçimini kaldırma ve alternatif yerel metin bileşeni karşılaştırıldı; mevcut seçme/kopyalama davranışını değiştiren düzenleme yayıma alınmadı.

Bu tanı görünür pencere açmaz; masaüstü görüntüsü almaz, model çalıştırmaz ve gerçek toplantıları okumaz/değiştirmez. Programatik kaydırma ölçümü fiziksel trackpad, ekran birleştiricisi veya kurulu uygulamanın kullanıcı kabulü değildir. Süre değerleri CI kabul eşiği olarak kullanılmaz.

Testleri normal komutla derledikten sonra yalnız tanıyı, işlem süresi sınırıyla çalıştırmak için:

```sh
python3 Scripts/probe-workspace-scroll.py --output-dir /tmp/meetingdesk-scroll-review
```

Başarılı rapor için hem ana görünümde hem transkriptte pozitif kaydırma alanı ve gerçek yer değiştirmesi, ayrıca transkriptin hazırlandığının doğrulanması gerekir. Rapor yalnız ölçümleri ve sentetik örneklerin sayaçlarını içerir.


## 0.10.2 etkin pencere kontrolü

Sorun, aynı toplantı arkada dururken kaydırmanın akıcı, pencere etkinleşince ağır olmasıyla daraltıldı. Öndeki pencere örneğinde maliyet ana iş parçacığının SwiftUI/AppKit etkileşim ve görünüm güncellemelerinde görüldü; arka plan model işlemi saptanmadı.

`workspaceQuickOpen` için `@FocusedValue` uygulamanın `App` türünden ayrı bir `Commands` türüne taşındı. Böylece bu odak bağımlılığı yalnız ilgili menü komutunda kalır. Pencereye özgü eylemi yayımlayan RootView bağlantısı aynıdır. SwiftUI içindeki tam geri besleme mekanizması çıkarımdır; doğrulanan değişiklik gözlem kapsamının daralmasıdır.

- Uygulamanın gerçek App/Scene/Commands yapısıyla iki geçici DEBUG uygulaması oluşturuldu. Aynı yerel veri kopyaları kullanıldı; sistem hizmetleri, gerçek ses kaydı ve model çalıştırma bu denemede kapalıydı. Ses düğmelerinin görünürlüğü için yalnız kullanılabilirlik yer tutucuları vardı; ses oynatma bu testin kapsamı değildir.
- A mevcut uygulama kapsamındaki gözlemciyi, B yalnız komut kapsamındaki gözlemciyi kullandı. Kullanıcı aynı toplantıyı öndeki pencerede kaydırarak **A kasıyor, B akıcı** sonucunu bildirdi. Uygulamaların kendi işlem CPU süreleri de bu farkı destekledi. Bu kısa deneme için genel bir hızlanma yüzdesi verilmez.
- Kullanıcı B penceresinde ⌘K aramasının açıldığını ayrıca doğruladı.
- Geçici kayıt kopyaları ve ham performans raporları depoya veya yayın dosyalarına eklenmedi. Gerçek kullanıcı arşivi bu testler için değiştirilmedi.
- 660 Swift testi (13 donanım/isteğe bağlı kontrol atlandı) ve 22 paketleme testi hatasız tamamlandı.

Uygulama içinden kurulum ve normal sürümdeki son kullanıcı kabulü yayın sonrasında ayrıca değerlendirilir.
