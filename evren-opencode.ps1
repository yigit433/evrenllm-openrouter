#Requires -Version 5.1
<#
.SYNOPSIS
    EVREN LLM provider'ini OpenCode'a kurar, modellerini gunceller veya kaldirir (Windows).

.DESCRIPTION
    Varsayilan mod (kurulum):
      - API anahtarini guvenli alir ve EVREN API'sinde dogrular (dogrulanmadan hicbir sey kaydedilmez)
      - EVREN kullanim sartlarini gosterir ve kabul alir
      - Anahtari <config>\.evren-key dosyasina yazar; config bu dosyaya referans verir
      - opencode.json(c) icindeki diger ayarlara dokunmadan "providers.evren" (OpenCode 2.x / V2) blogunu yazar
      - Eski script'in yazdigi "provider.evren" (V1) blogu varsa kaldirip V2'ye tasir

    -SyncModels : Kayitli anahtarla sadece model listesini API'den gunceller.
    -Uninstall  : evren'i config'ten, anahtar dosyasini ve eski EVREN_LLM_API_KEY degiskenini siler.

.EXAMPLE
    .\evren-opencode.ps1
    .\evren-opencode.ps1 -SyncModels
    .\evren-opencode.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$SyncModels
)

$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 varsayilan olarak TLS 1.2 acmayabilir.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$BaseUrl    = if ($env:EVREN_BASE_URL) { $env:EVREN_BASE_URL } else { "https://evren-llmapi.ssyz.org.tr/v1" }
$ProviderId = "evren"
$Utf8NoBom  = New-Object System.Text.UTF8Encoding $false

# ── Cikti yardimcilari ───────────────────────────────────────────────────────

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "HATA: $Message" -ForegroundColor Red
    exit 1
}
function Ok([string]$Message)   { Write-Host "[OK] $Message" -ForegroundColor Green }
function Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor DarkGray }
function Warn([string]$Message) { Write-Host "[UYARI] $Message" -ForegroundColor Yellow }

$HasOpenCode = [bool](Get-Command opencode -ErrorAction SilentlyContinue)

# ── Config yollari ───────────────────────────────────────────────────────────
# OpenCode'un gercekten kullandigi dizini ondan ogren; yoksa ~/.config/opencode.

$HomeDir   = [Environment]::GetFolderPath("UserProfile")
$ConfigDir = $null
if ($HasOpenCode) {
    try {
        $line = & opencode debug paths 2>$null | Where-Object { $_ -match '^\s*config\s+' } | Select-Object -First 1
        if ($line) { $ConfigDir = ($line -replace '^\s*config\s+', '').Trim() }
    } catch { }
}
if (-not $ConfigDir) { $ConfigDir = Join-Path $HomeDir ".config\opencode" }

$JsoncPath = Join-Path $ConfigDir "opencode.jsonc"
$JsonPath  = Join-Path $ConfigDir "opencode.json"
if (Test-Path $JsoncPath) {
    $ConfigPath = $JsoncPath
    if (Test-Path $JsonPath) { Warn "Hem opencode.jsonc hem opencode.json var; opencode.jsonc guncellenecek." }
}
elseif (Test-Path $JsonPath) { $ConfigPath = $JsonPath }
else { $ConfigPath = $JsoncPath }

$KeyFile = Join-Path $ConfigDir ".evren-key"

