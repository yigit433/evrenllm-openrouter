# Katkı Rehberi

Katkınız için teşekkürler! Hata bildirimleri, düzeltmeler ve yeni platform desteği memnuniyetle karşılanır.

## Hata bildirirken

Lütfen şunları ekleyin:

- İşletim sistemi ve sürümü (ör. macOS 26.1, Windows 11, Ubuntu 24.04)
- Shell / PowerShell sürümü: `bash --version` veya `$PSVersionTable.PSVersion`
- OpenCode sürümü: `opencode --version`
- Çalıştırdığınız komut ve script'in tam çıktısı
- İlgiliyse config dosyanız. **`.evren-key` dosyasını ve API anahtarınızı asla paylaşmayın.** Config'te başka provider'ların anahtarları düz metin olarak duruyorsa paylaşmadan önce silin.

## Geliştirme ilkeleri

İki script'in davranışı **aynı** kalmalı. `evren-opencode.sh` dosyasında yaptığınız bir değişikliği `evren-opencode.ps1` dosyasına da uygulayın (ya da tersini). Yapamıyorsanız PR açıklamasında belirtin.

Bunlara ek olarak şu kurallar geçerli:

- **Kullanıcının config'ine saygı:** Script yalnızca `evren` provider'ına, ayrıca boş ya da geçersizse `model` / `small_model` alanlarına dokunur. Diğer her şey olduğu gibi korunmalı.
- **Bozuk veriyle devam etme:** Config parse edilemiyorsa ya da API beklenmeyen yanıt veriyorsa script dosyaya yazmadan durmalı. Sessizce boş config üretmek kabul edilmez.
- **Önce doğrula, sonra kaydet:** Anahtar, API onaylamadan diske yazılmamalı.
- **Sıralama:** Kaldırma sırasında önce config'teki `{file:...}` referansı, sonra anahtar dosyası silinmeli. Ters sıra OpenCode'u bozar.
- **Şartları otomatik kabul etme:** Kullanım şartları her zaman kullanıcıya gösterilmeli ve açık `EVET` onayı alınmalı. Bu adımı atlayan bir seçenek eklemeyin.
- **Bağımlılıklar:** macOS/Linux'ta `curl`, `jq` ve `perl` dışında bağımlılık eklemeyin. Windows'ta yalnızca yerleşik PowerShell / .NET kullanın ve PowerShell 5.1 uyumluluğunu koruyun. Örneğin `-Encoding UTF8NoBOM`, `??` ve `?.` 5.1'de yoktur.
- **Mesajlar:** Kullanıcıya gösterilen mesajlar Türkçe olmalı. Eski konsollarda bozulmaması için script içinde ASCII karakterler tercih edilir.

## Test

Değişikliklerinizi gerçek OpenCode config'inize dokunmadan, geçici bir ev dizininde deneyin:

```bash
SANDBOX="$(mktemp -d)"
env HOME="$SANDBOX" \
    XDG_CONFIG_HOME="$SANDBOX/.config" XDG_DATA_HOME="$SANDBOX/.local/share" \
    XDG_STATE_HOME="$SANDBOX/.local/state" XDG_CACHE_HOME="$SANDBOX/.cache" \
    EVREN_SKIP_VERIFY=1 \
    ./evren-opencode.sh
cat "$SANDBOX/.config/opencode/opencode.jsonc"
```

Kendi API'nize ya da bir mock sunucuya yönlendirmek için `EVREN_BASE_URL` değişkenini kullanın.

PR açmadan önce en azından şu senaryoları kontrol edin:

1. **Temiz kurulum:** config dosyası hiç yokken
2. **Mevcut config:** yorumlar, sondaki virgüller ve başka provider'lar içeren bir `opencode.jsonc` ile. Diğer ayarlar korunmalı.
3. **Eski V1 kurulum:** `provider.evren` bloğu olan bir config ile. Blok `providers.evren`'e taşınmalı.
4. **Hatalı girdiler:** yanlış API anahtarı ve şartların reddedilmesi. İkisinde de hiçbir dosya oluşmamalı.
5. **Bozuk config:** geçersiz JSON içeren bir config ile. Dosya değişmeden kalmalı.
6. **`--sync-models` ve `--uninstall`**
7. **OpenCode doğrulaması:** OpenCode'un yazılan config'i uyarısız yüklediği. Sunucu logunda `configuration normalization diagnostic` uyarısı çıkmamalı.

Bash script'i için ayrıca `bash -n evren-opencode.sh` ve varsa `shellcheck evren-opencode.sh` çalıştırın.

## Pull request

- Her PR tek bir konuya odaklansın.
- Açıklamada neyi neden değiştirdiğinizi, hangi platformda ve hangi OpenCode sürümüyle test ettiğinizi yazın.
- OpenCode config formatıyla ilgili değişikliklerde dayandığınız dokümanı ekleyin (ör. <https://opencode.ai/docs/providers/>).

Katkılarınız [MIT lisansı](LICENSE) altında yayımlanır.
