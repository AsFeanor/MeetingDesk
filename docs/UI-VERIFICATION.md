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