# Config, anahtari bu dosyadan okur. Goreli yol ({file:.evren-key}) OpenCode 2.x'te
# calisma dizinine gore cozuldugu icin kullanilmiyor: ev dizini altindaysa ~ ile, degilse mutlak yol.
$homePrefix = $HomeDir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($KeyFile.StartsWith($homePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    $ApiKeyRef = "{file:~/" + ($KeyFile.Substring($homePrefix.Length) -replace '\\', '/') + "}"
} else {
    $ApiKeyRef = "{file:" + ($KeyFile -replace '\\', '/') + "}"
}

# ── HTTP yardimcisi ──────────────────────────────────────────────────────────
# Yanit govdesi UTF-8 olarak cozulur (5.1'de Invoke-RestMethod Turkce karakterleri bozabiliyor).
# Donus: @{ Code = <int>; Data = <PSObject|null>; Raw = <string> }

function Invoke-EvrenApi {
    param([string]$Method, [string]$Path, [string]$Body = $null)
    $params = @{
        Method          = $Method
        Uri             = "$BaseUrl$Path"
        Headers         = @{ Authorization = "Bearer $script:ApiKey" }
        UseBasicParsing = $true
        TimeoutSec      = 30
    }
    if ($Body) {
        $params.ContentType = "application/json; charset=utf-8"
        $params.Body = $Utf8NoBom.GetBytes($Body)
    }
    $code = 0; $raw = ""
    try {
        $resp = Invoke-WebRequest @params
        $code = [int]$resp.StatusCode
        $raw  = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    }
    catch {
        $r = $_.Exception.Response
        if ($null -ne $r) { $code = [int]$r.StatusCode }
        $raw = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    }
    $data = $null
    try { $data = $raw | ConvertFrom-Json } catch { }
    return @{ Code = $code; Data = $data; Raw = $raw }
}

function Get-ApiErrorMessage($Resp) {
    if ($Resp.Data -and $Resp.Data.error -and $Resp.Data.error.message) { return $Resp.Data.error.message }
    if ($Resp.Data -and $Resp.Data.message) { return $Resp.Data.message }
    return $Resp.Raw
}

# ── Config okuma/yazma ───────────────────────────────────────────────────────

# JSONC -> JSON: string'lere dokunmadan // ve /* */ yorumlarini ve sondaki virgulleri siler.
function ConvertFrom-Jsonc([string]$Text) {
    $s = [regex]::Replace($Text, '("(?:\\.|[^"\\])*")|//[^\n]*|/\*[\s\S]*?\*/', {
        param($m) if ($m.Groups[1].Success) { $m.Groups[1].Value } else { '' } })
    $s = [regex]::Replace($s, '("(?:\\.|[^"\\])*")|,(\s*[}\]])', {
        param($m) if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value } })
    return $s
}

# Config'i PSObject olarak dondurur; yoksa bos obje. Parse edilemezse DURUR
# (eski script bu durumda dosyayi bos config ile ezip diger ayarlari siliyordu).
function Read-Config {
    if (-not (Test-Path $ConfigPath)) { return [PSCustomObject]@{} }
    $raw = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return [PSCustomObject]@{} }
    try {
        $obj = (ConvertFrom-Jsonc $raw) | ConvertFrom-Json
    }
    catch {
        Fail "$ConfigPath okunamadi (gecersiz JSON/JSONC): $($_.Exception.Message). Dosyaya dokunulmadi; elle duzeltip tekrar calistirin."
    }
    if ($obj -isnot [PSCustomObject]) { Fail "$ConfigPath bir JSON objesi degil. Dosyaya dokunulmadi." }
    return $obj
}

function Backup-Config {
    if (Test-Path $ConfigPath) {
        $backup = "$ConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $ConfigPath $backup
        Info "Mevcut config yedeklendi: $backup"
        $raw = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
        if ((ConvertFrom-Jsonc $raw) -ne $raw) { Warn "Dosyadaki yorumlar yeniden yazimda kaybolacak (yedekte duruyor)." }
    }
}

# Gecici dosyaya yazip yerine tasir (yarim kalmis dosya birakmaz). UTF-8, BOM yok.
function Write-Config($Cfg) {
    $json = ConvertTo-Json -InputObject $Cfg -Depth 20
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $tmp = "$ConfigPath.tmp"
    [IO.File]::WriteAllText($tmp, $json, $Utf8NoBom)
    Move-Item -Path $tmp -Destination $ConfigPath -Force
}

function Remove-Property($Obj, [string]$Name) {
    if ($Obj -and $Obj.PSObject.Properties[$Name]) { $Obj.PSObject.Properties.Remove($Name) }
}

function Get-PropCount($Obj) { return @($Obj.PSObject.Properties).Count }

# ── Modeller ─────────────────────────────────────────────────────────────────

