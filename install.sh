#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
#  MTG Panel v2 — One-Command Installer
#  Repo: https://github.com/ZenithSolitude/mtg-panel
#  Usage: bash <(curl -fsSL https://raw.githubusercontent.com/ZenithSolitude/mtg-panel/main/install.sh)
# ════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

GITHUB_REPO="ZenithSolitude/mtg-panel"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/main"
MTG_GITHUB="9seconds/mtg"
PANEL_DIR="/opt/mtp-panel"
PANEL_PORT="8888"
MTG_BINARY="/usr/local/bin/mtg"
MTG_SKIP=false

log()  { echo -e "${CYAN}[•]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

banner(){
cat << 'EOF'

  ╔═══════════════════════════════════════════╗
  ║   ███╗   ███╗████████╗ ██████╗            ║
  ║   ████╗ ████║╚══██╔══╝██╔════╝            ║
  ║   ██╔████╔██║   ██║   ██║  ███╗           ║
  ║   ██║╚██╔╝██║   ██║   ██║   ██║           ║
  ║   ██║ ╚═╝ ██║   ██║   ╚██████╔╝           ║
  ║   ╚═╝     ╚═╝   ╚═╝    ╚═════╝  PANEL v2  ║
  ╚═══════════════════════════════════════════╝
       MTProto Proxy Web Management Panel

EOF
}

check_root(){
  [[ $EUID -eq 0 ]] || err "Запустите от root: sudo bash install.sh"
}

detect_arch(){
  MACHINE=$(uname -m)
  case "$MACHINE" in
    x86_64|amd64)     ARCH="amd64" ;;
    aarch64|arm64)    ARCH="arm64" ;;
    armv7*|armv6*)    ARCH="arm"   ;;
    *)                err "Неподдерживаемая архитектура: $MACHINE" ;;
  esac
  log "Архитектура: ${BOLD}${MACHINE}${NC} → ${BOLD}${ARCH}${NC}"
}

detect_os(){
  if   command -v apt-get &>/dev/null; then PKG="apt"
  elif command -v dnf     &>/dev/null; then PKG="dnf"
  elif command -v yum     &>/dev/null; then PKG="yum"
  else err "Не найден пакетный менеджер"; fi
  log "Пакетный менеджер: ${BOLD}${PKG}${NC}"
}

install_packages(){
  step "Системные пакеты"
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq python3 python3-pip python3-venv curl wget net-tools xxd 2>/dev/null || true
      ;;
    dnf|yum)
      $PKG install -y -q python3 python3-pip curl wget net-tools vim-common 2>/dev/null || true
      ;;
  esac
  ok "Пакеты установлены"
}

