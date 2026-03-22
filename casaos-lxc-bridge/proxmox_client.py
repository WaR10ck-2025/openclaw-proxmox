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
        body = json.dumps(data).encode() if data else None
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
        # Warten bis Clone-Task abgeschlossen (Lock freigegeben)
        upid = result.get("data", "")
        if upid:
            self._wait_for_task(upid)
        # Netzwerk setzen
        self._request("PUT", f"/nodes/{PROXMOX_NODE}/lxc/{new_id}/config", {
            "net0": f"name=eth0,bridge=vmbr0,ip={ip}/24,gw={LXC_GATEWAY}",
        })

    def start_lxc(self, lxc_id: int) -> None:
        self._request("POST", f"/nodes/{PROXMOX_NODE}/lxc/{lxc_id}/status/start")

    def stop_lxc(self, lxc_id: int) -> None:
        self._request("POST", f"/nodes/{PROXMOX_NODE}/lxc/{lxc_id}/status/stop")

    def destroy_lxc(self, lxc_id: int) -> None:
        self._request("DELETE", f"/nodes/{PROXMOX_NODE}/lxc/{lxc_id}", {"purge": 1})

    def get_lxc_status(self, lxc_id: int) -> str:
        result = self._request("GET", f"/nodes/{PROXMOX_NODE}/lxc/{lxc_id}/status/current")
        return result.get("data", {}).get("status", "unknown")

    def exec_in_lxc(self, lxc_id: int, command: str) -> None:
        """Führt Shell-Befehl via pct exec aus (blocking via Proxmox Task-API)."""
        import subprocess
        result = subprocess.run(
            ["pct", "exec", str(lxc_id), "--", "bash", "-c", command],
            capture_output=True, text=True, timeout=300
        )
        if result.returncode != 0:
            raise RuntimeError(f"pct exec failed: {result.stderr}")
