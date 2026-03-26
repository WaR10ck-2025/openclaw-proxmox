"""
proxmox_client.py — Proxmox VE REST-API Wrapper

Kommuniziert mit Proxmox über die native REST-API.
Verwendet API-Token-Authentifizierung (kein Passwort).

Token-Format: PVEAPIToken=casaos@pve!casaos-bridge-token=<uuid>
"""
from __future__ import annotations
import os
import ssl
import json
import urllib.request
import urllib.error
import urllib.parse
from dataclasses import dataclass

PROXMOX_HOST = os.getenv("PROXMOX_HOST", "https://192.168.10.147:8006")
PROXMOX_SSH_KEY = os.getenv("PROXMOX_SSH_KEY", "/app/proxmox_key")
PROXMOX_TOKEN = os.getenv("PROXMOX_TOKEN", "")   # PVEAPIToken=casaos@pve!casaos-bridge-token=<uuid>
PROXMOX_NODE = os.getenv("PROXMOX_NODE", "pve")
TEMPLATE_ID = int(os.getenv("PROXMOX_TEMPLATE_ID", "9000"))
LXC_ID_START = 300
LXC_ID_END = 399
LXC_IP_START = 180   # 192.168.10.180 = Bridge selbst, Apps ab .181
LXC_STORAGE = os.getenv("PROXMOX_STORAGE", "local-lvm")
LXC_GATEWAY = "192.168.10.1"


@dataclass
class LXCInfo:
    lxc_id: int
    ip: str
    hostname: str
    status: str


