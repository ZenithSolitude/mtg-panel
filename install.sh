#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  MTG Panel — One-Command Installer
#  Usage: bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/mtg-panel/main/install.sh)
# ════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Config ───────────────────────────────────────────────────────────────
PANEL_DIR="/opt/mtp-panel"
PANEL_PORT="8888"
MTG_BINARY="/usr/local/bin/mtg"
SERVICE_NAME="mtp-panel"
MTG_SERVICE_NAME="mtg"
GITHUB_REPO="YOUR_GITHUB_USERNAME/mtg-panel"   # <-- ЗАМЕНИТЬ
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/main"
MTG_GITHUB="9seconds/mtg"

# ── Banner ───────────────────────────────────────────────────────────────
print_banner() {
cat <<'EOF'
  ╔══════════════════════════════════════════╗
  ║        MTG PANEL  —  INSTALLER           ║
  ║    MTProto Proxy Web Management UI       ║
  ╚══════════════════════════════════════════╝
EOF
}

log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }

# ── Root Check ──────────────────────────────────────────────────────────
check_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Запустите установщик от root: sudo bash install.sh"
  fi
}

# ── Detect Architecture ─────────────────────────────────────────────────
detect_arch() {
  MACHINE=$(uname -m)
  case "$MACHINE" in
    x86_64|amd64)      ARCH="amd64" ;;
    aarch64|arm64)     ARCH="arm64" ;;
    armv7*|armv6*)     ARCH="arm"   ;;
    *)                 err "Неподдерживаемая архитектура: $MACHINE" ;;
  esac
  log "Архитектура процессора: ${BOLD}${MACHINE}${NC} → ${BOLD}${ARCH}${NC}"
}

# ── Detect OS ───────────────────────────────────────────────────────────
detect_os() {
  if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
  elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
  elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
  else
    err "Не найден менеджер пакетов (apt/yum/dnf)"
  fi
  log "Менеджер пакетов: ${BOLD}${PKG_MANAGER}${NC}"
}

