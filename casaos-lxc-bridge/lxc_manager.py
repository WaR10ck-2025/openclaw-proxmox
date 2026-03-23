"""
lxc_manager.py — LXC-Lifecycle-Management für CasaOS App-Store Apps

Koordiniert:
  1. LXC-Clone aus Template (Proxmox)
  2. Docker-Compose-Deployment im LXC
  3. Status-Tracking via SQLite (apps.db)
"""
from __future__ import annotations
import os
import time
import sqlite3
import textwrap
from dataclasses import dataclass
from proxmox_client import ProxmoxClient
from app_resolver import AppMeta

DB_PATH = os.getenv("BRIDGE_DB_PATH", "/data/apps.db")
DATA_DIR = os.getenv("CASAOS_DATA_DIR", "/DATA/AppData")


@dataclass
class AppRecord:
    app_id: str
    lxc_id: int
    ip: str
    hostname: str
    port: int
    status: str   # installing | running | stopped | error


def _get_db() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH) if os.path.dirname(DB_PATH) else ".", exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row

    # --- apps-Tabelle (original) ---
    conn.execute("""
        CREATE TABLE IF NOT EXISTS apps (
            app_id   TEXT PRIMARY KEY,
            lxc_id   INTEGER,
            ip       TEXT,
            hostname TEXT,
            port     INTEGER,
            status   TEXT
        )
    """)

    # --- users-Tabelle (Multi-Tenant) ---
    conn.execute("""
        CREATE TABLE IF NOT EXISTS users (
            user_id           INTEGER PRIMARY KEY AUTOINCREMENT,
            username          TEXT UNIQUE NOT NULL,
            api_key           TEXT UNIQUE NOT NULL,
            lxc_range_start   INTEGER NOT NULL,
            lxc_range_end     INTEGER NOT NULL,
            bridge            TEXT NOT NULL,
            subnet            TEXT NOT NULL,
            gateway           TEXT NOT NULL,
            casaos_lxc_id     INTEGER,
            casaos_url        TEXT,
            casaos_token      TEXT,
            zfs_dataset       TEXT,
            zfs_quota         TEXT DEFAULT '100G',
            smb_password      TEXT,
            tailscale_auth_key TEXT,
            headscale_namespace TEXT,
            status            TEXT DEFAULT 'provisioning',
            provisioning_step TEXT DEFAULT ''
        )
    """)

    # --- Migration: user_id zu apps hinzufügen (idempotent) ---
    cols = {row[1] for row in conn.execute("PRAGMA table_info(apps)").fetchall()}
    if "user_id" not in cols:
        conn.execute("ALTER TABLE apps ADD COLUMN user_id INTEGER REFERENCES users(user_id)")

    conn.commit()
    return conn


def _upsert(conn: sqlite3.Connection, rec: AppRecord) -> None:
    conn.execute("""
        INSERT INTO apps (app_id, lxc_id, ip, hostname, port, status)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(app_id) DO UPDATE SET
            lxc_id=excluded.lxc_id, ip=excluded.ip,
            hostname=excluded.hostname, port=excluded.port,
            status=excluded.status
    """, (rec.app_id, rec.lxc_id, rec.ip, rec.hostname, rec.port, rec.status))
    conn.commit()


def install(
    meta: AppMeta,
    fixed_lxc_id: int | None = None,
    fixed_ip: str | None = None,
) -> AppRecord:
    """
    Vollständiger Install-Flow:
      1. Freie LXC-ID + IP ermitteln (oder fixed_lxc_id/fixed_ip für feste Apps)
      2. Template klonen
      3. LXC starten + auf Netzwerk warten
      4. docker-compose.yml schreiben + docker compose up

    fixed_lxc_id/fixed_ip: für vorkonfigurierte Apps mit fester IP (z.B. Nextcloud → LXC 109)
    """
    proxmox = ProxmoxClient()
    conn = _get_db()

    # Prüfen ob bereits installiert
    row = conn.execute("SELECT * FROM apps WHERE app_id=?", (meta.app_id,)).fetchone()
    if row and row["status"] in ("running", "installing"):
        raise RuntimeError(f"App '{meta.app_id}' ist bereits installiert (Status: {row['status']})")

    lxc_id = fixed_lxc_id or proxmox.next_free_id()
    ip = fixed_ip or proxmox.next_free_ip()
    hostname = f"casaos-{meta.app_id.lower().replace('_', '-')}"

    rec = AppRecord(
        app_id=meta.app_id, lxc_id=lxc_id, ip=ip,
        hostname=hostname, port=meta.port, status="installing"
    )
    _upsert(conn, rec)

    try:
        # 1. LXC aus Template klonen
        proxmox.clone_template(lxc_id, hostname, ip)

        # 2. LXC starten
        proxmox.start_lxc(lxc_id)
        _wait_for_network(ip)

        # 3. Compose-Datei im LXC ablegen (shell-sicher via pct push)
        app_dir = f"/opt/{meta.app_id}"
        compose_content = _patch_compose(meta, ip=ip)
        proxmox.exec_in_lxc(lxc_id, f"mkdir -p {app_dir}")
        proxmox.push_file_to_lxc(lxc_id, compose_content, f"{app_dir}/docker-compose.yml")

        # 4. Docker Compose starten
        proxmox.exec_in_lxc(lxc_id, f"cd {app_dir} && docker compose up -d")

        rec.status = "running"
        _upsert(conn, rec)

    except Exception as e:
        rec.status = "error"
        _upsert(conn, rec)
        raise RuntimeError(f"Install fehlgeschlagen: {e}") from e

    return rec


