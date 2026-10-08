# Toplantı sürümleri

## Dağıtım biçimi

Kaynak kod deposu ile güncelleme deposu ayrı olabilir. İki desteklenen seçenek vardır:

1. **Özel kaynak + herkese açık güncelleme deposu:** kaynak kod özel kalır, derlenmiş uygulama ZIP'i ve imzalı `appcast.xml` herkese açık olur. Uygulama GitHub hesabı istemeden güncellenir.
2. **Tamamen özel depo:** kaynak, uygulama ZIP'i ve besleme özel kalır. Uygulamaya yalnız güncelleme deposunda `Contents: read` yetkisi olan kişisel GitHub belirteci girilir. Belirteç Anahtar Zinciri'nde saklanır. Yayınlama için ayrı yazma yetkisi gerekir.

Dağıtım biçimi kullanıcının tercihidir. Depo görünürlüğü yayın aracı tarafından doğrulanır; gizli yapılandırma ile herkese açık depo veya tersi kabul edilmez. Güncelleme deposunun varsayılan dalında ilk `README` commit'i olmalıdır. Herkese açık dağıtımda besleme ve uygulama ZIP'i aynı release'te bulunur; kaynağın güncelleme deposuna kopyalanması gerekmez.

## Bir defalık yapılandırma

Önce bağımlılığı indirip paketi oluşturun:

```sh
zsh Packaging/build.sh dist/bootstrap-unconfigured
```

