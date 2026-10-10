#!/usr/bin/env bash
# =============================================================================
# setup-playit.sh — baixa o Playit.gg (túnel pro servidor Minecraft) à prova de erros
#
# Uso:    bash setup-playit.sh
# Opções: SERVER_DIR=/caminho   (padrão: ./server ao lado do script)
#         PLAYIT_VERSION=v0.15.26  (força uma versão; padrão: a mais nova)
#
# Estratégia (para na primeira que funcionar):
#   1) binário da versão mais nova no GitHub
#   2) binário de uma versão fixa conhecida (v0.15.26)
#   3) pacote apt (repositório oficial do Playit)
# Cada download tem tentativas repetidas, validação (é mesmo um executável?)
# e teste de execução. Seguro rodar de novo: se já funciona, ele só avisa.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="${SERVER_DIR:-$SCRIPT_DIR/server}"
FALLBACK_VERSION="v0.15.26"
REPO="https://github.com/playit-cloud/playit-agent/releases"
BIN="$SERVER_DIR/playit"

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
info() { printf '  \033[2m%s\033[0m\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*" >&2; }
die()  { printf '  \033[31m✖\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$(id -u)" -ne 0 ] && need sudo; then SUDO="sudo -n"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- arquitetura ----------
case "$(uname -m)" in
  x86_64|amd64)  ASSET="playit-linux-amd64" ;;
  aarch64|arm64) ASSET="playit-linux-aarch64" ;;
  armv7l|armv7*) ASSET="playit-linux-armv7" ;;
  *) ASSET="" ;;
esac

# ---------- utilidades ----------
fetch() { # url destino  (curl ou wget, com tentativas)
  local url="$1" dest="$2"
  if need curl; then
    curl -fL --retry 5 --retry-delay 3 --retry-connrefused \
         --connect-timeout 20 --max-time 300 -sS -o "$dest" "$url"
  elif need wget; then
    wget -q --tries=5 --waitretry=3 --timeout=30 -O "$dest" "$url"
  else
    return 2
  fi
}

is_elf() { # arquivo grande o bastante e começando com \x7fELF
  [ -s "$1" ] || return 1
  [ "$(wc -c < "$1")" -gt 1000000 ] || return 1
  [ "$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]
}

works() { # o binário executa de verdade?
  [ -x "$1" ] || return 1
  timeout 15 "$1" --version >/dev/null 2>&1 || timeout 15 "$1" -V >/dev/null 2>&1 \
    || timeout 15 "$1" --help >/dev/null 2>&1
}

try_binary() { # url
  local url="$1" f="$TMP/playit.download"
  info "Baixando: $url"
  rm -f "$f"
  fetch "$url" "$f" || { warn "Download falhou."; return 1; }
  is_elf "$f" || { warn "O arquivo baixado não é um executável válido (corrompido ou página de erro)."; return 1; }
  chmod +x "$f"
  works "$f" || { warn "O binário baixou mas não executa neste sistema."; return 1; }
  mkdir -p "$SERVER_DIR"
  mv -f "$f" "$BIN"
  return 0
}

latest_tag() { # descobre a tag mais nova seguindo o redirecionamento de /releases/latest
  need curl || return 1
  curl -fsSLI --retry 3 --connect-timeout 15 -o /dev/null -w '%{url_effective}' "$REPO/latest" 2>/dev/null \
    | sed -E 's#.*/tag/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || return 1
}

try_apt() {
  need apt-get || return 1
  info "Tentando pelo apt (repositório oficial)..."
  need gpg || $SUDO apt-get install -y gnupg || return 1
  fetch https://playit-cloud.github.io/ppa/key.gpg "$TMP/key.gpg" || return 1
  gpg --dearmor < "$TMP/key.gpg" | $SUDO tee /etc/apt/trusted.gpg.d/playit.gpg >/dev/null || return 1
  echo "deb [signed-by=/etc/apt/trusted.gpg.d/playit.gpg] https://playit-cloud.github.io/ppa/data ./" \
    | $SUDO tee /etc/apt/sources.list.d/playit-cloud.list >/dev/null || return 1
  $SUDO apt-get update -y || warn "apt update falhou parcialmente; tentando assim mesmo."
  $SUDO apt-get install -y playit || return 1
  need playit || return 1
  # linka o binário do apt dentro da pasta do servidor, pra start.sh achar de qualquer jeito
  mkdir -p "$SERVER_DIR"
  ln -sf "$(command -v playit)" "$BIN"
  return 0
}

# ---------- início ----------
printf '\n  \033[1mPlayit.gg — instalador\033[0m\n\n'
mkdir -p "$SERVER_DIR"

if works "$BIN"; then
  ok "Playit já está instalado e funcionando em $BIN"
else
  need curl || need wget || die "Preciso de curl ou wget. Instale com: sudo apt-get install -y curl"
  [ -n "$ASSET" ] || warn "Arquitetura $(uname -m) sem binário conhecido; vou direto pro apt."

  done_ok=0
  if [ -n "$ASSET" ]; then
    tag="${PLAYIT_VERSION:-}"
    [ -n "$tag" ] || tag="$(latest_tag || true)"

    # 1) versão mais nova (ou a forçada)
    if [ -n "$tag" ] && try_binary "$REPO/download/$tag/$ASSET"; then
      ok "Playit $tag instalado."; done_ok=1
    # 1b) atalho "latest" caso a detecção da tag tenha falhado
    elif [ -z "$tag" ] && try_binary "$REPO/latest/download/$ASSET"; then
      ok "Playit (mais novo) instalado."; done_ok=1
    # 2) versão fixa conhecida
    elif [ "$tag" != "$FALLBACK_VERSION" ] && try_binary "$REPO/download/$FALLBACK_VERSION/$ASSET"; then
      ok "Playit $FALLBACK_VERSION instalado (versão de reserva)."; done_ok=1
    fi
  fi

  # 3) apt
  if [ "$done_ok" -eq 0 ]; then
    try_apt && { ok "Playit instalado pelo apt."; done_ok=1; }
  fi

  if [ "$done_ok" -eq 0 ]; then
    die "Não consegui instalar o Playit por nenhum método. Verifique a internet (o GitHub está acessível?)
    ou baixe manualmente em https://playit.gg/download e coloque o arquivo em: $BIN (chmod +x)."
  fi
fi

# ---------- integra com o start.sh do servidor ----------
if [ -f "$SERVER_DIR/start.sh" ]; then
  if ! grep -q 'PLAYIT_LOCAL' "$SERVER_DIR/start.sh"; then
    # garante que a pasta do servidor entra no PATH, pra "command -v playit" achar o binário local
    sed -i '/^cd /a export PATH="$PWD:$PATH"   # PLAYIT_LOCAL' "$SERVER_DIR/start.sh"
    ok "start.sh ajustado pra usar o Playit da pasta do servidor."
  else
    ok "start.sh já está ajustado."
  fi
else
  warn "start.sh não encontrado; rode primeiro o setup-neoforge.sh (ou rode o Playit à mão)."
fi

printf '\n  \033[1;32mPronto!\033[0m\n'
printf '  Para iniciar tudo:  bash "%s/start.sh"\n' "$SERVER_DIR"
printf '  Só o Playit:        "%s"\n' "$BIN"
printf '  Na 1ª vez ele mostra um link de "claim": abra no navegador e crie o túnel Minecraft Java.\n\n'
