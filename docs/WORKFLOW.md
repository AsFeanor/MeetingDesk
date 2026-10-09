# Toplantı iş akışı · 0.5.1

## Kayıttan önce

Yeni toplantıda konuşma dilini ve Genel/Ekip/Ürün/Müşteri şablonunu seçin. **Sesimi kontrol et** ile 10 saniye konuşup **Sesimi dinle** düğmesini kullanın. Uyarı düşük/sıfır/yüksek mikrofon girişini gösterir; netlik için kendi sesinizi dinleyin. Deneme kaydı geçicidir, toplantı arşivine eklenmez.

**Kaydı bitirince transkript ve özeti Mac’te hazırla** seçeneği isteğe bağlıdır ve yalnız Mac’te ücretsiz modunda çalışır. İlk dil modeli indirmesi internet gerektirebilir. OpenAI modunda otomatik işlem başlamaz. Kayıt ve not hazırlama sırasında güncelleme kurulumu bekler.

## Döküm ve notlar

Ayrı sesleri olan kayıtlarda mikrofon ve toplantı sesi ayrı çözülür. “Mikrofon” tek kişi kimliği değildir; odadaki birden fazla kişiyi alabilir. “Toplantı sesi” birden fazla uzaktaki katılımcıyı içerebilir. Kulaklık, karşı tarafın sesinin mikrofona geri girmesini azaltır. Yalnız kuvvetle örtüşen, aynı uzun ifade kaynaklar arasında tekrarlanmışsa olası yankı elenir; farklı konuşmalar korunur.

**Notları düzenle** bir taslak açar. Kaydetmeden kapatırsanız not değişmez. Sorumlu veya tarih bilinmiyorsa boş bırakın. Kaynak bağlantıları korunur; elle eklediğiniz maddeler ayrıca gösterilir. Yenilemede düzeltmeler korunur; eşleşmesi belirsiz eski düzeltme veya tamamlanmış iş ayrı tutulur. Bu nedenle yeni notları kaynaklarıyla kontrol edin. Kaynağı eksik eski notlar güncel olarak onaylanamaz.

**Kontrol edildi olarak işaretle** değerlendirme durumudur. Döküm, not veya şablon değişince işaret kalkar. Menüdeki **Önceki nota dön** yalnız notları, düzenleme bilgilerini ve görevlerin durumunu geri getirir; ses ve dökümü değiştirmez. Döküm kaynağı farklıysa eski not güncel olarak gösterilmez.

## Toplantı şablonları

**Genel toplantı** özet, karar, aksiyon ve açık soruları dengeli gösterir. **Ekip toplantısı** durum/ilerleme, engeller/bağımlılıklar ve sonraki adımları; **Ürün değerlendirmesi** ihtiyaçlar/problemler, geri bildirimler ve seçenekleri; **Müşteri görüşmesi** müşteri ihtiyaçları, endişeler/beklentiler ve takip konularını öne çıkarır. Kaynakta bilgi yoksa bölüm doldurulmaz.

Şablon değiştirip **Özeti yenile** kullanın. Başarılı yenilemeye kadar mevcut not eski şablonuyla gösterilir ve bu durum açıklanır. Eski dosyalarda üretim şablonu bilinmediğinden genel düzen kullanılır. Başka şablona ait elle düzeltilmiş özet, yeni model özetinin yerine geçmez; **Korunan özet düzeltmesi** adıyla ayrı bir konu notu olarak saklanır. Aynı şablonu yenilerken düzeltmeler korunur. Not sürümünü geri getirmek üretildiği şablonu da geri getirir. Ekran, düzenleyici ve bütün paylaşım biçimleri aynı başlık/sırayı kullanır.

## Paylaşım

**Paylaş** ekranında Özet ve kararlar / Sadece aksiyonlar / Tüm transkript seçin. Önizleme, kopyalama ve dosyalar aynı seçili içeriği kullanır. **Kendi notlarımı dahil et** başlangıçta kapalıdır; her paylaşımda bilinçli olarak açılmalıdır. PDF metin olarak seçilebilir ve uzun toplantılarda sayfalara bölünür. Özet/aksiyon çıktılarında kaynak zamanı gösterilir; tam Markdown dökümde zaman bağlantıları konuşma bölümlerine gider.

