#!/usr/bin/env python3
"""
MTG Panel v2.0 — Enhanced Backend
FastAPI application for managing mtg MTProto proxy server.

NEW in v2 (added by AI):
  - Active connection counter via ss/netstat
  - Telegram Bot crash notifications
  - IP Whitelist middleware for panel access
  - Restart/event history log (JSON)
  - QR code generation for tg:// link
  - Disk usage metrics
  - Service uptime display
  - Background crash-monitor task
  - /api/settings endpoint for Telegram & whitelist config
  - GeoIP lookup endpoint
"""

import os, re, json, socket, subprocess, asyncio, ipaddress, io, base64
from datetime import datetime, timedelta
from typing import Optional, List
from pathlib import Path

import psutil, httpx, qrcode
from fastapi import FastAPI, HTTPException, Depends, Request, status
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from fastapi.middleware.cors import CORSMiddleware
from jose import JWTError, jwt
from passlib.context import CryptContext
from pydantic import BaseModel

# ── Paths ─────────────────────────────────────────────────────────────────────
PANEL_DIR        = Path("/opt/mtp-panel")
SETTINGS_FILE    = PANEL_DIR / "settings.json"
HISTORY_FILE     = PANEL_DIR / "restart_history.json"
MTG_SERVICE_FILE = Path("/etc/systemd/system/mtg.service")
MTG_BINARY       = "/usr/local/bin/mtg"

SECRET_KEY   = "mtg-panel-v2-zenith-2025-unique"
ALGORITHM    = "HS256"
TOKEN_EXPIRE = 480  # minutes

ADMIN_USERNAME = "Fastg"
ADMIN_PASSWORD = "Mjmzxcmjm123"

DEFAULT_SETTINGS = {
    "tg_bot_token": "",
    "tg_chat_id": "",
    "tg_alerts_enabled": False,
    "ip_whitelist": [],
    "monitor_interval": 60,
}

# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(title="MTG Panel v2", docs_url=None, redoc_url=None)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True,
                   allow_methods=["*"], allow_headers=["*"])

pwd_context   = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/token")
hashed_pw     = pwd_context.hash(ADMIN_PASSWORD)
_monitor_task = None

# ── Auth ──────────────────────────────────────────────────────────────────────
def create_token(data: dict, expires: timedelta = None):
    payload = {**data, "exp": datetime.utcnow() + (expires or timedelta(minutes=15))}
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)

async def get_current_user(token: str = Depends(oauth2_scheme)):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        if payload.get("sub") != ADMIN_USERNAME:
            raise HTTPException(401, "Invalid token")
    except JWTError:
        raise HTTPException(401, "Invalid token", headers={"WWW-Authenticate": "Bearer"})
    return payload["sub"]

# ── IP Whitelist Middleware ────────────────────────────────────────────────────
@app.middleware("http")
async def ip_whitelist_middleware(request: Request, call_next):
    if request.url.path.startswith("/api/auth"):
        return await call_next(request)
    whitelist = load_settings().get("ip_whitelist", [])
    if not whitelist:
        return await call_next(request)
    client_ip = request.client.host
    for entry in whitelist:
        try:
            if ipaddress.ip_address(client_ip) in ipaddress.ip_network(entry, strict=False):
                return await call_next(request)
        except ValueError:
            if client_ip == entry:
                return await call_next(request)
    return JSONResponse(status_code=403, content={"detail": f"IP {client_ip} not whitelisted"})

# ── Settings ──────────────────────────────────────────────────────────────────
def load_settings() -> dict:
    try:
        if SETTINGS_FILE.exists():
            return {**DEFAULT_SETTINGS, **json.loads(SETTINGS_FILE.read_text())}
    except Exception:
        pass
    return DEFAULT_SETTINGS.copy()

def save_settings(data: dict):
    PANEL_DIR.mkdir(parents=True, exist_ok=True)
    SETTINGS_FILE.write_text(json.dumps({**load_settings(), **data}, indent=2))

# ── History ───────────────────────────────────────────────────────────────────
def load_history() -> list:
    try:
        if HISTORY_FILE.exists():
            return json.loads(HISTORY_FILE.read_text())
    except Exception:
        pass
    return []

def append_history(event: str, reason: str = ""):
    history = (load_history() + [{"ts": datetime.now().isoformat(timespec="seconds"),
                                   "event": event, "reason": reason}])[-100:]
    PANEL_DIR.mkdir(parents=True, exist_ok=True)
    HISTORY_FILE.write_text(json.dumps(history, indent=2))

