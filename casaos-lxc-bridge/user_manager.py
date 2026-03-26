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
from network_manager import create_bridge, destroy_bridge, get_user_network, get_user_casaos_ip, get_user_mgmt_ip
from zfs_manager import (
    create_user_dataset,
    mount_dataset_in_lxc,
    setup_nfs_export,
    mount_nfs_in_vm,
    destroy_user_dataset,
)
from auth import generate_api_key
from lxc_manager import _get_db
import authentik_client
import portainer_client

logger = logging.getLogger(__name__)

USER_LXC_RANGE_SIZE = int(os.getenv("USER_LXC_RANGE_SIZE", "100"))
HEADSCALE_LXC_ID = int(os.getenv("HEADSCALE_LXC_ID", "115"))
HEADSCALE_URL = os.getenv("HEADSCALE_URL", "http://192.168.10.115:8080")
TAILSCALE_ENABLED = os.getenv("TAILSCALE_ENABLED", "true").lower() == "true"
BRIDGE_URL = os.getenv("BRIDGE_URL", "http://192.168.10.141:8200")

# "casaos" = CasaOS-LXC (Template 9001) | "ugos" = UGOS-VM (Template 9002)
USER_DASHBOARD = os.getenv("USER_DASHBOARD", "casaos")


def _set_step(conn, user_id: int, step: str) -> None:
    conn.execute("UPDATE users SET provisioning_step=? WHERE user_id=?", (step, user_id))
    conn.commit()
    logger.info(f"User {user_id}: {step}")