## Ses kayıtlarını saklama · 0.5.1

**Ayarlar → Ses kayıtlarını saklama** bölümünden 7, 30, 90, 180 veya 365 gün seçin; **Özel süre…** ile 1–3650 gün belirleyebilirsiniz. Varsayılan **Otomatik silme kapalı**dır. Değişikliği **Uygula** ile kaydedin. Otomatik silmeyi açarken veya süreyi kısaltırken, süreyi doldurmuş mevcut ses kayıtlarının da etkileneceği gösterilir ve onay istenir.

Süre dolunca birleşik kayıt, mikrofon ve toplantı sesi dosyaları Mac’in **Çöp Sepeti**’ne taşınır. Transkript, özet, kişisel notlar, kontrol durumu ve önceki metin sürümleri arşivde kalır; okunabilir ve paylaşılabilir. Ses kaldırılınca uygulama bunu belirtir; bu kayıt artık dinlenemez veya yeniden transkripte çevrilemez. Diskteki alan Çöp Sepeti boşaltılınca geri kazanılır.

Süre, sesin kaydedildiği veya içe aktarıldığı tarihten başlar. Eski arşivlerde toplantı tarihi ile ses dosyalarının son değiştirilme tarihlerinden en yenisi kullanılır; eski toplantıya yeni eklenen ses hemen temizlenmez. Uygulama açılınca ve açık kaldığı sürece yaklaşık saatte bir kontrol edilir. Uygulama kapalıyken temizlik çalışmaz. Kayıt, kurtarma, mikrofon denemesi, dinleme, transkript/özet hazırlama veya Notion aktarımı sürerken kontrol ertelenir; duraklatılmış dinleme de ses dosyalarını korur. Yarım kalmış kayıt kurtarma dosyaları temizlenmez.

Bir ses dosyası taşınamazsa kalan dosyalar korunur ve sonraki kontrolde yeniden denenir. Bütün ses dosyaları kaldırılmadan toplantı tamamıyla temizlenmiş olarak işaretlenmez. Otomatik testler geçici arşiv ve sahte taşıma işlemleri kullanır; gerçek kullanıcı arşivine veya Çöp Sepeti’ne dokunmaz.

## Arama

Arşiv araması başlık, döküm, kararlar, aksiyonlar, sorumlu, tarih, açık sorular, konu notları ve kişisel notları kapsar. Birden fazla kelime farklı alanlarda bulunabilir. Türkçe karakterleri yazmadan da arayabilirsiniz.

## Doğrulama sınırı

Otomatik testler sentetik ses/metin ve geçici arşiv kullanır. Gerçek mikrofon alımı, Apple'ın bu Mac'teki konuşma/özet modelinin sonucu ve uygulama içi güncelleme kurulumu ayrıca gerçek kullanımda doğrulanmalıdır. Hiçbir test kullanıcı arşivini düzenlemez veya gerçek toplantıyı ücretli API'ye göndermez.

## Notion’a aktar · 0.5.0

Önce **Ayarlar → Notion’a aktar** bölümündeki **Notion bağlantısı oluştur** bağlantısını açın. Notion’da bir **iç entegrasyon** oluşturun; içerik okuma ve ekleme izinlerini verin. Notion’daki hedef üst sayfanın **••• → Bağlantılar → Bağlantı ekle** menüsünden bu entegrasyonu ekleyin. Entegrasyon anahtarı ve hedef sayfa bağlantısını uygulamaya kaydedin. Anahtar Mac’in Anahtar Zinciri’nde tutulur; GitHub’a veya toplantı dosyalarına yazılmaz.

**Paylaş** ekranında içeriği seçip önizlemeyi kontrol edin; **Notion’a aktar** seçili metni hedefin altında yeni bir sayfa olarak oluşturur. Özet ve kararlar için başlıklar, aksiyonlar için işaretlenebilir görevler, tam transkript için katlanabilir bir bölüm kullanılır. **Kendi notlarımı dahil et** yine başlangıçta kapalıdır. Ses dosyası gönderilmez. **Notion’da aç** ile sayfaya gidebilirsiniz.

