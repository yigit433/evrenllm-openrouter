# EVREN LLM × OpenCode

EVREN LLM modellerini [OpenCode](https://opencode.ai)'a provider olarak ekleyen kurulum script'leri. Kurulumdan sonra OpenCode'da `evren/glm-5.3`, `evren/deepseek-v4.1-flash` gibi modelleri seçebilirsiniz.

> **Not:** Bu proje OpenRouter ile ilgili değildir. OpenRouter, kullanıcıların kendi endpoint'lerini eklemesine izin vermez. Script'ler EVREN'i doğrudan OpenCode'a bağlar.

| Dosya | Platform | Durum |
|---|---|---|
| `evren-opencode.sh` | macOS, Linux | Test edildi (OpenCode 2.0.21, macOS) |
| `evren-opencode.ps1` | Windows (PowerShell 5.1+) | Henüz Windows'ta test edilmedi |

## Gereksinimler

- [OpenCode](https://opencode.ai) 2.x (config'i V2 `providers` formatında yazar)
- Bir EVREN LLM API anahtarı (`evren_llm_...`)
- **macOS / Linux:** `curl`, `jq`, `perl`. macOS'ta hepsi hazır gelir. Linux'ta eksik olanı paket yöneticisiyle kurun.
- **Windows:** Windows PowerShell 5.1 veya PowerShell 7+

## Kurulum

### macOS / Linux

```bash
chmod +x evren-opencode.sh
./evren-opencode.sh
```

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\evren-opencode.ps1
```

Script şu sırayla ilerler:

1. API anahtarını gizli olarak sorar ve EVREN API'sinde doğrular. Anahtar geçersizse **hiçbir şey kaydedilmez**.
2. Kullanım şartlarını henüz kabul etmediyseniz metni gösterir ve kabul için `EVET` yazmanızı ister.
3. Model listesini API'den çeker. API'ye ulaşamazsa script içindeki son bilinen listeyi kullanır.
4. Anahtarı `~/.config/opencode/.evren-key` dosyasına yazar (macOS/Linux'ta izin `600`).
5. `opencode.json(c)` dosyasını yedekler ve `evren` provider'ını ekler. Diğer ayarlarınıza dokunmaz.
6. OpenCode'un EVREN modellerini gördüğünü doğrular.

Test etmek için:

```bash
opencode run --model evren/glm-5.3 "Sadece EVREN OK yaz."
```

## Kullanım

| macOS / Linux | Windows | Ne yapar |
|---|---|---|
| `./evren-opencode.sh` | `.\evren-opencode.ps1` | Kurulum |
| `./evren-opencode.sh --sync-models` | `.\evren-opencode.ps1 -SyncModels` | Kayıtlı anahtarla model listesini günceller. Yeni modeller eklenir, kaldırılanlar silinir. |
| `./evren-opencode.sh --uninstall` | `.\evren-opencode.ps1 -Uninstall` | `evren` provider'ını ve anahtar dosyasını siler. Diğer ayarlar korunur. |
| `./evren-opencode.sh --help` | `Get-Help .\evren-opencode.ps1` | Yardım |

### Ortam değişkenleri

| Değişken | Script | Açıklama |
|---|---|---|
| `EVREN_LLM_API_KEY` | `.sh` | Anahtarı sormadan bu değişkenden alır (CI gibi etkileşimsiz kullanım için). |
| `EVREN_BASE_URL` | ikisi | API adresini değiştirir. Varsayılan: `https://evren-llmapi.ssyz.org.tr/v1` |
| `EVREN_SKIP_VERIFY=1` | `.sh` | Sondaki OpenCode doğrulamasını atlar. |

## Config'e ne yazılır?

Örnek (model listesi kısaltıldı):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "evren": {
      "name": "EVREN LLM",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "https://evren-llmapi.ssyz.org.tr/v1",
        "apiKey": "{file:~/.config/opencode/.evren-key}"
      },
      "models": {
        "glm-5.3": {
          "name": "GLM 5.3",
          "limit": { "context": 524288, "output": 16384 },
          "capabilities": { "tools": true, "input": ["text"], "output": ["text"] }
        },
        "qwen3-vl-30b": {
          "name": "Qwen3 VL 30B",
          "limit": { "context": 262144, "output": 16384 },
          "capabilities": { "tools": true, "input": ["text", "image"], "output": ["text"] }
        }
      }
    }
  },
  "model": "evren/glm-5.3",
  "small_model": "evren/deepseek-v4.1-flash"
}
```

- **Anahtar config'te durmaz.** Config yalnızca anahtar dosyasına referans verir, böylece config'i paylaşmak anahtarı açığa çıkarmaz.
- **Varsayılan modeller:** `model` ve `small_model` yalnızca boşsa ya da artık var olmayan bir `evren/...` modelini gösteriyorsa ayarlanır. Kendi seçtiğiniz modeller değiştirilmez.
- **Model türleri:** Sadece `chat` ve `vision_chat` türündeki modeller eklenir. Görsel modellere `image` girdisi tanımlanır. Diğerleri açıkça yalnızca metin olarak işaretlenir, çünkü OpenCode tanımadığı modelleri varsayılan olarak görsel destekli sayar.
- **Eski kurulumdan geçiş:** Önceki script'lerin yazdığı eski V1 `provider.evren` bloğu bulunursa silinir ve V2 `providers.evren` olarak yeniden yazılır.

## Sorun giderme

**`opencode models` EVREN modellerini göstermiyor**
OpenCode 2.x arka planda bir servis çalıştırır ve bu servis config değişikliğini genelde kendisi algılar. Algılamazsa:
```bash
opencode service restart && opencode models | grep evren/
```
Taze başlayan bir servisteki ilk `opencode models` çağrısı boş dönebilir. Bir kez daha deneyin.

**OpenCode tamamen hata veriyor (500)**
Config'te `{file:...}` referansı duruyor ama anahtar dosyası silinmiş olabilir. Kurulumu yeniden çalıştırın ya da `--uninstall` / `-Uninstall` ile temizleyin. Anahtar dosyasını elle silmeyin.

**"opencode.jsonc okunamadı (geçersiz JSON/JSONC)"**
Script bozuk bir config'in üzerine yazmaz. Dosyayı düzeltip tekrar çalıştırın. Önceki sürümler `.bak-YYYYMMDD-HHMMSS` uzantılı yedeklerde durur.

**Config'teki yorumlarım kayboldu**
Config yeniden yazılırken JSONC yorumları korunamaz. Script bu durumda uyarır ve yazmadan önce yedek alır.

**Windows: "running scripts is disabled on this system"**
Script'i `powershell -ExecutionPolicy Bypass -File .\evren-opencode.ps1` ile çalıştırın.

## Güvenlik

- Anahtar `Read-Host -AsSecureString` / `read -s` ile ekrana yazdırılmadan alınır.
- macOS/Linux'ta anahtar `curl`'e stdin üzerinden verilir, bu yüzden `ps` çıktısında görünmez.
- Anahtar dosyası yalnızca kullanıcıya açıktır (`600`). Windows'ta kullanıcı profil dizininin izinleri geçerlidir.
- Script, eski sürümlerin oluşturduğu kalıcı `EVREN_LLM_API_KEY` kullanıcı değişkenine ihtiyaç duymaz. Windows'ta `-Uninstall` bu değişkeni de temizler.

## Katkı

Katkı rehberi için [CONTRIBUTE.md](CONTRIBUTE.md) dosyasına bakın.

## Lisans

[MIT](LICENSE)

---

Bu proje EVREN LLM, SSYZ veya OpenCode ile resmî bir bağlantısı olmayan, topluluk tarafından geliştirilen bir araçtır.
