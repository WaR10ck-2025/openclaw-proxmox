"""
user_manager.py — User-Lifecycle + Provisioning-Orchestrierung

Provisioning-Schritte pro User:
  1. DB: INSERT users (status=provisioning)
  2. network_manager.create_bridge() → vmbr{U} + iptables-Regeln
  3. zfs_manager.create_user_dataset() → tank/users/{name}/appdata + /files
  4. proxmox.clone_template_for_user(LXC U*1000, bridge, ip)
  5. zfs_manager.mount_dataset_in_lxc() → pct set mp0/mp1
  6. proxmox.start_lxc() + warten bis erreichbar
  7. _deploy_bridge_env_in_lxc() → .env schreiben + docker compose up
  8. _setup_headscale_namespace() → Namespace + Pre-Auth-Key
  9. _install_tailscale_in_lxc() → Tailscale im CasaOS-LXC registrieren
 10. _configure_smb_shares() → Samba-Passwort setzen
 11. DB: UPDATE status=ready

Deprovision (rückwärts, fehler-tolerant):
  - LXC stoppen + zerstören
  - ZFS-Dataset entfernen
  - Bridge + iptables-Regeln entfernen
  - DB: DELETE
"""
from __future__ import annotations
import os
import json
import secrets
import logging
from proxmox_client import ProxmoxClient
from network_manager import create_bridge, destroy_bridge, get_user_network, get_user_casaos_ip
from zfs_manager import create_user_dataset, mount_dataset_in_lxc, destroy_user_dataset
from auth import generate_api_key
from lxc_manager import _get_db, _wait_for_network

logger = logging.getLogger(__name__)

USER_LXC_RANGE_SIZE = int(os.getenv("USER_LXC_RANGE_SIZE", "100"))
HEADSCALE_LXC_ID = int(os.getenv("HEADSCALE_LXC_ID", "115"))
HEADSCALE_URL = os.getenv("HEADSCALE_URL", "http://192.168.10.115:8080")
TAILSCALE_ENABLED = os.getenv("TAILSCALE_ENABLED", "true").lower() == "true"
BRIDGE_URL = os.getenv("BRIDGE_URL", "http://192.168.10.141:8200")


def _set_step(conn, user_id: int, step: str) -> None:
    conn.execute("UPDATE users SET provisioning_step=? WHERE user_id=?", (step, user_id))
    conn.commit()
    logger.info(f"User {user_id}: {step}")