def remove(app_id: str) -> None:
    """Stoppt + zerstört den LXC und entfernt den DB-Eintrag."""
    conn = _get_db()
    row = conn.execute("SELECT * FROM apps WHERE app_id=?", (app_id,)).fetchone()
    if not row:
        raise FileNotFoundError(f"App '{app_id}' nicht gefunden")

    proxmox = ProxmoxClient()
    lxc_id = row["lxc_id"]
    try:
        proxmox.stop_lxc(lxc_id)
        time.sleep(3)
    except Exception:
        pass
    proxmox.destroy_lxc(lxc_id)
    conn.execute("DELETE FROM apps WHERE app_id=?", (app_id,))
    conn.commit()


def list_apps() -> list[AppRecord]:
    """Alle bridge-verwalteten Apps aus DB."""
    conn = _get_db()
    rows = conn.execute("SELECT * FROM apps").fetchall()
    return [AppRecord(**dict(r)) for r in rows]


def sync_status() -> None:
    """Synchronisiert DB-Status mit tatsächlichem Proxmox-LXC-Status."""
    proxmox = ProxmoxClient()
    conn = _get_db()
    for row in conn.execute("SELECT * FROM apps").fetchall():
        try:
            status = proxmox.get_lxc_status(row["lxc_id"])
            mapped = "running" if status == "running" else "stopped"
            conn.execute("UPDATE apps SET status=? WHERE app_id=?", (mapped, row["app_id"]))
        except Exception:
            conn.execute("UPDATE apps SET status='error' WHERE app_id=?", (row["app_id"],))
    conn.commit()


def install_for_user(
    meta: AppMeta,
    user_id: int,
) -> AppRecord:
    """
    Installiert eine App im User-Scope:
      - IP + LXC-ID aus User-Subnetz (10.U.0.20+)
      - Bridge = vmbrU
      - App-Record mit user_id verknüpft

    Schlägt fehl wenn User nicht 'ready' ist.
    """
    conn = _get_db()
    user = conn.execute(
        "SELECT * FROM users WHERE user_id=? AND status='ready'", (user_id,)
    ).fetchone()
    if not user:
        raise RuntimeError(f"User {user_id} nicht gefunden oder nicht bereit")

    proxmox = ProxmoxClient()
    bridge = user["bridge"]
    gateway = user["gateway"]
    subnet_prefix = f"10.{user_id}.0"

    # Bereits installierte App-IPs im User-Subnetz sammeln
    used_ips = {
        row["ip"]
        for row in conn.execute(
            "SELECT ip FROM apps WHERE user_id=?", (user_id,)
        ).fetchall()
    }
    # .20 bis .118 → max 99 Apps pro User
    ip = None
    for offset in range(99):
        candidate = f"{subnet_prefix}.{20 + offset}"
        if candidate not in used_ips:
            ip = candidate
            break
    if not ip:
        raise RuntimeError(f"Kein freier IP-Slot im Subnetz {subnet_prefix}.0/24 für User {user_id}")

    lxc_id = proxmox.next_free_id_for_user(user["lxc_range_start"], user["lxc_range_end"])
    hostname = f"u{user_id}-{meta.app_id.lower().replace('_', '-')}"

    # Eindeutiger app_id-Key pro User: "alice__vaultwarden"
    scoped_app_id = f"u{user_id}__{meta.app_id}"

    row = conn.execute("SELECT status FROM apps WHERE app_id=?", (scoped_app_id,)).fetchone()
    if row and row["status"] in ("running", "installing"):
        raise RuntimeError(f"App '{meta.app_id}' für User {user_id} bereits installiert")

    rec = AppRecord(
        app_id=scoped_app_id, lxc_id=lxc_id, ip=ip,
        hostname=hostname, port=meta.port, status="installing"
    )
    conn.execute("""
        INSERT INTO apps (app_id, lxc_id, ip, hostname, port, status, user_id)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(app_id) DO UPDATE SET
            lxc_id=excluded.lxc_id, ip=excluded.ip, hostname=excluded.hostname,
            port=excluded.port, status=excluded.status, user_id=excluded.user_id
    """, (rec.app_id, rec.lxc_id, rec.ip, rec.hostname, rec.port, rec.status, user_id))
    conn.commit()

    try:
        proxmox.clone_template_for_user(lxc_id, hostname, ip, bridge, gateway)
        proxmox.start_lxc(lxc_id)
        proxmox.wait_for_lxc_ready(lxc_id)  # via pct exec (kein TCP — funktioniert trotz Netz-Isolation)

        app_dir = f"/opt/{meta.app_id}"
        compose_content = _patch_compose(meta, ip=ip)
        proxmox.exec_in_lxc(lxc_id, f"mkdir -p {app_dir}")
        proxmox.push_file_to_lxc(lxc_id, compose_content, f"{app_dir}/docker-compose.yml")
        proxmox.exec_in_lxc(lxc_id, f"cd {app_dir} && docker compose up -d")

        # Optional: Tailscale registrieren
        tailscale_key = user["tailscale_auth_key"]
        if tailscale_key:
            headscale_url = os.getenv("HEADSCALE_URL", "http://192.168.10.115:8080")
            try:
                proxmox.exec_in_lxc(lxc_id,
                    f"which tailscale || (curl -fsSL https://tailscale.com/install.sh | sh); "
                    f"tailscale up --login-server={headscale_url} "
                    f"--authkey={tailscale_key} --accept-routes=false --accept-dns=false"
                )
            except Exception:
                pass  # Tailscale ist optional

        rec.status = "running"
        conn.execute("UPDATE apps SET status='running' WHERE app_id=?", (rec.app_id,))
        conn.commit()

    except Exception as e:
        conn.execute("UPDATE apps SET status='error' WHERE app_id=?", (rec.app_id,))
        conn.commit()
        raise RuntimeError(f"Install fehlgeschlagen: {e}") from e

    return rec


