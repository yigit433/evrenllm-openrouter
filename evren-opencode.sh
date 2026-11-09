#!/usr/bin/env bash
# EVREN LLM provider'ini OpenCode'a kurar, modellerini gunceller veya kaldirir.
# macOS ve Linux icin. Gereksinimler: curl, jq, perl (macOS'ta hazir gelir).
#
# Kullanim:
#   ./evren-opencode.sh                 # kurulum (anahtar sorar, sartlari gosterir)
#   ./evren-opencode.sh --sync-models   # sadece model listesini API'den gunceller
#   ./evren-opencode.sh --uninstall     # evren'i config'den ve anahtar dosyasini siler
#
# Anahtari etkilesimsiz vermek icin (CI vb.): EVREN_LLM_API_KEY=... ./evren-opencode.sh
#
# OpenCode 2.x "providers" (V2) formatini yazar. Eski script'in yazdigi
# "provider.evren" (V1) blogu varsa kaldirilip V2'ye tasinir.

set -euo pipefail

BASE_URL="${EVREN_BASE_URL:-https://evren-llmapi.ssyz.org.tr/v1}"
PROVIDER_ID="evren"

# ── Cikti yardimcilari ───────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_DIM=""; C_OFF=""
fi
fail() { printf '\n%sHATA:%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit 1; }
ok()   { printf '%s[OK]%s %s\n' "$C_GRN" "$C_OFF" "$1"; }
info() { printf '%s[INFO]%s %s\n' "$C_DIM" "$C_OFF" "$1"; }
warn() { printf '%s[UYARI]%s %s\n' "$C_YEL" "$C_OFF" "$1"; }
title(){ printf '%s=== %s ===%s\n' "$C_CYN" "$1" "$C_OFF"; }

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

MODE=install
case "${1:-}" in
  "") ;;
  --uninstall|-u|-Uninstall) MODE=uninstall ;;
  --sync-models|-s|-SyncModels) MODE=sync ;;
  -h|--help) usage; exit 0 ;;
  *) usage; fail "Bilinmeyen secenek: $1" ;;
esac

for dep in curl jq perl; do
  command -v "$dep" >/dev/null 2>&1 || fail "'$dep' bulunamadi. Kurmak icin: brew install $dep (macOS) ya da dagitiminizin paket yoneticisi (Linux)."
done

HAS_OPENCODE=0
command -v opencode >/dev/null 2>&1 && HAS_OPENCODE=1

# ── Config yollari ───────────────────────────────────────────────────────────
# OpenCode'un gercekten kullandigi dizini ondan ogren; yoksa XDG varsayilani.
CONFIG_DIR=""
if [ "$HAS_OPENCODE" = 1 ]; then
  CONFIG_DIR="$(opencode debug paths 2>/dev/null | awk '$1=="config"{ $1=""; sub(/^ +/,""); print; exit }' || true)"
fi
[ -n "$CONFIG_DIR" ] || CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

# Mevcut dosyayi kullan (opencode.jsonc > opencode.json); hicbiri yoksa .jsonc olustur.
if [ -f "$CONFIG_DIR/opencode.jsonc" ]; then
  CONFIG_PATH="$CONFIG_DIR/opencode.jsonc"
  [ -f "$CONFIG_DIR/opencode.json" ] && warn "Hem opencode.jsonc hem opencode.json var; opencode.jsonc guncellenecek."
elif [ -f "$CONFIG_DIR/opencode.json" ]; then
  CONFIG_PATH="$CONFIG_DIR/opencode.json"
else
  CONFIG_PATH="$CONFIG_DIR/opencode.jsonc"
fi
KEY_FILE="$CONFIG_DIR/.evren-key"