$FallbackModelsJson = '{"object":"list","data":[{"id":"glm-5.3","task":"chat","context_length":524288,"default_max_output_tokens":16384},{"id":"deepseek-v4.1-flash","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"deepseek-v4-flash","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"qwen3.8-flash-next","task":"chat","context_length":262144,"default_max_output_tokens":16384},{"id":"gemma-4-31b","task":"chat","context_length":262144,"default_max_output_tokens":16384},{"id":"qwen3-vl-30b","task":"vision_chat","context_length":262144,"default_max_output_tokens":16384},{"id":"mimo-v2.6-pro","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"auto","task":"chat","context_length":32768,"default_max_output_tokens":16384}]}'

$KnownModelNames = @{
    "glm-5.3"             = "GLM 5.3"
    "deepseek-v4.1-flash" = "DeepSeek V4.1 Flash"
    "deepseek-v4-flash"   = "DeepSeek V4 Flash"
    "qwen3.8-flash-next"  = "Qwen 3.8 Flash Next"
    "gemma-4-31b"         = "Gemma 4 31B"
    "qwen3-vl-30b"        = "Qwen3 VL 30B"
    "mimo-v2.6-pro"       = "MiMo V2.6 Pro"
    "auto"                = "EVREN Auto"
}

function Get-PrettyModelName([string]$Id) {
    if ($KnownModelNames.ContainsKey($Id)) { return $KnownModelNames[$Id] }
    $acronyms = @{ glm = "GLM"; qwen = "Qwen"; gemma = "Gemma"; deepseek = "DeepSeek"; mimo = "MiMo"; vl = "VL"; ocr = "OCR"; asr = "ASR" }
    $words = foreach ($tok in ($Id -split '-')) {
        $low = $tok.ToLowerInvariant()
        if ($acronyms.ContainsKey($low)) { $acronyms[$low] }
        elseif ($low -match '^[0-9]+[a-z]*$') { $tok.ToUpperInvariant() }
        elseif ($tok.Length -gt 0) { $tok.Substring(0, 1).ToUpperInvariant() + $tok.Substring(1) }
        else { $tok }
    }
    return ($words -join ' ')
}

# /v1/models yanitindan OpenCode V2 "models" haritasi uretir (sadece chat / vision_chat).
# Kataloga kayitli olmayan modelleri OpenCode "gorsel destekli" sayar; capabilities bu yuzden acikca yazilir.
function ConvertTo-ModelsMap($Payload) {
    $map = [ordered]@{}
    foreach ($m in @($Payload.data)) {
        if ($null -eq $m -or [string]::IsNullOrWhiteSpace($m.id)) { continue }
        $task = if ($m.PSObject.Properties['task'] -and $m.task) { [string]$m.task } else { 'chat' }
        if ($task -notin @('chat', 'vision_chat')) { continue }
        $ctx = if ($m.context_length) { [long]$m.context_length } else { 128000 }
        $out = if ($m.default_max_output_tokens) { [long]$m.default_max_output_tokens } else { 8192 }
        $input = if ($task -eq 'vision_chat') { @('text', 'image') } else { @('text') }
        $map[[string]$m.id] = [ordered]@{
            name         = (Get-PrettyModelName $m.id)
            limit        = [ordered]@{ context = $ctx; output = $out }
            capabilities = [ordered]@{ tools = $true; input = $input; output = @('text') }
        }
    }
    if ($map.Count -eq 0) { throw "API sohbet modeli dondurmedi." }
    return $map
}

function Get-EvrenModels {
    $r = Invoke-EvrenApi GET "/models"
    if ($r.Code -eq 200 -and $r.Data) {
        try {
            $map = ConvertTo-ModelsMap $r.Data
            Ok "Model listesi API'den alindi ($($map.Count) sohbet modeli)."
            return $map
        } catch { }
    }
    $script:LastModelsCode = $r.Code
    return $null
}