Aktarım yarıda kalırsa oluşan sayfa bağlantısı korunur. Yanıt kaybolduğunda Notion yazmış olabileceğinden işlem kendiliğinden tekrarlanmaz. Hedefi kontrol ettikten sonra **Kontrol ettim; yeni kopya oluşturabilirim** düğmesi yeni sayfa oluşturmayı yeniden açar. Eksik kopya uygulama tarafından silinmez veya üzerine yazılmaz. Notion çalışma alanının erişim, API ve blok sınırları ayrıca geçerlidir.

Resmî belgeler: [İç entegrasyon izinleri](https://developers.notion.com/guides/get-started/authorization), [sayfa içeriği](https://developers.notion.com/guides/data-apis/working-with-page-content), [istek ve içerik sınırları](https://developers.notion.com/reference/request-limits).

## Toplantı hatırlatıcısı ve kayıt kartı · 0.5.0

**Ayarlar → Toplantı hatırlatıcısı → Toplantıda olabileceğimi algıla ve kaydı hatırlat** isteğe bağlıdır ve başlangıçta kapalıdır. Yerel Zoom, Teams, Webex, FaceTime ve Slack süreçlerinin aktif mikrofon kullanımını kontrol eder; uygulamanın açık olması veya ses çalması tek başına yeterli değildir. Toplantı'nın kendi kayıt/deneme mikrofonu öneri oluşturmaz. Kısa mikrofon denemelerini azaltmak için sinyal yaklaşık 6 saniye sürmelidir. Buna rağmen görüşme öncesi mikrofon testi de öneri oluşturabilir; bir görüşmeye katıldığınız kesin olarak bilinmez.

Chrome, Edge, Brave, Chromium ve Safari için aynı tarayıcının aktif mikrofonu ile tanınan **görünür** Google Meet/Teams/Zoom/Webex penceresi birlikte gerekir. Pencere başlığı yalnız zaten verilmiş ekran izni varsa kontrol edilir, saklanmaz veya gönderilmez. Bazı Safari mikrofonları ortak WebKit sürecine ait olduğundan güvenle eşlenemez ve algılanmayabilir. Başka sekmenin mikrofonu ile toplantı sekmesi ayırt edilemez. Mikrofonu kapalı görüşmeler, arka plandaki görünmez toplantı sekmeleri ve tanınmayan uygulamalar kaçırılabilir. Algılama ses dinlemez, kayıt akışı oluşturmaz ve yeni izin istemez.

Öneri kartında **Kayda başla** kayıt başlatır; hiçbir kayıt otomatik başlamaz. Öneriyi kapatırsanız aynı mikrofon oturumu sürerken tekrar gelmez. Sinyal yaklaşık 20 saniye kaybolursa yeniden önerilebilir. Kayıt, deneme, not hazırlama veya Notion aktarımı sırasında öneriler bekler.

**Kayıt sırasında küçük kontrol kartını göster** başlangıçta açıktır. Kayıt süresi, mikrofon/toplantı sesi seviyeleri ve duraklat/devam et/bitir ve sakla kontrolleri bu karttadır. Kartı başka yere sürükleyebilirsiniz; başka uygulamadaki odağı almaz. Çarpı yalnız kartı gizler, kaydı durdurmaz. Menü çubuğundaki Toplantı simgesinden **Kayıt kartını göster** ile yeniden açılır. Bitir/sakla, uygulamanın normal güvenli saklama ve isteğe bağlı transkript/özet akışını kullanır; güncelleme veya çıkış işi yarıda kesmez.

Doğrulama sınırı: Notion testleri sahte sunucu/anahtar, algılama testleri sentetik süreç/pencere sinyalleri kullanır. Bu testler gerçek bir Notion çalışma alanına yazmaz ve gerçek görüşme algılamasını ya da mikrofon alımını kanıtlamaz.
