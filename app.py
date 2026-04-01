#!/usr/bin/env python3
"""
MTG Proxy Web Panel - Backend API
FastAPI application for managing mtg MTProto proxy server
"""

import os
import re
import subprocess
import socket
import asyncio
import httpx
from datetime import datetime, timedelta
from typing import Optional

import psutil
from fastapi import FastAPI, HTTPException, Depends, status
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from jose import JWTError, jwt
from passlib.context import CryptContext
from pydantic import BaseModel

# ─── Configuration ────────────────────────────────────────────────────────────

SECRET_KEY = "mtg-panel-super-secret-key-change-in-production-2024"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 480  # 8 hours

ADMIN_USERNAME = "Fastg"
ADMIN_PASSWORD = "Mjmzxcmjm123"

MTG_SERVICE_FILE = "/etc/systemd/system/mtg.service"
MTG_BINARY = "/usr/local/bin/mtg"

# ─── FastAPI App ──────────────────────────────────────────────────────────────

app = FastAPI(title="MTG Panel", docs_url=None, redoc_url=None)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─── Auth Setup ───────────────────────────────────────────────────────────────

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/token")

hashed_admin_password = pwd_context.hash(ADMIN_PASSWORD)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def create_access_token(data: dict, expires_delta: Optional[timedelta] = None):
    to_encode = data.copy()
    expire = datetime.utcnow() + (expires_delta or timedelta(minutes=15))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)


async def get_current_user(token: str = Depends(oauth2_scheme)):
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username: str = payload.get("sub")
        if username is None or username != ADMIN_USERNAME:
            raise credentials_exception
    except JWTError:
        raise credentials_exception
    return username


# ─── Pydantic Models ─────────────────────────────────────────────────────────

class ProxyConfig(BaseModel):
    port: int
    fake_tls_domain: str
    secret: Optional[str] = None


class Token(BaseModel):
    access_token: str
    token_type: str


# ─── Helper Functions ─────────────────────────────────────────────────────────

def run_cmd(cmd: list, timeout: int = 30) -> tuple[int, str, str]:
    """Run a shell command and return (returncode, stdout, stderr)"""
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)


def is_port_available(port: int) -> bool:
    """Check if a port is available (not in use by another process)"""
    # Get current mtg port to exclude it
    current_port = get_current_config().get("port", 0)
    
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(1)
        result = s.connect_ex(("127.0.0.1", port))
        if result == 0:
            # Port is in use — check if it's mtg itself
            if port == current_port:
                return True  # It's our own service, OK
            return False
        return True