def provision_user(username: str, quota: str = "100G") -> dict:
    """
    Legt einen neuen User an und provisioniert alle Ressourcen.
    Gibt User-Record als Dict zurück (inkl. api_key).
    Wirft RuntimeError bei Fehler (nach Cleanup-Versuch).
    """
    conn = _get_db()

    # Username-Konflikt prüfen
    if conn.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone():
        raise RuntimeError(f"Username '{username}' bereits vergeben")

    # User-ID via INSERT reservieren (AUTOINCREMENT → bestimmt Subnetz + Bridge)
    api_key = generate_api_key()
    smb_password = secrets.token_urlsafe(16)

    cursor = conn.execute(
        "INSERT INTO users (username, api_key, lxc_range_start, lxc_range_end, "
        "bridge, subnet, gateway, zfs_quota, smb_password, status) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'provisioning')",
        (username, api_key, 0, 0, "", "", "", quota, smb_password)
    )
    conn.commit()
    user_id = cursor.lastrowid

    # Netzwerk-Parameter berechnen
    subnet, gateway, bridge = get_user_network(user_id)
    casaos_ip = get_user_casaos_ip(user_id)
    casaos_lxc_id = user_id * 1000
    range_start = casaos_lxc_id
    range_end = casaos_lxc_id + USER_LXC_RANGE_SIZE - 1

    conn.execute(
        "UPDATE users SET lxc_range_start=?, lxc_range_end=?, bridge=?, subnet=?, gateway=? "
        "WHERE user_id=?",
        (range_start, range_end, bridge, subnet, gateway, user_id)
    )
    conn.commit()

    proxmox = ProxmoxClient()

    try:
        # Schritt 2: Netzwerk-Bridge anlegen
        _set_step(conn, user_id, "creating_bridge")
        create_bridge(user_id, proxmox)

        # Schritt 3: ZFS-Datasets anlegen
        _set_step(conn, user_id, "creating_zfs_datasets")
        zfs_dataset = create_user_dataset(username, quota, proxmox)
        if zfs_dataset:
            conn.execute("UPDATE users SET zfs_dataset=? WHERE user_id=?", (zfs_dataset, user_id))
            conn.commit()

        # Schritt 4: CasaOS-LXC aus Template klonen
        _set_step(conn, user_id, "cloning_casaos_lxc")
        hostname = f"casaos-{username}"
        proxmox.clone_template_for_user(casaos_lxc_id, hostname, casaos_ip, bridge, gateway)
        conn.execute("UPDATE users SET casaos_lxc_id=? WHERE user_id=?", (casaos_lxc_id, user_id))
        conn.commit()

        # Schritt 5: ZFS-Datasets im LXC mounten (vor dem Start!)
        _set_step(conn, user_id, "mounting_zfs_datasets")
        mount_dataset_in_lxc(username, casaos_lxc_id, proxmox)

        # Schritt 6: LXC starten + auf Netzwerk warten
        _set_step(conn, user_id, "starting_casaos_lxc")
        proxmox.start_lxc(casaos_lxc_id)
        _wait_for_network(casaos_ip, timeout=120)

        # Schritt 7: Bridge-Env in LXC deployen (docker compose up)
        _set_step(conn, user_id, "deploying_bridge_env")
        _deploy_bridge_env_in_lxc(proxmox, casaos_lxc_id, user_id, username, api_key)

        casaos_url = f"http://{casaos_ip}"
        conn.execute("UPDATE users SET casaos_url=? WHERE user_id=?", (casaos_url, user_id))
        conn.commit()

        # Schritt 8+9: Headscale/Tailscale (optional)
        tailscale_auth_key = ""
        if TAILSCALE_ENABLED:
            _set_step(conn, user_id, "setting_up_headscale")
            try:
                tailscale_auth_key = _setup_headscale_namespace(proxmox, username)
                conn.execute(
                    "UPDATE users SET tailscale_auth_key=?, headscale_namespace=? WHERE user_id=?",
                    (tailscale_auth_key, username, user_id)
                )
                conn.commit()

                _set_step(conn, user_id, "installing_tailscale")
                _install_tailscale_in_lxc(proxmox, casaos_lxc_id, tailscale_auth_key)
            except Exception as e:
                logger.warning(f"Tailscale-Setup fehlgeschlagen (nicht kritisch): {e}")

        # Schritt 10: SMB-Passwort setzen
        _set_step(conn, user_id, "configuring_smb")
        try:
            _configure_smb_shares(proxmox, casaos_lxc_id, smb_password)
        except Exception as e:
            logger.warning(f"SMB-Konfiguration fehlgeschlagen (nicht kritisch): {e}")

        # Fertig
        conn.execute(
            "UPDATE users SET status='ready', provisioning_step='' WHERE user_id=?", (user_id,)
        )
        conn.commit()
        logger.info(f"User '{username}' (ID {user_id}) erfolgreich provisioniert")

    except Exception as e:
        conn.execute(
            "UPDATE users SET status='error', provisioning_step=? WHERE user_id=?",
            (str(e)[:200], user_id)
        )
        conn.commit()
        raise RuntimeError(f"Provisioning fehlgeschlagen bei User '{username}': {e}") from e

    return _user_to_dict(conn.execute("SELECT * FROM users WHERE user_id=?", (user_id,)).fetchone())