# Config, anahtari bu dosyadan okur (shell/GUI/arka plan servisinden bagimsiz).
# Not: goreli yol ({file:.evren-key}) OpenCode 2.x'te calisma dizinine gore
# cozuldugu icin kullanilmiyor; ev dizini altindaysa ~ ile, degilse mutlak yol.
case "$KEY_FILE" in
  "$HOME"/*) API_KEY_REF="{file:~/${KEY_FILE#"$HOME"/}}" ;;
  *)         API_KEY_REF="{file:$KEY_FILE}" ;;
esac

# ── HTTP yardimcisi ──────────────────────────────────────────────────────────
# api METHOD PATH [BODY] -> govdeyi $RESP'e, HTTP kodunu $HTTP_CODE'a koyar.
# (Alt kabukta calistirilmamali; $(api ...) degiskenleri kaybettirir.)
# Anahtar curl'e stdin'den header olarak verilir (ps ciktisinda gorunmez).
HTTP_CODE=""; RESP=""
api() {
  local method="$1" path="$2" body="${3:-}" out
  local args=(-sS --max-time 30 -X "$method" -H @- -w $'\n%{http_code}' "$BASE_URL$path")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
  if ! out="$(printf 'Authorization: Bearer %s\n' "$API_KEY" | curl "${args[@]}" 2>&1)"; then
    HTTP_CODE="000"; RESP="$out"; return 0
  fi
  HTTP_CODE="${out##*$'\n'}"
  RESP="${out%$'\n'*}"
}

api_error_msg() { jq -r '.error.message? // .message? // empty' 2>/dev/null <<<"$1" | head -1; }

# ── Config okuma/yazma ───────────────────────────────────────────────────────
# JSONC -> JSON: string'lere dokunmadan // ve /* */ yorumlarini, sondaki virgulleri siler.
jsonc_to_json() {
  perl -0777 -pe '
    s{("(?:\\.|[^"\\])*")|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse;
    s{("(?:\\.|[^"\\])*")|,(\s*[\}\]])}{defined $1 ? $1 : $2}gse;
  ' "$1"
}

# Mevcut config'i JSON olarak stdout'a verir; yoksa {}. Parse edilemezse DURUR
# (eski script bu durumda dosyayi bos config ile ezip diger ayarlari siliyordu).
read_config() {
  if [ ! -s "$CONFIG_PATH" ]; then echo '{}'; return; fi
  local json
  json="$(jsonc_to_json "$CONFIG_PATH")"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json"; then
    fail "$CONFIG_PATH okunamadi (gecersiz JSON/JSONC). Dosyaya dokunulmadi; lutfen elle duzeltip tekrar calistirin."
  fi
  printf '%s' "$json"
}

backup_config() {
  if [ -f "$CONFIG_PATH" ]; then
    local b; b="$CONFIG_PATH.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$CONFIG_PATH" "$b"
    info "Mevcut config yedeklendi: $b"
    if grep -qE '//|/\*' "$CONFIG_PATH" && [ "$(jsonc_to_json "$CONFIG_PATH")" != "$(cat "$CONFIG_PATH")" ]; then
      warn "Dosyadaki yorumlar yeniden yazimda kaybolacak (yedekte duruyor)."
    fi
  fi
}

# Verilen JSON'u (arguman) dogrulayip gecici dosyaya yazar ve atomik olarak yerine koyar.
write_config() {
  local json="$1" tmp="$CONFIG_PATH.tmp.$$"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json" || fail "Uretilen config gecersiz; dosyaya dokunulmadi."
  mkdir -p "$CONFIG_DIR"
  jq '.' <<<"$json" > "$tmp" || { rm -f "$tmp"; fail "Config yazilamadi."; }
  mv "$tmp" "$CONFIG_PATH"
}

# ── Modeller ─────────────────────────────────────────────────────────────────
FALLBACK_MODELS_JSON='{"object":"list","data":[{"id":"glm-5.3","task":"chat","context_length":524288,"default_max_output_tokens":16384},{"id":"deepseek-v4.1-flash","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"deepseek-v4-flash","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"qwen3.8-flash-next","task":"chat","context_length":262144,"default_max_output_tokens":16384},{"id":"gemma-4-31b","task":"chat","context_length":262144,"default_max_output_tokens":16384},{"id":"qwen3-vl-30b","task":"vision_chat","context_length":262144,"default_max_output_tokens":16384},{"id":"mimo-v2.6-pro","task":"chat","context_length":1048576,"default_max_output_tokens":16384},{"id":"auto","task":"chat","context_length":32768,"default_max_output_tokens":16384}]}'

