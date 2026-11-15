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
