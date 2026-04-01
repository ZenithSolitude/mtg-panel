#!/bin/bash
# ╔══════════════════════════════════════════════════╗
# ║      MTG PROXY PANEL v3.1 — INSTALLER            ║
# ║   Полная установка на чистую Ubuntu 22.04        ║
# ╚══════════════════════════════════════════════════╝
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}[✓]${RESET} $*"; }
info() { echo -e "${CYAN}[•]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*"; exit 1; }
hdr()  { echo -e "\n${BOLD}━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

clear
cat << 'EOF'
  ╔═══════════════════════════════════════════╗
  ║   ███╗   ███╗████████╗ ██████╗            ║
  ║   ████╗ ████║╚══██╔══╝██╔════╝            ║
  ║   ██╔████╔██║   ██║   ██║  ███╗           ║
  ║   ██║╚██╔╝██║   ██║   ██║   ██║           ║
  ║   ██║ ╚═╝ ██║   ██║   ╚██████╔╝           ║
  ║   ╚═╝     ╚═╝   ╚═╝    ╚═════╝ PANEL v3.1 ║
  ╚═══════════════════════════════════════════╝
       MTProto Proxy Web Management Panel
EOF

[[ $EUID -ne 0 ]] && err "Запускайте от root"

SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
  || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
  || hostname -I | awk '{print $1}')
info "IP сервера: $SERVER_IP"