# Config'e evren'i V2 formatinda yazar; eski V1 "provider.evren" blogunu temizler;
# model/small_model yoksa ya da artik var olmayan bir evren modelini gosteriyorsa duzeltir.
function Merge-EvrenConfig($Cfg, $ModelsMap) {
    if (-not $Cfg.PSObject.Properties['$schema']) {
        $Cfg | Add-Member -NotePropertyName '$schema' -NotePropertyValue "https://opencode.ai/config.json" -Force
    }
    if ($Cfg.PSObject.Properties['provider'] -and $Cfg.provider -is [PSCustomObject]) {
        if ($Cfg.provider.PSObject.Properties[$ProviderId]) {
            Remove-Property $Cfg.provider $ProviderId
            Info "Eski V1 'provider.$ProviderId' blogu kaldirildi (V2 'providers.$ProviderId' yaziliyor)."
        }
        if ((Get-PropCount $Cfg.provider) -eq 0) { Remove-Property $Cfg 'provider' }
    }
    if (-not ($Cfg.PSObject.Properties['providers'] -and $Cfg.providers -is [PSCustomObject])) {
        $Cfg | Add-Member -NotePropertyName 'providers' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $provider = [ordered]@{
        name     = "EVREN LLM"
        package  = "@opencode/ai/providers/openai-compatible"
        settings = [ordered]@{ baseURL = $BaseUrl; apiKey = $ApiKeyRef }
        models   = $ModelsMap
    }
    $Cfg.providers | Add-Member -NotePropertyName $ProviderId -NotePropertyValue $provider -Force

    $ids = @($ModelsMap.Keys)
    $prefix = "$ProviderId/"
    function Test-Stale($v) {
        if ($null -eq $v) { return $true }
        $s = [string]$v
        return ($s.StartsWith($prefix) -and ($ids -notcontains $s.Substring($prefix.Length)))
    }
    if (Test-Stale $Cfg.model) {
        $def = if ($ids -contains "glm-5.3") { "glm-5.3" } elseif ($ids -contains "auto") { "auto" } else { $ids[0] }
        $Cfg | Add-Member -NotePropertyName "model" -NotePropertyValue "$prefix$def" -Force
    }
    if (Test-Stale $Cfg.small_model) {
        if ($ids -contains "deepseek-v4.1-flash") { $small = "deepseek-v4.1-flash" }
        else { $small = ($ModelsMap.GetEnumerator() | Sort-Object { $_.Value.limit.context } | Select-Object -First 1).Key }
        $Cfg | Add-Member -NotePropertyName "small_model" -NotePropertyValue "$prefix$small" -Force
    }
}

# OpenCode 2.x'te arka plan servisi config degisikligini genelde kendisi algilar;
# ilk sorgu bos donebildigi icin birkac kez denenir, olmazsa servis yeniden baslatilir.
function Test-OpenCode {
    if (-not $HasOpenCode) {
        Warn "'opencode' PATH'te bulunamadi. Config yine de guncellendi."
        return
    }
    $getEvren = { @(& opencode models 2>$null | Where-Object { $_ -like "$ProviderId/*" }) }
    $found = @()
    for ($i = 0; $i -lt 10 -and $found.Count -eq 0; $i++) { $found = & $getEvren; if ($found.Count -eq 0) { Start-Sleep -Seconds 1 } }
    if ($found.Count -eq 0) {
        Info "Arka plan servisi yeni config'i henuz gormedi; yeniden baslatiliyor..."
        & opencode service restart 2>$null | Out-Null
        for ($i = 0; $i -lt 10 -and $found.Count -eq 0; $i++) { $found = & $getEvren; if ($found.Count -eq 0) { Start-Sleep -Seconds 1 } }
    }
    if ($found.Count -gt 0) {
        Ok "OpenCode $($found.Count) EVREN modelini goruyor:"
        $found | ForEach-Object { Write-Host "    $_" }
    } else {
        Warn "OpenCode evren modellerini listelemedi. Kontrol: opencode service restart; opencode models"
    }
}

# ════════════════════════════════════════════════════════════════════════════
# KALDIRMA
# ════════════════════════════════════════════════════════════════════════════

if ($Uninstall) {
    Write-Host "=== EVREN LLM OpenCode Kaldirma ===" -ForegroundColor Cyan

    # Sira onemli: once config'teki referans silinir, sonra anahtar dosyasi.
    # (Dosya silinip referans kalirsa OpenCode tamamen hata verir.)
    if (Test-Path $ConfigPath) {
        $cfg = Read-Config
        $removed = $false
        foreach ($key in @('providers', 'provider')) {
            $bag = $cfg.$key
            if ($bag -is [PSCustomObject] -and $bag.PSObject.Properties[$ProviderId]) {
                Remove-Property $bag $ProviderId
                $removed = $true
                if ((Get-PropCount $bag) -eq 0) { Remove-Property $cfg $key }
            }
        }
        foreach ($key in @('model', 'small_model')) {
            if ($cfg.PSObject.Properties[$key] -and ([string]$cfg.$key).StartsWith("$ProviderId/")) {
                Remove-Property $cfg $key
                $removed = $true
                Info "$key '$ProviderId/...' kaldirildi."
            }
        }
        if ($removed) {
            Backup-Config
            Write-Config $cfg
            Ok "'$ProviderId' provider'i config'ten kaldirildi: $ConfigPath"
        } else {
            Info "Config'te '$ProviderId' provider'i yok; degisiklik yapilmadi."
        }
    } else {
        Info "Config dosyasi yok; degisiklik gerekmedi."
    }

    if (Test-Path $KeyFile) { Remove-Item $KeyFile -Force; Ok "Anahtar dosyasi silindi: $KeyFile" }
    else { Info "Anahtar dosyasi zaten yok." }

    # Eski script'in olusturdugu kalici degisken
    if ($null -ne [Environment]::GetEnvironmentVariable("EVREN_LLM_API_KEY", "User")) {
        [Environment]::SetEnvironmentVariable("EVREN_LLM_API_KEY", $null, "User")
        Remove-Item Env:EVREN_LLM_API_KEY -ErrorAction SilentlyContinue
        Ok "Eski EVREN_LLM_API_KEY kullanici degiskeni kaldirildi."
    }

    Write-Host ""
    Ok "Kaldirma tamamlandi. Diger provider/ayarlar korundu."
    exit 0
}

# ════════════════════════════════════════════════════════════════════════════
# MODEL SENKRONU (anahtar sormaz, sartlar adimini atlar)
# ════════════════════════════════════════════════════════════════════════════

if ($SyncModels) {
    Write-Host "=== EVREN LLM Model Listesi Guncellemesi ===" -ForegroundColor Cyan
    $script:ApiKey = $null
    if (Test-Path $KeyFile) { $script:ApiKey = ([IO.File]::ReadAllText($KeyFile)).Trim() }
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) { Fail "Kayitli API anahtari bulunamadi ($KeyFile). Once kurulumu calistirin." }

    $modelsMap = Get-EvrenModels
    if (-not $modelsMap) { Fail "Model listesi alinamadi (HTTP $script:LastModelsCode)." }

    $cfg = Read-Config
    Merge-EvrenConfig $cfg $modelsMap
    Backup-Config
    Write-Config $cfg
    Ok "Model listesi senkronize edildi (diger provider'lar korundu): $ConfigPath"
    Test-OpenCode
    exit 0
}

