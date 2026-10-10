#!/usr/bin/env bash
# =============================================================================
# setup-neoforge.sh — Instalador de servidor Minecraft NeoForge 1.21.1
# online-mode=false · Playit.gg · interface com progresso · IA de reparo (Claude)
#
# Uso:    bash setup-neoforge.sh [opções]      Depois: bash server/start.sh
# Ajuda:  bash setup-neoforge.sh --help
# =============================================================================
set -Eeuo pipefail

MC_VERSION="1.21.1"
NEO_REGEX='^21\.1\.[0-9]+$'   # NeoForge 21.1.x = Minecraft 1.21.1
MAVEN="https://maven.neoforged.net/releases/net/neoforged/neoforge"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="${SERVER_DIR:-$SCRIPT_DIR/server}"
LOG="$SERVER_DIR/setup.log"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-haiku-5-5}"

NO_PLAYIT=0; YES_EULA=0; NO_AI=0; AI_AUTO=0
JAVA_DIR=""; AI_ON=0; AI_TRIES=0; AI_DIR=""; STATE_FILE=""
UI=0; COLS=80; RUN_PID=""
STEP_N=0; STEP_TOTAL=0; STEPS_DONE=0
C0=""; CB=""; CD=""; CG=""; CR=""; CY=""; CC=""