# /v1/models yanitindan OpenCode V2 "models" haritasi uretir.
# Sadece chat / vision_chat alinir. Kataloga kayitli olmayan modelleri OpenCode
# varsayilan olarak "gorsel destekli" sayar; bu yuzden capabilities acikca yazilir.
models_map() {
  jq -c '
    def known: {
      "glm-5.3": "GLM 5.3", "deepseek-v4.1-flash": "DeepSeek V4.1 Flash",
      "deepseek-v4-flash": "DeepSeek V4 Flash", "qwen3.8-flash-next": "Qwen 3.8 Flash Next",
      "gemma-4-31b": "Gemma 4 31B", "qwen3-vl-30b": "Qwen3 VL 30B",
      "mimo-v2.6-pro": "MiMo V2.6 Pro", "auto": "EVREN Auto" };
    def acr: { "glm":"GLM","qwen":"Qwen","gemma":"Gemma","deepseek":"DeepSeek",
               "mimo":"MiMo","vl":"VL","ocr":"OCR","asr":"ASR" };
    def pretty: . as $id
      | if known[$id] then known[$id]
        else [ split("-")[] | ascii_downcase as $l
               | if acr[$l] then acr[$l]
                 elif test("^[0-9]+[a-z]*$") then ascii_upcase
                 elif length > 0 then (.[0:1] | ascii_upcase) + .[1:]
                 else . end ] | join(" ") end;
    [ (.data // [])[]
      | select(type == "object" and (.id | type) == "string" and .id != "")
      | (.task // "chat") as $task
      | select($task == "chat" or $task == "vision_chat")
      | { key: .id,
          value: {
            name: (.id | pretty),
            limit: { context: ((.context_length // 128000) | floor),
                     output:  ((.default_max_output_tokens // 8192) | floor) },
            capabilities: { tools: true,
                            input: (if $task == "vision_chat" then ["text","image"] else ["text"] end),
                            output: ["text"] } } } ]
    | from_entries
    | if length == 0 then error("API sohbet modeli dondurmedi") else . end
  '
}

fetch_models() {
  api GET /models
  if [ "$HTTP_CODE" = 200 ] && MODELS="$(models_map <<<"$RESP" 2>/dev/null)"; then
    ok "Model listesi API'den alindi ($(jq 'length' <<<"$MODELS") sohbet modeli)."
    return 0
  fi
  return 1
}

# Config'e evren'i V2 formatinda yazar; eski V1 blogunu temizler;
# model/small_model yoksa ya da artik var olmayan bir evren modelini gosteriyorsa duzeltir.
merge_config() {
  jq --arg id "$PROVIDER_ID" --arg url "$BASE_URL" --arg key "$API_KEY_REF" --argjson models "$MODELS" '
    ($models | keys) as $ids
    | def stale($v): ($v == null) or (($v | tostring | startswith($id + "/")) and (($v | tostring | ltrimstr($id + "/")) | IN($ids[]) | not));
    .["$schema"] //= "https://opencode.ai/config.json"
    | if (.provider | type) == "object" then
        del(.provider[$id]) | if (.provider | length) == 0 then del(.provider) else . end
      else . end
    | .providers = ((.providers // {}) + { ($id): {
        name: "EVREN LLM",
        package: "@opencode/ai/providers/openai-compatible",
        settings: { baseURL: $url, apiKey: $key },
        models: $models } })
    | if stale(.model) then
        .model = $id + "/" + (if ("glm-5.3" | IN($ids[])) then "glm-5.3"
                              elif ("auto" | IN($ids[])) then "auto"
                              else $ids[0] end)
      else . end
    | if stale(.small_model) then
        .small_model = $id + "/" + (if ("deepseek-v4.1-flash" | IN($ids[])) then "deepseek-v4.1-flash"
                                    else ($models | to_entries | min_by(.value.limit.context) | .key) end)
      else . end
  '
}

# OpenCode'un evren modellerini gordugunu dogrular. 2.x'te arka plan servisi
# config degisikligini kendisi algilar; algilamazsa servisi yeniden baslatir.
verify_opencode() {
  if [ "$HAS_OPENCODE" != 1 ]; then
    warn "'opencode' PATH'te bulunamadi. Config yine de guncellendi."
    return
  fi
  [ "${EVREN_SKIP_VERIFY:-0}" = 1 ] && { info "Dogrulama atlandi (EVREN_SKIP_VERIFY=1)."; return; }
  local n=0 i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    n="$(opencode models 2>/dev/null | grep -c "^$PROVIDER_ID/" || true)"
    [ "$n" -gt 0 ] && break
    sleep 1
  done
  if [ "$n" -eq 0 ]; then
    info "Arka plan servisi yeni config'i henuz gormedi; yeniden baslatiliyor..."
    opencode service restart >/dev/null 2>&1 || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      n="$(opencode models 2>/dev/null | grep -c "^$PROVIDER_ID/" || true)"
      [ "$n" -gt 0 ] && break
      sleep 1
    done
  fi
  if [ "$n" -gt 0 ]; then
    ok "OpenCode $n EVREN modelini goruyor:"
    opencode models 2>/dev/null | grep "^$PROVIDER_ID/" | sed 's/^/    /'
  else
    warn "OpenCode evren modellerini listelemedi. Kontrol: opencode service restart && opencode models"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# KALDIRMA
# ════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = uninstall ]; then
  title "EVREN LLM OpenCode Kaldirma"
  # Sira onemli: once config'ten referans silinir, sonra anahtar dosyasi.
  # (Dosya silinip referans kalirsa OpenCode tamamen hata verir.)
  if [ -f "$CONFIG_PATH" ]; then
    cfg="$(read_config)"
    has="$(jq --arg id "$PROVIDER_ID" '(.providers[$id]? != null) or (.provider[$id]? != null)' <<<"$cfg")"
    if [ "$has" = true ]; then
      new="$(jq --arg id "$PROVIDER_ID" '
        def drop($k): if (.[$k] | type) == "object" then del(.[$k][$id]) | (if (.[$k] | length) == 0 then del(.[$k]) else . end) else . end;
        drop("providers") | drop("provider")
        | if ((.model // "") | tostring | startswith($id + "/")) then del(.model) else . end
        | if ((.small_model // "") | tostring | startswith($id + "/")) then del(.small_model) else . end
      ' <<<"$cfg")"
      backup_config
      write_config "$new"
      ok "'$PROVIDER_ID' provider'i config'ten kaldirildi: $CONFIG_PATH"
    else
      info "Config'te '$PROVIDER_ID' provider'i yok; degisiklik yapilmadi."
    fi
  else
    info "Config dosyasi yok; degisiklik gerekmedi."
  fi
  if [ -f "$KEY_FILE" ]; then rm -f "$KEY_FILE"; ok "Anahtar dosyasi silindi: $KEY_FILE"
  else info "Anahtar dosyasi zaten yok."; fi
  [ -n "${EVREN_LLM_API_KEY:-}" ] && warn "EVREN_LLM_API_KEY ortam degiskeni hala tanimli; shell profilinizden (~/.zshrc vb.) silebilirsiniz."
  echo; ok "Kaldirma tamamlandi. Diger provider/ayarlar korundu."
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# MODEL SENKRONU (anahtar sormaz, sartlar adimini atlar)
# ════════════════════════════════════════════════════════════════════════════
if [ "$MODE" = sync ]; then
  title "EVREN LLM Model Listesi Guncellemesi"
  API_KEY=""
  [ -f "$KEY_FILE" ] && API_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
  [ -n "$API_KEY" ] || API_KEY="$(printf '%s' "${EVREN_LLM_API_KEY:-}" | tr -d '[:space:]')"
  [ -n "$API_KEY" ] || fail "Kayitli API anahtari bulunamadi ($KEY_FILE). Once kurulumu calistirin."
  fetch_models || fail "Model listesi alinamadi (HTTP $HTTP_CODE)."
  cfg="$(read_config)"
  new="$(merge_config <<<"$cfg")"
  backup_config
  write_config "$new"
  ok "Model listesi senkronize edildi (diger provider'lar korundu): $CONFIG_PATH"
  verify_opencode
  exit 0
fi

# ════════════════════════════════════════════════════════════════════════════
# KURULUM
# ════════════════════════════════════════════════════════════════════════════
title "EVREN LLM + OpenCode Kurulumu"

# Config bozuksa hicbir sey yapmadan once dur.
CFG_JSON="$(read_config)"

# ── 1) API anahtarini al ─────────────────────────────────────────────────────
if [ -n "${EVREN_LLM_API_KEY:-}" ]; then
  API_KEY="$EVREN_LLM_API_KEY"
  info "Anahtar EVREN_LLM_API_KEY ortam degiskeninden alindi."
else
  [ -t 0 ] || fail "Anahtar girisi icin etkilesimli terminal gerekli (ya da EVREN_LLM_API_KEY verin)."
  read -rsp "EVREN LLM API anahtarinizi girin (ekranda gorunmez): " API_KEY; echo
fi
API_KEY="$(printf '%s' "$API_KEY" | tr -d '[:space:]')"
[ -n "$API_KEY" ] || fail "API anahtari bos birakilamaz."
[[ "$API_KEY" =~ ^evren_llm_[A-Za-z0-9_-]+$ ]] || fail "API anahtari beklenen 'evren_llm_...' formatinda degil."

# ── 2) Anahtari API'de dogrula + sartlar (hicbir sey kaydedilmeden once) ─────
api GET /terms/status; status="$RESP"
case "$HTTP_CODE" in
  200) ok "API anahtari dogrulandi." ;;
  401|403) fail "API anahtari reddedildi: $(api_error_msg "$status")" ;;
  000) fail "EVREN API'ye ulasilamadi ($BASE_URL): $status" ;;
  *) fail "terms/status beklenmeyen yanit (HTTP $HTTP_CODE): $(api_error_msg "$status")" ;;
esac
terms_version="$(jq -r '.current_version // empty' <<<"$status")"

if [ "$(jq -r '.accepted' <<<"$status")" != true ]; then
  api GET /terms/text; terms="$RESP"
  [ "$HTTP_CODE" = 200 ] || fail "terms/text alinamadi (HTTP $HTTP_CODE): $(api_error_msg "$terms")"
  echo; printf '%s=== EVREN Kullanim Sartlari (v%s) ===%s\n' "$C_YEL" "$terms_version" "$C_OFF"
  jq -r '.content // .text // .' <<<"$terms"
  echo
  read -rp "Bu kullanim sartlarini kabul ediyor musunuz? Kabul icin EVET yazin: " answer
  answer="$(printf '%s' "$answer" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  [ "$answer" = "EVET" ] || fail "Kullanim sartlari kabul edilmedi. Kurulum durduruldu (hicbir sey kaydedilmedi)."
  # Surum numarasi API'den geldigi tipte geri gonderilir (eski script [int] zorluyordu).
  api POST /terms/accept "$(jq -c '{version: .current_version}' <<<"$status")"; accept="$RESP"
  [ "$HTTP_CODE" = 200 ] || fail "terms/accept basarisiz (HTTP $HTTP_CODE): $(api_error_msg "$accept")"
  ok "Kullanim sartlari kabul edildi (v$(jq -r '.accepted_version // empty' <<<"$accept"))."
  api GET /terms/status
  [ "$HTTP_CODE" = 200 ] && [ "$(jq -r '.accepted' <<<"$RESP")" = true ] \
    || fail "Kabul durumu dogrulanamadi (accepted=true degil)."
  ok "Kabul durumu dogrulandi."
else
  ok "Kullanim sartlari zaten kabul edilmis (v$terms_version)."
fi

# ── 3) Model listesi ─────────────────────────────────────────────────────────
if ! fetch_models; then
  warn "Model listesi API'den alinamadi (HTTP $HTTP_CODE); son bilinen liste kullanilacak."
  MODELS="$(models_map <<<"$FALLBACK_MODELS_JSON")"
fi

# ── 4) Anahtari kaydet (sadece sahibi okuyabilir) ────────────────────────────
mkdir -p "$CONFIG_DIR"
( umask 077; printf '%s' "$API_KEY" > "$KEY_FILE" )
chmod 600 "$KEY_FILE"
ok "API anahtari kaydedildi: $KEY_FILE (izin 600)"

# ── 5) Config'e yaz ──────────────────────────────────────────────────────────
NEW_CFG="$(merge_config <<<"$CFG_JSON")"
backup_config
write_config "$NEW_CFG"
ok "OpenCode config guncellendi (diger provider'lar korundu): $CONFIG_PATH"
info "Varsayilan model: $(jq -r '.model' "$CONFIG_PATH")  |  small_model: $(jq -r '.small_model' "$CONFIG_PATH")"

# ── 6) Dogrula ───────────────────────────────────────────────────────────────
echo
verify_opencode
echo
printf '%sTest:%s     opencode run --model %s/glm-5.3 "Sadece EVREN OK yaz."\n' "$C_CYN" "$C_OFF" "$PROVIDER_ID"
printf '%sGuncelle:%s %s --sync-models\n' "$C_CYN" "$C_OFF" "$0"
printf '%sKaldir:%s   %s --uninstall\n' "$C_CYN" "$C_OFF" "$0"
