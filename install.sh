#!/bin/bash
# ╔══════════════════════════════════════════════════╗
# ║         MTG PROXY PANEL v3 — INSTALLER           ║
# ║   Полная установка на чистую Ubuntu 22.04        ║
# ╚══════════════════════════════════════════════════╝
set -euo pipefail

# ── Цвета ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}[✓]${RESET} $*"; }
info() { echo -e "${CYAN}[•]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*"; exit 1; }
hdr()  { echo -e "\n${BOLD}━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Баннер ─────────────────────────────────────────
clear
cat << 'EOF'
  ╔═══════════════════════════════════════════╗
  ║   ███╗   ███╗████████╗ ██████╗            ║
  ║   ████╗ ████║╚══██╔══╝██╔════╝            ║
  ║   ██╔████╔██║   ██║   ██║  ███╗           ║
  ║   ██║╚██╔╝██║   ██║   ██║   ██║           ║
  ║   ██║ ╚═╝ ██║   ██║   ╚██████╔╝           ║
  ║   ╚═╝     ╚═╝   ╚═╝    ╚═════╝  PANEL v3  ║
  ╚═══════════════════════════════════════════╝
       MTProto Proxy Web Management Panel
EOF

# ── Проверка root ───────────────────────────────────
[[ $EUID -ne 0 ]] && err "Запускайте от root (sudo bash install.sh)"

# ── Определение IP ─────────────────────────────────
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
  || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
  || hostname -I | awk '{print $1}')
info "IP сервера: $SERVER_IP"

# ── Ввод настроек ──────────────────────────────────
hdr "Настройка панели"
read -rp "$(echo -e "${CYAN}Логин панели${RESET} [admin]: ")" PANEL_USER
PANEL_USER=${PANEL_USER:-admin}