# ── Install System Packages ─────────────────────────────────────────────
install_packages() {
  step "Установка системных пакетов"

  if [[ "$PKG_MANAGER" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
      python3 python3-pip python3-venv \
      curl wget git \
      net-tools \
      systemd \
      2>/dev/null || true
  elif [[ "$PKG_MANAGER" == "yum" ]]; then
    yum install -y -q \
      python3 python3-pip \
      curl wget git \
      net-tools \
      systemd 2>/dev/null || true
  elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    dnf install -y -q \
      python3 python3-pip \
      curl wget git \
      net-tools \
      systemd 2>/dev/null || true
  fi

  ok "Системные пакеты установлены"
}

# ── Download MTG Binary ─────────────────────────────────────────────────
install_mtg() {
  step "Установка MTG бинарного файла"

  # Get latest release from GitHub API
  log "Получаю информацию о последней версии MTG..."
  LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${MTG_GITHUB}/releases/latest" \
    | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

  if [[ -z "$LATEST_TAG" ]]; then
    warn "Не удалось получить тег. Использую v2.2.4"
    LATEST_TAG="v2.2.4"
  fi

  log "Версия MTG: ${BOLD}${LATEST_TAG}${NC}"

  # Build download URL
  # mtg release asset naming: mtg-linux-amd64, mtg-linux-arm64, etc.
  MTG_URL="https://github.com/${MTG_GITHUB}/releases/download/${LATEST_TAG}/mtg-linux-${ARCH}"

  log "Скачиваю MTG с GitHub..."
  if ! curl -fsSL -o /tmp/mtg_download "${MTG_URL}"; then
    # Try alternative naming convention
    MTG_URL="https://github.com/${MTG_GITHUB}/releases/download/${LATEST_TAG}/mtg-${LATEST_TAG#v}-linux-${ARCH}"
    if ! curl -fsSL -o /tmp/mtg_download "${MTG_URL}"; then
      warn "Не удалось скачать MTG автоматически."
      warn "Скачайте вручную с: https://github.com/${MTG_GITHUB}/releases"
      warn "Положите файл в ${MTG_BINARY} и сделайте его исполняемым: chmod +x ${MTG_BINARY}"
      MTG_SKIP=true
      return
    fi
  fi

  mv /tmp/mtg_download "${MTG_BINARY}"
  chmod +x "${MTG_BINARY}"
  ok "MTG установлен: ${MTG_BINARY}"

  # Verify
  if "${MTG_BINARY}" --version &>/dev/null 2>&1; then
    MTG_VER=$("${MTG_BINARY}" --version 2>&1 | head -1 || echo "unknown")
    ok "Версия: ${MTG_VER}"
  fi

  MTG_SKIP=false
}

# ── Setup MTG Service (initial) ─────────────────────────────────────────
setup_mtg_service() {
  if [[ "${MTG_SKIP:-false}" == "true" ]]; then
    warn "MTG не установлен — пропускаю создание службы MTG"
    return
  fi

  step "Настройка службы MTG"

  # Check if already configured
  if [[ -f "/etc/systemd/system/${MTG_SERVICE_NAME}.service" ]]; then
    log "Служба MTG уже настроена, оставляю как есть"
    return
  fi

  # Generate initial secret with default domain
  DEFAULT_DOMAIN="itunes.apple.com"
  DEFAULT_PORT="8443"

  log "Генерирую начальный секретный ключ..."
  MTG_SECRET=$("${MTG_BINARY}" generate-secret --hex "${DEFAULT_DOMAIN}" 2>/dev/null || \
               "${MTG_BINARY}" generate-secret "${DEFAULT_DOMAIN}" 2>/dev/null || \
               echo "")

  if [[ -z "$MTG_SECRET" ]]; then
    warn "Не удалось сгенерировать секрет — создаю заглушку"
    MTG_SECRET="ee$(head -c 16 /dev/urandom | xxd -p | tr -d '\n')$(python3 -c "import base64; print(base64.b64encode(b'${DEFAULT_DOMAIN}').hex())" 2>/dev/null || echo '0000')"
  fi

  cat > "/etc/systemd/system/${MTG_SERVICE_NAME}.service" <<SVCEOF
[Unit]
Description=MTProto Proxy Server (mtg)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${MTG_BINARY} run --bind 0.0.0.0:${DEFAULT_PORT} --fake-tls ${DEFAULT_DOMAIN} ${MTG_SECRET}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtg
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable "${MTG_SERVICE_NAME}" 2>/dev/null || true
  systemctl start "${MTG_SERVICE_NAME}" 2>/dev/null || true

  ok "Служба MTG создана и запущена на порту ${DEFAULT_PORT}"
}

# ── Install Panel ────────────────────────────────────────────────────────
install_panel() {
  step "Установка веб-панели MTG"

  # Create panel directory
  mkdir -p "${PANEL_DIR}"
  log "Директория панели: ${PANEL_DIR}"

  # Download panel files from GitHub
  log "Скачиваю файлы панели..."
  
  for file in app.py index.html requirements.txt; do
    log "  ↓ ${file}"
    if ! curl -fsSL -o "${PANEL_DIR}/${file}" "${RAW_BASE}/${file}"; then
      err "Не удалось скачать ${file} с ${RAW_BASE}/${file}"
    fi
  done

  ok "Файлы панели загружены"
}

# ── Setup Python Virtualenv ──────────────────────────────────────────────
setup_venv() {
  step "Создание Python виртуального окружения"

  cd "${PANEL_DIR}"

  if [[ ! -d "venv" ]]; then
    python3 -m venv venv
    ok "Virtualenv создан"
  else
    log "Virtualenv уже существует"
  fi

  log "Устанавливаю Python зависимости..."
  "${PANEL_DIR}/venv/bin/pip" install --quiet --upgrade pip
  "${PANEL_DIR}/venv/bin/pip" install --quiet -r requirements.txt

  ok "Python зависимости установлены"
}

# ── Setup Panel Service ──────────────────────────────────────────────────
setup_panel_service() {
  step "Регистрация панели как системной службы"

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SVCEOF
[Unit]
Description=MTG Proxy Web Panel
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
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"

  ok "Служба ${SERVICE_NAME} запущена на порту ${PANEL_PORT}"
}

# ── Firewall Helper ──────────────────────────────────────────────────────
configure_firewall() {
  step "Проверка брандмауэра"

  if command -v ufw &>/dev/null; then
    log "Открываю порт ${PANEL_PORT} в UFW..."
    ufw allow "${PANEL_PORT}/tcp" &>/dev/null || true
    ok "UFW: порт ${PANEL_PORT} открыт"
  elif command -v firewall-cmd &>/dev/null; then
    log "Открываю порт в firewalld..."
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true
    ok "Firewalld: порт ${PANEL_PORT} открыт"
  else
    warn "Брандмауэр не обнаружен (ufw/firewalld). Убедитесь что порт ${PANEL_PORT} открыт вручную."
  fi
}

# ── Get Server IP ────────────────────────────────────────────────────────
get_server_ip() {
  SERVER_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || \
              curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || \
              hostname -I | awk '{print $1}' || \
              echo "YOUR_SERVER_IP")
}

# ── Print Summary ────────────────────────────────────────────────────────
print_summary() {
  get_server_ip

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}  ✓  УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  ${BOLD}🌐 Адрес панели:${NC}"
  echo -e "     ${CYAN}http://${SERVER_IP}:${PANEL_PORT}${NC}"
  echo ""
  echo -e "  ${BOLD}🔑 Данные для входа:${NC}"
  echo -e "     Логин:    ${CYAN}Fastg${NC}"
  echo -e "     Пароль:   ${CYAN}Mjmzxcmjm123${NC}"
  echo ""
  echo -e "  ${BOLD}📋 Управление службами:${NC}"
  echo -e "     Статус панели:  ${YELLOW}systemctl status mtp-panel${NC}"
  echo -e "     Статус MTG:     ${YELLOW}systemctl status mtg${NC}"
  echo -e "     Логи панели:    ${YELLOW}journalctl -u mtp-panel -f${NC}"
  echo -e "     Логи MTG:       ${YELLOW}journalctl -u mtg -f${NC}"
  echo ""
  if [[ "${MTG_SKIP:-false}" == "true" ]]; then
    echo -e "  ${YELLOW}⚠️  MTG бинарный файл не был скачан автоматически.${NC}"
    echo -e "     Скачайте вручную с GitHub и положите в ${MTG_BINARY}"
    echo ""
  fi
  echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
  clear
  print_banner
  echo ""

  check_root
  detect_arch
  detect_os

  install_packages
  install_mtg
  setup_mtg_service
  install_panel
  setup_venv
  setup_panel_service
  configure_firewall

  print_summary
}

main "$@"