def list_apps_for_user(user_id: int) -> list[AppRecord]:
    """Alle Apps eines Users aus DB."""
    conn = _get_db()
    rows = conn.execute("SELECT * FROM apps WHERE user_id=?", (user_id,)).fetchall()
    return [AppRecord(**{k: r[k] for k in ("app_id", "lxc_id", "ip", "hostname", "port", "status")}) for r in rows]


def _wait_for_network(ip: str, timeout: int = 60) -> None:
    """Wartet bis der LXC per TCP erreichbar ist (Port 22 = sshd)."""
    import socket
    for _ in range(timeout):
        try:
            with socket.create_connection((ip, 22), timeout=2):
                return
        except OSError:
            time.sleep(1)
    raise TimeoutError(f"LXC {ip} nicht im Netzwerk nach {timeout}s")


def _strip_app_proxy(compose: str) -> str:
    """Entfernt den app_proxy-Service-Block (Umbrel-spezifischer Reverse-Proxy)."""
    import re
    # Entfernt eingerückten Block unter "  app_proxy:" (2-Leerzeichen-Einrückung)
    return re.sub(r'  app_proxy:\n(    [^\n]*\n)*', '', compose)


def _patch_compose(meta: AppMeta, ip: str = "") -> str:
    """
    Ersetzt store-spezifische Magic-Variables in docker-compose.yml.

    CasaOS-Variablen:
      ${WEBUI_PORT}, ${AppID}, /DATA/AppData/${AppID}, ${PUID}, ${PGID}, ${TZ}

    Umbrel-Variablen:
      ${APP_DATA_DIR}, ${APP_PORT}, ${APP_DOMAIN}, ${NETWORK_IP},
      ${APP_PASSWORD}, ${TOR_*}, restliche ${APP_*}
    """
    import re
    compose = meta.compose_yaml

    if meta.store_type == "umbrel":
        compose = _strip_app_proxy(compose)
        compose = compose.replace("${APP_DATA_DIR}", f"/opt/{meta.app_id}/data")
        compose = compose.replace("${APP_PORT}", str(meta.port))
        compose = compose.replace("${APP_DOMAIN}", ip or "localhost")
        compose = compose.replace("${NETWORK_IP}", ip or "")
        compose = compose.replace("${APP_PASSWORD}", "changeme123")
        # Tor-Variablen → leer
        compose = re.sub(r'\$\{TOR_[^}]+\}', '', compose)
        # Restliche ${APP_*} → leer
        compose = re.sub(r'\$\{APP_[^}]+\}', '', compose)
    else:
        # CasaOS-Variablen
        compose = compose.replace("${WEBUI_PORT}", str(meta.port))
        compose = compose.replace("${WEBUI_PORT:-" + str(meta.port) + "}", str(meta.port))
        compose = compose.replace("${AppID}", meta.app_id)
        compose = compose.replace(f"/DATA/AppData/{meta.app_id}", f"/opt/{meta.app_id}/data")
        compose = compose.replace("/DATA/AppData/$AppID", f"/opt/{meta.app_id}/data")

    # Gemeinsame Variablen (beide Store-Typen)
    compose = compose.replace("${PUID}", "0")
    compose = compose.replace("${PGID}", "0")
    compose = compose.replace("${TZ}", "Europe/Berlin")
    return compose