def get_server_ip() -> str:
    """Get the public IP address of the server"""
    try:
        result = subprocess.run(
            ["curl", "-s", "--max-time", "5", "https://api.ipify.org"],
            capture_output=True, text=True, timeout=10
        )
        ip = result.stdout.strip()
        if re.match(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$", ip):
            return ip
    except Exception:
        pass
    # Fallback: get local IP
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "unknown"


def get_current_config() -> dict:
    """Parse current mtg service file for port and domain"""
    config = {"port": 443, "fake_tls_domain": "itunes.apple.com", "secret": ""}
    
    if not os.path.exists(MTG_SERVICE_FILE):
        return config
    
    try:
        with open(MTG_SERVICE_FILE, "r") as f:
            content = f.read()
        
        # Extract ExecStart line
        exec_match = re.search(r"ExecStart=(.+)", content)
        if exec_match:
            exec_line = exec_match.group(1)
            
            # Extract port (last number before end or next flag)
            port_match = re.search(r":(\d+)(?:\s|$)", exec_line)
            if port_match:
                config["port"] = int(port_match.group(1))
            
            # Extract fake-tls domain
            tls_match = re.search(r"--fake-tls[=\s]+([^\s]+)", exec_line)
            if tls_match:
                config["fake_tls_domain"] = tls_match.group(1)
            
            # Extract secret (after 'run' command)
            secret_match = re.search(r"run\s+([a-fA-F0-9]+)", exec_line)
            if secret_match:
                config["secret"] = secret_match.group(1)
    
    except Exception:
        pass
    
    return config


def generate_secret(fake_tls_domain: str) -> str:
    """Generate a new mtg secret"""
    code, stdout, stderr = run_cmd([MTG_BINARY, "generate-secret", "--hex", fake_tls_domain])
    if code == 0 and stdout.strip():
        return stdout.strip()
    
    # Fallback: try without --hex flag
    code, stdout, stderr = run_cmd([MTG_BINARY, "generate-secret", fake_tls_domain])
    if code == 0 and stdout.strip():
        return stdout.strip()
    
    raise HTTPException(status_code=500, detail=f"Failed to generate secret: {stderr}")


def write_service_file(port: int, fake_tls_domain: str, secret: str):
    """Write the systemd service file for mtg"""
    service_content = f"""[Unit]
Description=MTProto Proxy Server (mtg)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart={MTG_BINARY} run --bind 0.0.0.0:{port} --fake-tls {fake_tls_domain} {secret}
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
        with open(MTG_SERVICE_FILE, "w") as f:
            f.write(service_content)
    except PermissionError:
        raise HTTPException(status_code=500, detail="Permission denied writing service file. Run panel as root.")


# ─── API Routes ───────────────────────────────────────────────────────────────

@app.post("/api/auth/token", response_model=Token)
async def login(form_data: OAuth2PasswordRequestForm = Depends()):
    if form_data.username != ADMIN_USERNAME or not verify_password(form_data.password, hashed_admin_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    access_token = create_access_token(
        data={"sub": form_data.username},
        expires_delta=timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    )
    return {"access_token": access_token, "token_type": "bearer"}


@app.get("/api/status")
async def get_status(current_user: str = Depends(get_current_user)):
    """Get service status, system metrics, and current config"""
    # Service status
    code, stdout, _ = run_cmd(["systemctl", "is-active", "mtg"])
    is_active = stdout.strip() == "active"
    
    # System metrics
    cpu_percent = psutil.cpu_percent(interval=0.5)
    ram = psutil.virtual_memory()
    
    # Current config
    config = get_current_config()
    
    # Server IP
    server_ip = get_server_ip()
    
    # Build tg link
    secret = config.get("secret", "")
    port = config.get("port", 443)
    tg_link = f"tg://proxy?server={server_ip}&port={port}&secret={secret}" if secret else ""
    
    return {
        "service_active": is_active,
        "service_status": stdout.strip() if stdout.strip() else "inactive",
        "cpu_percent": round(cpu_percent, 1),
        "ram_percent": round(ram.percent, 1),
        "ram_used_gb": round(ram.used / 1024**3, 2),
        "ram_total_gb": round(ram.total / 1024**3, 2),
        "config": config,
        "server_ip": server_ip,
        "tg_link": tg_link,
    }


@app.get("/api/logs")
async def get_logs(lines: int = 50, current_user: str = Depends(get_current_user)):
    """Get last N lines from mtg journal logs"""
    code, stdout, stderr = run_cmd(
        ["journalctl", "-u", "mtg", f"-n{lines}", "--no-pager", "--output=short-iso"]
    )
    
    if code != 0 and not stdout:
        # Try alternative log fetching
        code, stdout, stderr = run_cmd(["journalctl", "-u", "mtg", f"-n{lines}", "--no-pager"])
    
    log_lines = stdout.strip().split("\n") if stdout.strip() else ["No logs available yet"]
    return {"logs": log_lines, "count": len(log_lines)}


@app.post("/api/config/apply")
async def apply_config(config: ProxyConfig, current_user: str = Depends(get_current_user)):
    """Apply new configuration and restart the service"""
    
    # Validate port range
    if not (1 <= config.port <= 65535):
        raise HTTPException(status_code=400, detail="Port must be between 1 and 65535")
    
    # Check if port is available
    if not is_port_available(config.port):
        raise HTTPException(
            status_code=409,
            detail=f"Port {config.port} is already in use by another process"
        )
    
    # Generate new secret if not provided
    if not config.secret:
        try:
            secret = generate_secret(config.fake_tls_domain)
        except HTTPException:
            # If secret generation fails, try to keep existing
            current = get_current_config()
            secret = current.get("secret", "")
            if not secret:
                raise
    else:
        secret = config.secret
    
    # Write service file
    write_service_file(config.port, config.fake_tls_domain, secret)
    
    # Reload systemd daemon
    code, _, err = run_cmd(["systemctl", "daemon-reload"])
    if code != 0:
        raise HTTPException(status_code=500, detail=f"daemon-reload failed: {err}")
    
    # Restart the service
    code, _, err = run_cmd(["systemctl", "restart", "mtg"], timeout=15)
    if code != 0:
        raise HTTPException(status_code=500, detail=f"Service restart failed: {err}")
    
    # Get server IP and build tg link
    server_ip = get_server_ip()
    tg_link = f"tg://proxy?server={server_ip}&port={config.port}&secret={secret}"
    
    return {
        "success": True,
        "message": "Configuration applied and service restarted",
        "secret": secret,
        "tg_link": tg_link,
        "server_ip": server_ip,
    }


@app.post("/api/service/{action}")
async def service_action(action: str, current_user: str = Depends(get_current_user)):
    """Start, stop, or restart the mtg service"""
    valid_actions = ["start", "stop", "restart"]
    if action not in valid_actions:
        raise HTTPException(status_code=400, detail=f"Invalid action. Use: {valid_actions}")
    
    code, stdout, stderr = run_cmd(["systemctl", action, "mtg"], timeout=15)
    
    if code != 0:
        raise HTTPException(status_code=500, detail=f"Action '{action}' failed: {stderr}")
    
    return {"success": True, "message": f"Service {action} executed successfully"}


@app.post("/api/generate-secret")
async def api_generate_secret(
    domain: str,
    current_user: str = Depends(get_current_user)
):
    """Generate a new MTG secret for given domain"""
    secret = generate_secret(domain)
    return {"secret": secret, "domain": domain}


@app.get("/api/check-port/{port}")
async def check_port(port: int, current_user: str = Depends(get_current_user)):
    """Check if a port is available"""
    if not (1 <= port <= 65535):
        return {"available": False, "reason": "Invalid port range"}
    
    available = is_port_available(port)
    return {
        "port": port,
        "available": available,
        "reason": "Port is free" if available else "Port is in use by another process"
    }


@app.get("/api/update/check")
async def check_update(current_user: str = Depends(get_current_user)):
    """Check latest mtg version on GitHub"""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                "https://api.github.com/repos/9seconds/mtg/releases/latest",
                headers={"Accept": "application/vnd.github.v3+json"}
            )
            data = resp.json()
            return {
                "latest_version": data.get("tag_name", "unknown"),
                "release_url": data.get("html_url", ""),
                "published_at": data.get("published_at", ""),
            }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to check updates: {str(e)}")


@app.post("/api/update/install")
async def install_update(current_user: str = Depends(get_current_user)):
    """Download and install the latest mtg binary"""
    import platform
    import tempfile
    import stat
    
    # Detect architecture
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        arch = "amd64"
    elif machine in ("aarch64", "arm64"):
        arch = "arm64"
    elif "arm" in machine:
        arch = "arm"
    else:
        raise HTTPException(status_code=400, detail=f"Unsupported architecture: {machine}")
    
    # Get latest release info
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(
                "https://api.github.com/repos/9seconds/mtg/releases/latest",
                headers={"Accept": "application/vnd.github.v3+json"}
            )
            data = resp.json()
            tag = data.get("tag_name", "")
            
            # Find the correct asset
            assets = data.get("assets", [])
            download_url = None
            for asset in assets:
                name = asset.get("name", "").lower()
                if "linux" in name and arch in name and not name.endswith(".sha256"):
                    download_url = asset.get("browser_download_url")
                    break
            
            if not download_url:
                raise HTTPException(status_code=404, detail="Could not find binary for your architecture")
            
            # Download the binary
            with tempfile.NamedTemporaryFile(delete=False, suffix=".tmp") as tmp:
                tmp_path = tmp.name
            
            async with httpx.AsyncClient(timeout=60, follow_redirects=True) as client:
                dl_resp = await client.get(download_url)
                with open(tmp_path, "wb") as f:
                    f.write(dl_resp.content)
            
            # Stop service, replace binary, restart
            run_cmd(["systemctl", "stop", "mtg"])
            
            os.chmod(tmp_path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
            os.replace(tmp_path, MTG_BINARY)
            
            run_cmd(["systemctl", "start", "mtg"])
            
            return {"success": True, "version": tag, "message": f"Updated to {tag} successfully"}
    
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Update failed: {str(e)}")


# ─── Serve Frontend ───────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
@app.get("/{path:path}", response_class=HTMLResponse)
async def serve_frontend(path: str = ""):
    """Serve the single-page frontend"""
    html_path = os.path.join(os.path.dirname(__file__), "index.html")
    if os.path.exists(html_path):
        with open(html_path, "r") as f:
            return HTMLResponse(content=f.read())
    return HTMLResponse(content="<h1>Frontend not found</h1>", status_code=404)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8888, log_level="info")
