# Toplantı — MeetingDesk

Mac üzerinde toplantı sesini kaydeden, yazılı döküm ve kaynak bağlantılı toplantı notları oluşturan kişisel macOS uygulaması. Kaynak proje adı `MeetingDesk`, uygulamanın görünen adı **Toplantı**.

## Neler yapıyor?

- Seçilen mikrofon ve Mac'te çalan sistem sesi birlikte kaydedilir. Mikrofon güçlendirmesi seçilebilir; birleşik, yalnız mikrofon ve yalnız sistem kayıtları saklanır.
- Türkçe veya İngilizce konuşma seçilen dilde Apple'ın yerel konuşma/dikte modeliyle yazıya çevrilir. Yerel döküm zaman damgalıdır; otomatik konuşmacı ayrımı yapmaz.
- Apple Intelligence dökümden özet, karar, aksiyon ve açık sorular çıkarır. Kaynak bağlantıları konuşmanın ilgili bölümüne götürür.
- Döküm düzenlenebilir; toplantı notu ve tam döküm Markdown olarak dışa aktarılabilir.
- Sparkle ile uygulama içinden imzalı güncelleme denetlenir, indirilir ve kullanıcı onayıyla kurulur.

## Gereksinimler

Kayıt arayüzü macOS 15 ve üzerini hedefler. Ücretsiz yerel transkript için macOS 26+, yerel özet için desteklenen Mac'te hazır Apple Intelligence gerekir. İlk kullanımda konuşma modeli indirilebilir. Yerel özelliklerin kullanılabilirliği uygulamada gösterilir.

Kaynak kodu derlemek için **Xcode 26.4+** ve macOS 26.4+ SDK gerekir. İlk derlemede SwiftPM sabitlenmiş Sparkle 2.10.0 paketini indirir. Paketlenen uygulama derlendiği Mac'in mimarisindedir; mevcut Apple Silicon dağıtımı Intel üzerinde çalışmaz.

## Gizlilik ve kayıtlar

**Mac'te ücretsiz** modunda ses ve döküm Mac'te işlenir. OpenAI modu ayrıca seçilirse ses ve metin ilgili API'ye gönderilir ve API ücretlendirmesi geçerlidir. API anahtarı macOS Anahtar Zinciri'nde tutulur.

Toplantı arşivi `~/Library/Application Support/MeetingDesk` içindedir. GitHub kaynak deposu ve güncelleme paketleri toplantı arşivini içermez. Güncellemeler uygulama paketini değiştirir; toplantı verisinin yeri aynıdır. Arşivin ayrıca yedeklenmesi yararlıdır.

Güncelleme denetimi yalnız sürüm beslemesini ve uygulama paketini indirir. Tamamen özel dağıtım seçilmişse GitHub erişim belirteci kişisel Anahtar Zinciri'nde tutulur. Kaynak depoya belirteç veya özel imza anahtarı eklenmez.

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

Sparkle güncelleme altyapısına sahip sürüm **bir kez kurulmalıdır**. Önceki sürümler bu altyapıyı içermediğinden kendilerini güncelleyemez. Sonraki sürümler uygulamadaki **Güncellemeleri kontrol et…** seçeneğiyle kurulur. Kayıt ve not işleme sırasında güncelleme kurulumu ertelenir.

Güncelleme ZIP'i yalnız `Toplanti.app` içerir. Kaynak kod, kayıtlar ve dışa aktarılan notlar ZIP'e eklenmez. Ed25519 imzası güncellemenin yayıncıdan geldiğini doğrular. Mevcut ad hoc Apple kod imzası notarizasyon değildir; geniş dağıtım için Developer ID ve notarizasyon ayrıca yapılandırılabilir.

[Sürüm yayımlama rehberi](docs/RELEASING.md), ilk kurulumdan yerel veya GitHub Actions ile sonraki sürümlerin yayımlanmasına kadar gerekli adımları içerir.

## Teknik yapı

SwiftPM, SwiftUI/AppKit, ScreenCaptureKit, AVFoundation, Speech, FoundationModels ve Sparkle. `Sources/MeetingDesk` uygulamayı, `Tests/MeetingDeskTests` testleri, `Packaging` dağıtım araçlarını içerir. Güncelleme altyapısı için [Sparkle belgeleri](https://sparkle-project.org/documentation/) ve [yayın rehberi](https://sparkle-project.org/documentation/publishing/) esas alınır.
