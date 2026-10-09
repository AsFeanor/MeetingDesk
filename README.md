# Toplantı — MeetingDesk

Mac üzerinde toplantı sesini kaydeden, yazılı döküm ve kaynak bağlantılı toplantı notları oluşturan kişisel macOS uygulaması. Kaynak proje adı `MeetingDesk`, uygulamanın görünen adı **Toplantı**.

## Kurulum

Güncellenebilir sürüm **0.5.0** yayımlandı. [En güncel GitHub sürümünü](https://github.com/AsFeanor/MeetingDesk/releases/latest) indirip uygulamayı bir kez Uygulamalar klasörüne taşıyın. Sonraki sürümler uygulamanın **Güncellemeleri kontrol et…** seçeneğiyle kurulabilir. [Adım adım kurulum rehberi](docs/INSTALLATION.md).

## Neler yapıyor?

- Seçilen mikrofon ve Mac'te çalan sistem sesi birlikte kaydedilir. Mikrofon güçlendirmesi seçilebilir; birleşik, yalnız mikrofon ve yalnız sistem kayıtları saklanır.
- Türkçe veya İngilizce konuşma seçilen dilde Apple'ın yerel konuşma/dikte modeliyle yazıya çevrilir. Yerel döküm zaman damgalıdır; ayrı ses kaynaklarını etiketler, kişi kimliğini otomatik tanımaz.
- Apple Intelligence dökümden özet, karar, aksiyon ve açık sorular çıkarır. Kaynak bağlantıları konuşmanın ilgili bölümüne götürür.
- Kayıttan önce 10 saniyelik ses denemesi yapılabilir; deneme yalnız mikrofonu dinletir ve kapatıldığında geçici sesler silinir.
- Ayrı mikrofon ve sistem kayıtları ayrı çözülüp zaman sırasına birleştirilir. Kaynak etiketleri “Mikrofon” ve “Toplantı sesi”dir; karşı taraftaki kişileri tek tek tanımaz. Eski veya içe aktarılan birleşik kayıtlar açık bir bilgiyle birleşik olarak çözülür.
- Özet, kararlar, aksiyonlar, sorumlu/tarih, sorular, fikirler ve konular düzenlenebilir. Manuel düzeltmeler ve tamamlanan görevler yenilemede korunur; önceki not sürümüne dönülebilir. Kontrol edilen notlar işaretlenebilir.
- Paylaşım önizlemesinden özet/kararlar, yalnız aksiyonlar veya tüm notlar ve döküm seçilir; metin kopyalanabilir, Markdown ve çok sayfalı seçilebilir metin içeren PDF kaydedilebilir. Kişisel notlar varsayılan olarak paylaşılmaz.
- İsteğe bağlı otomatik hazırlama kaydı bitirince transkripti, ardından özeti **yalnız ücretsiz yerel modda** oluşturur. Özet/model hatası veya iptal, kaydedilmiş dökümü silmez.
- Arşivde başlık, döküm, kararlar, aksiyonlar, sorumlu/tarih, kişi adları ve kişisel notlar birlikte aranabilir.
- Genel, ekip, ürün ve müşteri şablonları hem özetin odağını hem bölüm düzenini değiştirir. Ekip şablonunda ilerleme/engeller, ürün şablonunda ihtiyaçlar/geri bildirim/seçenekler, müşteri şablonunda ihtiyaçlar/endişeler öne çıkar. Şablon değiştirdikten sonra **Özeti yenile** kullanılır; söylenmemiş sorumlu, tarih veya karar eklenmez.
- Ses kayıtları için isteğe bağlı 7/30/90/180/365 gün veya özel saklama süresi. Süresi dolan sesler Çöp Sepeti’ne taşınır; transkript, özet ve kişisel notlar korunur. Varsayılan kapalıdır.
- Sparkle ile uygulama içinden imzalı güncelleme denetlenir, indirilir ve kullanıcı onayıyla kurulur.

[İş akışı rehberi](docs/WORKFLOW.md).

### 0.5.0 ile gelenler

Notion’a doğrudan aktarım, isteğe bağlı toplantı hatırlatıcısı ve şablona göre bölüm düzeni eklendi. Şablon değişince yeni özet kullanılır; önceki elle yazılmış özet düzeltmesi ayrı bir konu notu olarak korunur. Uygulama, Markdown, PDF ve Notion aynı bölüm düzenini kullanır. Paylaşım ekranında seçilen içerik yerel Notion başlıkları/görev kutuları ve katlanabilir transkript olarak yeni bir alt sayfaya gönderilir. Bağlantı anahtarı bir kez Anahtar Zinciri’ne kaydedilir; ses gönderilmez.

Toplantı hatırlatıcısı desteklenen uygulamanın mikrofon sinyaline bakar, kayıt başlatmaz. Kayıt kartından süre, iki ses göstergesi, duraklat/devam et ve bitir/sakla kullanılabilir. Algılama başlangıçta kapalıdır; mikrofon kapalı görüşmeler ve bazı tarayıcılar algılanmayabilir. Bu özelliklerin ayrıntıları ve sınırları [iş akışı rehberinde](docs/WORKFLOW.md) açıklanır. Kararlı sürüm için yukarıdaki GitHub Releases bağlantısını kullanın.

## Gereksinimler

Kayıt arayüzü macOS 15 ve üzerini hedefler. Ücretsiz yerel transkript için macOS 26+, yerel özet için desteklenen Mac'te hazır Apple Intelligence gerekir. İlk kullanımda konuşma modeli indirilebilir. Yerel özelliklerin kullanılabilirliği uygulamada gösterilir.

Kaynak kodu derlemek için **Xcode 26.4+** ve macOS 26.4+ SDK gerekir. İlk derlemede SwiftPM sabitlenmiş Sparkle 2.10.0 paketini indirir. Paketlenen uygulama derlendiği Mac'in mimarisindedir; mevcut Apple Silicon dağıtımı Intel üzerinde çalışmaz.

## Gizlilik ve kayıtlar

**Mac'te ücretsiz** modunda ses ve döküm Mac'te işlenir. OpenAI modu ayrıca seçilirse ses ve metin ilgili API'ye gönderilir ve API ücretlendirmesi geçerlidir. API anahtarı macOS Anahtar Zinciri'nde tutulur. Notion aktarımı yalnız seçili paylaşım metnini gönderir; Notion anahtarı ayrı bir Anahtar Zinciri kaydıdır.

Toplantı arşivi `~/Library/Application Support/MeetingDesk` içindedir. GitHub kaynak deposu ve güncelleme paketleri toplantı arşivini içermez. Güncellemeler uygulama paketini değiştirir; toplantı verisinin yeri aynıdır. Arşivin ayrıca yedeklenmesi yararlıdır.

Kaynak kod ve sürüm paketleri aynı herkese açık [AsFeanor/MeetingDesk deposunda](https://github.com/AsFeanor/MeetingDesk) yayımlanır. Güncelleme denetimi yalnız sürüm beslemesini ve uygulama paketini indirir; GitHub hesabı veya belirteç gerektirmez. Kaynak depoya belirteç veya özel imza anahtarı eklenmez. Toplantı sesleri, transkriptleri ve kişisel notlar depoya veya release paketine dahil edilmez.

## Geliştirme

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache"
swift test --disable-sandbox --disable-keychain --cache-path .build/cache --scratch-path .build
python3 -m unittest discover -s Packaging -p 'test_*.py'
zsh Packaging/build.sh dist/development
```

Paket `dist/development/Toplanti.app` olur. Aynı çıktı klasöründeki mevcut uygulama üzerine yazılmaz; yeni derleme için yeni bir çıktı klasörü seçin. Uygulamayı Finder'dan çalıştırın. Kayıt için macOS'un mikrofon ve sistem sesi izinleri gerekir. Kabuk veya CI ortamında ses kodeği erişilemeyebilir; bu testler açıkça atlanır. CI testleri gerçek mikrofon kaydı veya Apple Intelligence model çalışmasını doğrulamaz.

Geliştirme sırasında bu depoda değişiklik yapıp test edin; kalıcı uygulamayı yenilemek için yeni sürüm yayımlayın. Güncelleme kaynağı ve kamuya açık imza anahtarı `Packaging/release-config.json` içindedir. Derleme aynı ayarları uygulamaya ekler.

## Güncellemeler ve sürüm yayımlama

Sürümler bu kaynak deposunun [GitHub Releases sayfasında](https://github.com/AsFeanor/MeetingDesk/releases) yayımlanır. Kamuya açık güncelleme adresi `https://github.com/AsFeanor/MeetingDesk/releases/latest/download/appcast.xml` olur. İmzalama özel anahtarı yerel Anahtar Zinciri'nde tutulur; yalnız kamuya açık anahtar ve besleme adresi uygulamaya eklenir. Yerel yayın için CI secret gerekmez. GitHub Actions ile otomatik imzalı yayın ayrıca ilgili secret yapılandırmasını ve `ENABLE_AUTOMATED_RELEASES=true` repository variable’ını gerektirir; varsayılan olarak kapalıdır.

Sparkle güncelleme altyapısına sahip sürüm **bir kez kurulmalıdır**. Önceki sürümler bu altyapıyı içermediğinden kendilerini güncelleyemez. Sonraki sürümler uygulamadaki **Güncellemeleri kontrol et…** seçeneğiyle kurulur. Kayıt ve not işleme sırasında güncelleme kurulumu ertelenir.

Güncelleme ZIP'i yalnız `Toplanti.app` içerir. Kaynak kod, kayıtlar ve dışa aktarılan notlar ZIP'e eklenmez. Ed25519 imzası güncellemenin yayıncıdan geldiğini doğrular. Mevcut ad hoc Apple kod imzası notarizasyon değildir; geniş dağıtım için Developer ID ve notarizasyon ayrıca yapılandırılabilir.

[Sürüm yayımlama rehberi](docs/RELEASING.md), ilk kurulumdan yerel veya GitHub Actions ile sonraki sürümlerin yayımlanmasına kadar gerekli adımları içerir.

## Teknik yapı

SwiftPM, SwiftUI/AppKit, ScreenCaptureKit, AVFoundation, Speech, FoundationModels ve Sparkle. `Sources/MeetingDesk` uygulamayı, `Tests/MeetingDeskTests` testleri, `Packaging` dağıtım araçlarını içerir. Güncelleme altyapısı için [Sparkle belgeleri](https://sparkle-project.org/documentation/) ve [yayın rehberi](https://sparkle-project.org/documentation/publishing/) esas alınır.

## Lisans

Kaynak kod [MIT lisansı](LICENSE) ile sunulur. Sparkle ve içindeki üçüncü taraf bileşenlerin lisansları [üçüncü taraf bildirimlerinde](THIRD_PARTY_NOTICES.md) yer alır. Bildirimler derlenmiş uygulama paketine de dahil edilir.