hdr "Настройка панели"
read -rp "$(echo -e "${CYAN}Логин панели${RESET} [admin]: ")" PANEL_USER
PANEL_USER=${PANEL_USER:-admin}
while true; do
  read -rsp "$(echo -e "${CYAN}Пароль панели${RESET}: ")" PANEL_PASS; echo
  [[ ${#PANEL_PASS} -ge 6 ]] && break
  warn "Пароль минимум 6 символов"
done
read -rp "$(echo -e "${CYAN}Порт панели${RESET} [8080]: ")" PANEL_PORT
PANEL_PORT=${PANEL_PORT:-8080}
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
  iptables qrencode jq 2>/dev/null | tail -3
ok "Пакеты установлены"

# ── MTG ────────────────────────────────────────────
hdr "MTG бинарный файл"
MTG_VER="v2.2.6"
MTG_URL="https://github.com/9seconds/mtg/releases/download/${MTG_VER}/mtg-2.2.6-linux-amd64.tar.gz"
MTG_TMP=$(mktemp -d)
info "Скачиваю MTG ${MTG_VER}..."
wget -q --show-progress -O "${MTG_TMP}/mtg.tar.gz" "$MTG_URL" || err "Не удалось скачать MTG"
cd "$MTG_TMP"
tar -xzf mtg.tar.gz

# Ищем файл с именем ровно "mtg" (бинарник всегда так называется)
MTG_BIN=$(find "$MTG_TMP" -type f -name "mtg" | head -1)

# Запасной вариант: любой ELF-файл
if [[ -z "$MTG_BIN" ]]; then
  MTG_BIN=$(find "$MTG_TMP" -type f | while read f; do
    head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF' && echo "$f" && break
  done)
fi

[[ -z "$MTG_BIN" ]] && err "Бинарник MTG не найден в архиве. Содержимое: $(find $MTG_TMP -type f)"

# Проверяем что это ELF (исполняемый файл Linux), а не текст
MAGIC=$(head -c 4 "$MTG_BIN" 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 8)
if [[ "$MAGIC" != "7f454c46" ]]; then
  err "Скачанный файл не является ELF-бинарником (magic=$MAGIC). Возможно, сервер вернул HTML/текст."
fi

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

# ── Конфиг ─────────────────────────────────────────
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
  "theme": "dark"
}
EOCFG
ok "Конфиг создан"

# ── app.py ─────────────────────────────────────────
hdr "Файлы панели"
cat > "$INSTALL_DIR/app.py" << 'PYEOF'
import asyncio, json, os, socket, subprocess, time, uuid, hashlib, io, zipfile
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

import httpx, psutil
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from fastapi import FastAPI, Request, HTTPException, Form, Depends
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, StreamingResponse
from jose import jwt, JWTError
from passlib.context import CryptContext

BASE   = Path(__file__).parent
DATA   = BASE / "data"
PCFG   = DATA / "config.json"
PFILE  = DATA / "proxies" / "proxies.json"
EVENTS = DATA / "logs" / "events.jsonl"
for p in [PFILE.parent, EVENTS.parent]: p.mkdir(parents=True, exist_ok=True)

SECRET_KEY = hashlib.sha256(os.urandom(32)).hexdigest()
ALGORITHM  = "HS256"
TOKEN_TTL  = 60 * 8
pwd_ctx    = CryptContext(schemes=["bcrypt"], deprecated="auto")

# ── helpers ────────────────────────────────────────
def load_cfg():  return json.loads(PCFG.read_text())
def save_cfg(c): PCFG.write_text(json.dumps(c, indent=2, ensure_ascii=False))
def load_proxies(): return json.loads(PFILE.read_text()) if PFILE.exists() else []
def save_proxies(p): PFILE.write_text(json.dumps(p, indent=2, ensure_ascii=False))

def log_event(kind, msg, proxy_id=""):
    e = {"ts": datetime.utcnow().isoformat(), "kind": kind, "msg": msg, "proxy_id": proxy_id}
    with open(EVENTS, "a") as f: f.write(json.dumps(e, ensure_ascii=False) + "\n")

def get_events(limit=200):
    if not EVENTS.exists(): return []
    lines = [l for l in EVENTS.read_text().strip().splitlines() if l.strip()]
    return list(reversed([json.loads(l) for l in lines[-limit:]]))

async def tg_send(text):
    cfg = load_cfg()
    tok, chat = cfg.get("tg_token",""), cfg.get("tg_chat_id","")
    if not tok or not chat: return
    try:
        async with httpx.AsyncClient(timeout=5) as c:
            await c.post(f"https://api.telegram.org/bot{tok}/sendMessage",
                         json={"chat_id": chat, "text": text, "parse_mode": "HTML"})
    except: pass

# ── MTG process management ─────────────────────────
# MTG v2 использует TOML-конфиг: mtg run /path/to/config.toml
PROCS: dict = {}

def mtg_gen_secret(fake_tls=True, domain="www.google.com"):
    """Генерация секрета через mtg generate-secret"""
    try:
        if fake_tls:
            r = subprocess.run(
                ["mtg", "generate-secret", "--hex", domain],
                capture_output=True, text=True, timeout=5)
        else:
            r = subprocess.run(
                ["mtg", "generate-secret", "--hex"],
                capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            return r.stdout.strip()
    except: pass
    # fallback: генерируем вручную
    raw = os.urandom(16).hex()
    if fake_tls:
        return "ee" + raw + domain.encode().hex()
    return raw

def write_proxy_config(proxy) -> Path:
    """Создаёт TOML конфиг для MTG v2"""
    cfg_path = DATA / "proxies" / f"proxy_{proxy['id']}.toml"
    secret   = proxy["secret"]
    port     = proxy["port"]
    # MTG v2 TOML конфиг - минимальный рабочий вариант
    toml = f'''secret = "{secret}"
bind-to = "0.0.0.0:{port}"
concurrency = 8192

[network]
prefer-ip = "prefer-ipv4"

[network.timeout]
tcp   = "5s"
http  = "10s"
idle  = "1m"
'''
    cfg_path.write_text(toml)
    return cfg_path

def start_proxy(proxy) -> bool:
    pid = proxy["id"]
    if pid in PROCS:
        try:
            if PROCS[pid].poll() is None:
                return True
        except: pass

    log_p    = DATA / "logs" / f"proxy_{pid}.log"
    cfg_path = write_proxy_config(proxy)

    # MTG v2: mtg run <path_to_config.toml>
    cmd = ["mtg", "run", str(cfg_path)]

    try:
        with open(log_p, "a") as lf:
            proc = subprocess.Popen(
                cmd, stdout=lf, stderr=lf,
                start_new_session=True
            )
        PROCS[pid] = proc
        time.sleep(1.0)
        proc.poll()
        if proc.returncode is not None:
            tail = ""
            if log_p.exists():
                lines = log_p.read_text().splitlines()
                tail = " | ".join(lines[-5:])
            log_event("error", f"MTG завершился (rc={proc.returncode}) {tail}", pid)
            PROCS.pop(pid, None)
            return False
        log_event("start", f"Запущен порт {proxy['port']}", pid)
        return True
    except Exception as e:
        log_event("error", f"Ошибка запуска: {e}", pid)
        return False

def stop_proxy(proxy_id, remove_cfg=False):
    proc = PROCS.pop(proxy_id, None)
    if proc:
        try: proc.terminate(); proc.wait(timeout=5)
        except: proc.kill()
    if remove_cfg:
        cfg_p = DATA / "proxies" / f"proxy_{proxy_id}.toml"
        if cfg_p.exists(): cfg_p.unlink()
    log_event("stop", "Остановлен", proxy_id)

def proxy_status(proxy) -> str:
    pid = proxy["id"]
    if pid not in PROCS: return "stopped"
    PROCS[pid].poll()
    return "running" if PROCS[pid].returncode is None else "stopped"

def get_connections(port) -> int:
    try:
        return sum(1 for c in psutil.net_connections("tcp")
                   if c.laddr.port == port and c.status == "ESTABLISHED")
    except: return 0

def is_port_free(port) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        return s.connect_ex(("127.0.0.1", port)) != 0

def find_free_port(start=4430):
    for p in range(start, start+500):
        if is_port_free(p): return p
    return start

def proxy_link(ip, port, secret):
    return f"tg://proxy?server={ip}&port={port}&secret={secret}"

# ── Scheduler ─────────────────────────────────────
async def watchdog_task():
    for proxy in load_proxies():
        if not proxy.get("enabled", True): continue
        if proxy_status(proxy) == "stopped":
            if start_proxy(proxy):
                await tg_send(
                    f"⚠️ Прокси <b>{proxy['name']}</b> (:{proxy['port']}) "
                    f"перезапущен автоматически")

async def rotate_task():
    proxies = load_proxies(); cfg = load_cfg(); changed = False
    for proxy in proxies:
        if not proxy.get("auto_rotate"): continue
        new_sec = mtg_gen_secret(
            proxy.get("fake_tls", True),
            proxy.get("tls_domain", "www.google.com"))
        proxy["secret"] = new_sec
        proxy["rotated_at"] = datetime.utcnow().isoformat()
        stop_proxy(proxy["id"]); time.sleep(0.3); start_proxy(proxy)
        link = proxy_link(cfg["server_ip"], proxy["port"], new_sec)
        await tg_send(
            f"🔄 Ротация <b>{proxy['name']}</b>\n"
            f"🔗 <code>{link}</code>")
        log_event("rotate", "Авторотация секрета", proxy["id"])
        changed = True
    if changed: save_proxies(proxies)

# ── Auth ───────────────────────────────────────────
def create_token(u):
    return jwt.encode(
        {"sub": u, "exp": datetime.utcnow() + timedelta(minutes=TOKEN_TTL)},
        SECRET_KEY, ALGORITHM)

def verify_token(t):
    try: return jwt.decode(t, SECRET_KEY, algorithms=[ALGORITHM]).get("sub")
    except: return None

def auth_required(request: Request):
    tok = request.cookies.get("access_token")
    if not tok or not verify_token(tok): raise HTTPException(401)
    return verify_token(tok)

def check_whitelist(request: Request):
    wl = load_cfg().get("ip_whitelist", [])
    if wl and request.client.host not in wl:
        raise HTTPException(403, f"IP {request.client.host} заблокирован")

# ── App ────────────────────────────────────────────
scheduler = AsyncIOScheduler()

@asynccontextmanager
async def lifespan(app: FastAPI):
    for proxy in load_proxies():
        if proxy.get("enabled", True):
            start_proxy(proxy)
    scheduler.add_job(watchdog_task, "interval", seconds=30, id="wd")
    scheduler.add_job(rotate_task,   "interval", hours=1,    id="rot")
    scheduler.start()
    log_event("system", "Панель запущена v3.1")
    await tg_send("🟢 <b>MTG Panel v3.1</b> запущена")
    yield
    for p in load_proxies(): stop_proxy(p["id"])
    scheduler.shutdown()

app = FastAPI(title="MTG Panel v3.1", lifespan=lifespan)

# ── Pages ──────────────────────────────────────────
@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    try: check_whitelist(request); auth_required(request)
    except: return RedirectResponse("/login")
    return HTMLResponse((BASE / "index.html").read_text())

@app.get("/login", response_class=HTMLResponse)
async def login_page():
    return HTMLResponse((BASE / "login.html").read_text())

@app.post("/login")
async def login(request: Request,
                username: str = Form(...),
                password: str = Form(...)):
    check_whitelist(request)
    cfg = load_cfg()
    if username != cfg["panel_user"] or \
       not pwd_ctx.verify(password, cfg["panel_pass_hash"]):
        return HTMLResponse(
            '<script>alert("Неверный логин или пароль");history.back()</script>')
    resp = RedirectResponse("/", status_code=302)
    resp.set_cookie("access_token", create_token(username),
                    httponly=True, max_age=TOKEN_TTL * 60)
    log_event("auth", f"Вход: {username}")
    return resp

@app.get("/logout")
async def logout():
    r = RedirectResponse("/login", status_code=302)
    r.delete_cookie("access_token")
    return r

# ── API: System ────────────────────────────────────
@app.get("/api/system")
async def api_system(_=Depends(auth_required)):
    cpu  = psutil.cpu_percent(interval=0.2)
    ram  = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    uptime = str(timedelta(seconds=int(time.time() - psutil.boot_time())))
    return {
        "cpu":        cpu,
        "ram_used":   round(ram.used / 1024**2),
        "ram_total":  round(ram.total / 1024**2),
        "ram_pct":    ram.percent,
        "disk_used":  round(disk.used / 1024**3, 1),
        "disk_total": round(disk.total / 1024**3, 1),
        "disk_pct":   disk.percent,
        "uptime":     uptime,
        "server_ip":  load_cfg()["server_ip"],
    }

# ── API: Proxies ───────────────────────────────────
@app.get("/api/proxies")
async def api_proxies(_=Depends(auth_required)):
    cfg = load_cfg()
    result = []
    for p in load_proxies():
        st   = proxy_status(p)
        conn = get_connections(p["port"]) if st == "running" else 0
        link = proxy_link(cfg["server_ip"], p["port"], p["secret"])
        result.append({**p, "status": st, "connections": conn, "link": link})
    return result

@app.post("/api/proxies")
async def api_add_proxy(request: Request, _=Depends(auth_required)):
    b = await request.json()
    proxies = load_proxies()
    cfg     = load_cfg()
    port    = int(b.get("port", 0)) or find_free_port()
    if not is_port_free(port):
        raise HTTPException(400, f"Порт {port} занят")
    fake_tls = b.get("fake_tls", True)
    domain   = (b.get("tls_domain") or "www.google.com").strip()
    secret   = b.get("secret", "").strip() or mtg_gen_secret(fake_tls, domain)
    proxy = {
        "id":          str(uuid.uuid4())[:8],
        "name":        b.get("name") or f"Прокси {len(proxies)+1}",
        "port":        port,
        "secret":      secret,
        "fake_tls":    fake_tls,
        "tls_domain":  domain,
        "auto_rotate": b.get("auto_rotate", False),
        "enabled":     True,
        "created_at":  datetime.utcnow().isoformat(),
        "rotated_at":  None,
    }
    proxies.append(proxy)
    save_proxies(proxies)
    ok2  = start_proxy(proxy)
    link = proxy_link(cfg["server_ip"], port, secret)
    log_event("create", f"Создан {proxy['name']} :{port}", proxy["id"])
    await tg_send(f"➕ Новый прокси <b>{proxy['name']}</b>\n🔗 <code>{link}</code>")
    return {**proxy, "status": "running" if ok2 else "error", "link": link}

@app.delete("/api/proxies/{pid}")
async def api_del(pid: str, _=Depends(auth_required)):
    proxies = load_proxies()
    proxy   = next((p for p in proxies if p["id"] == pid), None)
    if not proxy: raise HTTPException(404)
    stop_proxy(pid, remove_cfg=True)
    save_proxies([p for p in proxies if p["id"] != pid])
    log_event("delete", f"Удалён {proxy['name']}", pid)
    await tg_send(f"🗑 Удалён прокси <b>{proxy['name']}</b>")
    return {"ok": True}

@app.post("/api/proxies/{pid}/start")
async def api_start(pid: str, _=Depends(auth_required)):
    proxy = next((p for p in load_proxies() if p["id"] == pid), None)
    if not proxy: raise HTTPException(404)
    ok2 = start_proxy(proxy)
    if not ok2:
        log_p = DATA / "logs" / f"proxy_{pid}.log"
        tail  = ""
        if log_p.exists():
            tail = "\n".join(log_p.read_text().splitlines()[-8:])
        raise HTTPException(500, f"Не удалось запустить:\n{tail}")
    return {"ok": True}

@app.post("/api/proxies/{pid}/stop")
async def api_stop(pid: str, _=Depends(auth_required)):
    stop_proxy(pid)
    return {"ok": True}

@app.post("/api/proxies/{pid}/rotate")
async def api_rotate(pid: str, _=Depends(auth_required)):
    proxies = load_proxies()
    cfg     = load_cfg()
    proxy   = next((p for p in proxies if p["id"] == pid), None)
    if not proxy: raise HTTPException(404)
    new_sec = mtg_gen_secret(
        proxy.get("fake_tls", True),
        proxy.get("tls_domain", "www.google.com"))
    proxy["secret"]     = new_sec
    proxy["rotated_at"] = datetime.utcnow().isoformat()
    save_proxies(proxies)
    stop_proxy(pid); time.sleep(0.3); start_proxy(proxy)
    link = proxy_link(cfg["server_ip"], proxy["port"], new_sec)
    log_event("rotate", "Ручная ротация", pid)
    await tg_send(f"🔄 Ротация <b>{proxy['name']}</b>\n🔗 <code>{link}</code>")
    return {"ok": True, "secret": new_sec, "link": link}

@app.get("/api/proxies/{pid}/qr")
async def api_qr(pid: str, _=Depends(auth_required)):
    proxy = next((p for p in load_proxies() if p["id"] == pid), None)
    if not proxy: raise HTTPException(404)
    link = proxy_link(load_cfg()["server_ip"], proxy["port"], proxy["secret"])
    try:
        r = subprocess.run(
            ["qrencode", "-t", "SVG", "-o", "-", link],
            capture_output=True, timeout=5)
        if r.returncode == 0:
            return JSONResponse({"qr_svg": r.stdout.decode(), "link": link})
    except: pass
    return JSONResponse({"qr_svg": None, "link": link})

@app.get("/api/proxies/{pid}/logs")
async def api_logs(pid: str, _=Depends(auth_required)):
    log_p = DATA / "logs" / f"proxy_{pid}.log"
    if not log_p.exists(): return {"lines": []}
    return {"lines": log_p.read_text().splitlines()[-150:]}

@app.get("/api/events")
async def api_events(_=Depends(auth_required)):
    return get_events(300)

@app.get("/api/settings")
async def api_get_settings(_=Depends(auth_required)):
    cfg = load_cfg()
    return {
        "ip_whitelist":  cfg.get("ip_whitelist", []),
        "tg_configured": bool(cfg.get("tg_token")),
        "tg_chat_id":    cfg.get("tg_chat_id", ""),
        "server_ip":     cfg.get("server_ip", ""),
    }

@app.post("/api/settings")
async def api_save_settings(request: Request, _=Depends(auth_required)):
    b = await request.json()
    cfg = load_cfg()
    if "ip_whitelist" in b:
        raw = b["ip_whitelist"]
        cfg["ip_whitelist"] = (
            [x.strip() for x in raw.split(",") if x.strip()]
            if isinstance(raw, str) else raw)
    if "tg_token" in b and b["tg_token"] not in ("", "***"):
        cfg["tg_token"] = b["tg_token"]
    if "tg_chat_id" in b: cfg["tg_chat_id"] = b["tg_chat_id"]
    if "server_ip"  in b: cfg["server_ip"]  = b["server_ip"]
    save_cfg(cfg)
    log_event("settings", "Настройки обновлены")
    return {"ok": True}

@app.post("/api/settings/change_password")
async def api_change_pw(request: Request, _=Depends(auth_required)):
    b   = await request.json()
    cfg = load_cfg()
    if not pwd_ctx.verify(b.get("old", ""), cfg["panel_pass_hash"]):
        raise HTTPException(400, "Неверный текущий пароль")
    if len(b.get("new", "")) < 6:
        raise HTTPException(400, "Пароль слишком короткий")
    cfg["panel_pass_hash"] = pwd_ctx.hash(b["new"])
    save_cfg(cfg)
    log_event("auth", "Пароль изменён")
    return {"ok": True}

@app.post("/api/test_telegram")
async def api_test_tg(_=Depends(auth_required)):
    await tg_send("✅ Тест уведомлений MTG Panel v3.1 работает!")
    return {"ok": True}

@app.post("/api/backup")
async def api_backup(_=Depends(auth_required)):
    buf = io.BytesIO()
    ts  = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    with zipfile.ZipFile(buf, "w") as zf:
        for f in [PCFG, PFILE]:
            if f.exists(): zf.write(f, f.name)
    buf.seek(0)
    return StreamingResponse(
        buf, media_type="application/zip",
        headers={"Content-Disposition":
                 f"attachment; filename=mtg_backup_{ts}.zip"})
PYEOF
ok "app.py создан"

# ── login.html ─────────────────────────────────────
cat > "$INSTALL_DIR/login.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MTG Panel · Вход</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{
  min-height:100vh;
  background:linear-gradient(135deg,#0a0e1a 0%,#0d1628 50%,#0a1020 100%);
  display:flex;align-items:center;justify-content:center;
  font-family:'Segoe UI',system-ui,sans-serif;
}
.bg-glow{
  position:fixed;inset:0;pointer-events:none;
  background:
    radial-gradient(ellipse 600px 400px at 20% 50%,rgba(56,139,253,.08) 0%,transparent 70%),
    radial-gradient(ellipse 400px 600px at 80% 30%,rgba(88,96,253,.05) 0%,transparent 70%);
}
.card{
  position:relative;z-index:1;
  background:rgba(22,27,34,.96);
  border:1px solid rgba(48,54,61,.9);
  border-radius:20px;padding:44px 40px;width:380px;
  box-shadow:0 24px 80px rgba(0,0,0,.6),0 0 0 1px rgba(255,255,255,.03);
  backdrop-filter:blur(20px);
}
.logo{text-align:center;margin-bottom:36px}
.logo-icon{
  width:64px;height:64px;margin:0 auto 16px;
  background:linear-gradient(135deg,#1f6feb,#388bfd);
  border-radius:16px;display:flex;align-items:center;justify-content:center;
  font-size:28px;box-shadow:0 8px 32px rgba(56,139,253,.35);
}
.logo h1{color:#e6edf3;font-size:22px;font-weight:700;letter-spacing:1px}
.logo p{color:#7d8590;font-size:13px;margin-top:5px}
.field{margin-bottom:20px}
.field label{display:block;color:#7d8590;font-size:11px;font-weight:600;letter-spacing:1px;text-transform:uppercase;margin-bottom:8px}
.field input{
  width:100%;background:rgba(13,17,23,.8);
  border:1px solid rgba(48,54,61,.8);border-radius:10px;
  padding:11px 14px;color:#e6edf3;font-size:14px;outline:none;transition:.2s;
}
.field input:focus{border-color:#388bfd;box-shadow:0 0 0 3px rgba(56,139,253,.12)}
.btn-login{
  width:100%;padding:13px;
  background:linear-gradient(135deg,#1f6feb,#388bfd);
  border:none;border-radius:10px;color:#fff;font-size:15px;font-weight:600;
  cursor:pointer;transition:.2s;letter-spacing:.3px;
  box-shadow:0 4px 16px rgba(56,139,253,.3);
}
.btn-login:hover{transform:translateY(-1px);box-shadow:0 6px 24px rgba(56,139,253,.45)}
.footer{text-align:center;margin-top:20px;color:rgba(125,133,144,.6);font-size:11px}
</style>
</head>
<body>
<div class="bg-glow"></div>
<div class="card">
  <div class="logo">
    <div class="logo-icon">⚡</div>
    <h1>MTG PANEL</h1>
    <p>MTProto Proxy Management v3.1</p>
  </div>
  <form method="POST" action="/login">
    <div class="field"><label>Логин</label><input name="username" autofocus autocomplete="username" required></div>
    <div class="field"><label>Пароль</label><input type="password" name="password" autocomplete="current-password" required></div>
    <button type="submit" class="btn-login">Войти →</button>
  </form>
  <div class="footer">Secure MTProto Proxy Panel</div>
</div>
</body>
</html>
HTMLEOF
ok "login.html создан"

# ── index.html ─────────────────────────────────────
python3 << 'PYEOF'
html = r'''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MTG Panel v3.1</title>
<style>
:root{
  --bg:#090d16;--surface:#0d1117;--surface2:#161b22;
  --border:#21262d;--border2:#30363d;
  --text:#e6edf3;--muted:#7d8590;--muted2:#484f58;
  --accent:#388bfd;--accent2:#1f6feb;
  --green:#3fb950;--green-bg:rgba(63,185,80,.12);
  --red:#f85149;--red-bg:rgba(248,81,73,.12);
  --yellow:#d29922;--yellow-bg:rgba(210,153,34,.12);
  --purple:#a371f7;--purple-bg:rgba(163,113,247,.12);
  --r:12px;--rs:8px;
}
*{margin:0;padding:0;box-sizing:border-box}
html{font-size:14px}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;min-height:100vh;display:flex}

/* Sidebar */
.sidebar{
  width:240px;background:var(--surface);border-right:1px solid var(--border);
  display:flex;flex-direction:column;position:fixed;top:0;left:0;bottom:0;z-index:10;
}
.sb-head{padding:18px 16px 14px;border-bottom:1px solid var(--border)}
.sb-logo{display:flex;align-items:center;gap:10px;margin-bottom:12px}
.sb-ico{
  width:38px;height:38px;border-radius:10px;flex-shrink:0;
  background:linear-gradient(135deg,var(--accent2),var(--accent));
  display:flex;align-items:center;justify-content:center;font-size:18px;
  box-shadow:0 4px 14px rgba(56,139,253,.3);
}
.sb-txt h2{color:var(--text);font-size:14px;font-weight:700;letter-spacing:.5px}
.sb-txt p{color:var(--muted);font-size:10px;margin-top:1px}
.sb-mini{display:grid;grid-template-columns:1fr 1fr;gap:6px}
.sb-chip{background:rgba(255,255,255,.03);border:1px solid var(--border);border-radius:8px;padding:7px 10px;text-align:center}
.sb-chip .v{font-size:17px;font-weight:700}
.sb-chip .l{font-size:10px;color:var(--muted);margin-top:1px}

.nav{flex:1;padding:8px;overflow-y:auto}
.nav-sec{font-size:10px;color:var(--muted2);font-weight:600;letter-spacing:.9px;text-transform:uppercase;padding:12px 8px 5px}
.nitem{
  display:flex;align-items:center;gap:9px;padding:9px 10px;border-radius:9px;
  color:var(--muted);cursor:pointer;font-size:13px;font-weight:500;
  transition:.15s;text-decoration:none;margin-bottom:2px;position:relative;
}
.nitem:hover{background:rgba(255,255,255,.05);color:var(--text)}
.nitem.on{background:rgba(56,139,253,.14);color:var(--accent)}
.nitem.on::before{
  content:'';position:absolute;left:-8px;top:50%;transform:translateY(-50%);
  width:3px;height:55%;background:var(--accent);border-radius:0 3px 3px 0;
}
.ni{width:18px;text-align:center;font-size:15px;flex-shrink:0}
.nbadge{margin-left:auto;background:var(--accent);color:#fff;font-size:10px;font-weight:700;padding:1px 7px;border-radius:10px}

.sb-foot{padding:12px;border-top:1px solid var(--border)}
.sb-foot a{
  display:flex;align-items:center;gap:8px;padding:8px 10px;
  border-radius:8px;color:var(--muted);font-size:13px;text-decoration:none;transition:.15s;
}
.sb-foot a:hover{background:var(--red-bg);color:var(--red)}

/* Main */
.main{margin-left:240px;flex:1;display:flex;flex-direction:column}
.topbar{
  background:var(--surface);border-bottom:1px solid var(--border);
  padding:0 24px;height:54px;display:flex;align-items:center;
  justify-content:space-between;position:sticky;top:0;z-index:5;
}
.tb-l{display:flex;align-items:center;gap:10px}
.ptitle{font-size:15px;font-weight:700}
.tb-r{display:flex;align-items:center;gap:10px}
.tb-pill{font-size:12px;color:var(--muted);padding:4px 10px;background:rgba(255,255,255,.05);border-radius:20px}
.content{padding:22px;flex:1}

/* Sections */
.sec{display:none}.sec.on{display:block}

/* Stats row */
.srow{display:grid;grid-template-columns:repeat(auto-fit,minmax(155px,1fr));gap:12px;margin-bottom:20px}
.scard{
  background:var(--surface2);border:1px solid var(--border);
  border-radius:var(--r);padding:16px;position:relative;overflow:hidden;
}
.scard::after{
  content:'';position:absolute;top:0;left:0;right:0;height:2px;
  background:var(--ac,var(--accent));
}
.scard .si{font-size:18px;margin-bottom:6px}
.scard .sv{font-size:20px;font-weight:700;line-height:1}
.scard .sl{font-size:11px;color:var(--muted);margin-top:4px}
.scard .sb{height:3px;background:rgba(255,255,255,.06);border-radius:2px;margin-top:8px;overflow:hidden}
.scard .sbf{height:100%;border-radius:2px;background:var(--ac,var(--accent));transition:width .5s}

/* Panel */
.panel{background:var(--surface2);border:1px solid var(--border);border-radius:var(--r);overflow:hidden}
.ph{padding:14px 18px;border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between}
.ptl{font-size:13px;font-weight:600}
.pb{padding:20px}

/* Table */
table{width:100%;border-collapse:collapse}
th{padding:9px 14px;text-align:left;font-size:11px;font-weight:600;color:var(--muted);background:rgba(255,255,255,.02);border-bottom:1px solid var(--border);text-transform:uppercase;letter-spacing:.5px}
td{padding:11px 14px;font-size:13px;border-bottom:1px solid var(--border);vertical-align:middle}
tr:last-child td{border:none}
tbody tr:hover td{background:rgba(255,255,255,.015)}

/* Badges */
.badge{display:inline-flex;align-items:center;gap:4px;padding:3px 8px;border-radius:20px;font-size:11px;font-weight:600}
.bg{background:var(--green-bg);color:var(--green)}
.br{background:var(--red-bg);color:var(--red)}
.by{background:var(--yellow-bg);color:var(--yellow)}
.bb{background:rgba(56,139,253,.14);color:var(--accent)}
.bd{background:rgba(255,255,255,.06);color:var(--muted)}
.dot{width:6px;height:6px;border-radius:50%;background:currentColor}

/* Buttons */
.btn{
  display:inline-flex;align-items:center;gap:5px;padding:7px 14px;
  border-radius:var(--rs);border:none;cursor:pointer;font-size:13px;
  font-weight:500;transition:.15s;text-decoration:none;white-space:nowrap;
}
.btn:active{transform:scale(.97)}
.btp{background:linear-gradient(135deg,var(--accent2),var(--accent));color:#fff;box-shadow:0 2px 8px rgba(56,139,253,.25)}
.btp:hover{box-shadow:0 4px 16px rgba(56,139,253,.4);transform:translateY(-1px)}
.btd{background:var(--red-bg);color:var(--red);border:1px solid rgba(248,81,73,.2)}
.btd:hover{background:rgba(248,81,73,.2)}
.bts{background:var(--green-bg);color:var(--green);border:1px solid rgba(63,185,80,.2)}
.bts:hover{background:rgba(63,185,80,.2)}
.btg{background:rgba(255,255,255,.06);color:var(--text);border:1px solid var(--border2)}
.btg:hover{background:rgba(255,255,255,.1)}
.sm{padding:5px 10px;font-size:12px}
.xs{padding:3px 8px;font-size:11px;border-radius:6px}

/* Toggle */
.tog{position:relative;width:40px;height:22px;cursor:pointer;flex-shrink:0}
.tog input{opacity:0;width:0;height:0;position:absolute}
.tt{position:absolute;inset:0;background:var(--border2);border-radius:22px;transition:.25s}
.th{position:absolute;width:16px;height:16px;background:#fff;border-radius:50%;top:3px;left:3px;transition:.25s;box-shadow:0 1px 4px rgba(0,0,0,.3)}
input:checked~.tt{background:var(--green)}
input:checked~.th{transform:translateX(18px)}

/* Modal */
.overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.78);backdrop-filter:blur(4px);z-index:100;align-items:center;justify-content:center;padding:16px}
.overlay.on{display:flex}
.modal{
  background:var(--surface2);border:1px solid var(--border2);
  border-radius:16px;padding:26px;width:100%;max-width:480px;
  max-height:92vh;overflow-y:auto;
  box-shadow:0 32px 80px rgba(0,0,0,.65);
  animation:mi .2s ease;
}
@keyframes mi{from{opacity:0;transform:scale(.95) translateY(10px)}to{opacity:1;transform:none}}
.mtitle{font-size:15px;font-weight:700;margin-bottom:20px;display:flex;align-items:center;gap:8px}
.mfoot{display:flex;gap:10px;margin-top:20px}

/* Form */
.fg{margin-bottom:15px}
.fg label{display:block;font-size:10px;font-weight:700;color:var(--muted);letter-spacing:.8px;text-transform:uppercase;margin-bottom:6px}
.fg input,.fg select{
  width:100%;background:rgba(9,13,22,.8);
  border:1px solid var(--border2);border-radius:var(--rs);
  padding:9px 12px;color:var(--text);font-size:13px;outline:none;transition:.2s;
}
.fg input:focus,.fg select:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(56,139,253,.1)}
.fg .hint{font-size:10px;color:var(--muted);margin-top:4px}
.trow{display:flex;align-items:center;justify-content:space-between;padding:11px 0;border-bottom:1px solid var(--border)}
.trow:last-child{border:none}
.tri .n{font-size:13px}.tri .d{font-size:11px;color:var(--muted);margin-top:2px}

/* Proxy cards */
.pcards{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:14px}
.pcard{
  background:var(--surface2);border:1px solid var(--border);
  border-radius:var(--r);padding:16px;transition:.2s;
}
.pcard:hover{border-color:var(--border2);transform:translateY(-1px)}
.pchead{display:flex;align-items:flex-start;justify-content:space-between;margin-bottom:10px}
.pcname{font-size:14px;font-weight:700}
.pcport{font-size:11px;color:var(--muted);margin-top:2px}
.pcsec{
  font-family:'Consolas',monospace;font-size:11px;color:var(--muted);
  background:rgba(255,255,255,.03);border-radius:6px;
  padding:6px 10px;margin-bottom:10px;word-break:break-all;cursor:pointer;
  transition:.15s;border:1px solid transparent;
}
.pcsec:hover{border-color:var(--border2);color:var(--accent)}
.pcstats{display:flex;gap:14px;margin-bottom:12px}
.pcstat{font-size:11px;color:var(--muted)}
.pcstat span{color:var(--text);font-weight:600}
.pcact{display:flex;gap:6px;flex-wrap:wrap}

/* Events */
.evitem{display:flex;align-items:flex-start;gap:10px;padding:9px 0;border-bottom:1px solid var(--border)}
.evitem:last-child{border:none}
.evkind{padding:2px 7px;border-radius:6px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;flex-shrink:0;margin-top:1px}
.evmsg{font-size:12px}
.evts{font-size:10px;color:var(--muted);margin-top:2px}

/* QR */
.qrwrap{display:flex;justify-content:center;padding:12px 0}
.qrwrap svg{max-width:175px;height:auto;border-radius:8px;background:#fff;padding:8px}
.lcopy{
  background:rgba(9,13,22,.8);border:1px solid var(--border2);border-radius:8px;
  padding:9px 13px;font-size:11px;word-break:break-all;color:var(--accent);
  cursor:pointer;margin-top:10px;transition:.15s;
}
.lcopy:hover{border-color:var(--accent);background:rgba(56,139,253,.06)}

/* Log */
.logbox{
  background:rgba(9,13,22,.9);border:1px solid var(--border);border-radius:8px;
  padding:12px;font-size:11px;font-family:'Consolas','Monaco',monospace;
  max-height:310px;overflow-y:auto;color:#3fb950;line-height:1.6;
  white-space:pre-wrap;word-break:break-all;
}

/* View toggle */
.vtbtn{padding:5px 10px;border-radius:6px;border:1px solid var(--border2);background:transparent;color:var(--muted);cursor:pointer;font-size:13px;transition:.15s}
.vtbtn.on,.vtbtn:hover{background:var(--accent);border-color:var(--accent);color:#fff}

/* Notif */
.notif{
  position:fixed;bottom:22px;right:22px;z-index:999;
  display:flex;align-items:center;gap:8px;padding:11px 16px;
  border-radius:11px;font-size:13px;font-weight:600;
  box-shadow:0 8px 30px rgba(0,0,0,.5);animation:noti .25s ease;transition:opacity .3s;
}
@keyframes noti{from{opacity:0;transform:translateX(16px)}to{opacity:1;transform:none}}
.n-ok{background:#1c2e20;border:1px solid rgba(63,185,80,.4);color:var(--green)}
.n-err{background:#2d1414;border:1px solid rgba(248,81,73,.4);color:var(--red)}

::-webkit-scrollbar{width:5px;height:5px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--border2);border-radius:3px}
</style>
</head>
<body>

<aside class="sidebar">
  <div class="sb-head">
    <div class="sb-logo">
      <div class="sb-ico">⚡</div>
      <div class="sb-txt"><h2>MTG PANEL</h2><p>v3.1 · MTProto</p></div>
    </div>
    <div class="sb-mini">
      <div class="sb-chip"><div class="v" id="sb-run">—</div><div class="l">Запущено</div></div>
      <div class="sb-chip"><div class="v" id="sb-con">—</div><div class="l">Соединений</div></div>
    </div>
  </div>
  <nav class="nav">
    <div class="nav-sec">Основное</div>
    <a class="nitem on" onclick="nav('dashboard',this)"><span class="ni">📊</span>Дашборд</a>
    <a class="nitem"    onclick="nav('proxies',this)"><span class="ni">🔌</span>Прокси <span class="nbadge" id="nb">0</span></a>
    <div class="nav-sec">Система</div>
    <a class="nitem" onclick="nav('events',this)"><span class="ni">📋</span>События</a>
    <a class="nitem" onclick="nav('settings',this)"><span class="ni">⚙️</span>Настройки</a>
  </nav>
  <div class="sb-foot"><a href="/logout"><span>🚪</span>Выйти</a></div>
</aside>

<div class="main">
  <header class="topbar">
    <div class="tb-l"><span class="ptitle" id="ptitle">Дашборд</span></div>
    <div class="tb-r">
      <span class="tb-pill" id="tb-up"></span>
      <span class="tb-pill" id="tb-ip"></span>
      <button class="btn btg sm" onclick="loadAll()">↻</button>
    </div>
  </header>

  <div class="content">

    <!-- Dashboard -->
    <div class="sec on" id="sec-dashboard">
      <div class="srow">
        <div class="scard" style="--ac:#388bfd">
          <div class="si">💻</div><div class="sv" id="d-cpu">—</div>
          <div class="sl">CPU</div>
          <div class="sb"><div class="sbf" id="b-cpu"></div></div>
        </div>
        <div class="scard" style="--ac:#a371f7">
          <div class="si">🧠</div><div class="sv" id="d-ram">—</div>
          <div class="sl">RAM</div>
          <div class="sb"><div class="sbf" id="b-ram" style="background:var(--purple)"></div></div>
        </div>
        <div class="scard" style="--ac:#d29922">
          <div class="si">💾</div><div class="sv" id="d-dsk">—</div>
          <div class="sl">Диск</div>
          <div class="sb"><div class="sbf" id="b-dsk" style="background:var(--yellow)"></div></div>
        </div>
        <div class="scard" style="--ac:#3fb950">
          <div class="si">🔌</div><div class="sv" id="d-prx">—</div>
          <div class="sl">Прокси</div>
        </div>
        <div class="scard" style="--ac:#388bfd">
          <div class="si">👥</div><div class="sv" id="d-cnn">—</div>
          <div class="sl">Соединений</div>
        </div>
      </div>
      <div class="panel">
        <div class="ph">
          <span class="ptl">Все прокси</span>
          <button class="btn btp sm" onclick="nav('proxies',null);openAdd()">+ Добавить</button>
        </div>
        <table>
          <thead><tr><th>Имя</th><th>Порт</th><th>Статус</th><th>Соединений</th><th></th></tr></thead>
          <tbody id="dtbl"></tbody>
        </table>
      </div>
    </div>

    <!-- Proxies -->
    <div class="sec" id="sec-proxies">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:14px">
        <div style="display:flex;gap:8px">
          <button class="vtbtn on" id="vb-c" onclick="setView('card')">⊞ Карточки</button>
          <button class="vtbtn"    id="vb-t" onclick="setView('table')">☰ Таблица</button>
        </div>
        <button class="btn btp" onclick="openAdd()">+ Новый прокси</button>
      </div>
      <div id="view-card"><div class="pcards" id="pcards"></div></div>
      <div id="view-table" style="display:none">
        <div class="panel">
          <table>
            <thead><tr><th>Имя</th><th>Порт</th><th>Тип</th><th>Соединений</th><th>Статус</th><th>Ротация</th><th>Действия</th></tr></thead>
            <tbody id="ptbl"></tbody>
          </table>
        </div>
      </div>
    </div>

    <!-- Events -->
    <div class="sec" id="sec-events">
      <div style="display:flex;justify-content:flex-end;margin-bottom:14px">
        <button class="btn btg sm" onclick="loadEvents()">↻</button>
      </div>
      <div class="panel"><div style="padding:16px 18px" id="evlist"></div></div>
    </div>

    <!-- Settings -->
    <div class="sec" id="sec-settings">
      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:14px">

        <div class="panel">
          <div class="ph"><span class="ptl">🔔 Telegram</span></div>
          <div class="pb">
            <div class="fg"><label>Bot Token</label><input id="s-tt" type="password" placeholder="1234567890:ABC..."></div>
            <div class="fg"><label>Chat ID</label><input id="s-tc" placeholder="-100..."></div>
            <div style="display:flex;gap:8px">
              <button class="btn btp" onclick="saveS()">Сохранить</button>
              <button class="btn btg" onclick="testTg()">Тест</button>
            </div>
          </div>
        </div>

        <div class="panel">
          <div class="ph"><span class="ptl">🛡 Безопасность</span></div>
          <div class="pb">
            <div class="fg"><label>IP Whitelist</label><input id="s-wl" placeholder="Пусто = все разрешены"><div class="hint">IP через запятую: 1.2.3.4, 5.6.7.8</div></div>
            <div class="fg"><label>IP сервера</label><input id="s-ip"></div>
            <button class="btn btp" onclick="saveS()">Сохранить</button>
          </div>
        </div>

        <div class="panel">
          <div class="ph"><span class="ptl">🔐 Пароль</span></div>
          <div class="pb">
            <div class="fg"><label>Текущий</label><input id="pw-o" type="password"></div>
            <div class="fg"><label>Новый</label><input id="pw-n" type="password"></div>
            <div class="fg"><label>Повтор</label><input id="pw-n2" type="password"></div>
            <button class="btn btp" onclick="changePw()">Сменить</button>
          </div>
        </div>

        <div class="panel">
          <div class="ph"><span class="ptl">💾 Бэкап</span></div>
          <div class="pb">
            <p style="color:var(--muted);font-size:12px;margin-bottom:14px">Скачать архив с конфигурацией всех прокси и настроек</p>
            <a href="/api/backup" class="btn btg">⬇ Скачать backup.zip</a>
          </div>
        </div>

      </div>
    </div>

  </div>
</div>

<!-- Modal: Add -->
<div class="overlay" id="m-add">
  <div class="modal">
    <div class="mtitle">➕ Новый прокси</div>
    <div class="fg"><label>Имя</label><input id="a-n" placeholder="Например: Основной"></div>
    <div class="fg"><label>Порт (0 = авто)</label><input id="a-p" type="number" value="0" min="0" max="65535"></div>
    <div class="fg">
      <label>Fake-TLS домен</label>
      <input id="a-d" value="www.google.com">
      <div class="hint">Маскировка трафика. Рекомендуется: www.google.com, cloudflare.com</div>
    </div>
    <div class="fg">
      <label>Свой секрет (пусто = автогенерация)</label>
      <input id="a-s" placeholder="Оставьте пустым">
    </div>
    <div class="trow">
      <div class="tri"><div class="n">Fake-TLS</div><div class="d">Маскировка под HTTPS трафик</div></div>
      <label class="tog"><input type="checkbox" id="a-ftls" checked><div class="tt"></div><div class="th"></div></label>
    </div>
    <div class="trow">
      <div class="tri"><div class="n">Авто-ротация</div><div class="d">Менять секрет каждый час автоматически</div></div>
      <label class="tog"><input type="checkbox" id="a-rot"><div class="tt"></div><div class="th"></div></label>
    </div>
    <div class="mfoot">
      <button class="btn btp" onclick="addProxy()">Создать</button>
      <button class="btn btg" onclick="closeM('m-add')">Отмена</button>
    </div>
  </div>
</div>

<!-- Modal: QR -->
<div class="overlay" id="m-qr">
  <div class="modal" style="max-width:350px;text-align:center">
    <div class="mtitle" style="justify-content:center">📱 Подключение</div>
    <p style="font-size:12px;color:var(--muted);margin-bottom:4px" id="qr-nm"></p>
    <div class="qrwrap" id="qr-box"></div>
    <div class="lcopy" id="qr-lnk" onclick="copyLink()"></div>
    <p style="font-size:10px;color:var(--muted);margin-top:6px">Нажмите ссылку чтобы скопировать</p>
    <div class="mfoot" style="justify-content:center"><button class="btn btg" onclick="closeM('m-qr')">Закрыть</button></div>
  </div>
</div>

<!-- Modal: Logs -->
<div class="overlay" id="m-logs">
  <div class="modal" style="max-width:620px">
    <div class="mtitle">📄 Логи прокси</div>
    <div class="logbox" id="logbox">Загрузка...</div>
    <div class="mfoot"><button class="btn btg" onclick="closeM('m-logs')">Закрыть</button></div>
  </div>
</div>

<script>
let VIEW='card', PROXIES=[];
const TITLES={dashboard:'Дашборд',proxies:'Прокси',events:'События',settings:'Настройки'};

function nav(p,el){
  document.querySelectorAll('.sec').forEach(s=>s.classList.remove('on'));
  document.querySelectorAll('.nitem').forEach(n=>n.classList.remove('on'));
  document.getElementById('sec-'+p).classList.add('on');
  document.getElementById('ptitle').textContent=TITLES[p]||p;
  if(el) el.classList.add('on');
  if(p==='proxies') loadProxies();
  if(p==='events')  loadEvents();
  if(p==='settings') loadSettings();
}

async function api(url,opts={}){
  const r=await fetch(url,{headers:{'Content-Type':'application/json'},...opts});
  if(!r.ok){const e=await r.json().catch(()=>({detail:r.statusText}));throw new Error(e.detail||r.statusText);}
  return r.json();
}

async function loadAll(){ await Promise.all([loadSys(),loadDash()]); }

async function loadSys(){
  try{
    const s=await api('/api/system');
    g('d-cpu').textContent=s.cpu+'%';
    g('d-ram').textContent=s.ram_used+' MB';
    g('d-dsk').textContent=s.disk_used+' GB';
    g('b-cpu').style.width=s.cpu+'%';
    g('b-ram').style.width=s.ram_pct+'%';
    g('b-dsk').style.width=s.disk_pct+'%';
    g('tb-up').textContent='⏱ '+s.uptime;
    g('tb-ip').textContent=s.server_ip;
  }catch(e){console.error(e);}
}

async function loadDash(){
  try{
    PROXIES=await api('/api/proxies');
    let run=0,cn=0,rows='';
    for(const p of PROXIES){
      if(p.status==='running')run++;
      cn+=p.connections||0;
      rows+=`<tr>
        <td><b>${x(p.name)}</b></td>
        <td><code style="color:var(--muted)">${p.port}</code></td>
        <td>${sb(p.status)}</td>
        <td>${p.connections||0}</td>
        <td><button class="btn btg xs" onclick="showQR('${p.id}','${x(p.name)}')">📱 QR</button></td>
      </tr>`;
    }
    g('dtbl').innerHTML=rows||nd(5);
    g('d-prx').textContent=run+'/'+PROXIES.length;
    g('d-cnn').textContent=cn;
    g('sb-run').textContent=run;
    g('sb-con').textContent=cn;
    g('nb').textContent=PROXIES.length;
  }catch(e){console.error(e);}
}

function setView(v){
  VIEW=v;
  g('view-card').style.display=v==='card'?'block':'none';
  g('view-table').style.display=v==='table'?'block':'none';
  g('vb-c').classList.toggle('on',v==='card');
  g('vb-t').classList.toggle('on',v==='table');
}

async function loadProxies(){
  try{PROXIES=await api('/api/proxies');renderCards();renderTable();}
  catch(e){notify('Ошибка: '+e.message,'err');}
}

function renderCards(){
  const el=g('pcards');
  if(!PROXIES.length){
    el.innerHTML='<div style="text-align:center;padding:48px;color:var(--muted)">Нет прокси.<br><br><button class="btn btp" onclick="openAdd()">Создать первый прокси</button></div>';
    return;
  }
  el.innerHTML=PROXIES.map(p=>{
    const run=p.status==='running';
    return `<div class="pcard">
      <div class="pchead">
        <div><div class="pcname">${x(p.name)}</div><div class="pcport">:${p.port} · ${p.fake_tls?'<span class="badge bb">fake-TLS</span>':'<span class="badge bd">raw</span>'}</div></div>
        ${sb(p.status)}
      </div>
      <div class="pcsec" title="Нажмите чтобы скопировать" onclick="navigator.clipboard.writeText('${p.secret}').then(()=>notify('📋 Секрет скопирован'))">${p.secret.slice(0,34)}…</div>
      <div class="pcstats">
        <div class="pcstat">Соединений: <span>${p.connections||0}</span></div>
        <div class="pcstat">Ротация: <span>${p.auto_rotate?'авто':'—'}</span></div>
      </div>
      <div class="pcact">
        ${run
          ?`<button class="btn btd xs" onclick="stopPx('${p.id}')">⏹ Стоп</button>`
          :`<button class="btn bts xs" onclick="startPx('${p.id}')">▶ Старт</button>`}
        <button class="btn btg xs" onclick="showQR('${p.id}','${x(p.name)}')">📱</button>
        <button class="btn btg xs" onclick="rotatePx('${p.id}')">🔄</button>
        <button class="btn btg xs" onclick="showLogs('${p.id}')">📄</button>
        <button class="btn btd xs" onclick="delPx('${p.id}','${x(p.name)}')">🗑</button>
      </div>
    </div>`;
  }).join('');
}

function renderTable(){
  const el=g('ptbl');
  if(!PROXIES.length){el.innerHTML=nd(7);return;}
  el.innerHTML=PROXIES.map(p=>{
    const run=p.status==='running';
    return `<tr>
      <td><b>${x(p.name)}</b></td>
      <td><code>${p.port}</code></td>
      <td>${p.fake_tls?'<span class="badge bb">fake-TLS</span>':'<span class="badge bd">raw</span>'}<div style="font-size:10px;color:var(--muted);margin-top:2px">${x(p.tls_domain||'')}</div></td>
      <td>${p.connections||0}</td>
      <td>${sb(p.status)}</td>
      <td>${p.auto_rotate?'<span class="badge bg">авто</span>':'<span class="badge bd">нет</span>'}</td>
      <td><div style="display:flex;gap:5px;flex-wrap:wrap">
        ${run
          ?`<button class="btn btd xs" onclick="stopPx('${p.id}')">⏹</button>`
          :`<button class="btn bts xs" onclick="startPx('${p.id}')">▶</button>`}
        <button class="btn btg xs" onclick="showQR('${p.id}','${x(p.name)}')">📱</button>
        <button class="btn btg xs" onclick="rotatePx('${p.id}')">🔄</button>
        <button class="btn btg xs" onclick="showLogs('${p.id}')">📄</button>
        <button class="btn btd xs" onclick="delPx('${p.id}','${x(p.name)}')">🗑</button>
      </div></td>
    </tr>`;
  }).join('');
}

function openAdd(){g('m-add').classList.add('on');}

async function addProxy(){
  const body={
    name:       g('a-n').value||'Прокси',
    port:       parseInt(g('a-p').value)||0,
    tls_domain: g('a-d').value||'www.google.com',
    secret:     g('a-s').value.trim(),
    fake_tls:   g('a-ftls').checked,
    auto_rotate:g('a-rot').checked,
  };
  try{
    const p=await api('/api/proxies',{method:'POST',body:JSON.stringify(body)});
    closeM('m-add');
    if(p.status==='error') notify('⚠️ Создан, но не запустился — смотрите логи','err');
    else notify('✅ Прокси создан и запущен');
    loadProxies();loadDash();
  }catch(e){notify('Ошибка: '+e.message,'err');}
}

async function startPx(id){
  try{await api('/api/proxies/'+id+'/start',{method:'POST'});notify('▶ Запущен');loadProxies();loadDash();}
  catch(e){notify('Ошибка: '+e.message,'err');}
}
async function stopPx(id){
  await api('/api/proxies/'+id+'/stop',{method:'POST'});notify('⏹ Остановлен');loadProxies();loadDash();
}
async function delPx(id,name){
  if(!confirm('Удалить «'+name+'»?'))return;
  await api('/api/proxies/'+id,{method:'DELETE'});notify('🗑 Удалён');loadProxies();loadDash();
}
async function rotatePx(id){
  if(!confirm('Сменить секрет? Активные подключения разорвутся.'))return;
  try{await api('/api/proxies/'+id+'/rotate',{method:'POST'});notify('🔄 Секрет обновлён');loadProxies();}
  catch(e){notify('Ошибка: '+e.message,'err');}
}

async function showQR(id,name){
  g('qr-nm').textContent=name;
  g('qr-box').innerHTML='<div style="color:var(--muted);padding:20px">Генерация…</div>';
  g('qr-lnk').textContent='';
  g('m-qr').classList.add('on');
  try{
    const r=await api('/api/proxies/'+id+'/qr');
    g('qr-lnk').textContent=r.link;
    g('qr-box').innerHTML=r.qr_svg
      ?r.qr_svg
      :'<div style="color:var(--muted);font-size:12px;padding:16px">Установите qrencode:<br><code>apt install qrencode</code></div>';
  }catch(e){g('qr-box').innerHTML='Ошибка';}
}
function copyLink(){
  navigator.clipboard.writeText(g('qr-lnk').textContent).then(()=>notify('📋 Скопировано'));
}

async function showLogs(id){
  g('logbox').textContent='Загрузка…';
  g('m-logs').classList.add('on');
  try{
    const r=await api('/api/proxies/'+id+'/logs');
    const el=g('logbox');
    el.textContent=r.lines.join('\n')||'Лог пуст';
    el.scrollTop=el.scrollHeight;
  }catch(e){g('logbox').textContent='Ошибка';}
}

const EVS={start:'bg',stop:'br',create:'bb',delete:'br',rotate:'by',error:'br',auth:'bd',system:'bd',watchdog:'by',settings:'bd'};
async function loadEvents(){
  try{
    const evs=await api('/api/events');
    const el=g('evlist');
    if(!evs.length){el.innerHTML='<p style="text-align:center;padding:28px;color:var(--muted)">Нет событий</p>';return;}
    el.innerHTML=evs.map(e=>{
      const cls=EVS[e.kind]||'bd';
      const dt=new Date(e.ts).toLocaleString('ru',{hour12:false});
      return `<div class="evitem">
        <span class="evkind badge ${cls}">${e.kind}</span>
        <div><div class="evmsg">${x(e.msg)}</div><div class="evts">${dt}</div></div>
      </div>`;
    }).join('');
  }catch(e){console.error(e);}
}

async function loadSettings(){
  try{
    const s=await api('/api/settings');
    g('s-tt').value='';
    g('s-tc').value=s.tg_chat_id||'';
    g('s-wl').value=(s.ip_whitelist||[]).join(', ');
    g('s-ip').value=s.server_ip||'';
  }catch(e){}
}
async function saveS(){
  const data={tg_token:g('s-tt').value,tg_chat_id:g('s-tc').value,ip_whitelist:g('s-wl').value,server_ip:g('s-ip').value};
  try{await api('/api/settings',{method:'POST',body:JSON.stringify(data)});notify('✅ Сохранено');}
  catch(e){notify('Ошибка: '+e.message,'err');}
}
async function testTg(){
  try{await api('/api/test_telegram',{method:'POST'});notify('📤 Тест отправлен');}
  catch(e){notify('Ошибка: '+e.message,'err');}
}
async function changePw(){
  const o=g('pw-o').value,n=g('pw-n').value,n2=g('pw-n2').value;
  if(n!==n2){notify('Пароли не совпадают','err');return;}
  try{
    await api('/api/settings/change_password',{method:'POST',body:JSON.stringify({old:o,new:n})});
    notify('✅ Пароль изменён');
    g('pw-o').value=g('pw-n').value=g('pw-n2').value='';
  }catch(e){notify('Ошибка: '+e.message,'err');}
}

function closeM(id){document.getElementById(id).classList.remove('on');}
function g(id){return document.getElementById(id);}
function x(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function nd(c){return `<tr><td colspan="${c}" style="text-align:center;padding:28px;color:var(--muted)">Нет данных</td></tr>`;}
function sb(s){
  return s==='running'
    ?'<span class="badge bg"><span class="dot"></span> Активен</span>'
    :'<span class="badge br"><span class="dot"></span> Стоп</span>';
}
function notify(msg,t='ok'){
  const el=document.createElement('div');
  el.className='notif '+(t==='err'?'n-err':'n-ok');
  el.textContent=msg;
  document.body.appendChild(el);
  setTimeout(()=>{el.style.opacity='0';setTimeout(()=>el.remove(),300);},2800);
}

document.querySelectorAll('.overlay').forEach(o=>{
  o.addEventListener('click',e=>{if(e.target===o)o.classList.remove('on');});
});

loadAll();
setInterval(loadAll,10000);
</script>
</body>
</html>'''

with open('/opt/mtg-panel/index.html','w') as f:
    f.write(html)
print('OK')
PYEOF
ok "index.html создан"

# ── systemd ────────────────────────────────────────
hdr "Systemd служба"
cat > /etc/systemd/system/mtg-panel.service << SVCEOF
[Unit]
Description=MTG Proxy Panel v3.1
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV}/bin/uvicorn app:app --host 0.0.0.0 --port ${PANEL_PORT} --workers 1
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable mtg-panel --quiet
systemctl restart mtg-panel
sleep 3
if systemctl is-active --quiet mtg-panel; then
  ok "Служба запущена"
else
  warn "Служба не запустилась:"
  journalctl -u mtg-panel -n 15 --no-pager
fi

# ── Firewall ───────────────────────────────────────
hdr "Брандмауэр"
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
  ufw allow "${PANEL_PORT}/tcp" > /dev/null 2>&1 && ok "UFW: порт ${PANEL_PORT} открыт"
elif command -v iptables &>/dev/null; then
  iptables -I INPUT -p tcp --dport "${PANEL_PORT}" -j ACCEPT 2>/dev/null \
    && ok "iptables: порт ${PANEL_PORT} открыт"
else
  warn "Брандмауэр не найден — откройте порт ${PANEL_PORT} вручную"
fi

# ── Done ───────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}   УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО ✓${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${CYAN}Адрес панели:${RESET}  ${BOLD}http://${SERVER_IP}:${PANEL_PORT}${RESET}"
echo -e "  ${CYAN}Логин:${RESET}         ${BOLD}${PANEL_USER}${RESET}"
echo -e "  ${CYAN}Пароль:${RESET}        ${BOLD}${PANEL_PASS}${RESET}"
echo ""
echo -e "  ${CYAN}Что нового в v3.1:${RESET}"
echo -e "   ★ Исправлен запуск MTG (правильный порядок аргументов)"
echo -e "   ★ При сбое запуска — подробная диагностика в логах"
echo -e "   ★ Дизайн: тёмная тема GitHub-стиль"
echo -e "   ★ Два режима просмотра прокси: карточки / таблица"
echo -e "   ★ Клик по секрету — копирование в буфер"
echo -e "   ★ Неограниченное число прокси"
echo -e "   ★ Fake-TLS с настраиваемым доменом"
echo -e "   ★ QR-коды · Авто-ротация · Watchdog"
echo -e "   ★ Telegram алерты · IP Whitelist"
echo -e "   ★ История событий · Бэкап конфигурации"
echo ""
echo -e "  ${YELLOW}Управление:${RESET}"
echo -e "   systemctl status mtg-panel"
echo -e "   journalctl -u mtg-panel -f"
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