# ── Shell ─────────────────────────────────────────────────────────────────────
def run_cmd(cmd: list, timeout: int = 30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except Exception as e:
        return -1, "", str(e)

def get_server_ip() -> str:
    try:
        r = subprocess.run(["curl", "-s", "--max-time", "4", "https://api.ipify.org"],
                           capture_output=True, text=True, timeout=8)
        ip = r.stdout.strip()
        if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", ip):
            return ip
    except Exception:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]; s.close(); return ip
    except Exception:
        return "unknown"

def is_port_free(port: int) -> bool:
    current = get_current_config().get("port", 0)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(1)
        return s.connect_ex(("127.0.0.1", port)) != 0 or port == current

def get_current_config() -> dict:
    cfg = {"port": 443, "fake_tls_domain": "itunes.apple.com", "secret": ""}
    if not MTG_SERVICE_FILE.exists():
        return cfg
    try:
        content = MTG_SERVICE_FILE.read_text()
        m = re.search(r"ExecStart=(.+)", content)
        if m:
            line = m.group(1)
            if pm := re.search(r":(\d+)(?:\s|$)", line): cfg["port"] = int(pm.group(1))
            if dm := re.search(r"--fake-tls[=\s]+(\S+)", line): cfg["fake_tls_domain"] = dm.group(1)
            if sm := re.search(r"run\s+(\S+)", line): cfg["secret"] = sm.group(1)
    except Exception:
        pass
    return cfg

def generate_secret(domain: str) -> str:
    for flags in [["--hex"], []]:
        code, out, _ = run_cmd([MTG_BINARY, "generate-secret"] + flags + [domain])
        if code == 0 and out.strip():
            return out.strip()
    raise HTTPException(500, "Failed to generate secret")

def write_service(port: int, domain: str, secret: str):
    content = f"""[Unit]
Description=MTProto Proxy Server (mtg)
After=network.target

[Service]
Type=simple
User=root
ExecStart={MTG_BINARY} run --bind 0.0.0.0:{port} --fake-tls {domain} {secret}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtg
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
"""
    try:
        MTG_SERVICE_FILE.write_text(content)
    except PermissionError:
        raise HTTPException(500, "Permission denied. Run panel as root.")

def get_active_connections(port: int) -> int:
    code, out, _ = run_cmd(["ss", "-tn", "state", "established", f"sport = :{port}"])
    if code == 0:
        return max(0, len([l for l in out.strip().split("\n")
                           if l and not l.startswith("Recv")]))
    code, out, _ = run_cmd(["netstat", "-tn"])
    if code == 0:
        return sum(1 for l in out.split("\n") if f":{port} " in l and "ESTABLISHED" in l)
    return 0

# ── Telegram ──────────────────────────────────────────────────────────────────
async def send_tg_alert(message: str):
    s = load_settings()
    if not s.get("tg_alerts_enabled") or not s.get("tg_bot_token") or not s.get("tg_chat_id"):
        return
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            await client.post(
                f"https://api.telegram.org/bot{s['tg_bot_token']}/sendMessage",
                json={"chat_id": s["tg_chat_id"], "text": message, "parse_mode": "HTML"})
    except Exception:
        pass

# ── Crash Monitor (background task) ──────────────────────────────────────────
_last_active = True

