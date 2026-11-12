# Mac'e kurulum ve güncelleme

## Gereksinimler

Mevcut dağıtım Apple Silicon Mac içindir. Kayıt için macOS 15+, ücretsiz yerel transkript için macOS 26+ gerekir. Yerel özet için desteklenen Mac'te Apple Intelligence açık olmalı ve modelleri indirilmiş olmalıdır. Dil/özellik kullanılabilirliği uygulamanın ayarlarında gösterilir.

## İlk kurulum

1. [GitHub sürümleri](https://github.com/AsFeanor/MeetingDesk/releases) sayfasından en güncel kararlı sürümün `Toplanti-VERSION.zip` dosyasını indirin.
2. ZIP'i açın ve içindeki **Toplanti.app** uygulamasını Finder'da **Uygulamalar** klasörüne taşıyın.
3. Daha önceki Toplantı uygulamasını kapatın; yeni kopyayı Uygulamalar klasöründen açın. İsterseniz bu kopyayı Dock'a ekleyin.
4. İlk kayıtta macOS'un mikrofon ve sistem sesi izinlerini verin. Uygulamadaki mikrofon seçiminizi ve konuşma dilinizi kontrol edin.

**0.5.3 veya önceki bir sürümden geçiyorsanız bu adımları bir kez elle uygulayın.** Eski imzalama anahtarına erişilemediği için 0.5.5 yeni anahtar kullanır; eski uygulama yeni güncelleme imzasını doğrulayamaz. Çalışan kayıt veya not hazırlama işlemi bittikten sonra eski uygulamayı kapatın ve Uygulamalar klasöründeki kopyayı yenisiyle değiştirin. Toplantı arşivini silmeyin. 0.5.5 ve daha yeni sürümler aynı uygulama üzerinden güncellenebilir. Uygulamayı ZIP'in içinden veya geçici indirme klasöründen çalıştırmak yerine kalıcı Uygulamalar klasörüne taşıyın.

Sürümler sayfasında henüz uygulama ZIP'i görünmüyorsa aşağıdaki kaynak koddan derleme yolu kullanılabilir. İmzalama yapılandırması boş bırakılmış yerel geliştirme paketi uygulama içi güncelleme alamaz; resmi release paketinin içine doğrulama anahtarı ve besleme adresi eklenir.

## macOS ilk açılışı engellerse

Mevcut paket ad hoc kod imzalıdır; Apple Developer ID ile notarize edilmiş değildir. Mac ilk açılışta geliştirenin doğrulanamadığını belirtebilir. Doğrudan bu projenin sürümünü indirdiyseniz Apple'ın [ilk açılış rehberindeki](https://support.apple.com/102445) uygulamaya özel onay adımlarını kullanabilirsiniz. **Sistem Ayarları → Gizlilik ve Güvenlik** altında, uygulamayı açma denemesinden sonra ilgili **Yine de Aç** seçeneği görünebilir. Sparkle güncelleme imzası Apple'ın ilk açılış onayından ayrı çalışır.

## Sonraki güncellemeler

0.5.5 kurulduktan sonra üst menü veya uygulama ayarlarından **Güncellemeleri kontrol et…** seçeneğini kullanın. Yeni sürüm varsa değişiklikler gösterilir; onay verdiğinizde indirilir, imzası doğrulanır ve uygulama yeniden açılarak kurulur. Kayıt veya transkript/özet işlemi sürerken güncelleme ve yeniden açma ertelenir.

Herkese açık GitHub dağıtımında güncelleme için API anahtarı veya GitHub belirteci gerekmez. Güncelleme denetimi toplantı sesini ve transkripti yüklemez.

Güncelleme, uygulama paketini yeniler. Toplantı arşivi aynı yerde kalır:

```text
~/Library/Application Support/MeetingDesk
```

## 0.5.5 ile ilk deneme

Yeni toplantıda **Sesimi kontrol et** düğmesiyle 10 saniye konuşup yalnız mikrofon sesini dinleyin. İsterseniz **Kaydı bitirince transkript ve özeti Mac’te hazırla** seçeneğini açın; bu özellik yalnız ücretsiz yerel modda çalışır. Şablonla özetin odağını ve bölüm düzenini seçebilirsiniz; eski bir notun şablonunu değiştirdikten sonra **Özeti yenile** kullanın. **Notları düzenle** ile düzeltme yapabilir ve **Paylaş** önizlemesinden kişisel notları dahil etmeden PDF/metin çıktısı alabilirsiniz. Notion’a aktarım için bağlantıyı bir kez ayarlayın; toplantı hatırlatıcısını isterseniz ayarlardan açın. [İş akışı rehberi](WORKFLOW.md).

Ses saklama süresini **Ayarlar → Ses kayıtlarını saklama** bölümünden seçip **Uygula** ile kaydedebilirsiniz. Otomatik silme başlangıçta kapalıdır; süre dolan sesler Çöp Sepeti’ne taşınırken transkript ve özetler kalır. Otomatik silmeyi etkinleştirirken veya süreyi kısaltırken mevcut eski kayıtların da etkileneceği açıklanır.

Önceki toplantılarda aksiyonlar boş kaldıysa veya kaynak bağlantısı hatası aldıysanız 0.5.5'i kurduktan sonra aynı toplantıyı açıp istediğiniz şablonla **Özeti yenile** kullanın. Mevcut transkript yeniden kullanılabilir; ses kaydını yeniden çözmek gerekmez.

## Kaynak koddan derleme

Git ve Xcode 26.4+ ile macOS 26.4+ SDK gerekir:

```sh
git clone https://github.com/AsFeanor/MeetingDesk.git
cd MeetingDesk
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache"
swift test --disable-sandbox --disable-keychain --cache-path .build/cache --scratch-path .build
zsh Packaging/build.sh dist/local
```

Derlenen `dist/local/Toplanti.app` uygulamasını Finder ile Uygulamalar klasörüne taşıyın. Aynı hedefte mevcut paket varsa derleme üzerine yazmaz; sonraki deneme için yeni bir çıktı klasörü seçin. Güncelleme yapılandırması boşsa uygulama kayıt/transkript/özet özellikleriyle kullanılabilir, güncelleyici kapalı kalır.

Geliştirme ve yeni sürüm yayımlama adımları için [README](../README.md) ve [yayın rehberi](RELEASING.md) dosyalarına bakın.

## Konuşmacı tanıma ve hatırlanan kişiler

Ayarlar → Konuşmacılar ve ses profilleri bölümünden modelleri bir kez indirin. Transkript → Konuşmacıları düzenle seçeneğinde kısa örneği dinleyin, “Bu kim?” sorusunda mevcut kişiyi seçin veya yeni isim yazın. Aynı kişinin başka örneklerini de listeden aynı kişiye bağlayabilirsiniz. Kaydet ve devam et ile sonraki sese geçin. Bu işlem sadece o toplantıdaki isimleri değiştirir.

Sonraki toplantılarda da tanınmasını istediğiniz ses için, dinledikten sonra “Dinlediğim bu sesi sonraki toplantılarda tanı” seçeneğini onaylayın. Bu onay yeni transkriptlerde otomatik tanımayı da açar. Güçlü eşleşmeler isimlendirilir, belirsiz eşleşmeler onay bekler.

Kenar çubuğundaki **Kişiler** ekranında isimleri ve ilgili toplantıları görebilir, hatırlanan ses profilinin adını değiştirebilir veya **Sesini unut** seçeneğini kullanabilirsiniz. Sesi hatırlatılmadan isim verilen kişiler de bu listede görünür. Silmek eski toplantılardaki yazılı isimleri değiştirmez; kayıtların otomatik silinmesi de ses profillerini silmez. Ses kaydı silinmiş toplantılarda yeni örnek dinlenemez veya hatırlatılamaz. Eski dökümlerde mevcut ses aralıkları isimlendirme için kullanılır; daha hassas kelime düzeyi ayrım için dökümü yeniden oluşturabilirsiniz.