usage() {
  cat <<'TXT'
Uso: bash setup-neoforge.sh [opções]

  --no-playit   não instala o túnel Playit.gg
  --yes-eula    aceita a EULA da Mojang sem perguntar (https://aka.ms/MinecraftEULA)
  --no-ai       desliga a IA de reparo
  --ai-auto     a IA aplica sozinha correções simples e seguras (apt install, mkdir, ...);
                qualquer outra coisa continua pedindo sua confirmação
  -h, --help    mostra esta ajuda

Variáveis opcionais:
  SERVER_DIR=/caminho       pasta do servidor (padrão: ./server ao lado do script)
  NEOFORGE_VERSION=21.1.X   força uma versão (padrão: a 21.1.x mais nova)
  RAM_MB=6144               RAM do servidor (padrão: 75% da RAM, entre 1.5 e 12 GB)
  ANTHROPIC_API_KEY=...     chave da API pra IA de reparo (ou cole quando o script pedir)
  CLAUDE_MODEL=...          modelo da IA (padrão: claude-haiku-5-5)
  AI_SEARCH=0               impede a IA de pesquisar na web

Mods por link: crie "mods-urls.txt" ao lado do script, com um link direto de .jar
por linha (# = comentário). Ou ponha os .jar em server/mods.
É seguro rodar de novo: o que já está pronto é pulado. Log completo: server/setup.log
TXT
}

# ---------- log (vai pro arquivo; a tela é desenhada pela interface) ----------
log()  { printf '[ok] %s\n' "$*"; }
warn() { printf '[aviso] %s\n' "$*" >&2; }
die()  { printf '[erro] %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$(id -u)" -ne 0 ] && need sudo; then SUDO="sudo -n"; fi

# ---------- interface ---------------------------------------------------------
setup_ui() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    UI=1
    C0=$'\033[0m'; CB=$'\033[1m'; CD=$'\033[2m'
    CG=$'\033[32m'; CR=$'\033[31m'; CY=$'\033[33m'; CC=$'\033[36m'
    COLS="$(tput cols 2>/dev/null || echo 80)"
    [ "$COLS" -ge 30 ] 2>/dev/null || COLS=80
  fi
}

ui_ok()   { printf '  %s✔%s %s\n' "$CG" "$C0" "$1"; }
ui_fail() { printf '  %s✖%s %s\n' "$CR" "$C0" "$1"; }
ui_warn() { printf '  %s⚠%s %s\n' "$CY" "$C0" "$1"; }
ui_note() { printf '  %s%s%s\n' "$CD" "$1" "$C0"; }

bar() { # porcentagem largura
  local pct="$1" w="$2" filled i s=""
  filled=$(( pct * w / 100 ))
  for ((i = 0; i < w; i++)); do
    if [ "$i" -lt "$filled" ]; then s+="█"; else s+="░"; fi
  done
  printf '%s' "$s"
}

banner() {
  printf '\n%s╭──────────────────────────────────────────────────╮%s\n' "$CC" "$C0"
  printf '%s│%s %s%-48s%s %s│%s\n' "$CC" "$C0" "$CB" "NeoForge $MC_VERSION - Instalador de servidor" "$C0" "$CC" "$C0"
  printf '%s│%s %-48s %s│%s\n' "$CC" "$C0" "online-mode=false | Playit | IA de reparo" "$CC" "$C0"
  printf '%s╰──────────────────────────────────────────────────╯%s\n\n' "$CC" "$C0"
}

draw() { # quadro rótulo segundos última_linha
  local w=22 pct=0 l1 l2 l3
  if [ "$COLS" -lt 60 ]; then w=10; fi
  if [ "$STEP_TOTAL" -gt 0 ]; then pct=$(( STEPS_DONE * 100 / STEP_TOTAL )); fi
  l1="  ${CC}$1${C0} ${2:0:$((COLS - 14))} ${CD}${3}s${C0}"
  l2="  ${CC}$(bar "$pct" "$w")${C0} ${pct}% ${CD}(${STEPS_DONE}/${STEP_TOTAL} passos)${C0}"
  l3="    ${CD}↳ ${4:0:$((COLS - 8))}${C0}"
  printf '\r\033[K%s\n\033[K%s\n\033[K%s\033[2A\r' "$l1" "$l2" "$l3"
}

# Roda "$@" em segundo plano (com log), mostrando spinner + barra. Devolve o código de saída.
run_bg() { # rótulo comando...
  local label="$1"; shift
  (
    trap 'rc=$?; [ "$rc" -eq 10 ] || printf "[erro] Um comando falhou inesperadamente (código %s)\n" "$rc" >&2' ERR
    set -e
    "$@"
  ) >>"$LOG" 2>&1 &
  RUN_PID=$!
  local start=$SECONDS i=0 rc=0 last=""
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  if [ "$UI" -eq 1 ]; then
    printf '\033[?25l'
    while kill -0 "$RUN_PID" 2>/dev/null; do
      last="$(tail -n1 "$LOG" 2>/dev/null | tr -d '\r' || true)"
      draw "${frames[i % 10]}" "$label" "$((SECONDS - start))" "$last"
      i=$((i + 1))
      sleep 0.1
    done
    printf '\r\033[K\n\033[K\n\033[K\033[2A\r\033[?25h'
  else
    printf '  ... %s\n' "$label"
  fi
  wait "$RUN_PID" || rc=$?
  RUN_PID=""
  return "$rc"
}

cleanup() {
  if [ "$UI" -eq 1 ]; then printf '\033[?25h'; fi
  if [ -n "$RUN_PID" ]; then
    pkill -P "$RUN_PID" 2>/dev/null || true
    kill "$RUN_PID" 2>/dev/null || true
  fi
  if [ -n "$AI_DIR" ]; then rm -rf "$AI_DIR"; fi
  if [ -n "$STATE_FILE" ]; then rm -f "$STATE_FILE"; fi
}

state_set() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }
state_get() { grep -E "^$1=" "$STATE_FILE" | tail -n1 | cut -d= -f2- || true; }

confirm() { # pergunta [auto]
  if [ "$AI_AUTO" -eq 1 ] && [ "${2:-}" = "auto" ]; then return 0; fi
  [ -t 0 ] || return 1
  local ans=""
  read -r -p "  $1 [s/N] " ans || return 1
  case "$ans" in s|S|sim|Sim|y|Y) return 0 ;; *) return 1 ;; esac
}

# ---------- utilidades --------------------------------------------------------
download() { # url destino
  local url="$1" dest="$2" tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  if ! curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 -sS -o "$tmp" "$url"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dest"
}

valid_jar() { # um .jar é um zip: começa com "PK" e não é minúsculo
  [ -s "$1" ] || return 1
  [ "$(wc -c < "$1")" -gt 1000 ] || return 1
  [ "$(head -c2 "$1")" = "PK" ]
}

is_installed() { [ -f "$SERVER_DIR/run.sh" ] && [ -d "$SERVER_DIR/libraries/net/neoforged/neoforge" ]; }

# ---------- Java 21 -----------------------------------------------------------
java_major_of() {
  "$1" -version 2>&1 | awk -F'[".]' '/version/ {print ($2=="1") ? $3 : $2; exit}'
}

