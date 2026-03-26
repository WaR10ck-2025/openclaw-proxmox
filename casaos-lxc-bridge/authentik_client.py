"""
authentik_client.py — Authentik SSO Admin API Client

Verwaltet User-Lifecycle in Authentik (Identity Provider):
  - User anlegen / löschen
  - Gruppen-Mitgliedschaft setzen
  - Basis: Authentik REST API v3 (https://docs.goauthentik.io/developer-docs/api/reference/)

Authentik API-Token: In Authentik UI → Admin → Tokens → Typ "API"
Token-Format: Bearer <token>
"""
from __future__ import annotations
import os
import json
import logging
import urllib.request
import urllib.error
import urllib.parse

AUTHENTIK_URL = os.getenv("AUTHENTIK_URL", "http://192.168.10.125:9000")
AUTHENTIK_TOKEN = os.getenv("AUTHENTIK_TOKEN", "")

# Standard-Gruppen — werden beim ersten User-Anlegen auto-erstellt falls nicht vorhanden
GROUP_USERS = "openclaw-users"
GROUP_ADMINS = "openclaw-admins"
GROUP_GUESTS = "openclaw-guests"

logger = logging.getLogger(__name__)


def _enabled() -> bool:
    return bool(AUTHENTIK_TOKEN)


def _request(method: str, path: str, data: dict | None = None) -> dict:
    url = f"{AUTHENTIK_URL}/api/v3{path}"
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {AUTHENTIK_TOKEN}",
            "Content-Type": "application/json",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()
        raise RuntimeError(
            f"Authentik API {method} {path} → HTTP {e.code}: {body_text}"
        ) from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"Authentik nicht erreichbar ({AUTHENTIK_URL}): {e.reason}") from e


def _get_group_pk(group_name: str) -> str | None:
    """Gibt PK der Gruppe zurück oder None wenn nicht vorhanden."""
    result = _request("GET", f"/core/groups/?name={urllib.parse.quote(group_name)}")
    results = result.get("results", [])
    return results[0]["pk"] if results else None


def _ensure_group(group_name: str) -> str:
    """Stellt sicher dass die Gruppe existiert. Gibt PK zurück."""
    pk = _get_group_pk(group_name)
    if pk:
        return pk
    result = _request("POST", "/core/groups/", {"name": group_name})
    return result["pk"]


def create_user(username: str, email: str = "", group: str = GROUP_USERS) -> str:
    """
    Legt User in Authentik an und weist ihn der Gruppe zu.
    Gibt Authentik User-PK zurück.
    Überspringt wenn AUTHENTIK_TOKEN nicht gesetzt (opt-in).
    """
    if not _enabled():
        logger.debug("Authentik deaktiviert (AUTHENTIK_TOKEN nicht gesetzt)")
        return ""
    try:
        user_email = email or f"{username}@openclaw.local"
        result = _request("POST", "/core/users/", {
            "username": username,
            "name": username,
            "email": user_email,
            "is_active": True,
            "type": "internal",
        })
        user_pk = result["pk"]
        group_pk = _ensure_group(group)
        _request("POST", f"/core/groups/{group_pk}/add_user/", {"pk": user_pk})
        logger.info(f"Authentik: User '{username}' angelegt (PK={user_pk}), Gruppe='{group}'")
        return str(user_pk)
    except Exception as e:
        logger.warning(f"Authentik create_user fehlgeschlagen (nicht kritisch): {e}")
        return ""


def delete_user(username: str) -> None:
    """
    Entfernt User aus Authentik.
    Überspringt wenn nicht vorhanden oder Authentik deaktiviert.
    """
    if not _enabled():
        return
    try:
        result = _request("GET", f"/core/users/?username={urllib.parse.quote(username)}")
        users = result.get("results", [])
        if not users:
            logger.debug(f"Authentik: User '{username}' nicht gefunden — übersprungen")
            return
        user_pk = users[0]["pk"]
        _request("DELETE", f"/core/users/{user_pk}/")
        logger.info(f"Authentik: User '{username}' (PK={user_pk}) entfernt")
    except Exception as e:
        logger.warning(f"Authentik delete_user fehlgeschlagen (nicht kritisch): {e}")