Sparkle imza anahtarını bir kez oluşturun. Bu işlem özel anahtarı Anahtar Zinciri'ne kaydeder ve kamuya açık anahtarı gösterir:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account AsFeanor/MeetingDesk
```

Özel anahtarı koruyun; mevcut ad hoc dağıtımda anahtar kaybolursa güvenli anahtar geçişi için elle kurulum gerekebilir. Bu projeye ayrılmış Anahtar Zinciri hesabı `AsFeanor/MeetingDesk` olarak seçilmiştir. Başka hesap kullanılacaksa `signingAccount` alanını veya yayın sırasında `SPARKLE_KEYCHAIN_ACCOUNT` ortam değişkenini aynı ada ayarlayın.

`Packaging/release-config.json` dosyasına yalnız kamuya açık ayarları yazın:

```json
{
  "updateRepository": "OWNER/MeetingDesk-Updates",
  "feedURL": "https://github.com/OWNER/MeetingDesk-Updates/releases/latest/download/appcast.xml",
  "publicEDKey": "SPARKLE_GENERATE_KEYS_PUBLIC_KEY",
  "privateUpdates": false,
  "signingAccount": "AsFeanor/MeetingDesk"
}
```

Tamamen özel dağıtımda `privateUpdates: true` ve besleme adresi şu olur:

```text
https://api.github.com/repos/OWNER/MeetingDesk/contents/appcast.xml?ref=main
```

Özel beslemede `main` yerine güncelleme deposunun gerçek varsayılan dalı kullanılmalıdır. Özel besleme GitHub Contents API'sinden ham XML olarak okunur; arşivler GitHub release asset API'si üzerinden indirilir. Sürüm notları beslemeye gömülür. Belirteç dağıtılan uygulamanın içine eklenmez.

Ortam değişkenleri `UPDATE_REPOSITORY`, `SU_FEED_URL`, `SU_PUBLIC_ED_KEY`, `PRIVATE_UPDATES` dosyadaki ayarları geçersiz kılabilir. Besleme, depo ve kamuya açık anahtar birlikte sağlanmalıdır. Bunların tamamı boşsa derleme yapılabilir, ancak güncelleyici yapılandırılmaz.

## İlk güncellenebilir sürüm

`Packaging/Info.plist` içindeki `CFBundleShortVersionString` kullanıcıya görünen sürüm, `CFBundleVersion` artan tam sayı yapı numarasıdır. İlk güncellenebilir sürüm `0.3.0` / yapı `5` olacak şekilde hazırlanmıştır.

```sh
zsh Packaging/build.sh dist/bootstrap
python3 Packaging/release.py publish --app dist/bootstrap/Toplanti.app --bootstrap
```

GitHub CLI yayınlayacak hesaba giriş yapmış olmalıdır. Yerel yayın imzası Anahtar Zinciri'nden okunur; araç özel anahtarı dosyaya yazmaz veya komut satırına koymaz. Kod deposundan farklı depo seçilecekse `--update-repo OWNER/MeetingDesk-Updates` kullanılabilir; bu değer uygulamaya gömülen yapılandırmayla eşleşmelidir.

Bu sürümü **bir kez** kalıcı uygulama klasörüne kurun. Daha önceki sürümlerde Sparkle bulunmadığından ilk geçiş elle yapılır. Sonraki güncellemeler aynı `Toplanti.app` adı ve `com.altugegesari.meetingdesk` kimliğiyle dağıtılmalıdır. Arşiv konumu değiştirilmez.

## Sonraki sürümler: yerel yayın

1. Kaynak değişikliklerini test edin ve commit edin.
2. `CFBundleShortVersionString` ve `CFBundleVersion` değerlerini artırın. Önceki bir yapı numarasını tekrar kullanmayın.
3. İstenirse `docs/release-notes.md` dosyasına bu sürümün kısa notlarını yazın.
4. Yeni çıktı klasöründe derleyin ve yalnız yerel imza doğrulamasını yapın.
5. Sürümün hazır olduğu doğrulandıktan sonra yayınlayın.

```sh
zsh Packaging/build.sh dist/v0.3.1
python3 Packaging/release.py publish --app dist/v0.3.1/Toplanti.app --prepare-only
python3 Packaging/release.py publish --app dist/v0.3.1/Toplanti.app --notes-file docs/release-notes.md
```

`--prepare-only` GitHub'dan salt okunur depo/besleme bilgisi alır ve yerel ZIP'i imzalar; release oluşturmaz ve beslemeyi değiştirmez. Kamuya açık anahtar ile ZIP imzası ayrıca CryptoKit kullanılarak doğrulanır.

Yayın akışı:

```text
Paket + ZIP imzasını doğrula
→ GitHub draft release oluştur
→ Uygulama ZIP'ini yükle
→ Asset adresiyle appcast oluştur ve imzala
→ İmzalı appcast.xml dosyasını aynı draft'a yükle
→ ZIP ve beslemeyi birlikte yayımla
```

Herkese açık besleme `/releases/latest/download/appcast.xml` adresinden gelir. ZIP ve besleme ikisi de draft'a yüklendikten sonra release yayımlandığı için güncelleme kaynağı tamamlanmış bir sürüme geçer. Yükleme veya yayın başarısızsa eski kararlı release korunur. Tamamen özel veya desteklenen ham XML beslemesi kullanıldığında ZIP önce yayımlanır; imzalı `appcast.xml` ardından tek commit ile güncellenir. Commit başarısız olursa önceki besleme çalışmaya devam eder.

Kesilen yayını aynı uygulama ve mevcut `dist/releases/vVERSION/Toplanti-VERSION.zip` ile `--resume` kullanarak tamamlayın. Araç aynı arşivi tekrar kullanır ve GitHub'daki arşivin SHA-256 değerini karşılaştırır; farklıysa durur ve üzerine yazmaz. Yayınlanan arşivleri değiştirmeyin; düzeltme için sürüm/yapı numarasını artırın.

Besleme en son tam paketi içerir; delta güncelleme üretilmez. `--bootstrap` besleme ilk kez oluşturulurken kullanılabilir ve mevcut beslemeyi sıfırlamaz. Actions yayınları aynı concurrency grubunda sırayla çalışır. Contents beslemesinde birden fazla eşzamanlı yayın aynı SHA ile yarışırsa GitHub commit kontrolü ikinci yayını durdurur. Aynı anda iki ayrı Mac'ten yerel yayın başlatmayın.

## GitHub Actions

`ci.yml` push/PR için test ve imzalı uygulama paketi oluşturur. `release.yml` `v*` kaynak tag'inde veya elle başlatıldığında test/build sonrası kararlı güncelleme yayınlar. Runner `macos-latest` kullanır ve macOS SDK'sının 26.4+ olduğunu açıkça kontrol eder. Runner'da yerel Apple Intelligence bulunması gerekmez; canlı model kalitesi ve gerçek ses kayıtları ayrı Mac denemesi gerektirir.

Otomatik yayın için kaynak deponun Actions secrets alanında:

- `SPARKLE_PRIVATE_KEY`: Sparkle `generate_keys` ile güvenli biçimde dışa aktarılmış base64 anahtar (yeni anahtarlar 32 byte seed; eski 96 byte biçimi de desteklenir). İmza aracına stdin üzerinden aktarılır; komut satırına veya dosyaya yazılmaz.
- `RELEASE_GITHUB_TOKEN`: Güncelleme deposu ayrıysa, yalnız bu depoda `Contents: read/write` yetkili belirteç. Aynı depo için standart `GITHUB_TOKEN` yeterli olabilir. Korumalı dal kuralları ayrıca izin gerektirebilir.

İmza secret'ı yoksa workflow açıkça durur; imzasız release yayınlamaz. Yerel Anahtar Zinciri ile yayın yapmak için Actions secret'larına gerek yoktur. Bu dosyalar secret oluşturmaz veya belirteç paylaşmaz. Özel kaynak depo üzerinde Actions çalışması hesabın GitHub Actions kotasını kullanır; uygulamanın yerel transkript/özet maliyetinden ayrıdır.

Tag'i göndermeden önce sürüm/yapı değerleri ve kamuya açık güncelleme yapılandırması commit edilmiş olmalıdır:

```sh
git tag v0.3.1
git push origin main
git push origin v0.3.1
```

İlk Actions yayını için workflow'u elle çalıştırıp `bootstrap: true` seçin. Yerelde ilk release zaten yayımlandıysa bu seçenek kullanılmaz.

## Apple kod imzası ve notarizasyon

Mevcut paketleme `codesign -` ile ad hoc imzalar. Sparkle'ın ZIP ve besleme Ed25519 imzaları yayıncı doğrulaması sağlar; Apple Gatekeeper'ın Developer ID/notarizasyon doğrulamasının yerine geçmez. Başka kullanıcılara daha rahat dağıtım için Apple Developer Program sertifikası ile `CODE_SIGN_IDENTITY` ayarlanabilir.

Build script framework yardımcılarını, frameworkü ve uygulamayı içten dışa imzalar; Downloader XPC entitlements korunur. `--deep` imzalama için kullanılmaz, yalnız doğrulamada kullanılır. Developer ID kullanıldığında Hardened Runtime ve güvenilir zaman damgası eklenir. Notarizasyon, `notarytool` ve stapling ayrıca yapılandırılmalıdır; bu depo mevcut durumda bunları otomatik tamamlandığını iddia etmez.

Referanslar: [Sparkle kurulum](https://sparkle-project.org/documentation/), [paket ve besleme yayınlama](https://sparkle-project.org/documentation/publishing/), [yardımcıların kod imzası](https://sparkle-project.org/documentation/sandboxing/#code-signing), [GitHub release asset API](https://docs.github.com/en/rest/releases/assets), [GitHub Contents API](https://docs.github.com/en/rest/repos/contents).