find_java21() {
  local j major
  for j in "$(command -v java 2>/dev/null || true)" /usr/lib/jvm/*21*/bin/java; do
    [ -x "$j" ] || continue
    major="$(java_major_of "$j" || true)"
    if [ "${major:-0}" -ge 21 ] 2>/dev/null; then
      dirname "$j"
      return 0
    fi
  done
  return 1
}

ensure_java() {
  if JAVA_DIR="$(find_java21)"; then log "Java 21+ encontrado em $JAVA_DIR"; return 0; fi
  warn "Java 21 não encontrado. Instalando openjdk-21-jre-headless..."
  need apt-get || die "Sem apt-get. Instale o Java 21 manualmente e rode de novo."
  $SUDO apt-get update -y || warn "apt update falhou parcialmente; tentando instalar assim mesmo."
  $SUDO apt-get install -y openjdk-21-jre-headless \
    || die "Não consegui instalar o openjdk-21-jre-headless (sem permissão de sudo?)."
  JAVA_DIR="$(find_java21)" || die "Instalei o Java 21, mas não achei o binário. Veja: ls /usr/lib/jvm"
  log "Java 21 instalado em $JAVA_DIR"
}

refresh_java() {
  if JAVA_DIR="$(find_java21)"; then export PATH="$JAVA_DIR:$PATH"; fi
}

# ---------- NeoForge ----------------------------------------------------------
latest_neoforge() {
  local xml
  xml="$(curl -fsSL --retry 3 --connect-timeout 15 "$MAVEN/maven-metadata.xml")" || return 1
  printf '%s' "$xml" \
    | grep -oE '<version>[^<]+</version>' \
    | sed -E 's#</?version>##g' \
    | grep -E "$NEO_REGEX" \
    | sort -V | tail -n1 || true
}

verify_sha1() { # arquivo url
  local want got
  want="$(curl -fsSL --retry 2 --connect-timeout 15 "$2.sha1" 2>/dev/null | awk '{print $1}' || true)"
  if ! [[ "$want" =~ ^[0-9a-f]{40}$ ]]; then
    warn "Sem checksum online; pulei a verificação do instalador."
    return 0
  fi
  got="$(sha1sum "$1" | awk '{print $1}')"
  [ "$want" = "$got" ]
}

# ---------- passos (cada um roda em segundo plano, por isso se reiniciam sozinhos) ----
step_check() {
  cd "$SERVER_DIR"
  need curl || die "O curl não está instalado."
  local avail
  avail="$(df -Pm . | awk 'NR==2 {print $4}')"
  [ "${avail:-0}" -ge 1500 ] || die "Pouco espaço em disco (${avail:-?} MB livres). Preciso de pelo menos 1500 MB."
  log "Sistema ok: ${avail} MB livres, RAM total $(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo) MB"
}

step_java() { ensure_java; }

step_version() {
  local ver="${NEOFORGE_VERSION:-}"
  if [ -z "$ver" ]; then ver="$(latest_neoforge)" || true; fi
  [ -n "$ver" ] || die "Não consegui descobrir a versão mais nova. Rode com NEOFORGE_VERSION=21.1.X"
  [[ "$ver" =~ $NEO_REGEX ]] || warn "A versão $ver não parece 21.1.x (Minecraft $MC_VERSION)."
  state_set NEO_VER "$ver"
  log "NeoForge $ver"
}

step_download() {
  cd "$SERVER_DIR"
  if is_installed; then log "NeoForge já instalado, nada a baixar."; return 0; fi
  local ver url inst="neoforge-installer.jar"
  ver="$(state_get NEO_VER)"
  [ -n "$ver" ] || die "Versão do NeoForge desconhecida."
  url="$MAVEN/$ver/neoforge-$ver-installer.jar"
  download "$url" "$inst" || die "Falha ao baixar $url (a versão não existe ou sem internet)."
  valid_jar "$inst" || { rm -f "$inst"; die "O instalador baixado está corrompido."; }
  verify_sha1 "$inst" "$url" || { rm -f "$inst"; die "Checksum do instalador não bate (download corrompido)."; }
  log "Instalador baixado e verificado."
}