def create_ugos_oidc_app(username: str, ugos_ip: str) -> dict:
    """
    Erstellt einen Authentik OIDC Provider + Application für die UGOS-VM des Users.
    UGOS kann sich damit via OIDC/OAuth2 bei Authentik authentifizieren.

    Gibt {'client_id': str, 'client_secret': str, 'issuer_url': str} zurück.
    Gibt leeres Dict zurück wenn Authentik deaktiviert oder fehlgeschlagen.
    """
    if not _enabled():
        return {}
    try:
        app_name = f"ugos-{username}"
        redirect_uri = f"http://{ugos_ip}/api/auth/oidc/callback"

        # 1. OIDC Provider anlegen
        provider_result = _request("POST", "/providers/oauth2/", {
            "name": f"UGOS {username}",
            "authorization_flow": _get_default_flow("authorization"),
            "client_type": "confidential",
            "redirect_uris": redirect_uri,
            "sub_mode": "user_username",
            "include_claims_in_id_token": True,
            "issuer_mode": "global",
        })
        provider_pk = provider_result["pk"]
        client_id = provider_result["client_id"]
        client_secret = provider_result["client_secret"]

        # 2. Application anlegen und Provider binden
        _request("POST", "/core/applications/", {
            "name": f"UGOS {username}",
            "slug": app_name,
            "provider": provider_pk,
            "policy_engine_mode": "any",
        })
        logger.info(
            f"Authentik: OIDC App '{app_name}' angelegt "
            f"(client_id={client_id[:8]}…)"
        )
        return {
            "client_id": client_id,
            "client_secret": client_secret,
            "issuer_url": f"{AUTHENTIK_URL}/application/o/{app_name}/",
        }
    except Exception as e:
        logger.warning(f"Authentik OIDC App fehlgeschlagen (nicht kritisch): {e}")
        return {}


def delete_ugos_oidc_app(username: str) -> None:
    """Entfernt OIDC Application + Provider für den User."""
    if not _enabled():
        return
    try:
        slug = f"ugos-{username}"
        apps = _request("GET", f"/core/applications/?slug={urllib.parse.quote(slug)}")
        for app in apps.get("results", []):
            _request("DELETE", f"/core/applications/{app['slug']}/")
        logger.info(f"Authentik: OIDC App '{slug}' entfernt")
    except Exception as e:
        logger.warning(f"Authentik delete_ugos_oidc_app fehlgeschlagen: {e}")


def _get_default_flow(designation: str) -> str:
    """
    Gibt PK des ersten Flows mit der angegebenen Designation zurück.
    Fallback: 'default-authentication-flow' / 'default-authorization-flow'.
    """
    try:
        result = _request("GET", f"/flows/instances/?designation={designation}")
        flows = result.get("results", [])
        if flows:
            return flows[0]["pk"]
    except Exception:
        pass
    # Bekannte Authentik-Standard-Flow-Slugs
    fallbacks = {
        "authorization": "default-provider-authorization-implicit-consent",
        "authentication": "default-authentication-flow",
    }
    slug = fallbacks.get(designation, "default-authentication-flow")
    try:
        result = _request("GET", f"/flows/instances/{slug}/")
        return result["pk"]
    except Exception:
        return slug  # Slug als Fallback (Authentik akzeptiert auch Slugs)


def set_user_group(username: str, group: str) -> None:
    """Ändert Gruppen-Mitgliedschaft eines bestehenden Users."""
    if not _enabled():
        return
    try:
        user_result = _request("GET", f"/core/users/?username={urllib.parse.quote(username)}")
        users = user_result.get("results", [])
        if not users:
            return
        user_pk = users[0]["pk"]
        group_pk = _ensure_group(group)
        _request("POST", f"/core/groups/{group_pk}/add_user/", {"pk": user_pk})
        logger.info(f"Authentik: '{username}' → Gruppe '{group}'")
    except Exception as e:
        logger.warning(f"Authentik set_user_group fehlgeschlagen: {e}")


def is_available() -> bool:
    """Prüft ob Authentik erreichbar ist."""
    if not _enabled():
        return False
    try:
        _request("GET", "/core/users/?page_size=1")
        return True
    except Exception:
        return False