def deprovision_user(user_id: int) -> None:
    """
    Entfernt User + alle Ressourcen (fehler-tolerant, rückwärts).
    Schlägt nicht fehl wenn einzelne Ressourcen nicht existieren.
    """
    conn = _get_db()
    user = conn.execute("SELECT * FROM users WHERE user_id=?", (user_id,)).fetchone()
    if not user:
        raise FileNotFoundError(f"User {user_id} nicht gefunden")

    conn.execute("UPDATE users SET status='deleting' WHERE user_id=?", (user_id,))
    conn.commit()

    proxmox = ProxmoxClient()
    casaos_lxc_id = user["casaos_lxc_id"]

    # Headscale-Namespace entfernen
    namespace = user["headscale_namespace"]
    if namespace:
        try:
            proxmox._ssh_run(
                f"pct exec {HEADSCALE_LXC_ID} -- headscale users destroy {namespace} 2>/dev/null || true"
            )
        except Exception as e:
            logger.warning(f"Headscale namespace destroy fehlgeschlagen: {e}")

    # Alle App-LXCs des Users stoppen + zerstören
    app_lxcs = conn.execute(
        "SELECT lxc_id FROM apps WHERE user_id=?", (user_id,)
    ).fetchall()
    for row in app_lxcs:
        try:
            proxmox.stop_lxc(row["lxc_id"])
        except Exception:
            pass
        try:
            proxmox.destroy_lxc(row["lxc_id"])
        except Exception as e:
            logger.warning(f"App-LXC {row['lxc_id']} destroy fehlgeschlagen: {e}")
    conn.execute("DELETE FROM apps WHERE user_id=?", (user_id,))
    conn.commit()

    # CasaOS-LXC stoppen + zerstören
    if casaos_lxc_id:
        try:
            proxmox.stop_lxc(casaos_lxc_id)
        except Exception:
            pass
        try:
            proxmox.destroy_lxc(casaos_lxc_id)
        except Exception as e:
            logger.warning(f"CasaOS-LXC {casaos_lxc_id} destroy fehlgeschlagen: {e}")

    # ZFS-Dataset entfernen
    try:
        destroy_user_dataset(user["username"], proxmox)
    except Exception as e:
        logger.warning(f"ZFS destroy fehlgeschlagen: {e}")

    # Bridge + iptables entfernen
    try:
        destroy_bridge(user_id, proxmox)
    except Exception as e:
        logger.warning(f"Bridge destroy fehlgeschlagen: {e}")

    # DB-Eintrag löschen
    conn.execute("DELETE FROM users WHERE user_id=?", (user_id,))
    conn.commit()
    logger.info(f"User {user_id} ('{user['username']}') vollständig entfernt")


def get_user(user_id: int) -> dict:
    conn = _get_db()
    row = conn.execute("SELECT * FROM users WHERE user_id=?", (user_id,)).fetchone()
    if not row:
        raise FileNotFoundError(f"User {user_id} nicht gefunden")
    return _user_to_dict(row)


def list_users() -> list[dict]:
    conn = _get_db()
    rows = conn.execute("SELECT * FROM users ORDER BY user_id").fetchall()
    return [_user_to_dict(r) for r in rows]


def get_user_quota(user_id: int) -> dict:
    """ZFS-Quota + Nutzung für User."""
    conn = _get_db()
    row = conn.execute("SELECT * FROM users WHERE user_id=?", (user_id,)).fetchone()
    if not row:
        raise FileNotFoundError(f"User {user_id} nicht gefunden")
    proxmox = ProxmoxClient()
    from zfs_manager import get_dataset_usage
    return get_dataset_usage(row["username"], proxmox)


# ─── Interne Hilfsfunktionen ─────────────────────────────────────────────────