step_install() {
  cd "$SERVER_DIR"
  if is_installed; then log "NeoForge já instalado, pulando."; return 0; fi
  [ -f neoforge-installer.jar ] || die "Instalador não encontrado (neoforge-installer.jar)."
  java -jar neoforge-installer.jar --installServer \
    || die "O instalador do NeoForge falhou. Veja installer.jar.log nesta pasta."
  [ -f run.sh ] || die "A instalação terminou sem criar o run.sh."
  chmod +x run.sh
  rm -f neoforge-installer.jar
  log "NeoForge instalado."
}

set_prop() { # chave valor (valores simples, sem | nem &)
  local k="$1" v="$2" f="server.properties"
  touch "$f"
  if grep -qE "^${k}=" "$f"; then
    sed -i -E "s|^${k}=.*|${k}=${v}|" "$f"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

auto_ram() {
  local total ram
  total="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  ram=$(( total * 75 / 100 ))
  if [ "$ram" -gt 12288 ]; then ram=12288; fi
  if [ "$ram" -lt 1536 ]; then ram=1536; fi
  echo "$ram"
}

step_config() {
  cd "$SERVER_DIR"
  set_prop "online-mode" "false"
  set_prop "enforce-secure-profile" "false"
  log "server.properties: online-mode=false"
  local ram="${RAM_MB:-$(auto_ram)}"
  case "$ram" in ''|*[!0-9]*) die "RAM_MB precisa ser um número (ex.: 4096)." ;; esac
  touch user_jvm_args.txt
  sed -i -E '/^[[:space:]]*-Xm[sx]/d' user_jvm_args.txt
  printf -- '-Xms1024M\n-Xmx%sM\n' "$ram" >> user_jvm_args.txt
  log "RAM do servidor: ${ram} MB"
}

step_mods() {
  cd "$SERVER_DIR"
  mkdir -p mods
  local list="$SCRIPT_DIR/mods-urls.txt" url name n=0
  if [ ! -f "$list" ]; then log "Pasta mods pronta (sem mods-urls.txt)."; return 0; fi
  while IFS= read -r url || [ -n "$url" ]; do
    url="$(printf '%s' "$url" | tr -d '\r' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    case "$url" in ''|'#'*) continue ;; esac
    name="$(basename "${url%%\?*}")"
    case "$name" in *.jar) ;; *) warn "Ignorei (não termina em .jar): $url"; continue ;; esac
    case "$name" in *[!A-Za-z0-9._+-]*) warn "Ignorei (nome de arquivo estranho): $name"; continue ;; esac
    if [ -f "mods/$name" ]; then continue; fi
    if download "$url" "mods/$name" && valid_jar "mods/$name"; then
      n=$((n + 1))
      log "Mod baixado: $name"
    else
      rm -f "mods/$name"
      warn "Falhou, pulei: $url"
    fi
  done < "$list"
  log "Mods baixados agora: $n"
}

install_playit() {
  if need playit; then log "Playit já instalado."; return 0; fi
  need apt-get || return 1
  need gpg || { $SUDO apt-get install -y gnupg || return 1; }
  curl -fsSL https://playit-cloud.github.io/ppa/key.gpg | gpg --dearmor \
    | $SUDO tee /etc/apt/trusted.gpg.d/playit.gpg >/dev/null || return 1
  echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" \
    | $SUDO tee /etc/apt/sources.list.d/playit-cloud.list >/dev/null || return 1
  $SUDO apt-get update -y || warn "apt update falhou parcialmente; tentando instalar assim mesmo."
  $SUDO apt-get install -y playit || return 1
  log "Playit instalado."
}

step_playit() { install_playit || return 10; }   # 10 = pulado com aviso (não é fatal)