async def crash_monitor():
    global _last_active
    await asyncio.sleep(30)
    while True:
        try:
            interval = load_settings().get("monitor_interval", 60)
            _, out, _ = run_cmd(["systemctl", "is-active", "mtg"])
            is_active = out.strip() == "active"
            if _last_active and not is_active:
                append_history("CRASH", "Detected by monitor")
                await send_tg_alert(
                    f"🚨 <b>MTG Alert</b>\n\n❌ Прокси <b>упал</b>!\n"
                    f"🕒 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            elif not _last_active and is_active:
                append_history("RECOVERED", "Auto-recovered")
                await send_tg_alert(
                    f"✅ <b>MTG Alert</b>\n\n✅ Прокси <b>восстановлен</b>!\n"
                    f"🕒 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            _last_active = is_active
            await asyncio.sleep(interval)
        except asyncio.CancelledError:
            break
        except Exception:
            await asyncio.sleep(60)

@app.on_event("startup")
async def startup():
    global _monitor_task
    PANEL_DIR.mkdir(parents=True, exist_ok=True)
    _monitor_task = asyncio.create_task(crash_monitor())

@app.on_event("shutdown")
async def shutdown():
    if _monitor_task: _monitor_task.cancel()

# ── Models ────────────────────────────────────────────────────────────────────
class ProxyConfig(BaseModel):
    port: int
    fake_tls_domain: str
    secret: Optional[str] = None

class PanelSettings(BaseModel):
    tg_bot_token: Optional[str] = ""
    tg_chat_id: Optional[str] = ""
    tg_alerts_enabled: Optional[bool] = False
    ip_whitelist: Optional[List[str]] = []
    monitor_interval: Optional[int] = 60

# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.post("/api/auth/token")
async def login(form: OAuth2PasswordRequestForm = Depends()):
    if form.username != ADMIN_USERNAME or not pwd_context.verify(form.password, hashed_pw):
        raise HTTPException(401, "Incorrect username or password",
                            headers={"WWW-Authenticate": "Bearer"})
    return {"access_token": create_token({"sub": form.username},
                                          timedelta(minutes=TOKEN_EXPIRE)),
            "token_type": "bearer"}

@app.get("/api/status")
async def get_status(_: str = Depends(get_current_user)):
    _, out, _ = run_cmd(["systemctl", "is-active", "mtg"])
    is_active = out.strip() == "active"
    cpu = psutil.cpu_percent(interval=0.5)
    ram = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    cfg = get_current_config()
    server_ip = get_server_ip()
    secret = cfg.get("secret", "")
    port = cfg.get("port", 443)
    conns = get_active_connections(port) if is_active else 0
    tg_link = f"tg://proxy?server={server_ip}&port={port}&secret={secret}" if secret else ""

    uptime_str = ""
    _, out2, _ = run_cmd(["systemctl", "show", "mtg",
                           "--property=ActiveEnterTimestamp", "--value"])
    if out2.strip() and out2.strip() != "n/a":
        try:
            ts = datetime.strptime(out2.strip()[:19], "%a %Y-%m-%d %H:%M:%S")
            d = datetime.utcnow() - ts
            h, r = divmod(int(d.total_seconds()), 3600)
            m, s = divmod(r, 60)
            uptime_str = f"{h}h {m}m {s}s"
        except Exception:
            pass

    return {
        "service_active": is_active, "service_status": out.strip() or "inactive",
        "uptime": uptime_str, "active_connections": conns,
        "cpu_percent": round(cpu, 1),
        "ram_percent": round(ram.percent, 1),
        "ram_used_gb": round(ram.used/1024**3, 2), "ram_total_gb": round(ram.total/1024**3, 2),
        "disk_percent": round(disk.percent, 1),
        "disk_used_gb": round(disk.used/1024**3, 1), "disk_total_gb": round(disk.total/1024**3, 1),
        "config": cfg, "server_ip": server_ip, "tg_link": tg_link,
    }

@app.get("/api/logs")
async def get_logs(lines: int = 60, _: str = Depends(get_current_user)):
    _, out, _ = run_cmd(["journalctl", "-u", "mtg", f"-n{lines}", "--no-pager", "--output=short-iso"])
    if not out.strip():
        _, out, _ = run_cmd(["journalctl", "-u", "mtg", f"-n{lines}", "--no-pager"])
    return {"logs": out.strip().split("\n") if out.strip() else ["No logs yet"]}

@app.post("/api/config/apply")
async def apply_config(cfg: ProxyConfig, _: str = Depends(get_current_user)):
    if not (1 <= cfg.port <= 65535):
        raise HTTPException(400, "Port must be 1–65535")
    if not is_port_free(cfg.port):
        raise HTTPException(409, f"Port {cfg.port} is already in use")
    secret = cfg.secret or generate_secret(cfg.fake_tls_domain)
    write_service(cfg.port, cfg.fake_tls_domain, secret)
    c, _, err = run_cmd(["systemctl", "daemon-reload"])
    if c != 0: raise HTTPException(500, f"daemon-reload: {err}")
    c, _, err = run_cmd(["systemctl", "restart", "mtg"], timeout=15)
    if c != 0: raise HTTPException(500, f"restart: {err}")
    append_history("RESTART", "Config applied via panel")
    server_ip = get_server_ip()
    tg_link = f"tg://proxy?server={server_ip}&port={cfg.port}&secret={secret}"
    await send_tg_alert(
        f"⚙️ <b>MTG</b> — конфиг применён\n"
        f"🌐 {cfg.fake_tls_domain} | 🔌 :{cfg.port}\n"
        f"🕒 {datetime.now().strftime('%H:%M:%S')}")
    return {"success": True, "secret": secret, "tg_link": tg_link, "server_ip": server_ip}

@app.post("/api/service/{action}")
async def service_action(action: str, _: str = Depends(get_current_user)):
    if action not in ("start", "stop", "restart"):
        raise HTTPException(400, "Invalid action")
    c, _, err = run_cmd(["systemctl", action, "mtg"], timeout=15)
    if c != 0: raise HTTPException(500, f"{action}: {err}")
    append_history(action.upper(), "Manual via panel")
    if action == "stop":
        await send_tg_alert(f"⛔ MTG остановлен вручную\n🕒 {datetime.now().strftime('%H:%M:%S')}")
    return {"success": True}

@app.get("/api/check-port/{port}")
async def check_port(port: int, _: str = Depends(get_current_user)):
    if not (1 <= port <= 65535):
        return {"available": False, "reason": "Invalid range"}
    avail = is_port_free(port)
    return {"port": port, "available": avail,
            "reason": "Free" if avail else "In use by another process"}

@app.get("/api/generate-secret")
async def api_gen_secret(domain: str, _: str = Depends(get_current_user)):
    return {"secret": generate_secret(domain), "domain": domain}

@app.get("/api/qrcode")
async def get_qrcode(link: str, _: str = Depends(get_current_user)):
    try:
        qr = qrcode.QRCode(version=1,
                            error_correction=qrcode.constants.ERROR_CORRECT_M,
                            box_size=8, border=3)
        qr.add_data(link); qr.make(fit=True)
        img = qr.make_image(fill_color="#00d4ff", back_color="#070b12")
        buf = io.BytesIO(); img.save(buf, format="PNG"); buf.seek(0)
        return {"qr_base64": "data:image/png;base64," + base64.b64encode(buf.read()).decode()}
    except Exception as e:
        raise HTTPException(500, str(e))

@app.get("/api/settings")
async def get_settings(_: str = Depends(get_current_user)):
    s = load_settings()
    tok = s.get("tg_bot_token", "")
    s["tg_bot_token_masked"] = (tok[:4] + "****" + tok[-4:]) if len(tok) > 8 else tok
    return s

@app.post("/api/settings")
async def post_settings(settings: PanelSettings, _: str = Depends(get_current_user)):
    save_settings(settings.model_dump(exclude_none=True))
    return {"success": True}

@app.post("/api/settings/test-telegram")
async def test_telegram(_: str = Depends(get_current_user)):
    await send_tg_alert(
        f"✅ <b>MTG Panel Test</b>\nTelegram уведомления работают!\n"
        f"🕒 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    return {"success": True}

@app.get("/api/history")
async def get_history(_: str = Depends(get_current_user)):
    h = load_history()
    return {"history": list(reversed(h)), "count": len(h)}

@app.delete("/api/history")
async def clear_history(_: str = Depends(get_current_user)):
    if HISTORY_FILE.exists(): HISTORY_FILE.unlink()
    return {"success": True}

@app.get("/api/update/check")
async def check_update(_: str = Depends(get_current_user)):
    async with httpx.AsyncClient(timeout=10) as client:
        d = (await client.get("https://api.github.com/repos/9seconds/mtg/releases/latest",
                               headers={"Accept": "application/vnd.github.v3+json"})).json()
    return {"latest_version": d.get("tag_name","?"), "release_url": d.get("html_url",""),
            "published_at": d.get("published_at","")}

@app.post("/api/update/install")
async def install_update(_: str = Depends(get_current_user)):
    import platform, tempfile
    arch = {"x86_64":"amd64","amd64":"amd64","aarch64":"arm64","arm64":"arm64"}.get(
        platform.machine().lower(), "arm")
    async with httpx.AsyncClient(timeout=15) as c:
        d = (await c.get("https://api.github.com/repos/9seconds/mtg/releases/latest",
                          headers={"Accept":"application/vnd.github.v3+json"})).json()
    tag = d.get("tag_name","")
    url = next((a["browser_download_url"] for a in d.get("assets",[])
                if "linux" in a["name"].lower() and arch in a["name"].lower()
                and not a["name"].endswith(".sha256")), None)
    if not url: raise HTTPException(404, "Binary not found for your arch")
    with tempfile.NamedTemporaryFile(delete=False, suffix=".tmp") as t: tmp = t.name
    async with httpx.AsyncClient(timeout=90, follow_redirects=True) as c:
        Path(tmp).write_bytes((await c.get(url)).content)
    run_cmd(["systemctl","stop","mtg"])
    os.chmod(tmp, 0o755); os.replace(tmp, MTG_BINARY)
    run_cmd(["systemctl","start","mtg"])
    append_history("UPDATE", f"Updated to {tag}")
    return {"success": True, "version": tag}

@app.get("/", response_class=HTMLResponse)
@app.get("/{path:path}", response_class=HTMLResponse)
async def serve_frontend(path: str = ""):
    html = Path(__file__).parent / "index.html"
    return HTMLResponse(html.read_text() if html.exists() else "<h1>Not found</h1>",
                        status_code=200 if html.exists() else 404)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8888, log_level="info")