class ProxmoxClient:
    def __init__(self):
        self._ctx = ssl.create_default_context()
        self._ctx.check_hostname = False
        self._ctx.verify_mode = ssl.CERT_NONE  # Proxmox self-signed

    def _request(self, method: str, path: str, data: dict | None = None) -> dict:
        url = f"{PROXMOX_HOST}/api2/json{path}"
        body = json.dumps(data if data is not None else {}).encode() if method in ("POST", "PUT", "PATCH") else None
        req = urllib.request.Request(
            url,
            data=body,
            headers={
                "Authorization": PROXMOX_TOKEN,
                "Content-Type": "application/json",
            },
            method=method,
        )
        try:
            with urllib.request.urlopen(req, context=self._ctx, timeout=15) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"Proxmox API {method} {path} → HTTP {e.code}: {e.read().decode()}") from e

    def get_existing_ids(self) -> set[int]:
        """Gibt alle LXC-IDs im Bridge-Bereich (300-399) zurück."""
        result = self._request("GET", f"/nodes/{PROXMOX_NODE}/lxc")
        return {
            int(lxc["vmid"])
            for lxc in result.get("data", [])
            if LXC_ID_START <= int(lxc["vmid"]) <= LXC_ID_END
        }

    def next_free_id(self) -> int:
        """Nächste freie LXC-ID im Bereich 301-399 (300 = Bridge)."""
        used = self.get_existing_ids()
        for lxc_id in range(LXC_ID_START + 1, LXC_ID_END + 1):
            if lxc_id not in used:
                return lxc_id
        raise RuntimeError("Kein freier LXC-Slot im Bereich 301-399")

    def next_free_ip(self) -> str:
        """Nächste freie IP im Bereich 192.168.10.181–249."""
        used_ids = self.get_existing_ids()
        # LXC 301 → .181, LXC 302 → .182, etc.
        for lxc_id in range(LXC_ID_START + 1, LXC_ID_END + 1):
            if lxc_id not in used_ids:
                offset = lxc_id - LXC_ID_START  # 301→1, 302→2, ...
                return f"192.168.10.{LXC_IP_START + offset}"
        raise RuntimeError("Keine freie IP im App-Bereich")

    def _wait_for_task(self, upid: str, timeout: int = 120) -> None:
        """Wartet bis ein Proxmox-Task (UPID) abgeschlossen ist."""
        import time
        for _ in range(timeout):
            result = self._request("GET", f"/nodes/{PROXMOX_NODE}/tasks/{urllib.parse.quote(upid, safe='')}/status")
            status = result.get("data", {}).get("status", "")
            if status == "stopped":
                exitstatus = result.get("data", {}).get("exitstatus", "")
                if exitstatus != "OK":
                    raise RuntimeError(f"Proxmox Task fehlgeschlagen: {exitstatus}")
                return
            time.sleep(1)
        raise TimeoutError(f"Proxmox Task {upid} nicht abgeschlossen nach {timeout}s")

    def clone_template(self, new_id: int, hostname: str, ip: str) -> None:
        """Klont das App-Template (ID 9000) zu einem neuen LXC."""
        result = self._request("POST", f"/nodes/{PROXMOX_NODE}/lxc/{TEMPLATE_ID}/clone", {
            "newid": new_id,
            "hostname": hostname,
            "full": 1,
            "storage": LXC_STORAGE,
        })
        upid = result.get("data", "")
        if upid:
            self._wait_for_task(upid)
        self._request("PUT", f"/nodes/{PROXMOX_NODE}/lxc/{new_id}/config", {
            "net0": f"name=eth0,bridge=vmbr0,ip={ip}/24,gw={LXC_GATEWAY}",
        })

    def clone_template_for_user(
        self,
        new_id: int,
        hostname: str,
        ip: str,
        bridge: str,
        gateway: str,
        template_id: int | None = None,
    ) -> None:
        """
        Klont das User-CasaOS-Template (default: 9001) zu einem neuen LXC.
        Setzt User-Bridge, User-Subnetz-IP + User-Gateway.
        Privilegierter Modus (nesting + keyctl) für Docker + ZFS-Bindmounts.
        """
        tmpl = template_id or int(os.getenv("CASAOS_TEMPLATE_ID", "9001"))

        # Template muss gestoppt sein für Full-Clone (Proxmox-Anforderung)
        tmpl_status = self._request("GET", f"/nodes/{PROXMOX_NODE}/lxc/{tmpl}/status/current")
        if tmpl_status.get("data", {}).get("status") == "running":
            self._request("POST", f"/nodes/{PROXMOX_NODE}/lxc/{tmpl}/status/stop")
            import time
            for _ in range(30):
                s = self._request("GET", f"/nodes/{PROXMOX_NODE}/lxc/{tmpl}/status/current")
                if s.get("data", {}).get("status") == "stopped":
                    break
                time.sleep(1)

        result = self._request("POST", f"/nodes/{PROXMOX_NODE}/lxc/{tmpl}/clone", {
            "newid": new_id,
            "hostname": hostname,
            "full": 1,
            "storage": LXC_STORAGE,
        })
        upid = result.get("data", "")
        if upid:
            self._wait_for_task(upid)

        # Netzwerk + Hostname via API (keine root@pam-Rechte nötig)
        self._request("PUT", f"/nodes/{PROXMOX_NODE}/lxc/{new_id}/config", {
            "net0": f"name=eth0,bridge={bridge},ip={ip}/24,gw={gateway}",
            "hostname": hostname,
        })
        # Privilegiert + Features via SSH (erfordert root@pam, daher nicht via API)
        self._ssh_run(
            f"pct set {new_id} --unprivileged 0 --features 'nesting=1,keyctl=1'"
        )

    def next_free_id_for_user(self, range_start: int, range_end: int) -> int:
        """Nächste freie LXC-ID im gegebenen User-Bereich (range_start+1 bis range_end)."""
        result = self._request("GET", f"/nodes/{PROXMOX_NODE}/lxc")
        used = {
            int(x["vmid"])
            for x in result.get("data", [])
            if range_start <= int(x["vmid"]) <= range_end
        }
        for i in range(range_start + 1, range_end + 1):
            if i not in used:
                return i
        raise RuntimeError(f"Kein freier LXC-Slot {range_start + 1}–{range_end}")

    def start_lxc(self, lxc_id: int) -> None:
        self._request("POST", f"/nodes/{PROXMOX_NODE}/lxc/{lxc_id}/status/start")

    def stop_lxc(self, lxc_id: int) -> None:
        self._request("POST", f"/nodes/{PROXMOX_NODE}/lxc/{lxc_id}/status/stop")

    def destroy_lxc(self, lxc_id: int) -> None:
        # purge als Query-Parameter (DELETE hat keinen Body in der Proxmox API)
        self._request("DELETE", f"/nodes/{PROXMOX_NODE}/lxc/{lxc_id}?purge=1")

    def get_lxc_status(self, lxc_id: int) -> str:
        result = self._request("GET", f"/nodes/{PROXMOX_NODE}/lxc/{lxc_id}/status/current")
        return result.get("data", {}).get("status", "unknown")

    def _ssh_run(self, remote_cmd: str, timeout: int = 300) -> subprocess.CompletedProcess:
        """Führt Befehl via SSH auf dem Proxmox-Host aus."""
        import subprocess, re, tempfile, shutil, stat, os
        host_ip = re.sub(r"https?://([^:/]+).*", r"\1", PROXMOX_HOST)
        tmp_key = tempfile.mktemp(suffix=".key")
        try:
            shutil.copy2(PROXMOX_SSH_KEY, tmp_key)
            os.chmod(tmp_key, stat.S_IRUSR | stat.S_IWUSR)
            return subprocess.run(
                ["ssh", "-i", tmp_key, "-o", "StrictHostKeyChecking=no",
                 "-o", "ConnectTimeout=10", f"root@{host_ip}", remote_cmd],
                capture_output=True, text=True, timeout=timeout,
            )
        finally:
            try:
                os.unlink(tmp_key)
            except OSError:
                pass

    def wait_for_lxc_ready(self, lxc_id: int, timeout: int = 120) -> None:
        """
        Wartet bis der LXC bereit ist — via pct exec auf dem Proxmox-Host.
        Umgeht Netzwerk-Isolation: kein direkter TCP-Connect nötig.
        """
        import time
        for _ in range(timeout):
            result = self._ssh_run(
                f"pct exec {lxc_id} -- test -f /etc/hostname 2>/dev/null && echo ok || echo wait"
            )
            if result.returncode == 0 and "ok" in result.stdout:
                return
            time.sleep(1)
        raise TimeoutError(f"LXC {lxc_id} nicht bereit nach {timeout}s")

    def exec_in_lxc(self, lxc_id: int, command: str) -> None:
        """Führt Shell-Befehl im LXC aus — via SSH + pct exec, Befehl base64-kodiert."""
        import base64
        # Base64-Encoding vermeidet alle Shell-Escaping-Probleme
        cmd_b64 = base64.b64encode(command.encode()).decode()
        remote = f"pct exec {lxc_id} -- bash -c \"echo {cmd_b64} | base64 -d | bash\""
        result = self._ssh_run(remote)
        if result.returncode != 0:
            raise RuntimeError(f"pct exec failed (SSH): {result.stderr}")

    def exec_in_vm(self, vm_id: int, command: str, timeout: int = 60) -> str:
        """
        Führt Shell-Befehl in einer QEMU-VM via QEMU Guest Agent aus.
        Benötigt: qemu-guest-agent im VM (UGOS/Debian installiert es automatisch).
        Gibt stdout zurück.
        """
        import base64
        cmd_b64 = base64.b64encode(command.encode()).decode()
        # --sync: wartet auf Abschluss + gibt Ausgabe zurück (Proxmox 8+)
        remote = (
            f"qm guest exec {vm_id} --sync -- bash -c "
            f"\"echo {cmd_b64} | base64 -d | bash\" 2>&1 || true"
        )
        result = self._ssh_run(remote, timeout=timeout + 30)
        if result.returncode != 0:
            raise RuntimeError(f"qm guest exec VM {vm_id} fehlgeschlagen: {result.stderr}")
        return result.stdout

    def wait_for_vm_ready(self, vm_id: int, timeout: int = 300) -> None:
        """
        Wartet bis VM läuft UND QEMU Guest Agent antwortet.
        Polls get_vm_status() + prüft ob guest exec möglich ist.
        """
        import time
        # Schritt 1: Warten bis VM status=running
        for _ in range(timeout):
            if self.get_vm_status(vm_id) == "running":
                break
            time.sleep(1)

        # Schritt 2: Warten bis Guest Agent antwortet (max 3 Minuten)
        for _ in range(180):
            try:
                result = self._ssh_run(
                    f"qm guest exec {vm_id} --sync -- echo ok 2>/dev/null"
                )
                if result.returncode == 0 and "ok" in result.stdout:
                    return
            except Exception:
                pass
            time.sleep(2)
        raise TimeoutError(f"VM {vm_id}: QEMU Guest Agent nicht erreichbar nach {timeout}s")

    def push_file_to_lxc(self, lxc_id: int, content: str, remote_path: str) -> None:
        """Überträgt Datei-Inhalt in den LXC via pct push (Shell-sicher via base64)."""
        import base64
        content_b64 = base64.b64encode(content.encode()).decode()
        tmp = f"/tmp/bridge_{lxc_id}_{abs(hash(remote_path)) % 100000}.tmp"
        remote = f"printf '%s' {content_b64} | base64 -d > {tmp} && pct push {lxc_id} {tmp} {remote_path} && rm -f {tmp}"
        result = self._ssh_run(remote)
        if result.returncode != 0:
            raise RuntimeError(f"pct push failed (SSH): {result.stderr}")

    # ─── VM (QEMU/KVM) Methoden ─────────────────────────────────────────────

    UGOS_TEMPLATE_ID = int(os.getenv("UGOS_TEMPLATE_ID", "9002"))

    def clone_vm_for_user(
        self,
        new_id: int,
        hostname: str,
        bridge: str,
        storage: str | None = None,
    ) -> None:
        """
        Klont die UGOS-Template-VM (Standard: 9002) als Full-Clone für einen User.
        Setzt VirtIO-NIC auf User-Bridge. IP wird nach erstem Boot in UGOS gesetzt.
        """
        vm_storage = storage or LXC_STORAGE
        result = self._request(
            "POST",
            f"/nodes/{PROXMOX_NODE}/qemu/{self.UGOS_TEMPLATE_ID}/clone",
            {
                "newid": new_id,
                "name": hostname,
                "full": 1,
                "storage": vm_storage,
            },
        )
        upid = result.get("data", "")
        if upid:
            self._wait_for_task(upid, timeout=300)  # Full-Clone kann länger dauern
        self._request("PUT", f"/nodes/{PROXMOX_NODE}/qemu/{new_id}/config", {
            "net0": f"virtio,bridge={bridge}",
            "name": hostname,
        })

    def start_vm(self, vm_id: int) -> None:
        self._request("POST", f"/nodes/{PROXMOX_NODE}/qemu/{vm_id}/status/start")

    def stop_vm(self, vm_id: int) -> None:
        self._request("POST", f"/nodes/{PROXMOX_NODE}/qemu/{vm_id}/status/stop")

    def destroy_vm(self, vm_id: int) -> None:
        self._request("DELETE", f"/nodes/{PROXMOX_NODE}/qemu/{vm_id}?purge=1")

    def get_vm_status(self, vm_id: int) -> str:
        result = self._request("GET", f"/nodes/{PROXMOX_NODE}/qemu/{vm_id}/status/current")
        return result.get("data", {}).get("status", "unknown")

    def get_vm_resources(self, vm_id: int) -> dict:
        """CPU/RAM-Nutzung einer VM. Gibt leeres Dict wenn VM nicht läuft."""
        try:
            result = self._request(
                "GET", f"/nodes/{PROXMOX_NODE}/qemu/{vm_id}/status/current"
            )
            data = result.get("data", {})
            return {
                "cpu_percent": round(data.get("cpu", 0) * 100, 1),
                "mem_used_bytes": data.get("mem", 0),
                "mem_total_bytes": data.get("maxmem", 0),
                "type": "vm",
            }
        except Exception:
            return {}

    def get_lxc_resources(self, lxc_id: int) -> dict:
        """CPU/RAM-Nutzung eines LXC. Gibt leeres Dict wenn LXC nicht läuft."""
        try:
            result = self._request(
                "GET", f"/nodes/{PROXMOX_NODE}/lxc/{lxc_id}/status/current"
            )
            data = result.get("data", {})
            return {
                "cpu_percent": round(data.get("cpu", 0) * 100, 1),
                "mem_used_bytes": data.get("mem", 0),
                "mem_total_bytes": data.get("maxmem", 0),
                "type": "lxc",
            }
        except Exception:
            return {}

    def set_vm_resources(self, vm_id: int, cores: int, memory_mb: int) -> None:
        """Setzt CPU-Kerne und RAM-Limit für eine VM."""
        self._request("PUT", f"/nodes/{PROXMOX_NODE}/qemu/{vm_id}/config", {
            "cores": cores,
            "memory": memory_mb,
        })

    def set_lxc_resources(self, lxc_id: int, cores: int, memory_mb: int) -> None:
        """Setzt CPU-Kerne und RAM-Limit für einen LXC."""
        self._request("PUT", f"/nodes/{PROXMOX_NODE}/lxc/{lxc_id}/config", {
            "cores": cores,
            "memory": memory_mb,
        })

    # ─── Proxmox Resource Pools + User-ACLs ─────────────────────────────────

    def create_resource_pool(self, pool_name: str, comment: str = "") -> None:
        """
        Legt einen Proxmox Resource Pool an.
        Idempotent: existierende Pools werden übersprungen.
        """
        try:
            self._request("POST", "/pools", {
                "poolid": pool_name,
                "comment": comment,
            })
        except RuntimeError as e:
            if "already exists" in str(e) or "500" in str(e):
                return  # Pool existiert bereits
            raise

    def assign_to_pool(self, pool_name: str, vm_ids: list[int]) -> None:
        """Weist VMs/LXCs einem Resource Pool zu."""
        if not vm_ids:
            return
        vms_str = ";".join(str(v) for v in vm_ids)
        self._request("PUT", f"/pools/{pool_name}", {"vms": vms_str})

    def create_proxmox_user(self, username: str, realm: str = "authentik") -> None:
        """
        Legt einen Proxmox-User an (für Authentik-Realm-Login).
        Idempotent: existierende User werden übersprungen.
        """
        try:
            self._ssh_run(
                f"pveum useradd '{username}@{realm}' 2>/dev/null || true"
            )
        except Exception as e:
            import logging
            logging.getLogger(__name__).warning(
                f"Proxmox create_user fehlgeschlagen (nicht kritisch): {e}"
            )

    def set_user_pool_acl(
        self,
        username: str,
        pool_name: str,
        role: str = "PVEVMUser",
        realm: str = "authentik",
    ) -> None:
        """
        Setzt ACL für einen User auf seinen Resource Pool.
        Ermöglicht User-Zugriff auf eigene VMs/LXCs via Proxmox-UI.
        """
        try:
            self._ssh_run(
                f"pveum aclmod /pool/{pool_name} "
                f"--users '{username}@{realm}' --roles {role}"
            )
        except Exception as e:
            import logging
            logging.getLogger(__name__).warning(
                f"Proxmox set_acl fehlgeschlagen (nicht kritisch): {e}"
            )

    def delete_proxmox_user(self, username: str, realm: str = "authentik") -> None:
        """Entfernt Proxmox-User."""
        try:
            self._ssh_run(f"pveum userdel '{username}@{realm}' 2>/dev/null || true")
        except Exception:
            pass

    def delete_resource_pool(self, pool_name: str) -> None:
        """Entfernt Proxmox Resource Pool."""
        try:
            self._request("DELETE", f"/pools/{pool_name}")
        except Exception:
            pass