# ════════════════════════════════════════════════════════════════════════════
# KURULUM
# ════════════════════════════════════════════════════════════════════════════

Write-Host "=== EVREN LLM + OpenCode Kurulumu ===" -ForegroundColor Cyan

# Config bozuksa hicbir sey yapmadan once dur.
$cfg = Read-Config

# ── 1) API anahtarini al ─────────────────────────────────────────────────────

$secureKey = Read-Host "EVREN LLM API anahtarinizi girin" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
try { $script:ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$script:ApiKey = ($script:ApiKey -replace '\s', '')
if ([string]::IsNullOrWhiteSpace($script:ApiKey)) { Fail "API anahtari bos birakilamaz." }
if ($script:ApiKey -notmatch '^evren_llm_[A-Za-z0-9_-]+$') { Fail "API anahtari beklenen 'evren_llm_...' formatinda degil." }

# ── 2) Anahtari API'de dogrula + sartlar (hicbir sey kaydedilmeden once) ─────

$status = Invoke-EvrenApi GET "/terms/status"
switch ($status.Code) {
    200     { Ok "API anahtari dogrulandi." }
    401     { Fail "API anahtari reddedildi: $(Get-ApiErrorMessage $status)" }
    403     { Fail "API anahtari reddedildi: $(Get-ApiErrorMessage $status)" }
    0       { Fail "EVREN API'ye ulasilamadi ($BaseUrl): $($status.Raw)" }
    default { Fail "terms/status beklenmeyen yanit (HTTP $($status.Code)): $(Get-ApiErrorMessage $status)" }
}
$termsVersion = $status.Data.current_version

if (-not $status.Data.accepted) {
    $terms = Invoke-EvrenApi GET "/terms/text"
    if ($terms.Code -ne 200) { Fail "terms/text alinamadi (HTTP $($terms.Code)): $(Get-ApiErrorMessage $terms)" }

    Write-Host ""
    Write-Host "=== EVREN Kullanim Sartlari (v$termsVersion) ===" -ForegroundColor Yellow
    Write-Host $terms.Data.content
    Write-Host ""

    $confirmation = Read-Host "Bu kullanim sartlarini kabul ediyor musunuz? Kabul icin EVET yazin"
    if ($confirmation.Trim().ToUpperInvariant() -ne "EVET") {
        Fail "Kullanim sartlari kabul edilmedi. Kurulum durduruldu (hicbir sey kaydedilmedi)."
    }

    # Surum numarasi API'den geldigi tipte geri gonderilir (eski script [int] zorluyordu).
    $body = ConvertTo-Json -InputObject @{ version = $termsVersion } -Compress
    $accept = Invoke-EvrenApi POST "/terms/accept" $body
    if ($accept.Code -ne 200) { Fail "terms/accept basarisiz (HTTP $($accept.Code)): $(Get-ApiErrorMessage $accept)" }
    Ok "Kullanim sartlari kabul edildi (v$($accept.Data.accepted_version))."

    $verify = Invoke-EvrenApi GET "/terms/status"
    if ($verify.Code -ne 200 -or -not $verify.Data.accepted) { Fail "Kabul durumu dogrulanamadi (accepted=true degil)." }
    Ok "Kabul durumu dogrulandi."
}
else {
    Ok "Kullanim sartlari zaten kabul edilmis (v$termsVersion)."
}

# ── 3) Model listesi ─────────────────────────────────────────────────────────

$modelsMap = Get-EvrenModels
if (-not $modelsMap) {
    Warn "Model listesi API'den alinamadi (HTTP $script:LastModelsCode); son bilinen liste kullanilacak."
    $modelsMap = ConvertTo-ModelsMap ($FallbackModelsJson | ConvertFrom-Json)
}

# ── 4) Anahtari kaydet ───────────────────────────────────────────────────────

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
[IO.File]::WriteAllText($KeyFile, $script:ApiKey, $Utf8NoBom)   # -Encoding UTF8NoBOM 5.1'de yok
Ok "API anahtari kaydedildi: $KeyFile"

if ($null -ne [Environment]::GetEnvironmentVariable("EVREN_LLM_API_KEY", "User")) {
    Info "Eski kurulumdan kalan EVREN_LLM_API_KEY kullanici degiskeni artik gerekmiyor (-Uninstall ile ya da elle silebilirsiniz)."
}

# ── 5) Config'e yaz ──────────────────────────────────────────────────────────

Merge-EvrenConfig $cfg $modelsMap
Backup-Config
Write-Config $cfg
Ok "OpenCode config guncellendi (diger provider'lar korundu): $ConfigPath"
Info "Varsayilan model: $($cfg.model)  |  small_model: $($cfg.small_model)"

# ── 6) Dogrula ───────────────────────────────────────────────────────────────

Write-Host ""
Test-OpenCode
Write-Host ""
Write-Host "Test:     " -ForegroundColor Cyan -NoNewline; Write-Host "opencode run --model $ProviderId/glm-5.3 `"Sadece EVREN OK yaz.`""
Write-Host "Guncelle: " -ForegroundColor Cyan -NoNewline; Write-Host ".\evren-opencode.ps1 -SyncModels"
Write-Host "Kaldir:   " -ForegroundColor Cyan -NoNewline; Write-Host ".\evren-opencode.ps1 -Uninstall"
