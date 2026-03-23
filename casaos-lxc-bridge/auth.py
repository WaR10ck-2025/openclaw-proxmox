"""
auth.py — API-Key-Authentifizierung für casaos-lxc-bridge

Admin-Key:  Vollzugriff auf /admin/* und alle /bridge/* Endpoints
User-Key:   Zugriff auf /bridge/* im eigenen User-Scope
"""
from __future__ import annotations
import os
import secrets
from fastapi import HTTPException, Header

ADMIN_API_KEY = os.getenv("ADMIN_API_KEY", "")


def generate_api_key() -> str:
    """Generiert einen kryptographisch sicheren API-Key."""
    return secrets.token_urlsafe(32)


def require_admin(x_api_key: str = Header(..., alias="X-API-Key")) -> None:
    """FastAPI-Dependency: nur Admin-Key erlaubt."""
    if not ADMIN_API_KEY:
        raise HTTPException(500, detail="ADMIN_API_KEY nicht konfiguriert")
    if x_api_key != ADMIN_API_KEY:
        raise HTTPException(403, detail="Ungültiger Admin-API-Key")


def require_user_or_admin(
    x_api_key: str = Header(..., alias="X-API-Key"),
) -> int | None:
    """
    FastAPI-Dependency: Admin-Key oder User-Key.

    Gibt user_id zurück (int) wenn User-Key.
    Gibt None zurück wenn Admin-Key (kein User-Scope).
    """
    if ADMIN_API_KEY and x_api_key == ADMIN_API_KEY:
        return None  # Admin → kein User-Scope

    # User-Key in DB nachschlagen (import hier um Zirkel-Import zu vermeiden)
    from lxc_manager import _get_db
    conn = _get_db()
    row = conn.execute(
        "SELECT user_id FROM users WHERE api_key=? AND status='ready'",
        (x_api_key,)
    ).fetchone()
    if not row:
        raise HTTPException(403, detail="Ungültiger API-Key oder User nicht bereit")
    return int(row["user_id"])