def provision_user(username: str, quota: str = "100G",
                   storage_tier: str = "premium") -> dict:
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
        # Schritt 2: Netzwerk-Bridge anlegen (inkl. DNAT für lokale 192.168.10.x-Erreichbarkeit)
        _set_step(conn, user_id, "creating_bridge")
        create_bridge(user_id, proxmox)
        mgmt_ip = get_user_mgmt_ip(user_id)
        conn.execute("UPDATE users SET casaos_mgmt_ip=? WHERE user_id=?", (mgmt_ip, user_id))
        conn.commit()

        # Schritt 3: ZFS-Datasets anlegen
        _set_step(conn, user_id, "creating_zfs_datasets")
        zfs_dataset = create_user_dataset(username, quota, proxmox)
        if zfs_dataset:
            conn.execute("UPDATE users SET zfs_dataset=? WHERE user_id=?", (zfs_dataset, user_id))
            conn.commit()

        # Schritt 4–10: UGOS-VM oder CasaOS-LXC (komplett unterschiedliche Pfade)
        _default_storage = os.getenv("PROXMOX_STORAGE", "local-lvm")
        storage = os.getenv(f"STORAGE_TIER_{storage_tier.upper()}", _default_storage)

        if USER_DASHBOARD == "ugos":
            casaos_url, tailscale_auth_key = _provision_ugos_vm(
                conn, user_id, username, casaos_lxc_id,
                bridge, gateway, subnet, storage, smb_password, api_key, storage_tier, proxmox,
            )
        else:
            casaos_url, tailscale_auth_key = _provision_casaos_lxc(
                conn, user_id, username, casaos_lxc_id,
                casaos_ip, bridge, gateway, storage, smb_password, api_key, storage_tier, proxmox,
            )

        conn.execute("UPDATE users SET casaos_url=? WHERE user_id=?", (casaos_url, user_id))
        conn.commit()

        # Schritt 11: Authentik SSO-User anlegen (opt-in via AUTHENTIK_TOKEN)
        _set_step(conn, user_id, "creating_sso_user")
        try:
            authentik_pk = authentik_client.create_user(username)
            # UGOS: OIDC-Application für SSO-Login
            if USER_DASHBOARD == "ugos":
                ugos_mgmt_ip = get_user_mgmt_ip(user_id)
                oidc_info = authentik_client.create_ugos_oidc_app(username, ugos_mgmt_ip)
                if oidc_info:
                    conn.execute(
                        "UPDATE users SET ugos_oidc_client_id=?, ugos_oidc_client_secret=?, "
                        "ugos_oidc_issuer=? WHERE user_id=?",
                        (oidc_info.get("client_id", ""),
                         oidc_info.get("client_secret", ""),
                         oidc_info.get("issuer_url", ""),
                         user_id)
                    )
            # Proxmox-User + ACL anlegen (Authentik-Realm)
            pool_name = f"pool-u{user_id}"
            proxmox.create_resource_pool(pool_name, comment=f"User {username}")
            proxmox.assign_to_pool(pool_name, [casaos_lxc_id])
            proxmox.create_proxmox_user(username)
            proxmox.set_user_pool_acl(username, pool_name)
            conn.execute(
                "UPDATE users SET authentik_user_pk=? WHERE user_id=?",
                (authentik_pk, user_id)
            )
            conn.commit()
        except Exception as e:
            logger.warning(f"SSO/Proxmox-User-Setup fehlgeschlagen (nicht kritisch): {e}")

        # Schritt 12: Portainer-Team + User anlegen (opt-in via PORTAINER_ADMIN_PASS)
        _set_step(conn, user_id, "creating_portainer_team")
        try:
            team_id = portainer_client.create_team(f"user-{username}")
            portainer_pwd = secrets.token_urlsafe(16)
            portainer_client.create_user(username, portainer_pwd, team_id)
            conn.execute(
                "UPDATE users SET portainer_team_id=? WHERE user_id=?",
                (team_id, user_id)
            )
            conn.commit()
        except Exception as e:
            logger.warning(f"Portainer-Setup fehlgeschlagen (nicht kritisch): {e}")

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

    dashboard_type = user["dashboard_type"] if "dashboard_type" in user.keys() else "casaos"

    # Authentik-User + OIDC App entfernen
    try:
        authentik_client.delete_user(user["username"])
        if dashboard_type == "ugos":
            authentik_client.delete_ugos_oidc_app(user["username"])
    except Exception as e:
        logger.warning(f"Authentik delete_user fehlgeschlagen: {e}")

    # Portainer-Team + User entfernen
    try:
        portainer_client.delete_user(user["username"])
        portainer_client.delete_team(f"user-{user['username']}")
    except Exception as e:
        logger.warning(f"Portainer delete fehlgeschlagen: {e}")

    # Proxmox-User + Resource Pool entfernen
    try:
        proxmox.delete_proxmox_user(user["username"])
        proxmox.delete_resource_pool(f"pool-u{user_id}")
    except Exception as e:
        logger.warning(f"Proxmox User/Pool delete fehlgeschlagen: {e}")

    # Headscale-Namespace entfernen
    namespace = user["headscale_namespace"]
    if namespace:
        try:
            proxmox._ssh_run(
                f"pct exec {HEADSCALE_LXC_ID} -- /usr/local/bin/headscale users destroy {namespace} 2>/dev/null || true"
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

    # Dashboard-VM/LXC stoppen + zerstören
    if casaos_lxc_id:
        try:
            if dashboard_type == "ugos":
                proxmox.stop_vm(casaos_lxc_id)
            else:
                proxmox.stop_lxc(casaos_lxc_id)
        except Exception:
            pass
        try:
            if dashboard_type == "ugos":
                proxmox.destroy_vm(casaos_lxc_id)
            else:
                proxmox.destroy_lxc(casaos_lxc_id)
        except Exception as e:
            logger.warning(f"Dashboard {casaos_lxc_id} destroy fehlgeschlagen: {e}")

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

def _provision_ugos_vm(
    conn, user_id, username, vm_id,
    bridge, gateway, subnet, storage, smb_password, api_key, storage_tier, proxmox,
) -> tuple[str, str]:
    """
    UGOS-VM Provisioning-Pfad (KVM/QEMU).
    Gibt (casaos_url, tailscale_auth_key) zurück.

    Unterschiede zu CasaOS-LXC:
      - clone_vm_for_user statt clone_template_for_user
      - ZFS via NFS statt pct set bindmount
      - start_vm + wait_for_vm_ready statt start_lxc
      - Kein App-Store / Bridge-Env (UGOS hat eigenes Dashboard)
      - QEMU Guest Agent für SSH-lose Exec-Befehle
    """
    _set_step(conn, user_id, "cloning_ugos_vm")
    hostname = f"ugos-{username}"
    proxmox.clone_vm_for_user(vm_id, hostname, bridge, storage)
    conn.execute(
        "UPDATE users SET casaos_lxc_id=?, dashboard_type=?, storage_tier=? WHERE user_id=?",
        (vm_id, "ugos", storage_tier, user_id)
    )
    conn.commit()

    # Schritt 5: ZFS via NFS exportieren (statt LXC-Bindmount)
    _set_step(conn, user_id, "mounting_zfs_datasets")
    setup_nfs_export(username, subnet, proxmox)

    # Schritt 6: VM starten + auf Guest Agent warten
    _set_step(conn, user_id, "starting_casaos_lxc")
    proxmox.start_vm(vm_id)
    proxmox.wait_for_vm_ready(vm_id, timeout=300)

    # NFS-Shares in VM mounten (via QEMU Guest Agent)
    try:
        nfs_host = gateway   # Proxmox-Bridge-IP = 10.U.0.1
        mount_nfs_in_vm(username, vm_id, nfs_host, proxmox)
    except Exception as e:
        logger.warning(f"NFS-Mount in UGOS-VM fehlgeschlagen (nicht kritisch): {e}")

    # Kein App-Store / Bridge-Env für UGOS (hat eigenes Dashboard)

    # Headscale/Tailscale (optional, via Guest Agent)
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
            _install_tailscale_in_vm(proxmox, vm_id, tailscale_auth_key)
        except Exception as e:
            logger.warning(f"Tailscale-Setup (UGOS) fehlgeschlagen (nicht kritisch): {e}")

    # UGOS hat eingebautes Samba → kein separates Passwort nötig
    # Management-URL (lokale Erreichbarkeit via DNAT 192.168.10.{149+U})
    mgmt_ip = get_user_mgmt_ip(user_id)
    casaos_url = f"http://{mgmt_ip}"
    return casaos_url, tailscale_auth_key


def _provision_casaos_lxc(
    conn, user_id, username, lxc_id,
    casaos_ip, bridge, gateway, storage, smb_password, api_key, storage_tier, proxmox,
) -> tuple[str, str]:
    """
    CasaOS-LXC Provisioning-Pfad (ursprünglicher Pfad).
    Gibt (casaos_url, tailscale_auth_key) zurück.
    """
    _set_step(conn, user_id, "cloning_casaos_lxc")
    hostname = f"casaos-{username}"
    proxmox.clone_template_for_user(lxc_id, hostname, casaos_ip, bridge, gateway)
    conn.execute(
        "UPDATE users SET casaos_lxc_id=?, dashboard_type=?, storage_tier=? WHERE user_id=?",
        (lxc_id, "casaos", storage_tier, user_id)
    )
    conn.commit()

    # cgroup2: Kernelzugriff auf physische Blockgeräte verweigern (LXC only)
    proxmox._ssh_run(
        f"printf 'lxc.cgroup2.devices.deny: b 8:* rwm\\n"
        f"lxc.cgroup2.devices.deny: b 259:* rwm\\n"
        f"lxc.cgroup2.devices.deny: b 65:* rwm\\n' "
        f">> /etc/pve/lxc/{lxc_id}.conf"
    )

    # Schritt 5: ZFS-Datasets im LXC mounten (vor dem Start!)
    _set_step(conn, user_id, "mounting_zfs_datasets")
    mount_dataset_in_lxc(username, lxc_id, proxmox)

    # Schritt 6: LXC starten + warten bis bereit
    _set_step(conn, user_id, "starting_casaos_lxc")
    proxmox.start_lxc(lxc_id)
    proxmox.wait_for_lxc_ready(lxc_id, timeout=120)

    # OpenClaw App-Store in User-CasaOS registrieren
    try:
        proxmox.exec_in_lxc(lxc_id,
            f"for i in $(seq 1 12); do "
            f"  casaos-cli app-management register app-store {BRIDGE_URL}/casaos-store.zip "
            f"  2>/dev/null && break || sleep 5; "
            f"done"
        )
    except Exception as e:
        logger.warning(f"App-Store-Registrierung fehlgeschlagen (nicht kritisch): {e}")

    # Schritt 7: Bridge-Env in LXC deployen (docker compose up)
    _set_step(conn, user_id, "deploying_bridge_env")
    _deploy_bridge_env_in_lxc(proxmox, lxc_id, user_id, username, api_key)

    # Schritt 8+9: Headscale/Tailscale
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
            _install_tailscale_in_lxc(proxmox, lxc_id, tailscale_auth_key)
        except Exception as e:
            logger.warning(f"Tailscale-Setup fehlgeschlagen (nicht kritisch): {e}")

    # Schritt 10: SMB-Passwort setzen
    _set_step(conn, user_id, "configuring_smb")
    try:
        _configure_smb_shares(proxmox, lxc_id, smb_password)
    except Exception as e:
        logger.warning(f"SMB-Konfiguration fehlgeschlagen (nicht kritisch): {e}")

    casaos_url = f"http://{casaos_ip}"
    return casaos_url, tailscale_auth_key


def _install_tailscale_in_vm(proxmox: ProxmoxClient, vm_id: int, auth_key: str) -> None:
    """Installiert Tailscale in einer UGOS-VM via QEMU Guest Agent."""
    proxmox.exec_in_vm(vm_id,
        "which tailscale 2>/dev/null || curl -fsSL https://tailscale.com/install.sh | sh"
    )
    proxmox.exec_in_vm(vm_id, "systemctl restart tailscaled 2>/dev/null || true")
    import time; time.sleep(5)
    proxmox.exec_in_vm(vm_id,
        f"tailscale up --login-server={HEADSCALE_URL} --authkey={auth_key} "
        "--accept-routes --accept-dns=false"
    )


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
    # Vollständiger Pfad — pct exec hat /usr/local/bin nicht im PATH
    HS = "/usr/local/bin/headscale"

    # Namespace anlegen (idempotent)
    proxmox._ssh_run(
        f"pct exec {HEADSCALE_LXC_ID} -- {HS} users create {username} 2>/dev/null || true"
    )
    # User-ID ermitteln (Headscale 0.28+ braucht numerische ID)
    id_result = proxmox._ssh_run(
        f"pct exec {HEADSCALE_LXC_ID} -- {HS} users list --output json"
    )
    hs_user_id = "1"  # Fallback
    if id_result.returncode == 0 and id_result.stdout.strip():
        import json as _json
        for u in _json.loads(id_result.stdout):
            if u.get("name") == username:
                hs_user_id = str(u["id"])
                break

    # Pre-Auth-Key generieren (reusable, 10 Jahre Laufzeit)
    # --expiration 0 würde sofort ablaufen — 87600h = ~10 Jahre
    result = proxmox._ssh_run(
        f"pct exec {HEADSCALE_LXC_ID} -- {HS} preauthkeys create "
        f"--user {hs_user_id} --reusable --expiration 87600h --output json"
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError(f"Headscale preauthkey create fehlgeschlagen: {result.stderr}")
    key_data = json.loads(result.stdout.strip())
    return key_data.get("key", "")


def _install_tailscale_in_lxc(proxmox: ProxmoxClient, lxc_id: int, auth_key: str) -> None:
    """
    Installiert Tailscale-Client im LXC + registriert beim Headscale-Server.
    Aktiviert /dev/net/tun via lxc.conf (Proxmox 8.x).
    """
    import time

    # TUN-Device in LXC-Config aktivieren (Proxmox 8: kein tun= Feature-Flag)
    proxmox._ssh_run(
        f"grep -q 'dev/net/tun' /etc/pve/lxc/{lxc_id}.conf || "
        f"echo 'lxc.cgroup2.devices.allow: c 10:200 rwm\\n"
        f"lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' "
        f">> /etc/pve/lxc/{lxc_id}.conf"
    )
    # LXC neu starten damit TUN-Device verfügbar wird
    proxmox._ssh_run(f"pct stop {lxc_id} && sleep 3 && pct start {lxc_id}")
    time.sleep(10)  # Warten bis Container-Init abgeschlossen

    # Tailscale installieren falls nicht vorhanden
    proxmox.exec_in_lxc(lxc_id,
        "which tailscale 2>/dev/null || curl -fsSL https://tailscale.com/install.sh | sh"
    )

    # tailscaled starten
    proxmox._ssh_run(f"pct exec {lxc_id} -- systemctl restart tailscaled")
    time.sleep(5)

    # Bei Headscale registrieren
    proxmox.exec_in_lxc(lxc_id,
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
    dashboard_type = row["dashboard_type"] if "dashboard_type" in row.keys() else "casaos"
    return {
        "user_id": row["user_id"],
        "username": row["username"],
        "api_key": row["api_key"],
        "bridge": row["bridge"],
        "subnet": row["subnet"],
        "gateway": row["gateway"],
        "casaos_lxc_id": row["casaos_lxc_id"],
        "casaos_url": row["casaos_url"],
        "casaos_mgmt_ip": row["casaos_mgmt_ip"],
        "local_url": f"http://{row['casaos_mgmt_ip']}" if row["casaos_mgmt_ip"] else None,
        "zfs_dataset": row["zfs_dataset"],
        "zfs_quota": row["zfs_quota"],
        "smb_password": row["smb_password"],
        "headscale_namespace": row["headscale_namespace"],
        "status": row["status"],
        "provisioning_step": row["provisioning_step"],
        "dashboard_type": dashboard_type,
        "storage_tier": row["storage_tier"] if "storage_tier" in row.keys() else "premium",
        "portainer_team_id": row["portainer_team_id"] if "portainer_team_id" in row.keys() else 0,
        "smb_shares": _smb_shares(row),
        "vpn": _vpn_info(row),
        "oidc": _oidc_info(row),
    }


def _smb_shares(row) -> dict | None:
    if not row["casaos_url"]:
        return None
    # Lokale Management-IP bevorzugen (192.168.10.x), Fallback auf internen IP
    display_ip = row["casaos_mgmt_ip"] or row["casaos_url"].replace("http://", "")
    return {
        "files":   f"\\\\{display_ip}\\files",
        "appdata": f"\\\\{display_ip}\\appdata",
        "user":    "casaos",
        "password": row["smb_password"],
    }


def _oidc_info(row) -> dict | None:
    """OIDC-Credentials für UGOS SSO — nur wenn vorhanden."""
    cols = row.keys() if hasattr(row, "keys") else []
    client_id = row["ugos_oidc_client_id"] if "ugos_oidc_client_id" in cols else ""
    if not client_id:
        return None
    return {
        "client_id": client_id,
        "client_secret": row["ugos_oidc_client_secret"] if "ugos_oidc_client_secret" in cols else "",
        "issuer_url": row["ugos_oidc_issuer"] if "ugos_oidc_issuer" in cols else "",
        "hint": "UGOS: Einstellungen → Authentifizierung → OIDC/OAuth2",
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