step_finish() {
  cd "$SERVER_DIR"
  cat > start.sh <<'EOF'
#!/usr/bin/env bash
# Inicia o Playit (se existir) e o servidor NeoForge.
cd "$(dirname "$0")" || exit 1
export PATH="__JAVA_DIR__:$PATH"
PLAYIT_PID=""
cleanup() { if [ -n "$PLAYIT_PID" ]; then kill "$PLAYIT_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT

if command -v playit >/dev/null 2>&1; then
  if pgrep -x playit >/dev/null 2>&1; then
    echo "[playit] já está rodando."
  else
    nohup playit > playit.log 2>&1 &
    PLAYIT_PID=$!
    echo "[playit] iniciado. Procurando o link (até 10 s)..."
    sleep 10
    strings playit.log | grep -iE 'claim|playit\.gg|\.link|\.gg' | tail -n 5 || true
    echo "[playit] Se não apareceu link/IP acima, abra outro terminal e rode: playit"
  fi
fi

echo "[servidor] iniciando... (digite 'stop' no console pra desligar com segurança)"
bash run.sh nogui
EOF
  sed -i "s|__JAVA_DIR__|${JAVA_DIR}|" start.sh
  chmod +x start.sh
  log "start.sh criado."
}

# ---------- IA de reparo (Claude) --------------------------------------------
# Segurança: a IA só SUGERE. Nada roda sem sua confirmação, exceto com --ai-auto e só
# para comandos simples de uma lista permitida. Comandos perigosos são sempre bloqueados.
is_dangerous() {
  local c="$1"
  local re_rm='rm +-[a-zA-Z]*[rf][a-zA-Z]* +(/|~|\$HOME|\*)'
  local re_sys='(mkfs|dd +if=|:\(\)|shutdown|reboot|halt|>[[:space:]]*/dev/|chmod +-R +[0-7]+ +/|chown +-R +[^ ]+ +/)'
  local re_pipe='(curl|wget)[^|]*\|[[:space:]]*(sudo +)?(ba)?sh'
  local re_secret='(ANTHROPIC_API_KEY|/etc/passwd|/etc/shadow|ssh|authorized_keys|\.bashrc|\.profile)'
  local re_eval='(^|[[:space:];|&])eval[[:space:]]'
  if [[ "$c" =~ $re_rm ]] || [[ "$c" =~ $re_sys ]] || [[ "$c" =~ $re_pipe ]] \
     || [[ "$c" =~ $re_secret ]] || [[ "$c" =~ $re_eval ]]; then
    return 0
  fi
  return 1
}

is_auto_safe() {
  local c="$1"
  case "$c" in
    *\;*|*\&*|*\|*|*\`*|*\>*|*\<*|*\$*|*\(*|*\)*|*\{*|*\}*|*\\*|*..*) return 1 ;;
  esac
  local re_apt='^(sudo +)?apt-get +(update|install +-y +[a-z0-9.+-]+( +[a-z0-9.+-]+)*)$'
  local re_mk='^mkdir +-p +[A-Za-z0-9._/-]+$'
  local re_rm='^rm +-f +[A-Za-z0-9._+-]+$'
  local re_ch='^chmod +\+x +[A-Za-z0-9._-]+$'
  if [[ "$c" =~ $re_apt ]] || { [[ "$c" =~ $re_mk ]] && [[ "$c" != *" /"* ]]; } \
     || [[ "$c" =~ $re_rm ]] || [[ "$c" =~ $re_ch ]]; then
    return 0
  fi
  return 1
}

build_ctx() { # rótulo do passo
  {
    echo "PASSO QUE FALHOU: $1"
    echo "MINECRAFT: $MC_VERSION (NeoForge 21.1.x), online-mode=false"
    echo "VARIAVEIS: NEOFORGE_VERSION=${NEOFORGE_VERSION:-<auto>} RAM_MB=${RAM_MB:-<auto>}"
    echo "SISTEMA: $( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-?}") || echo ?) | $(uname -m)"
    echo "JAVA: $(java -version 2>&1 | head -n1 || true)"
    echo "RAM/DISCO: $(free -m 2>/dev/null | awk '/Mem:/ {print $2" MB total, "$7" MB livre"}') | $(df -Pm "$SERVER_DIR" | awk 'NR==2 {print $4" MB livres"}')"
    echo "ARQUIVOS NA PASTA: $(ls "$SERVER_DIR" 2>/dev/null | head -n 30 | tr '\n' ' ')"
    echo "--- ÚLTIMAS 80 LINHAS DO LOG ---"
    tail -n 80 "$LOG" | sed -E 's/sk-ant-[A-Za-z0-9_-]+/[REDACTED]/g'
  } > "$AI_DIR/ctx.txt"
}

ai_call() {
  export AI_DIR CLAUDE_MODEL
  python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error

D = os.environ["AI_DIR"]
KEY = os.environ["ANTHROPIC_API_KEY"]
MODEL = os.environ.get("CLAUDE_MODEL", "claude-haiku-5-5")
BASE = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
ctx = open(os.path.join(D, "ctx.txt"), encoding="utf-8", errors="replace").read()

SYSTEM = (
    "Você é o assistente de reparo de um instalador de servidor Minecraft (NeoForge 1.21.1, Java 21, "
    "online-mode=false, Linux tipo Debian/Ubuntu, possivelmente GitHub Codespaces). Receberá o passo que "
    "falhou, informações do sistema e o final do log. Responda SOMENTE com um objeto JSON, sem markdown, "
    "com as chaves: "
    "\"diagnosis\" (string curta e clara em português: o que deu errado e por quê); "
    "\"env\" (objeto; só pode conter as chaves NEOFORGE_VERSION, com uma versão 21.1.x que você tenha "
    "confirmado que existe, e RAM_MB, número); "
    "\"fixes\" (lista de objetos {\"description\": string, \"command\": string}); comandos bash simples, "
    "de uma linha, não interativos, rodados na pasta do servidor; prefira apt-get install -y, mkdir -p, "
    "chmod +x e rm -f de um arquivo relativo corrompido; nunca use pipes pra shell nem apague nada fora "
    "da pasta do servidor. "
    "Se não houver correção automática possível, devolva env {} e fixes [] e explique na diagnosis o que o "
    "usuário deve fazer. Se precisar confirmar uma versão, erro ou pacote, pesquise na web."
)

def call(search):
    body = {"model": MODEL, "max_tokens": 1500, "system": SYSTEM,
            "messages": [{"role": "user", "content": ctx}]}
    if search:
        body["tools"] = [{"type": "web_search_20250305", "name": "web_search", "max_uses": 3}]
    req = urllib.request.Request(
        BASE + "/v1/messages", data=json.dumps(body).encode(), method="POST",
        headers={"content-type": "application/json", "x-api-key": KEY,
                 "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)

def fail(msg, code):
    open(os.path.join(D, "error"), "w", encoding="utf-8").write(msg)
    sys.exit(code)

data, searched, last_err = None, False, "sem resposta"
modes = (True, False) if os.environ.get("AI_SEARCH", "1") != "0" else (False,)
for use_search in modes:
    try:
        data, searched = call(use_search), use_search
        break
    except urllib.error.HTTPError as e:
        try:
            last_err = "%s: %s" % (e.code, json.load(e)["error"]["message"])
        except Exception:
            last_err = "HTTP %s" % e.code
        if e.code in (401, 403):
            fail("a API recusou a chave (%s)" % last_err, 2)
    except Exception as e:
        last_err = "falha de rede (%s)" % e
if data is None:
    fail(last_err, 2)

text = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
a, b = text.find("{"), text.rfind("}")
try:
    out = json.loads(text[a:b + 1])
except Exception:
    fail("a resposta da IA não veio em JSON", 3)

def one_line(s):
    return " ".join(str(s).split())

open(os.path.join(D, "diag"), "w", encoding="utf-8").write(str(out.get("diagnosis", "")).strip())
if searched and any(x.get("type") == "server_tool_use" for x in data.get("content", [])):
    open(os.path.join(D, "searched"), "w").write("1")
with open(os.path.join(D, "env.txt"), "w", encoding="utf-8") as f:
    env = out.get("env") or {}
    if isinstance(env, dict):
        for k, v in env.items():
            f.write("%s=%s\n" % (one_line(k), one_line(v)))
with open(os.path.join(D, "fixes.tsv"), "w", encoding="utf-8") as f:
    fixes = out.get("fixes") or []
    if isinstance(fixes, list):
        for fx in fixes:
            if isinstance(fx, dict) and fx.get("command") and "\n" not in str(fx["command"]):
                f.write("%s\t%s\n" % (one_line(fx.get("description", "")), str(fx["command"]).strip()))
PY
}

ai_repair() { # rótulo do passo. Devolve 0 se aplicou algo (vale tentar de novo).
  if [ "$AI_ON" -ne 1 ]; then
    ui_note "Dica: com ANTHROPIC_API_KEY definida, a IA diagnostica e corrige erros sozinha."
    return 1
  fi
  if [ "$AI_TRIES" -ge 2 ]; then ui_warn "A IA já tentou 2 correções neste passo."; return 1; fi
  AI_TRIES=$((AI_TRIES + 1))
  rm -f "$AI_DIR"/diag "$AI_DIR"/fixes.tsv "$AI_DIR"/env.txt "$AI_DIR"/searched "$AI_DIR"/error
  build_ctx "$1"

  local rc=0
  set +e; run_bg "IA analisando o erro (tentativa $AI_TRIES/2)" ai_call; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    ui_warn "IA indisponível: $(cat "$AI_DIR/error" 2>/dev/null || echo 'veja setup.log')"
    return 1
  fi

  printf '\n  %s◆ IA%s' "$CB$CC" "$C0"
  if [ -f "$AI_DIR/searched" ]; then printf ' %s(pesquisou na web)%s' "$CD" "$C0"; fi
  printf '\n'
  fold -s -w $((COLS - 6)) "$AI_DIR/diag" | sed 's/^/    /'
  printf '\n'

  local applied=0 k v desc cmd auto
  while IFS='=' read -r -u 3 k v; do
    case "$k" in NEOFORGE_VERSION|RAM_MB) ;; *) continue ;; esac
    [[ "$v" =~ ^[0-9][0-9.]*$ ]] || continue
    if confirm "Aplicar a configuração $k=$v?" auto; then
      export "$k=$v"
      if [ "$k" = "NEOFORGE_VERSION" ]; then
        state_set NEO_VER "$v"
        rm -f "$SERVER_DIR/neoforge-installer.jar"
      fi
      ui_ok "Configuração aplicada: $k=$v"
      applied=1
    fi
  done 3< "$AI_DIR/env.txt"

  while IFS=$'\t' read -r -u 3 desc cmd; do
    [ -n "$cmd" ] || continue
    if is_dangerous "$cmd"; then ui_warn "Bloqueei um comando perigoso sugerido pela IA: $cmd"; continue; fi
    printf '  %s•%s %s\n    %s$ %s%s\n' "$CY" "$C0" "$desc" "$CD" "$cmd" "$C0"
    auto=""
    if is_auto_safe "$cmd"; then auto="auto"; fi
    confirm "Rodar este comando?" "$auto" || continue
    cmd="${cmd/#sudo /sudo -n }"
    rc=0
    set +e
    run_bg "Aplicando correção" bash -c 'cd "$0" && exec bash -c "$1"' "$SERVER_DIR" "$cmd"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then ui_ok "Correção aplicada."; applied=1; else ui_fail "O comando falhou (veja setup.log)."; fi
  done 3< "$AI_DIR/fixes.tsv"

  [ "$applied" -eq 1 ]
}

# ---------- executor de passos ------------------------------------------------
show_failure() {
  local reason
  reason="$(grep -E '^\[erro\]' "$LOG" | tail -n1 || true)"
  if [ -n "$reason" ]; then ui_note "Motivo: $reason"; fi
  ui_note "Últimas linhas do log:"
  tail -n 8 "$LOG" | sed -E 's/^/      /' | cut -c1-$((COLS - 2)) || true
}

run_step() { # rótulo explicação função
  local label="$1" why="$2"; shift 2
  STEP_N=$((STEP_N + 1)); AI_TRIES=0
  printf '  %s%s%s\n' "$CB" "[$STEP_N/$STEP_TOTAL] $label" "$C0"
  ui_note "$why"
  local rc t0=$SECONDS
  while :; do
    rc=0
    set +e; run_bg "$label" "$@"; rc=$?; set -e
    if [ "$rc" -eq 0 ]; then
      ui_ok "$label ($((SECONDS - t0))s)"
      STEPS_DONE=$((STEPS_DONE + 1))
      return 0
    fi
    if [ "$rc" -eq 10 ]; then
      ui_warn "$label: pulado (não é essencial; veja setup.log)"
      STEPS_DONE=$((STEPS_DONE + 1))
      return 0
    fi
    ui_fail "$label falhou"
    show_failure
    if ai_repair "$label"; then
      ui_note "Tentando este passo de novo com as correções..."
      continue
    fi
    printf '\n  %sInstalação interrompida.%s Log completo: %s\n  Corrija o problema e rode de novo: o script continua de onde parou.\n\n' "$CR" "$C0" "$LOG"
    exit 1
  done
}

# ---------- início ------------------------------------------------------------
accept_eula() {
  cd "$SERVER_DIR"
  if grep -qs '^eula=true' eula.txt; then ui_ok "EULA da Mojang já aceita."; return 0; fi
  if [ "$YES_EULA" -ne 1 ]; then
    printf '  Para rodar o servidor você precisa aceitar a EULA da Mojang:\n  %shttps://aka.ms/MinecraftEULA%s\n' "$CC" "$C0"
    [ -t 0 ] || die "Sem terminal interativo. Rode com --yes-eula se você aceita a EULA."
    confirm "Você aceita a EULA?" || die "EULA não aceita. Nada foi instalado."
  fi
  printf '# EULA aceita em %s\neula=true\n' "$(date -u +%FT%TZ)" > eula.txt
  ui_ok "EULA registrada."
}

preflight() {
  banner
  printf '  %-14s %s\n' "Pasta:" "$SERVER_DIR"
  printf '  %-14s %s\n' "Playit:" "$([ "$NO_PLAYIT" -eq 1 ] && echo desligado || echo ligado)"

  if [ "$NO_AI" -eq 0 ]; then
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -t 0 ]; then
      local key=""
      printf '  Chave da API da Anthropic pra IA de reparo (Enter pula): '
      read -rs key || true
      printf '\n'
      if [ -n "$key" ]; then export ANTHROPIC_API_KEY="$key"; fi
    fi
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      if need python3; then AI_ON=1; else ui_warn "python3 não encontrado: IA desligada."; fi
    fi
  fi
  if [ "$AI_ON" -eq 1 ]; then
    printf '  %-14s %sligada%s (%s)\n' "IA de reparo:" "$CG" "$C0" "$CLAUDE_MODEL"
    ui_note "Se algo falhar, o fim do log e dados básicos do sistema vão pra API da Anthropic."
  else
    printf '  %-14s desligada\n' "IA de reparo:"
  fi
  printf '\n'
  accept_eula
  printf '\n'
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --no-playit) NO_PLAYIT=1 ;;
      --yes-eula)  YES_EULA=1 ;;
      --no-ai)     NO_AI=1 ;;
      --ai-auto)   AI_AUTO=1 ;;
      -h|--help)   usage; exit 0 ;;
      *) die "Opção desconhecida: $arg (use --help)" ;;
    esac
  done

  mkdir -p "$SERVER_DIR"
  printf '\n===== %s =====\n' "$(date -u +%FT%TZ)" >> "$LOG"
  AI_DIR="$(mktemp -d)"
  STATE_FILE="$(mktemp)"
  trap cleanup EXIT
  trap 'printf "\n"; ui_warn "Interrompido."; exit 130' INT TERM
  setup_ui
  preflight

  STEP_TOTAL=9
  if [ "$NO_PLAYIT" -eq 1 ]; then STEP_TOTAL=8; fi

  run_step "Verificando o sistema" "Confiro internet, ferramentas e espaço em disco." step_check
  run_step "Preparando o Java 21" "O NeoForge $MC_VERSION exige Java 21; instalo se faltar." step_java
  refresh_java
  run_step "Procurando a versão do NeoForge" "Consulto o repositório oficial pela 21.1.x mais nova." step_version
  run_step "Baixando o instalador" "Baixo do repositório oficial e confiro se o arquivo está íntegro." step_download
  run_step "Instalando o NeoForge" "Baixa o Minecraft e as bibliotecas; pode levar alguns minutos." step_install
  run_step "Configurando o servidor" "Deixo online-mode=false e ajusto a RAM do Java." step_config
  run_step "Preparando os mods" "Baixo os mods do mods-urls.txt, se existir." step_mods
  if [ "$NO_PLAYIT" -eq 0 ]; then
    run_step "Instalando o Playit.gg" "Túnel pra seus amigos entrarem sem abrir porta." step_playit
  fi
  run_step "Criando o start.sh" "Script que liga o Playit e o servidor juntos." step_finish

  local w=22
  if [ "$COLS" -lt 60 ]; then w=10; fi
  printf '\n  %s%s%s 100%%\n' "$CG" "$(bar 100 "$w")" "$C0"
  printf '\n  %sTudo pronto!%s\n' "$CB$CG" "$C0"
  printf '  Para iniciar:   %sbash "%s/start.sh"%s\n' "$CC" "$SERVER_DIR" "$C0"
  printf '  Mods:           coloque os .jar (NeoForge %s) em %s/mods\n' "$MC_VERSION" "$SERVER_DIR"
  printf '  Log completo:   %s\n\n' "$LOG"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