def _deploy_bridge_env_in_lxc(
    proxmox: ProxmoxClient,
    lxc_id: int,
    user_id: int,
    username: str,
    api_key: str,
) -> None:
    """
    Schreibt .env + docker-compose.yml in den CasaOS-LXC und startet die Bridge.
    Die Bridge läuft im CasaOS-LXC und routet App-Installationen an Proxmox.
    """
    env_content = (
        f"ADMIN_API_KEY={api_key}\n"
        f"USER_ID={user_id}\n"
        f"USERNAME={username}\n"
        f"BRIDGE_URL={BRIDGE_URL}\n"
    )
    proxmox.exec_in_lxc(lxc_id, "mkdir -p /opt/casaos-bridge")
    proxmox.push_file_to_lxc(lxc_id, env_content, "/opt/casaos-bridge/.env")
    # docker compose up falls vorhanden (Template hat bereits compose.yml)
    proxmox.exec_in_lxc(
        lxc_id,
        "cd /opt/casaos-bridge && test -f docker-compose.yml && docker compose up -d || true"
    )


def _setup_headscale_namespace(proxmox: ProxmoxClient, username: str) -> str:
    """Legt Headscale-Namespace + Pre-Auth-Key für den User an. Gibt Auth-Key zurück."""
    # Namespace anlegen (idempotent)
    proxmox._ssh_run(
        f"pct exec {HEADSCALE_LXC_ID} -- headscale users create {username} 2>/dev/null || true"
    )
    # Pre-Auth-Key generieren (reusable, kein Ablauf)
    result = proxmox._ssh_run(
        f"pct exec {HEADSCALE_LXC_ID} -- headscale preauthkeys create "
        f"--user {username} --reusable --expiration 0 --output json"
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError(f"Headscale preauthkey create fehlgeschlagen: {result.stderr}")
    key_data = json.loads(result.stdout.strip())
    return key_data.get("key", "")


def _install_tailscale_in_lxc(proxmox: ProxmoxClient, lxc_id: int, auth_key: str) -> None:
    """Installiert Tailscale-Client im LXC + registriert beim Headscale-Server."""
    proxmox.exec_in_lxc(lxc_id,
        "which tailscale 2>/dev/null || curl -fsSL https://tailscale.com/install.sh | sh; "
        f"tailscale up --login-server={HEADSCALE_URL} --authkey={auth_key} "
        "--accept-routes --accept-dns=false"
    )


def _configure_smb_shares(proxmox: ProxmoxClient, lxc_id: int, smb_password: str) -> None:
    """Setzt Samba-Passwort + startet smbd im User-LXC."""
    proxmox.exec_in_lxc(lxc_id,
        f"echo -e '{smb_password}\\n{smb_password}' | smbpasswd -a -s casaos; "
        "systemctl restart smbd nmbd 2>/dev/null || true"
    )


def _user_to_dict(row) -> dict:
    """Konvertiert SQLite-Row zu Dict (api_key immer enthalten für Admin-Response)."""
    return {
        "user_id": row["user_id"],
        "username": row["username"],
        "api_key": row["api_key"],
        "bridge": row["bridge"],
        "subnet": row["subnet"],
        "gateway": row["gateway"],
        "casaos_lxc_id": row["casaos_lxc_id"],
        "casaos_url": row["casaos_url"],
        "zfs_dataset": row["zfs_dataset"],
        "zfs_quota": row["zfs_quota"],
        "smb_password": row["smb_password"],
        "headscale_namespace": row["headscale_namespace"],
        "status": row["status"],
        "provisioning_step": row["provisioning_step"],
        "smb_shares": _smb_shares(row),
        "vpn": _vpn_info(row),
    }


def _smb_shares(row) -> dict | None:
    if not row["casaos_url"]:
        return None
    ip = row["casaos_url"].replace("http://", "")
    return {
        "files":   f"\\\\{ip}\\files",
        "appdata": f"\\\\{ip}\\appdata",
        "user":    "casaos",
        "password": row["smb_password"],
    }


def _vpn_info(row) -> dict | None:
    if not row["tailscale_auth_key"]:
        return None
    return {
        "headscale_url": HEADSCALE_URL,
        "namespace": row["headscale_namespace"],
        "auth_key": row["tailscale_auth_key"],
        "connect_hint": (
            f"tailscale up --login-server={HEADSCALE_URL} "
            f"--authkey={row['tailscale_auth_key']}"
        ),
    }