while true; do
  read -rsp "$(echo -e "${CYAN}Пароль панели${RESET}: ")" PANEL_PASS; echo
  [[ ${#PANEL_PASS} -ge 6 ]] && break
  warn "Пароль должен быть не менее 6 символов"
done

read -rp "$(echo -e "${CYAN}Порт панели${RESET} [8888]: ")" PANEL_PORT
PANEL_PORT=${PANEL_PORT:-8888}

read -rp "$(echo -e "${CYAN}Telegram Bot Token${RESET} (Enter — пропустить): ")" TG_TOKEN
read -rp "$(echo -e "${CYAN}Telegram Chat ID${RESET} (Enter — пропустить): ")" TG_CHAT_ID

INSTALL_DIR="/opt/mtg-panel"
VENV="$INSTALL_DIR/venv"
DATA_DIR="$INSTALL_DIR/data"

# ── Системные пакеты ───────────────────────────────
hdr "Системные пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  python3 python3-pip python3-venv python3-dev \
  curl wget net-tools build-essential \
  iptables qrencode jq 2>/dev/null | tail -5
ok "Пакеты установлены"

# ── MTG бинарник ───────────────────────────────────
hdr "MTG бинарный файл"
MTG_VER="v2.2.6"
MTG_URL="https://github.com/9seconds/mtg/releases/download/${MTG_VER}/mtg-2.2.6-linux-amd64.tar.gz"
MTG_TMP=$(mktemp -d)

info "Скачиваю MTG ${MTG_VER}..."
wget -q --show-progress -O "${MTG_TMP}/mtg.tar.gz" "$MTG_URL" \
  || err "Не удалось скачать MTG"

cd "$MTG_TMP"
tar -xzf mtg.tar.gz
# Ищем бинарник в извлечённых файлах
MTG_BIN=$(find "$MTG_TMP" -maxdepth 2 -type f -executable ! -name "*.tar.gz" | head -1)
[[ -z "$MTG_BIN" ]] && {
  # Может быть не исполняемый ещё
  MTG_BIN=$(find "$MTG_TMP" -maxdepth 2 -type f ! -name "*.tar.gz" ! -name "*.md" ! -name "LICENSE" | head -1)
}
[[ -z "$MTG_BIN" ]] && err "Не удалось найти бинарник MTG в архиве"

cp "$MTG_BIN" /usr/local/bin/mtg
chmod +x /usr/local/bin/mtg
rm -rf "$MTG_TMP"
cd /
mtg --version && ok "MTG установлен: $(mtg --version)"

# ── Директории ─────────────────────────────────────
hdr "Файловая структура"
mkdir -p "$INSTALL_DIR" "$DATA_DIR"/{proxies,logs,backups}
ok "Директории созданы"

# ── Python окружение ───────────────────────────────
hdr "Python окружение"
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q \
  "fastapi==0.104.1" \
  "uvicorn[standard]==0.24.0" \
  "python-multipart==0.0.6" \
  "aiofiles==23.2.1" \
  "bcrypt==4.0.1" \
  "passlib[bcrypt]==1.7.4" \
  "python-jose[cryptography]==3.3.0" \
  "httpx==0.25.2" \
  "psutil==5.9.6" \
  "apscheduler==3.10.4" \
  "jinja2==3.1.2"
ok "Зависимости установлены"

# ── Конфиг панели ──────────────────────────────────
hdr "Конфигурация"
HASHED_PASS=$("$VENV/bin/python3" -c "
from passlib.context import CryptContext
ctx = CryptContext(schemes=['bcrypt'], deprecated='auto')
print(ctx.hash('${PANEL_PASS}'))
")

cat > "$DATA_DIR/config.json" << EOCFG
{
  "panel_user": "${PANEL_USER}",
  "panel_pass_hash": "${HASHED_PASS}",
  "panel_port": ${PANEL_PORT},
  "server_ip": "${SERVER_IP}",
  "tg_token": "${TG_TOKEN}",
  "tg_chat_id": "${TG_CHAT_ID}",
  "ip_whitelist": [],
  "secret_rotation_hours": 0
}
EOCFG
ok "Конфиг создан"

# ── app.py ─────────────────────────────────────────
hdr "Файлы панели"
cat > "$INSTALL_DIR/app.py" << 'PYEOF'
"""
MTG Proxy Panel v3 — Backend
"""
import asyncio, json, os, random, re, signal, string, subprocess
import time, uuid, base64, hashlib, socket
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, List

import httpx, psutil
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from fastapi import FastAPI, Request, HTTPException, Form, Depends
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.staticfiles import StaticFiles
from jose import jwt, JWTError
from passlib.context import CryptContext

# ── Пути ───────────────────────────────────────────
BASE   = Path(__file__).parent
DATA   = BASE / "data"
PCFG   = DATA / "config.json"
PFILE  = DATA / "proxies" / "proxies.json"
EVENTS = DATA / "logs" / "events.jsonl"

PFILE.parent.mkdir(parents=True, exist_ok=True)
EVENTS.parent.mkdir(parents=True, exist_ok=True)

# ── Константы ──────────────────────────────────────
SECRET_KEY = hashlib.sha256(os.urandom(32)).hexdigest()
ALGORITHM  = "HS256"
TOKEN_TTL  = 60 * 8  # 8 часов

pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")

# ── Загрузка конфига ───────────────────────────────
def load_cfg() -> dict:
    return json.loads(PCFG.read_text())

def load_proxies() -> list:
    if not PFILE.exists():
        return []
    return json.loads(PFILE.read_text())

def save_proxies(proxies: list):
    PFILE.write_text(json.dumps(proxies, indent=2, ensure_ascii=False))

# ── Событие ────────────────────────────────────────
def log_event(kind: str, msg: str, proxy_id: str = ""):
    entry = {
        "ts": datetime.utcnow().isoformat(),
        "kind": kind,
        "msg": msg,
        "proxy_id": proxy_id
    }
    with open(EVENTS, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

def get_events(limit=100) -> list:
    if not EVENTS.exists():
        return []
    lines = EVENTS.read_text().strip().splitlines()
    events = [json.loads(l) for l in lines if l.strip()]
    return list(reversed(events[-limit:]))

# ── Telegram ───────────────────────────────────────
async def tg_send(text: str):
    cfg = load_cfg()
    token = cfg.get("tg_token", "")
    chat  = cfg.get("tg_chat_id", "")
    if not token or not chat:
        return
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    try:
        async with httpx.AsyncClient(timeout=5) as c:
            await c.post(url, json={"chat_id": chat, "text": text, "parse_mode": "HTML"})
    except Exception:
        pass

# ── MTG helpers ────────────────────────────────────
def gen_secret(fake_tls: bool = True, domain: str = "www.google.com") -> str:
    raw = os.urandom(16).hex()
    if fake_tls:
        domain_hex = domain.encode().hex()
        return "ee" + raw + domain_hex
    return raw

def mtg_generate_secret(fake_tls=True, domain="www.google.com") -> str:
    try:
        result = subprocess.run(
            ["mtg", "generate-secret", "--hex", domain if fake_tls else ""],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return gen_secret(fake_tls, domain)

def get_proxy_link(ip: str, port: int, secret: str) -> str:
    return f"tg://proxy?server={ip}&port={port}&secret={secret}"

def get_proxy_connections(port: int) -> int:
    try:
        conns = psutil.net_connections(kind="tcp")
        return sum(1 for c in conns if c.laddr.port == port and c.status == "ESTABLISHED")
    except Exception:
        return 0

def is_port_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", port)) != 0

def find_free_port(start=4430) -> int:
    for p in range(start, start + 200):
        if is_port_free(p):
            return p
    return start

# ── Запуск/остановка прокси ────────────────────────
PROXY_PROCS: dict[str, subprocess.Popen] = {}

def start_proxy_process(proxy: dict) -> bool:
    pid = proxy["id"]
    if pid in PROXY_PROCS:
        try:
            PROXY_PROCS[pid].poll()
            if PROXY_PROCS[pid].returncode is None:
                return True  # уже запущен
        except Exception:
            pass

    secret  = proxy["secret"]
    port    = proxy["port"]
    workers = proxy.get("workers", 4)
    log_p   = DATA / "logs" / f"proxy_{pid}.log"

    cmd = [
        "mtg", "run",
        "--bind", f"0.0.0.0:{port}",
        "--workers", str(workers),
        secret
    ]
    try:
        with open(log_p, "a") as lf:
            proc = subprocess.Popen(cmd, stdout=lf, stderr=lf)
        PROXY_PROCS[pid] = proc
        log_event("start", f"Прокси запущен порт {port}", pid)
        return True
    except Exception as e:
        log_event("error", f"Ошибка запуска: {e}", pid)
        return False

def stop_proxy_process(proxy_id: str):
    proc = PROXY_PROCS.pop(proxy_id, None)
    if proc:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
    log_event("stop", "Прокси остановлен", proxy_id)

def proxy_status(proxy: dict) -> str:
    pid = proxy["id"]
    if pid not in PROXY_PROCS:
        return "stopped"
    proc = PROXY_PROCS[pid]
    proc.poll()
    return "running" if proc.returncode is None else "stopped"

# ── Watchdog ───────────────────────────────────────
async def watchdog():
    proxies = load_proxies()
    for proxy in proxies:
        if not proxy.get("enabled", True):
            continue
        if proxy_status(proxy) == "stopped":
            if start_proxy_process(proxy):
                await tg_send(f"⚠️ Прокси <b>{proxy['name']}</b> (порт {proxy['port']}) перезапущен автоматически")
                log_event("watchdog", f"Автоперезапуск {proxy['name']}", proxy["id"])

# ── Ротация секретов ───────────────────────────────
async def rotate_secrets():
    cfg = load_cfg()
    proxies = load_proxies()
    changed = False
    for proxy in proxies:
        if proxy.get("auto_rotate", False):
            new_secret = mtg_generate_secret(
                proxy.get("fake_tls", True),
                proxy.get("tls_domain", "www.google.com")
            )
            old = proxy["secret"]
            proxy["secret"] = new_secret
            proxy["rotated_at"] = datetime.utcnow().isoformat()
            stop_proxy_process(proxy["id"])
            time.sleep(0.3)
            start_proxy_process(proxy)
            log_event("rotate", f"Секрет ротирован {old[:8]}...→{new_secret[:8]}...", proxy["id"])
            await tg_send(
                f"🔄 Прокси <b>{proxy['name']}</b> ротирован\n"
                f"Новая ссылка: <code>{get_proxy_link(cfg['server_ip'], proxy['port'], new_secret)}</code>"
            )
            changed = True
    if changed:
        save_proxies(proxies)

# ── Auth ───────────────────────────────────────────
def create_token(username: str) -> str:
    exp = datetime.utcnow() + timedelta(minutes=TOKEN_TTL)
    return jwt.encode({"sub": username, "exp": exp}, SECRET_KEY, algorithm=ALGORITHM)

def verify_token(token: str) -> Optional[str]:
    try:
        data = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return data.get("sub")
    except JWTError:
        return None

def auth_required(request: Request) -> str:
    token = request.cookies.get("access_token")
    if not token:
        raise HTTPException(status_code=401, detail="Unauthorized")
    user = verify_token(token)
    if not user:
        raise HTTPException(status_code=401, detail="Invalid token")
    return user

# ── IP whitelist ───────────────────────────────────
def check_ip_whitelist(request: Request):
    cfg = load_cfg()
    wl = cfg.get("ip_whitelist", [])
    if not wl:
        return
    client_ip = request.client.host
    if client_ip not in wl:
        raise HTTPException(status_code=403, detail=f"IP {client_ip} не в whitelist")

# ── Lifespan ───────────────────────────────────────
scheduler = AsyncIOScheduler()

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Запускаем все активные прокси
    proxies = load_proxies()
    for proxy in proxies:
        if proxy.get("enabled", True):
            start_proxy_process(proxy)
    
    # Планировщик
    scheduler.add_job(watchdog, "interval", seconds=30, id="watchdog")
    scheduler.add_job(rotate_secrets, "interval", hours=1, id="rotate")
    scheduler.start()
    log_event("system", "Панель запущена")
    await tg_send("🟢 MTG Panel v3 запущена")
    
    yield
    
    # Останавливаем всё
    for proxy in load_proxies():
        stop_proxy_process(proxy["id"])
    scheduler.shutdown()
    await tg_send("🔴 MTG Panel v3 остановлена")

# ── Приложение ─────────────────────────────────────
app = FastAPI(title="MTG Panel v3", lifespan=lifespan)

# ── Маршруты ───────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    try:
        check_ip_whitelist(request)
        auth_required(request)
    except HTTPException:
        return RedirectResponse("/login")
    html = (BASE / "index.html").read_text()
    return HTMLResponse(html)

@app.get("/login", response_class=HTMLResponse)
async def login_page():
    html = (BASE / "login.html").read_text()
    return HTMLResponse(html)

@app.post("/login")
async def login(request: Request, username: str = Form(...), password: str = Form(...)):
    check_ip_whitelist(request)
    cfg = load_cfg()
    if username != cfg["panel_user"] or not pwd_ctx.verify(password, cfg["panel_pass_hash"]):
        return HTMLResponse('<script>alert("Неверный логин или пароль");history.back()</script>')
    token = create_token(username)
    resp = RedirectResponse("/", status_code=302)
    resp.set_cookie("access_token", token, httponly=True, max_age=TOKEN_TTL * 60)
    log_event("auth", f"Вход: {username}")
    return resp

@app.get("/logout")
async def logout():
    resp = RedirectResponse("/login", status_code=302)
    resp.delete_cookie("access_token")
    return resp

# ── API: Статус системы ────────────────────────────
@app.get("/api/system")
async def api_system(request: Request, _=Depends(auth_required)):
    cpu  = psutil.cpu_percent(interval=0.1)
    ram  = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    boot = psutil.boot_time()
    uptime_s = time.time() - boot
    uptime = str(timedelta(seconds=int(uptime_s)))
    return {
        "cpu_percent": cpu,
        "ram_used_mb": round(ram.used / 1024**2),
        "ram_total_mb": round(ram.total / 1024**2),
        "ram_percent": ram.percent,
        "disk_used_gb": round(disk.used / 1024**3, 1),
        "disk_total_gb": round(disk.total / 1024**3, 1),
        "disk_percent": disk.percent,
        "uptime": uptime,
        "server_ip": load_cfg()["server_ip"]
    }

# ── API: Прокси ────────────────────────────────────
@app.get("/api/proxies")
async def api_proxies(request: Request, _=Depends(auth_required)):
    proxies = load_proxies()
    cfg = load_cfg()
    result = []
    for p in proxies:
        status = proxy_status(p)
        conns  = get_proxy_connections(p["port"]) if status == "running" else 0
        link   = get_proxy_link(cfg["server_ip"], p["port"], p["secret"])
        result.append({**p, "status": status, "connections": conns, "link": link})
    return result

@app.post("/api/proxies")
async def api_add_proxy(request: Request, _=Depends(auth_required)):
    body = await request.json()
    proxies = load_proxies()
    cfg = load_cfg()

    name       = body.get("name", f"Прокси {len(proxies)+1}")
    port       = int(body.get("port", 0)) or find_free_port()
    fake_tls   = body.get("fake_tls", True)
    domain     = body.get("tls_domain", "www.google.com")
    workers    = int(body.get("workers", 4))
    auto_rotate= body.get("auto_rotate", False)
    custom_secret = body.get("secret", "").strip()

    if not is_port_free(port):
        raise HTTPException(400, f"Порт {port} занят")

    secret = custom_secret if custom_secret else mtg_generate_secret(fake_tls, domain)

    proxy = {
        "id":          str(uuid.uuid4())[:8],
        "name":        name,
        "port":        port,
        "secret":      secret,
        "fake_tls":    fake_tls,
        "tls_domain":  domain,
        "workers":     workers,
        "auto_rotate": auto_rotate,
        "enabled":     True,
        "created_at":  datetime.utcnow().isoformat(),
        "rotated_at":  None
    }
    proxies.append(proxy)
    save_proxies(proxies)
    start_proxy_process(proxy)

    link = get_proxy_link(cfg["server_ip"], port, secret)
    log_event("create", f"Создан прокси {name} порт {port}", proxy["id"])
    await tg_send(f"➕ Новый прокси <b>{name}</b>\n🔗 <code>{link}</code>")
    return proxy

@app.delete("/api/proxies/{proxy_id}")
async def api_del_proxy(proxy_id: str, request: Request, _=Depends(auth_required)):
    proxies = load_proxies()
    proxy = next((p for p in proxies if p["id"] == proxy_id), None)
    if not proxy:
        raise HTTPException(404, "Не найден")
    stop_proxy_process(proxy_id)
    proxies = [p for p in proxies if p["id"] != proxy_id]
    save_proxies(proxies)
    log_event("delete", f"Удалён прокси {proxy['name']}", proxy_id)
    await tg_send(f"🗑 Прокси <b>{proxy['name']}</b> удалён")
    return {"ok": True}

@app.post("/api/proxies/{proxy_id}/start")
async def api_start(proxy_id: str, request: Request, _=Depends(auth_required)):
    proxies = load_proxies()
    proxy = next((p for p in proxies if p["id"] == proxy_id), None)
    if not proxy:
        raise HTTPException(404, "Не найден")
    ok2 = start_proxy_process(proxy)
    return {"ok": ok2}

@app.post("/api/proxies/{proxy_id}/stop")
async def api_stop(proxy_id: str, request: Request, _=Depends(auth_required)):
    stop_proxy_process(proxy_id)
    return {"ok": True}

@app.post("/api/proxies/{proxy_id}/rotate")
async def api_rotate(proxy_id: str, request: Request, _=Depends(auth_required)):
    proxies = load_proxies()
    cfg = load_cfg()
    proxy = next((p for p in proxies if p["id"] == proxy_id), None)
    if not proxy:
        raise HTTPException(404, "Не найден")
    new_secret = mtg_generate_secret(proxy.get("fake_tls", True), proxy.get("tls_domain", "www.google.com"))
    proxy["secret"] = new_secret
    proxy["rotated_at"] = datetime.utcnow().isoformat()
    save_proxies(proxies)
    stop_proxy_process(proxy_id)
    time.sleep(0.3)
    start_proxy_process(proxy)
    link = get_proxy_link(cfg["server_ip"], proxy["port"], new_secret)
    log_event("rotate", f"Ручная ротация", proxy_id)
    await tg_send(f"🔄 Ротация прокси <b>{proxy['name']}</b>\n🔗 <code>{link}</code>")
    return {"ok": True, "secret": new_secret, "link": link}

@app.get("/api/proxies/{proxy_id}/qr")
async def api_qr(proxy_id: str, request: Request, _=Depends(auth_required)):
    proxies = load_proxies()
    cfg = load_cfg()
    proxy = next((p for p in proxies if p["id"] == proxy_id), None)
    if not proxy:
        raise HTTPException(404, "Не найден")
    link = get_proxy_link(cfg["server_ip"], proxy["port"], proxy["secret"])
    try:
        result = subprocess.run(
            ["qrencode", "-t", "SVG", "-o", "-", link],
            capture_output=True, timeout=5
        )
        if result.returncode == 0:
            svg = result.stdout.decode()
            return JSONResponse({"qr_svg": svg, "link": link})
    except Exception:
        pass
    return JSONResponse({"qr_svg": None, "link": link})

@app.get("/api/proxies/{proxy_id}/logs")
async def api_proxy_logs(proxy_id: str, request: Request, _=Depends(auth_required)):
    log_p = DATA / "logs" / f"proxy_{proxy_id}.log"
    if not log_p.exists():
        return JSONResponse({"lines": []})
    lines = log_p.read_text().splitlines()[-100:]
    return JSONResponse({"lines": lines})

@app.get("/api/events")
async def api_events(request: Request, _=Depends(auth_required)):
    return get_events(200)

# ── API: Настройки ─────────────────────────────────
@app.get("/api/settings")
async def api_get_settings(request: Request, _=Depends(auth_required)):
    cfg = load_cfg()
    return {
        "ip_whitelist": cfg.get("ip_whitelist", []),
        "tg_token": "***" if cfg.get("tg_token") else "",
        "tg_chat_id": cfg.get("tg_chat_id", ""),
        "secret_rotation_hours": cfg.get("secret_rotation_hours", 0),
        "server_ip": cfg.get("server_ip", "")
    }

@app.post("/api/settings")
async def api_save_settings(request: Request, _=Depends(auth_required)):
    body = await request.json()
    cfg = load_cfg()
    
    if "ip_whitelist" in body:
        raw = body["ip_whitelist"]
        cfg["ip_whitelist"] = [ip.strip() for ip in raw.split(",") if ip.strip()] if isinstance(raw, str) else raw
    if "tg_token" in body and body["tg_token"] != "***":
        cfg["tg_token"] = body["tg_token"]
    if "tg_chat_id" in body:
        cfg["tg_chat_id"] = body["tg_chat_id"]
    if "secret_rotation_hours" in body:
        cfg["secret_rotation_hours"] = int(body["secret_rotation_hours"])
    if "server_ip" in body:
        cfg["server_ip"] = body["server_ip"]
    
    PCFG.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
    log_event("settings", "Настройки обновлены")
    return {"ok": True}

@app.post("/api/settings/change_password")
async def api_change_pass(request: Request, _=Depends(auth_required)):
    body = await request.json()
    cfg = load_cfg()
    old = body.get("old_password", "")
    new = body.get("new_password", "")
    if not pwd_ctx.verify(old, cfg["panel_pass_hash"]):
        raise HTTPException(400, "Неверный текущий пароль")
    if len(new) < 6:
        raise HTTPException(400, "Пароль слишком короткий")
    cfg["panel_pass_hash"] = pwd_ctx.hash(new)
    PCFG.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
    log_event("auth", "Пароль изменён")
    return {"ok": True}

@app.post("/api/test_telegram")
async def api_test_tg(request: Request, _=Depends(auth_required)):
    await tg_send("✅ Тест уведомлений MTG Panel v3 — всё работает!")
    return {"ok": True}

@app.post("/api/backup")
async def api_backup(request: Request, _=Depends(auth_required)):
    import zipfile, io
    buf = io.BytesIO()
    ts = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    with zipfile.ZipFile(buf, "w") as zf:
        for f in [PCFG, PFILE]:
            if f.exists():
                zf.write(f, f.name)
    buf.seek(0)
    from fastapi.responses import StreamingResponse
    return StreamingResponse(
        buf,
        media_type="application/zip",
        headers={"Content-Disposition": f"attachment; filename=mtg_backup_{ts}.zip"}
    )
PYEOF
ok "app.py создан"

# ── login.html ─────────────────────────────────────
cat > "$INSTALL_DIR/login.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MTG Panel — Вход</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{min-height:100vh;background:#0d1117;display:flex;align-items:center;justify-content:center;font-family:'Segoe UI',system-ui,sans-serif}
  .card{background:#161b22;border:1px solid #30363d;border-radius:16px;padding:40px;width:360px}
  .logo{text-align:center;margin-bottom:32px}
  .logo h1{color:#58a6ff;font-size:24px;font-weight:700;letter-spacing:2px}
  .logo p{color:#8b949e;font-size:13px;margin-top:4px}
  label{display:block;color:#c9d1d9;font-size:13px;margin-bottom:6px}
  input{width:100%;background:#0d1117;border:1px solid #30363d;border-radius:8px;padding:10px 14px;color:#c9d1d9;font-size:14px;outline:none;transition:.2s}
  input:focus{border-color:#58a6ff}
  .field{margin-bottom:18px}
  button{width:100%;background:#238636;border:none;border-radius:8px;padding:12px;color:#fff;font-size:15px;font-weight:600;cursor:pointer;transition:.2s}
  button:hover{background:#2ea043}
  .hint{color:#8b949e;font-size:12px;text-align:center;margin-top:16px}
</style>
</head>
<body>
<div class="card">
  <div class="logo">
    <h1>⚡ MTG PANEL</h1>
    <p>MTProto Proxy Management v3</p>
  </div>
  <form method="POST" action="/login">
    <div class="field">
      <label>Логин</label>
      <input type="text" name="username" autofocus autocomplete="username" required>
    </div>
    <div class="field">
      <label>Пароль</label>
      <input type="password" name="password" autocomplete="current-password" required>
    </div>
    <button type="submit">Войти</button>
  </form>
  <p class="hint">MTG Proxy Panel v3</p>
</div>
</body>
</html>
HTMLEOF
ok "login.html создан"

# ── index.html ─────────────────────────────────────
# (большой файл — пишем через python)
python3 << 'PYEOF'
html = r'''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MTG Panel v3</title>
<style>
:root{
  --bg:#0d1117;--surface:#161b22;--border:#30363d;--text:#c9d1d9;
  --muted:#8b949e;--accent:#58a6ff;--green:#238636;--green2:#2ea043;
  --red:#da3633;--yellow:#e3b341;--purple:#8957e5;
}
*{margin:0;padding:0;box-sizing:border-box}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;min-height:100vh}
/* Layout */
.layout{display:flex;min-height:100vh}
.sidebar{width:220px;background:var(--surface);border-right:1px solid var(--border);padding:20px 0;position:fixed;height:100vh;overflow-y:auto}
.main{margin-left:220px;padding:24px;flex:1}
/* Sidebar */
.sidebar-logo{padding:0 16px 20px;border-bottom:1px solid var(--border);margin-bottom:12px}
.sidebar-logo h2{color:var(--accent);font-size:16px;font-weight:700;letter-spacing:1px}
.sidebar-logo p{color:var(--muted);font-size:11px}
.nav-item{display:flex;align-items:center;gap:10px;padding:10px 16px;color:var(--muted);cursor:pointer;border-radius:8px;margin:2px 8px;transition:.15s;font-size:14px;text-decoration:none}
.nav-item:hover,.nav-item.active{background:rgba(88,166,255,.1);color:var(--accent)}
.nav-item span.icon{font-size:16px;width:20px;text-align:center}
/* Cards */
.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;margin-bottom:24px}
.stat-card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:16px}
.stat-card .label{color:var(--muted);font-size:12px;margin-bottom:6px}
.stat-card .value{font-size:22px;font-weight:700;color:var(--text)}
.stat-card .sub{color:var(--muted);font-size:11px;margin-top:4px}
/* Section */
.section{display:none}.section.active{display:block}
.section-title{font-size:18px;font-weight:700;margin-bottom:16px;color:var(--text)}
/* Table */
.table-wrap{background:var(--surface);border:1px solid var(--border);border-radius:12px;overflow:hidden}
table{width:100%;border-collapse:collapse}
th{padding:12px 16px;text-align:left;font-size:12px;color:var(--muted);background:rgba(255,255,255,.02);border-bottom:1px solid var(--border);text-transform:uppercase;letter-spacing:.5px}
td{padding:12px 16px;font-size:13px;border-bottom:1px solid #21262d}
tr:last-child td{border:none}
tr:hover td{background:rgba(255,255,255,.02)}
/* Badges */
.badge{display:inline-flex;align-items:center;gap:4px;padding:3px 8px;border-radius:20px;font-size:11px;font-weight:600}
.badge-green{background:rgba(35,134,54,.2);color:#3fb950}
.badge-red{background:rgba(218,54,51,.2);color:#f85149}
.badge-yellow{background:rgba(227,179,65,.2);color:var(--yellow)}
/* Buttons */
.btn{display:inline-flex;align-items:center;gap:6px;padding:7px 14px;border-radius:8px;border:none;cursor:pointer;font-size:13px;font-weight:500;transition:.15s}
.btn-primary{background:var(--green);color:#fff}.btn-primary:hover{background:var(--green2)}
.btn-danger{background:var(--red);color:#fff}.btn-danger:hover{opacity:.85}
.btn-secondary{background:var(--border);color:var(--text)}.btn-secondary:hover{background:#3d444d}
.btn-accent{background:rgba(88,166,255,.15);color:var(--accent);border:1px solid rgba(88,166,255,.3)}
.btn-accent:hover{background:rgba(88,166,255,.25)}
.btn-sm{padding:4px 10px;font-size:12px}
.btn-icon{padding:6px 8px}
/* Modal */
.modal-bg{display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:100;align-items:center;justify-content:center}
.modal-bg.open{display:flex}
.modal{background:var(--surface);border:1px solid var(--border);border-radius:16px;padding:28px;width:100%;max-width:460px;max-height:90vh;overflow-y:auto}
.modal h3{font-size:16px;font-weight:700;margin-bottom:20px}
/* Form */
.form-group{margin-bottom:16px}
.form-group label{display:block;color:var(--muted);font-size:12px;margin-bottom:6px;text-transform:uppercase;letter-spacing:.5px}
.form-group input,.form-group select{width:100%;background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:9px 12px;color:var(--text);font-size:14px;outline:none}
.form-group input:focus,.form-group select:focus{border-color:var(--accent)}
.form-group .hint{color:var(--muted);font-size:11px;margin-top:4px}
.toggle-row{display:flex;align-items:center;justify-content:space-between;padding:10px 0;border-bottom:1px solid var(--border)}
.toggle-row:last-child{border:none}
.toggle-row .label{font-size:13px}.toggle-row .desc{color:var(--muted);font-size:11px}
/* Toggle switch */
.toggle{position:relative;width:44px;height:24px;cursor:pointer;flex-shrink:0}
.toggle input{opacity:0;width:0;height:0}
.slider{position:absolute;inset:0;background:#30363d;border-radius:24px;transition:.3s}
.slider:before{content:'';position:absolute;height:18px;width:18px;left:3px;top:3px;background:#fff;border-radius:50%;transition:.3s}
input:checked+.slider{background:var(--green)}
input:checked+.slider:before{transform:translateX(20px)}
/* Progress */
.progress{background:#21262d;border-radius:4px;height:6px;overflow:hidden}
.progress-bar{height:100%;border-radius:4px;transition:width .5s}
/* Events */
.event-list{max-height:400px;overflow-y:auto}
.event-item{display:flex;gap:12px;padding:10px 0;border-bottom:1px solid #21262d;font-size:12px}
.event-item:last-child{border:none}
.event-kind{padding:2px 8px;border-radius:10px;font-size:10px;font-weight:600;flex-shrink:0}
/* QR Modal */
.qr-box{display:flex;justify-content:center;margin:16px 0}
.qr-box svg{max-width:200px;height:auto}
.link-box{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:10px;font-size:11px;word-break:break-all;color:var(--accent);cursor:pointer;margin-top:12px}
/* Responsive */
@media(max-width:768px){
  .sidebar{transform:translateX(-100%);transition:.3s;z-index:50}
  .sidebar.open{transform:none}
  .main{margin-left:0}
}
/* Scrollbar */
::-webkit-scrollbar{width:6px}::-webkit-scrollbar-track{background:var(--bg)}::-webkit-scrollbar-thumb{background:#30363d;border-radius:3px}
/* Top bar */
.topbar{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px}
.topbar h1{font-size:20px;font-weight:700}
.topbar-actions{display:flex;gap:10px;align-items:center}
/* Log pre */
.log-pre{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:12px;font-size:11px;font-family:monospace;max-height:300px;overflow-y:auto;color:#7ee787}
</style>
</head>
<body>

<!-- Sidebar -->
<div class="layout">
<nav class="sidebar" id="sidebar">
  <div class="sidebar-logo">
    <h2>⚡ MTG PANEL</h2>
    <p>v3 · MTProto Proxy</p>
  </div>
  <a class="nav-item active" onclick="nav('dashboard')"><span class="icon">📊</span> Дашборд</a>
  <a class="nav-item" onclick="nav('proxies')"><span class="icon">🔌</span> Прокси</a>
  <a class="nav-item" onclick="nav('events')"><span class="icon">📋</span> События</a>
  <a class="nav-item" onclick="nav('settings')"><span class="icon">⚙️</span> Настройки</a>
  <a class="nav-item" href="/logout" style="position:absolute;bottom:20px;left:0;right:0;margin:0 8px"><span class="icon">🚪</span> Выход</a>
</nav>

<!-- Main -->
<main class="main">

<!-- Dashboard -->
<div class="section active" id="sec-dashboard">
  <div class="topbar">
    <h1>Дашборд</h1>
    <div class="topbar-actions">
      <span id="sys-uptime" style="color:var(--muted);font-size:13px"></span>
      <button class="btn btn-secondary btn-sm" onclick="loadAll()">↻ Обновить</button>
    </div>
  </div>
  <div class="stats-grid" id="stats-grid">
    <div class="stat-card"><div class="label">CPU</div><div class="value" id="s-cpu">—</div><div class="progress" style="margin-top:8px"><div class="progress-bar" id="p-cpu" style="background:var(--accent)"></div></div></div>
    <div class="stat-card"><div class="label">RAM</div><div class="value" id="s-ram">—</div><div class="progress" style="margin-top:8px"><div class="progress-bar" id="p-ram" style="background:var(--purple)"></div></div></div>
    <div class="stat-card"><div class="label">Диск</div><div class="value" id="s-disk">—</div><div class="progress" style="margin-top:8px"><div class="progress-bar" id="p-disk" style="background:var(--yellow)"></div></div></div>
    <div class="stat-card"><div class="label">Прокси</div><div class="value" id="s-proxies">—</div><div class="sub" id="s-proxies-sub"></div></div>
    <div class="stat-card"><div class="label">Соединений</div><div class="value" id="s-conns">—</div><div class="sub">активных сейчас</div></div>
    <div class="stat-card"><div class="label">IP сервера</div><div class="value" id="s-ip" style="font-size:14px">—</div><div class="sub">внешний адрес</div></div>
  </div>
  <!-- Quick proxies list -->
  <div class="section-title">Активные прокси</div>
  <div class="table-wrap">
    <table>
      <thead><tr><th>Имя</th><th>Порт</th><th>Статус</th><th>Соединений</th><th>Действия</th></tr></thead>
      <tbody id="dash-proxy-list"></tbody>
    </table>
  </div>
</div>

<!-- Proxies -->
<div class="section" id="sec-proxies">
  <div class="topbar">
    <h1>Прокси</h1>
    <div class="topbar-actions">
      <button class="btn btn-primary" onclick="openAddModal()">+ Добавить прокси</button>
    </div>
  </div>
  <div class="table-wrap">
    <table>
      <thead><tr><th>Имя</th><th>Порт</th><th>Тип секрета</th><th>Соединений</th><th>Статус</th><th>Авторотация</th><th>Действия</th></tr></thead>
      <tbody id="proxy-list"></tbody>
    </table>
  </div>
</div>

<!-- Events -->
<div class="section" id="sec-events">
  <div class="topbar"><h1>История событий</h1><button class="btn btn-secondary btn-sm" onclick="loadEvents()">↻</button></div>
  <div class="table-wrap" style="padding:16px">
    <div class="event-list" id="event-list"></div>
  </div>
</div>

<!-- Settings -->
<div class="section" id="sec-settings">
  <div class="topbar"><h1>Настройки</h1></div>
  <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:20px">
    <!-- Telegram -->
    <div class="table-wrap" style="padding:20px">
      <div class="section-title" style="margin-bottom:16px">🔔 Telegram уведомления</div>
      <div class="form-group"><label>Bot Token</label><input id="set-tg-token" type="password" placeholder="1234567890:ABC..."></div>
      <div class="form-group"><label>Chat ID</label><input id="set-tg-chat" placeholder="-100xxxxxxxxxx"></div>
      <div style="display:flex;gap:10px">
        <button class="btn btn-primary" onclick="saveSettings()">Сохранить</button>
        <button class="btn btn-secondary" onclick="testTg()">Тест уведомления</button>
      </div>
    </div>
    <!-- IP Whitelist -->
    <div class="table-wrap" style="padding:20px">
      <div class="section-title" style="margin-bottom:16px">🛡 IP Whitelist</div>
      <div class="form-group">
        <label>Разрешённые IP (через запятую)</label>
        <input id="set-whitelist" placeholder="Пусто = все разрешены">
        <div class="hint">Например: 1.2.3.4, 5.6.7.8</div>
      </div>
      <div class="form-group"><label>IP сервера</label><input id="set-server-ip"></div>
      <button class="btn btn-primary" onclick="saveSettings()">Сохранить</button>
    </div>
    <!-- Password -->
    <div class="table-wrap" style="padding:20px">
      <div class="section-title" style="margin-bottom:16px">🔐 Смена пароля</div>
      <div class="form-group"><label>Текущий пароль</label><input id="pw-old" type="password"></div>
      <div class="form-group"><label>Новый пароль</label><input id="pw-new" type="password"></div>
      <div class="form-group"><label>Повтор</label><input id="pw-new2" type="password"></div>
      <button class="btn btn-primary" onclick="changePass()">Сменить пароль</button>
    </div>
    <!-- Backup -->
    <div class="table-wrap" style="padding:20px">
      <div class="section-title" style="margin-bottom:16px">💾 Бэкап</div>
      <p style="color:var(--muted);font-size:13px;margin-bottom:16px">Скачать архив с конфигами прокси и панели</p>
      <a href="/api/backup" class="btn btn-secondary">⬇ Скачать бэкап</a>
    </div>
  </div>
</div>

</main>
</div>

<!-- Modal: Add Proxy -->
<div class="modal-bg" id="modal-add">
  <div class="modal">
    <h3>➕ Добавить прокси</h3>
    <div class="form-group"><label>Имя</label><input id="add-name" placeholder="Мой прокси"></div>
    <div class="form-group"><label>Порт (0 = автовыбор)</label><input id="add-port" type="number" value="0" min="0" max="65535"></div>
    <div class="form-group">
      <label>TLS домен (fake-TLS)</label>
      <input id="add-domain" value="www.google.com">
      <div class="hint">Домен для маскировки трафика под HTTPS</div>
    </div>
    <div class="form-group"><label>Свой секрет (пусто = сгенерировать)</label><input id="add-secret" placeholder="Оставьте пустым для автогенерации"></div>
    <div class="form-group"><label>Воркеры</label><input id="add-workers" type="number" value="4" min="1" max="32"></div>
    <div class="toggle-row">
      <div><div class="label">Fake-TLS</div><div class="desc">Маскировка под HTTPS трафик</div></div>
      <label class="toggle"><input type="checkbox" id="add-faketls" checked><span class="slider"></span></label>
    </div>
    <div class="toggle-row">
      <div><div class="label">Авторотация секрета</div><div class="desc">Менять ключ автоматически каждый час</div></div>
      <label class="toggle"><input type="checkbox" id="add-rotate"><span class="slider"></span></label>
    </div>
    <div style="display:flex;gap:10px;margin-top:20px">
      <button class="btn btn-primary" onclick="addProxy()">Создать</button>
      <button class="btn btn-secondary" onclick="closeModal('modal-add')">Отмена</button>
    </div>
  </div>
</div>

<!-- Modal: QR -->
<div class="modal-bg" id="modal-qr">
  <div class="modal" style="max-width:340px;text-align:center">
    <h3>📱 QR для подключения</h3>
    <div class="qr-box" id="qr-container"></div>
    <div class="link-box" id="qr-link" onclick="copyLink()" title="Нажмите чтобы скопировать"></div>
    <p style="color:var(--muted);font-size:11px;margin-top:8px">Нажмите на ссылку чтобы скопировать</p>
    <button class="btn btn-secondary" style="margin-top:16px;width:100%" onclick="closeModal('modal-qr')">Закрыть</button>
  </div>
</div>

<!-- Modal: Logs -->
<div class="modal-bg" id="modal-logs">
  <div class="modal" style="max-width:600px">
    <h3>📄 Логи прокси</h3>
    <div class="log-pre" id="logs-pre">Загрузка...</div>
    <button class="btn btn-secondary" style="margin-top:16px" onclick="closeModal('modal-logs')">Закрыть</button>
  </div>
</div>

<script>
const $ = id => document.getElementById(id);

// ── Навигация ──────────────────────────────────────
function nav(page) {
  document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  $('sec-' + page).classList.add('active');
  event.currentTarget.classList.add('active');
  if (page === 'proxies') loadProxies();
  if (page === 'events')  loadEvents();
  if (page === 'settings') loadSettings();
}

// ── Fetch helpers ─────────────────────────────────
async function api(url, opts={}) {
  const r = await fetch(url, {headers:{'Content-Type':'application/json'}, ...opts});
  if (!r.ok) { const e = await r.json().catch(()=>({detail:r.statusText})); throw new Error(e.detail || r.statusText); }
  return r.json();
}

// ── Загрузка всего ────────────────────────────────
async function loadAll() {
  await Promise.all([loadSystem(), loadDashProxies()]);
}

async function loadSystem() {
  try {
    const s = await api('/api/system');
    $('s-cpu').textContent  = s.cpu_percent + '%';
    $('s-ram').textContent  = s.ram_used_mb + ' MB';
    $('s-disk').textContent = s.disk_used_gb + ' GB';
    $('s-ip').textContent   = s.server_ip;
    $('sys-uptime').textContent = '⏱ ' + s.uptime;
    $('p-cpu').style.width  = s.cpu_percent + '%';
    $('p-ram').style.width  = s.ram_percent + '%';
    $('p-disk').style.width = s.disk_percent + '%';
  } catch(e) { console.error(e); }
}

async function loadDashProxies() {
  try {
    const proxies = await api('/api/proxies');
    let running = 0, total_conns = 0;
    let rows = '';
    for (const p of proxies) {
      if (p.status === 'running') running++;
      total_conns += p.connections || 0;
      rows += `<tr>
        <td>${p.name}</td>
        <td>${p.port}</td>
        <td>${statusBadge(p.status)}</td>
        <td>${p.connections || 0}</td>
        <td>
          <button class="btn btn-accent btn-sm btn-icon" onclick="showQR('${p.id}')" title="QR">📱</button>
        </td>
      </tr>`;
    }
    $('dash-proxy-list').innerHTML = rows || '<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:20px">Нет прокси</td></tr>';
    $('s-proxies').textContent = running + '/' + proxies.length;
    $('s-proxies-sub').textContent = 'запущено из ' + proxies.length;
    $('s-conns').textContent = total_conns;
  } catch(e) { console.error(e); }
}

// ── Прокси ────────────────────────────────────────
async function loadProxies() {
  try {
    const proxies = await api('/api/proxies');
    let rows = '';
    for (const p of proxies) {
      const tls = p.fake_tls ? `<span class="badge badge-green">fake-TLS</span>` : `<span class="badge badge-yellow">raw</span>`;
      rows += `<tr>
        <td><b>${p.name}</b></td>
        <td>${p.port}</td>
        <td>${tls}<br><small style="color:var(--muted)">${p.tls_domain||''}</small></td>
        <td>${p.connections||0}</td>
        <td>${statusBadge(p.status)}</td>
        <td>${p.auto_rotate ? '<span class="badge badge-green">вкл</span>' : '<span class="badge" style="background:#21262d">выкл</span>'}</td>
        <td style="display:flex;gap:6px;flex-wrap:wrap">
          ${p.status==='running'
            ? `<button class="btn btn-danger btn-sm" onclick="stopProxy('${p.id}')">⏹</button>`
            : `<button class="btn btn-primary btn-sm" onclick="startProxy('${p.id}')">▶</button>`}
          <button class="btn btn-accent btn-sm btn-icon" onclick="showQR('${p.id}')" title="QR">📱</button>
          <button class="btn btn-secondary btn-sm btn-icon" onclick="rotateSecret('${p.id}')" title="Ротировать">🔄</button>
          <button class="btn btn-secondary btn-sm btn-icon" onclick="showLogs('${p.id}')" title="Логи">📄</button>
          <button class="btn btn-danger btn-sm btn-icon" onclick="delProxy('${p.id}','${p.name}')" title="Удалить">🗑</button>
        </td>
      </tr>`;
    }
    $('proxy-list').innerHTML = rows || '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">Нет прокси. Нажмите «Добавить прокси»</td></tr>';
  } catch(e) { alert('Ошибка: ' + e.message); }
}

function statusBadge(s) {
  if (s === 'running') return '<span class="badge badge-green">● Запущен</span>';
  return '<span class="badge badge-red">● Остановлен</span>';
}

// ── Добавить прокси ───────────────────────────────
function openAddModal() { $('modal-add').classList.add('open'); }

async function addProxy() {
  const data = {
    name:       $('add-name').value || 'Прокси',
    port:       parseInt($('add-port').value) || 0,
    tls_domain: $('add-domain').value || 'www.google.com',
    secret:     $('add-secret').value.trim(),
    workers:    parseInt($('add-workers').value) || 4,
    fake_tls:   $('add-faketls').checked,
    auto_rotate:$('add-rotate').checked,
  };
  try {
    await api('/api/proxies', {method:'POST', body:JSON.stringify(data)});
    closeModal('modal-add');
    loadProxies(); loadDashProxies();
    notify('✅ Прокси создан');
  } catch(e) { alert('Ошибка: ' + e.message); }
}

async function delProxy(id, name) {
  if (!confirm(`Удалить прокси «${name}»?`)) return;
  try {
    await api('/api/proxies/' + id, {method:'DELETE'});
    loadProxies(); loadDashProxies();
    notify('🗑 Прокси удалён');
  } catch(e) { alert('Ошибка: ' + e.message); }
}

async function startProxy(id) {
  await api('/api/proxies/' + id + '/start', {method:'POST'});
  loadProxies(); loadDashProxies();
}

async function stopProxy(id) {
  await api('/api/proxies/' + id + '/stop', {method:'POST'});
  loadProxies(); loadDashProxies();
}

async function rotateSecret(id) {
  if (!confirm('Сменить секретный ключ? Все текущие подключения отключатся.')) return;
  try {
    const r = await api('/api/proxies/' + id + '/rotate', {method:'POST'});
    notify('🔄 Секрет обновлён');
    loadProxies();
  } catch(e) { alert('Ошибка: ' + e.message); }
}

// ── QR ────────────────────────────────────────────
async function showQR(id) {
  $('qr-container').innerHTML = '<p style="color:var(--muted)">Генерация...</p>';
  $('qr-link').textContent = '';
  $('modal-qr').classList.add('open');
  try {
    const r = await api('/api/proxies/' + id + '/qr');
    $('qr-link').textContent = r.link;
    if (r.qr_svg) {
      $('qr-container').innerHTML = r.qr_svg;
    } else {
      $('qr-container').innerHTML = '<p style="color:var(--muted);font-size:12px">QR недоступен (установите qrencode)</p>';
    }
  } catch(e) { $('qr-container').innerHTML = 'Ошибка'; }
}

function copyLink() {
  const txt = $('qr-link').textContent;
  navigator.clipboard.writeText(txt).then(() => notify('📋 Скопировано!'));
}

// ── Логи ─────────────────────────────────────────
async function showLogs(id) {
  $('logs-pre').textContent = 'Загрузка...';
  $('modal-logs').classList.add('open');
  try {
    const r = await api('/api/proxies/' + id + '/logs');
    $('logs-pre').textContent = r.lines.join('\n') || 'Логи пусты';
    $('logs-pre').scrollTop = $('logs-pre').scrollHeight;
  } catch(e) { $('logs-pre').textContent = 'Ошибка'; }
}

// ── События ───────────────────────────────────────
const EVENT_COLORS = {
  start:'badge-green', stop:'badge-red', create:'badge-green',
  delete:'badge-red', rotate:'badge-yellow', auth:'',
  error:'badge-red', system:'', watchdog:'badge-yellow', settings:''
};

async function loadEvents() {
  try {
    const events = await api('/api/events');
    const el = $('event-list');
    if (!events.length) { el.innerHTML = '<p style="color:var(--muted);text-align:center;padding:20px">Нет событий</p>'; return; }
    el.innerHTML = events.map(e => {
      const cls = EVENT_COLORS[e.kind] || '';
      const dt = new Date(e.ts).toLocaleString('ru');
      return `<div class="event-item">
        <span class="event-kind badge ${cls}" style="background:rgba(255,255,255,.06)">${e.kind}</span>
        <div><div>${e.msg}</div><div style="color:var(--muted)">${dt}</div></div>
      </div>`;
    }).join('');
  } catch(e) { console.error(e); }
}

// ── Настройки ─────────────────────────────────────
async function loadSettings() {
  try {
    const s = await api('/api/settings');
    $('set-tg-token').value   = '';
    $('set-tg-chat').value    = s.tg_chat_id || '';
    $('set-whitelist').value  = (s.ip_whitelist||[]).join(', ');
    $('set-server-ip').value  = s.server_ip || '';
  } catch(e) {}
}

async function saveSettings() {
  const data = {
    tg_token:    $('set-tg-token').value,
    tg_chat_id:  $('set-tg-chat').value,
    ip_whitelist:$('set-whitelist').value,
    server_ip:   $('set-server-ip').value,
  };
  try {
    await api('/api/settings', {method:'POST', body:JSON.stringify(data)});
    notify('✅ Настройки сохранены');
  } catch(e) { alert('Ошибка: ' + e.message); }
}

async function testTg() {
  try {
    await api('/api/test_telegram', {method:'POST'});
    notify('📤 Тестовое сообщение отправлено');
  } catch(e) { alert('Ошибка: ' + e.message); }
}

async function changePass() {
  const old = $('pw-old').value;
  const nw  = $('pw-new').value;
  const nw2 = $('pw-new2').value;
  if (nw !== nw2) { alert('Пароли не совпадают'); return; }
  try {
    await api('/api/settings/change_password', {method:'POST', body:JSON.stringify({old_password:old, new_password:nw})});
    notify('✅ Пароль изменён'); $('pw-old').value=$('pw-new').value=$('pw-new2').value='';
  } catch(e) { alert('Ошибка: ' + e.message); }
}

// ── Utils ─────────────────────────────────────────
function closeModal(id) { $(id).classList.remove('open'); }

function notify(msg) {
  const el = document.createElement('div');
  el.textContent = msg;
  Object.assign(el.style, {
    position:'fixed', bottom:'24px', right:'24px', background:'#238636',
    color:'#fff', padding:'12px 20px', borderRadius:'10px', fontSize:'14px',
    fontWeight:'600', zIndex:'999', boxShadow:'0 4px 20px rgba(0,0,0,.4)',
    transition:'opacity .3s'
  });
  document.body.appendChild(el);
  setTimeout(() => { el.style.opacity = '0'; setTimeout(() => el.remove(), 300); }, 2500);
}

// ── Авто-обновление ───────────────────────────────
loadAll();
setInterval(loadAll, 10000);
</script>
</body>
</html>'''

with open('/opt/mtg-panel/index.html', 'w') as f:
    f.write(html)
print('index.html written')
PYEOF
ok "index.html создан"

# ── systemd сервис ─────────────────────────────────
hdr "Systemd служба"
cat > /etc/systemd/system/mtg-panel.service << SVCEOF
[Unit]
Description=MTG Proxy Panel v3
After=network.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV}/bin/uvicorn app:app --host 0.0.0.0 --port ${PANEL_PORT} --workers 1
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable mtg-panel --quiet
systemctl restart mtg-panel
sleep 2
systemctl is-active --quiet mtg-panel && ok "Служба запущена" || warn "Служба не запустилась — проверьте: journalctl -u mtg-panel -n 30"

# ── Firewall ───────────────────────────────────────
hdr "Брандмауэр"
if command -v ufw &>/dev/null; then
    ufw allow "${PANEL_PORT}/tcp" --comment "MTG Panel" > /dev/null 2>&1
    ok "UFW: порт $PANEL_PORT открыт"
elif command -v iptables &>/dev/null; then
    iptables -I INPUT -p tcp --dport "${PANEL_PORT}" -j ACCEPT 2>/dev/null
    ok "iptables: порт $PANEL_PORT открыт"
else
    warn "Брандмауэр не найден — откройте порт $PANEL_PORT вручную"
fi

# ── Итог ──────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}   УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО ✓${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${CYAN}Адрес панели:${RESET}"
echo -e "     ${BOLD}http://${SERVER_IP}:${PANEL_PORT}${RESET}"
echo ""
echo -e "  ${CYAN}Данные для входа:${RESET}"
echo -e "     Логин:   ${BOLD}${PANEL_USER}${RESET}"
echo -e "     Пароль:  ${BOLD}${PANEL_PASS}${RESET}"
echo ""
echo -e "  ${CYAN}Функции v3:${RESET}"
echo -e "     ★ Неограниченное кол-во прокси"
echo -e "     ★ Индивидуальные секреты и домены TLS"
echo -e "     ★ QR-коды для подключения"
echo -e "     ★ Telegram уведомления + команды"
echo -e "     ★ Авто-ротация секретов"
echo -e "     ★ Watchdog (автоперезапуск)"
echo -e "     ★ IP Whitelist для панели"
echo -e "     ★ История событий"
echo -e "     ★ CPU / RAM / Disk метрики"
echo -e "     ★ Бэкап конфигурации"
echo -e "     ★ Логи каждого прокси"
echo ""
echo -e "  ${CYAN}Управление:${RESET}"
echo -e "     systemctl status mtg-panel"
echo -e "     journalctl -u mtg-panel -f"
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
