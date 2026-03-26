"""
portainer_client.py — Portainer CE Admin API Client

Verwaltet Teams, User und Endpoints in der zentralen Portainer-Instanz (LXC 130):
  - Team pro User anlegen (isolierte Sicht auf eigene Endpoints)
  - Portainer-User anlegen + Team zuweisen
  - App-LXC-Endpoints registrieren (via Portainer Agent auf Port 9001)
  - Endpoint dem User-Team zuweisen

Portainer API-Dokumentation: https://app.swaggerhub.com/apis/portainer/portainer-ce/

Authentifizierung: Admin-Username + Passwort → JWT-Token (wird gecacht)
"""
from __future__ import annotations
import os
import json
import logging
import threading
import urllib.request
import urllib.error

PORTAINER_URL = os.getenv("PORTAINER_URL", "http://192.168.10.130:9000")
PORTAINER_ADMIN_USER = os.getenv("PORTAINER_ADMIN_USER", "admin")
PORTAINER_ADMIN_PASS = os.getenv("PORTAINER_ADMIN_PASS", "")

# Portainer Agent-Port (Standard) — läuft im App-LXC
PORTAINER_AGENT_PORT = int(os.getenv("PORTAINER_AGENT_PORT", "9001"))

logger = logging.getLogger(__name__)

# JWT-Token-Cache (Portainer-Token ist 8h gültig)
_token_cache: dict = {"jwt": "", "expires": 0.0}
_token_lock = threading.Lock()


def _enabled() -> bool:
    return bool(PORTAINER_ADMIN_PASS)


def _get_token() -> str:
    """JWT-Token von Portainer holen (gecacht bis Ablauf)."""
    import time
    with _token_lock:
        if _token_cache["jwt"] and time.time() < _token_cache["expires"]:
            return _token_cache["jwt"]
        payload = json.dumps({
            "username": PORTAINER_ADMIN_USER,
            "password": PORTAINER_ADMIN_PASS,
        }).encode()
        req = urllib.request.Request(
            f"{PORTAINER_URL}/api/auth",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read())
                _token_cache["jwt"] = data["jwt"]
                _token_cache["expires"] = time.time() + 7 * 3600  # 7h (Puffer vor 8h-Ablauf)
                return _token_cache["jwt"]
        except urllib.error.HTTPError as e:
            raise RuntimeError(
                f"Portainer Auth fehlgeschlagen: HTTP {e.code}: {e.read().decode()}"
            ) from e
        except urllib.error.URLError as e:
            raise RuntimeError(f"Portainer nicht erreichbar ({PORTAINER_URL}): {e.reason}") from e


def _request(method: str, path: str, data: dict | None = None) -> dict | list:
    jwt = _get_token()
    url = f"{PORTAINER_URL}/api{path}"
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {jwt}",
            "Content-Type": "application/json",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        # 401 → Token abgelaufen → Cache leeren + retry
        if e.code == 401:
            with _token_lock:
                _token_cache["jwt"] = ""
        body_text = e.read().decode()
        raise RuntimeError(
            f"Portainer API {method} {path} → HTTP {e.code}: {body_text}"
        ) from e


def create_team(team_name: str) -> int:
    """
    Erstellt ein Portainer-Team. Gibt Team-ID zurück.
    Idempotent: gibt bestehende ID zurück wenn Team bereits existiert.
    """
    if not _enabled():
        return 0
    try:
        teams = _request("GET", "/teams")
        for t in (teams if isinstance(teams, list) else []):
            if t.get("Name") == team_name:
                return int(t["Id"])
        result = _request("POST", "/teams", {"Name": team_name})
        return int(result["Id"])
    except Exception as e:
        logger.warning(f"Portainer create_team fehlgeschlagen: {e}")
        return 0


def create_user(username: str, password: str, team_id: int) -> int:
    """
    Erstellt Portainer-User + weist ihn dem Team zu.
    Gibt User-ID zurück (0 bei Fehler).
    """
    if not _enabled():
        return 0
    try:
        result = _request("POST", "/users", {
            "username": username,
            "password": password,
            "role": 2,  # 1=admin, 2=regular user
        })
        user_id = int(result["Id"])
        if team_id:
            _request("POST", f"/team_memberships", {
                "TeamID": team_id,
                "UserID": user_id,
                "Role": 2,  # 1=leader, 2=member
            })
        logger.info(f"Portainer: User '{username}' (ID={user_id}) → Team {team_id}")
        return user_id
    except Exception as e:
        logger.warning(f"Portainer create_user fehlgeschlagen: {e}")
        return 0


def register_endpoint(name: str, agent_ip: str, team_id: int) -> int:
    """
    Registriert einen Portainer Agent-Endpoint (App-LXC).
    Gibt Endpoint-ID zurück (0 bei Fehler).

    Voraussetzung: Portainer Agent läuft im App-LXC auf Port PORTAINER_AGENT_PORT.
    """
    if not _enabled():
        return 0
    try:
        agent_url = f"tcp://{agent_ip}:{PORTAINER_AGENT_PORT}"
        result = _request("POST", f"/endpoints?Name={name}&EndpointCreationType=2"
                          f"&URL={agent_url}&TLS=false", {})
        endpoint_id = int(result["Id"])
        if team_id:
            _request("PUT", f"/endpoints/{endpoint_id}/teamaccesspolicies", {
                str(team_id): {"RoleId": 1}  # 1=environment-admin für Team
            })
        logger.info(f"Portainer: Endpoint '{name}' (ID={endpoint_id}) → Team {team_id}")
        return endpoint_id
    except Exception as e:
        logger.warning(f"Portainer register_endpoint fehlgeschlagen: {e}")
        return 0


def remove_endpoint(endpoint_id: int) -> None:
    """Entfernt Portainer-Endpoint."""
    if not _enabled() or not endpoint_id:
        return
    try:
        _request("DELETE", f"/endpoints/{endpoint_id}")
    except Exception as e:
        logger.warning(f"Portainer remove_endpoint {endpoint_id} fehlgeschlagen: {e}")


def delete_team(team_name: str) -> None:
    """Entfernt Portainer-Team (und damit alle Team-Mitgliedschaften)."""
    if not _enabled():
        return
    try:
        teams = _request("GET", "/teams")
        for t in (teams if isinstance(teams, list) else []):
            if t.get("Name") == team_name:
                _request("DELETE", f"/teams/{t['Id']}")
                return
    except Exception as e:
        logger.warning(f"Portainer delete_team fehlgeschlagen: {e}")


def delete_user(username: str) -> None:
    """Entfernt Portainer-User."""
    if not _enabled():
        return
    try:
        users = _request("GET", "/users")
        for u in (users if isinstance(users, list) else []):
            if u.get("Username") == username:
                _request("DELETE", f"/users/{u['Id']}")
                return
    except Exception as e:
        logger.warning(f"Portainer delete_user fehlgeschlagen: {e}")


def is_available() -> bool:
    """Prüft ob Portainer erreichbar ist."""
    if not _enabled():
        return False
    try:
        _get_token()
        return True
    except Exception:
        return False