install_mtg(){
  step "MTG бинарный файл"
  log "Получаю последнюю версию с GitHub..."
  LATEST=$(curl -fsSL "https://api.github.com/repos/${MTG_GITHUB}/releases/latest" \
    | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
  [[ -z "$LATEST" ]] && { warn "Не удалось определить версию, использую v2.2.4"; LATEST="v2.2.4"; }
  log "Версия MTG: ${BOLD}${LATEST}${NC}"

  DL_URL="https://github.com/${MTG_GITHUB}/releases/download/${LATEST}/mtg-linux-${ARCH}"
  if curl -fsSL -o /tmp/mtg_bin "${DL_URL}" 2>/dev/null; then
    mv /tmp/mtg_bin "${MTG_BINARY}"
    chmod +x "${MTG_BINARY}"
    ok "MTG → ${MTG_BINARY}"
  else
    warn "Не удалось скачать MTG автоматически"
    warn "Скачайте вручную: https://github.com/${MTG_GITHUB}/releases"
    warn "Положите файл в ${MTG_BINARY} и: chmod +x ${MTG_BINARY}"
    MTG_SKIP=true
  fi
}

setup_mtg_service(){
  step "Служба MTG"
  [[ "${MTG_SKIP}" == "true" ]] && { warn "MTG не установлен — пропускаю"; return; }
  [[ -f "/etc/systemd/system/mtg.service" ]] && { log "Служба уже настроена"; return; }

  DEFAULT_DOMAIN="itunes.apple.com"
  DEFAULT_PORT="8443"
  log "Генерирую начальный ключ..."

  SECRET=$("${MTG_BINARY}" generate-secret --hex "${DEFAULT_DOMAIN}" 2>/dev/null || \
           "${MTG_BINARY}" generate-secret "${DEFAULT_DOMAIN}" 2>/dev/null || echo "")

  if [[ -z "$SECRET" ]]; then
    warn "Не удалось сгенерировать ключ — задайте его через панель"
    SECRET="ee$(head -c 16 /dev/urandom | xxd -p | tr -d '\n')0000"
  fi

  cat > /etc/systemd/system/mtg.service <<SVC
[Unit]
Description=MTProto Proxy Server (mtg)
After=network.target

[Service]
Type=simple
User=root
ExecStart=${MTG_BINARY} run --bind 0.0.0.0:${DEFAULT_PORT} --fake-tls ${DEFAULT_DOMAIN} ${SECRET}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtg
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVC

  systemctl daemon-reload
  systemctl enable mtg 2>/dev/null || true
  systemctl start  mtg 2>/dev/null || true
  ok "MTG запущен на порту ${DEFAULT_PORT}"
}

install_panel(){
  step "Файлы панели"
  mkdir -p "${PANEL_DIR}"
  for f in app.py index.html requirements.txt; do
    log "  ↓ ${f}"
    curl -fsSL -o "${PANEL_DIR}/${f}" "${RAW_BASE}/${f}" \
      || err "Не удалось скачать ${f}"
  done
  ok "Файлы загружены → ${PANEL_DIR}"
}

setup_venv(){
  step "Python окружение"
  cd "${PANEL_DIR}"
  [[ ! -d venv ]] && python3 -m venv venv
  "${PANEL_DIR}/venv/bin/pip" install --quiet --upgrade pip
  "${PANEL_DIR}/venv/bin/pip" install --quiet -r requirements.txt
  ok "Зависимости установлены"
}

setup_panel_service(){
  step "Служба панели"
  cat > /etc/systemd/system/mtp-panel.service <<SVC
[Unit]
Description=MTG Proxy Web Panel v2
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_DIR}/venv/bin/uvicorn app:app --host 0.0.0.0 --port ${PANEL_PORT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtp-panel

[Install]
WantedBy=multi-user.target
SVC

  systemctl daemon-reload
  systemctl enable mtp-panel
  systemctl restart mtp-panel
  sleep 2
  systemctl is-active --quiet mtp-panel && ok "Панель запущена на :${PANEL_PORT}" \
    || warn "Проверьте: journalctl -u mtp-panel -n30"
}

open_firewall(){
  step "Брандмауэр"
  if command -v ufw &>/dev/null; then
    ufw allow "${PANEL_PORT}/tcp" &>/dev/null || true
    ok "UFW: открыт порт ${PANEL_PORT}"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true
    ok "firewalld: открыт порт ${PANEL_PORT}"
  else
    warn "Брандмауэр не найден — откройте порт ${PANEL_PORT} вручную"
  fi
}

summary(){
  SERVER_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
    || hostname -I | awk '{print $1}' || echo "YOUR_IP")
  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}   УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО ✓${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  ${BOLD}Адрес панели:${NC}"
  echo -e "     ${CYAN}http://${SERVER_IP}:${PANEL_PORT}${NC}"
  echo ""
  echo -e "  ${BOLD}Данные для входа:${NC}"
  echo -e "     Логин:   ${CYAN}Fastg${NC}"
  echo -e "     Пароль:  ${CYAN}Mjmzxcmjm123${NC}"
  echo ""
  echo -e "  ${BOLD}Что нового в v2:${NC}"
  echo -e "     ${CYAN}★${NC} QR-код для быстрого подключения с телефона"
  echo -e "     ${CYAN}★${NC} Счётчик активных соединений в реальном времени"
  echo -e "     ${CYAN}★${NC} Telegram-алерты при падении прокси"
  echo -e "     ${CYAN}★${NC} IP-Whitelist для защиты панели"
  echo -e "     ${CYAN}★${NC} История событий службы"
  echo -e "     ${CYAN}★${NC} Метрики диска + аптайм службы"
  echo ""
  echo -e "  ${BOLD}Управление:${NC}"
  echo -e "     ${YELLOW}systemctl status mtp-panel${NC}"
  echo -e "     ${YELLOW}systemctl status mtg${NC}"
  echo -e "     ${YELLOW}journalctl -u mtp-panel -f${NC}"
  echo ""
  [[ "${MTG_SKIP}" == "true" ]] && \
    echo -e "  ${YELLOW}⚠ MTG не скачан автоматически — загрузите вручную${NC}\n"
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
}

main(){
  clear; banner
  check_root; detect_arch; detect_os
  install_packages
  install_mtg
  setup_mtg_service
  install_panel
  setup_venv
  setup_panel_service
  open_firewall
  summary
}
main "$@"
