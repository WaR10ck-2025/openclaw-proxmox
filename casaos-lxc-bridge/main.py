"""
main.py — casaos-lxc-bridge FastAPI

Endpunkte:
  GET    /                                   → Redirect zur Web-UI
  GET    /static/index.html                 Web-UI (One-Click App-Store)
  POST   /bridge/install?appid=<id>         App aus Store als LXC deployen
  DELETE /bridge/remove?appid=<id>          LXC stoppen + löschen
  GET    /bridge/list                        Alle bridge-verwalteten Apps
  GET    /bridge/status?appid=<id>          Status einer App
  POST   /bridge/sync                        DB-Status mit Proxmox abgleichen
  GET    /bridge/catalog                     Verfügbare Apps (alle Stores, filterbar)
  GET    /bridge/catalog/sources             Aktive Store-Quellen
  GET    /bridge/preconfigured               Freigeschaltete Apps (mit Live-Status)
  GET    /casaos-store/Apps                  GitHub-API-kompatibler App-Index (für CasaOS)
  GET    /casaos-store/{app_id}/docker-compose.yml  Compose mit x-casaos Block (für CasaOS)
  GET    /health                             Liveness-Check

  --- Admin-Endpoints (X-API-Key: $ADMIN_KEY erforderlich) ---
  POST   /admin/users?username=X&quota=100G  User anlegen + provisionieren
  GET    /admin/users                        Alle User auflisten
  GET    /admin/users/{id}/status           User-Status + Zugangsdaten
  GET    /admin/users/{id}/quota            ZFS-Quota + Nutzung
  DELETE /admin/users/{id}                  User + alle Ressourcen entfernen
"""
from __future__ import annotations
import asyncio
import os
import time
import logging
import textwrap
import json
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Query, Depends, Request
import io
import zipfile
from fastapi.responses import JSONResponse, RedirectResponse, PlainTextResponse, Response
from fastapi.staticfiles import StaticFiles
import app_resolver
import lxc_manager
import casaos_client
import preconfigured_apps
import user_manager
from auth import require_admin, require_user_or_admin

logger = logging.getLogger("casaos-lxc-bridge")
logging.basicConfig(level=logging.INFO)

BRIDGE_URL = os.getenv("BRIDGE_URL", "http://192.168.10.141:8200")
BRIDGE_LXC_ID = int(os.getenv("BRIDGE_LXC_ID", "120"))
STORE_AUTHOR = os.getenv("STORE_AUTHOR", "OpenClaw")

# ---------------------------------------------------------------------------
# Katalog-Cache: wird beim Start befüllt + alle 6h refreshed
# ---------------------------------------------------------------------------
_catalog_cache: dict = {"apps": [], "last_update": 0.0}
_store_zip_cache: dict = {"zip_bytes": b"", "last_update": 0.0}
_CACHE_TTL = 6 * 3600   # 6 Stunden


def _is_casaos_compatible(compose_yaml: str) -> bool:
    """
    Prüft ob ein Compose-File CasaOS-kompatibel ist.
    Umbrel-Apps verwenden app_proxy ohne Image → scheitern an CasaOS-Validierung.
    """
    if "app_proxy:" not in compose_yaml:
        return True
    # app_proxy-Service hat kein eigenes Image → Umbrel-Pattern, nicht CasaOS-kompatibel
    proxy_section = compose_yaml.split("app_proxy:")[1]
    next_service = proxy_section.find("\n  ") if "\n  " in proxy_section else len(proxy_section)
    return "image:" in proxy_section[:next_service]


def _build_store_zip_sync(apps: list) -> bytes:
    """
    Baut den Store-ZIP synchron im Memory. Für asyncio.to_thread().
    Schließt Umbrel-Apps mit app_proxy-Service aus (CasaOS-inkompatibel).
    """
    buf = io.BytesIO()
    included = 0
    skipped = 0
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for app_entry in apps:
            app_id = app_entry.get("app_id")
            if not app_id:
                continue
            try:
                meta = app_resolver.resolve(app_id)
                compose = _to_casaos_format(meta)
                if not _is_casaos_compatible(compose):
                    skipped += 1
                    continue
                # Root-level x-casaos author überschreiben (2-Space-Indent)
                compose = re.sub(r'^  author:.*$', f'  author: {STORE_AUTHOR}', compose, flags=re.MULTILINE)
                zf.writestr(f"casaos-store/Apps/{app_id}/docker-compose.yml", compose)
                included += 1
            except Exception:
                skipped += 1
    logger.info(f"Store-ZIP: {included} Apps eingeschlossen, {skipped} übersprungen")
    return buf.getvalue()


async def _refresh_catalog_cache() -> None:
    """Befüllt den Katalog-Cache + ZIP-Cache async im Hintergrund."""
    try:
        all_apps = await asyncio.to_thread(app_resolver.list_all_apps_with_meta)
        _catalog_cache["apps"] = all_apps
        _catalog_cache["last_update"] = time.time()
        logger.info(f"Katalog-Cache aktualisiert: {len(all_apps)} Apps")
    except Exception as e:
        logger.warning(f"Katalog-Cache-Refresh fehlgeschlagen: {e}")
        return

    # ZIP-Cache nach Katalog-Refresh neu bauen
    try:
        zip_bytes = await asyncio.to_thread(_build_store_zip_sync, _catalog_cache["apps"])
        _store_zip_cache["zip_bytes"] = zip_bytes
        _store_zip_cache["last_update"] = time.time()
        logger.info(f"Store-ZIP-Cache aktualisiert: {len(zip_bytes)} Bytes")
    except Exception as e:
        logger.warning(f"Store-ZIP-Cache-Refresh fehlgeschlagen: {e}")


async def _schedule_cache_refresh() -> None:
    """Loop: Katalog alle 6h aktualisieren."""
    while True:
        await _refresh_catalog_cache()
        await asyncio.sleep(_CACHE_TTL)


# ---------------------------------------------------------------------------
# CasaOS Custom Store: Pseudo-Store-API (GitHub-API-kompatibel)
# ---------------------------------------------------------------------------

def _to_casaos_format(meta: app_resolver.AppMeta) -> str:
    """
    Gibt CasaOS-kompatibles docker-compose.yml zurück.

    Für CasaOS-Apps: bestehendes Compose (hat bereits x-casaos Block).
    Für Umbrel-Apps: generiert synthetischen x-casaos Block.
    """
    compose = meta.compose_yaml
    if meta.store_type == "umbrel":
        # x-casaos Block synthetisch generieren (Umbrel hat keinen eigenen)
        xcasaos = textwrap.dedent(f"""

            x-casaos:
              architectures: ["amd64", "arm64"]
              main: {meta.app_id}
              category: {meta.category}
              description:
                en_US: "{(meta.description or meta.name).strip().splitlines()[0]}"
              icon: "{meta.icon}"
              tagline:
                en_US: "{meta.tagline}"
              title:
                en_US: "{meta.name}"
              port_map: "{meta.port}"
              developer: "{meta.developer}"
              author: "{meta.developer}"
        """)
        compose = compose + xcasaos
    return compose


# ---------------------------------------------------------------------------
# Lifespan: Startup-Event für CasaOS Store-Registrierung + Cache
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(fastapi_app: FastAPI):
    # Katalog-Cache im Hintergrund starten
    cache_task = asyncio.create_task(_schedule_cache_refresh())

    # Bridge als CasaOS Custom Store registrieren (idempotent)
    store_url = f"{BRIDGE_URL}/casaos-store.zip"
    try:
        from proxmox_client import ProxmoxClient
        proxmox = ProxmoxClient()
        proxmox.exec_in_lxc(
            BRIDGE_LXC_ID,
            f"casaos-cli app-management register app-store {store_url} || true"
        )
        logger.info(f"CasaOS Custom Store registriert: {store_url}")
    except Exception as e:
        logger.warning(f"CasaOS Store-Registrierung fehlgeschlagen (ggf. manuell): {e}")

    yield

    cache_task.cancel()
    try:
        await cache_task
    except asyncio.CancelledError:
        pass


# ---------------------------------------------------------------------------
# FastAPI App
# ---------------------------------------------------------------------------

app = FastAPI(
    title="casaos-lxc-bridge",
    description="CasaOS App-Store + Umbrel → Proxmox LXC Bridge",
    version="2.0.0",
    lifespan=lifespan,
)

app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse("/static/index.html")


@app.get("/admin", include_in_schema=False)
def admin_ui():
    return RedirectResponse("/static/admin.html")


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "casaos-lxc-bridge",
        "catalog_cached": len(_catalog_cache["apps"]),
        "cache_age_s": int(time.time() - _catalog_cache["last_update"]) if _catalog_cache["last_update"] else None,
    }


# ---------------------------------------------------------------------------
# Preconfigured Apps
# ---------------------------------------------------------------------------

@app.get("/bridge/preconfigured")
async def get_preconfigured():
    """Freigeschaltete Apps mit Live-Status aus der Bridge-DB."""
    installed = {a.app_id: a for a in lxc_manager.list_apps()}
    result = []
    for app_def in preconfigured_apps.PRECONFIGURED_APPS:
        entry = dict(app_def)
        if entry["app_id"] in installed:
            rec = installed[entry["app_id"]]
            entry["status"] = rec.status
            entry["url"] = f"http://{rec.ip}:{rec.port}"
            entry["lxc_id"] = rec.lxc_id
        else:
            entry["status"] = "not_installed"
            entry["url"] = None
        result.append(entry)
    return {"apps": result}


# ---------------------------------------------------------------------------
# Install / Remove / List / Status / Sync
# ---------------------------------------------------------------------------

@app.post("/bridge/install")
async def install_app(
    appid: str = Query(..., description="App-ID (z.B. 'N8n', 'vaultwarden')"),
    caller_user_id: int | None = Depends(require_user_or_admin),
):
    """
    Installiert eine App aus CasaOS- oder Umbrel-Store als isolierten Proxmox-LXC.
    Mit User-Key: App wird im User-Subnetz installiert (User-Scope).
    Mit Admin-Key oder ohne Auth: Admin-Modus (vmbr0, bestehende Range 300–399).
    """
    try:
        meta = app_resolver.resolve(appid)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))

    if caller_user_id is not None:
        # User-Scope: App in User-Subnetz + User-LXC-Range
        try:
            rec = await asyncio.to_thread(lxc_manager.install_for_user, meta, caller_user_id)
        except RuntimeError as e:
            raise HTTPException(409 if "bereits installiert" in str(e) else 500, detail=str(e))
        return {
            "success": True,
            "app_id": rec.app_id,
            "lxc_id": rec.lxc_id,
            "ip": rec.ip,
            "port": rec.port,
            "url": f"http://{rec.ip}:{rec.port}",
            "store_type": meta.store_type,
            "user_id": caller_user_id,
        }

    # Admin-Modus: klassische Installation in vmbr0
    fixed_lxc_id, fixed_ip = preconfigured_apps.get_fixed_params(appid)
    try:
        rec = await asyncio.to_thread(lxc_manager.install, meta, fixed_lxc_id, fixed_ip)
    except RuntimeError as e:
        raise HTTPException(409 if "bereits installiert" in str(e) else 500, detail=str(e))

    casaos_msg = "CasaOS-Registrierung übersprungen (kein Token)"
    try:
        casaos_msg = await asyncio.to_thread(casaos_client.register, meta, rec)
    except RuntimeError as e:
        casaos_msg = f"Warnung: {e}"

    return {
        "success": True,
        "app_id": rec.app_id,
        "lxc_id": rec.lxc_id,
        "ip": rec.ip,
        "port": rec.port,
        "url": f"http://{rec.ip}:{rec.port}",
        "store_type": meta.store_type,
        "casaos": casaos_msg,
    }


@app.delete("/bridge/remove")
async def remove_app(appid: str = Query(..., description="App-ID")):
    """Stoppt und zerstört den LXC-Container. Entfernt den CasaOS-Dashboard-Eintrag."""
    try:
        await asyncio.to_thread(casaos_client.unregister, appid)
    except Exception:
        pass

    try:
        await asyncio.to_thread(lxc_manager.remove, appid)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(500, detail=str(e))

    return {"success": True, "app_id": appid, "message": "LXC gestoppt und zerstört"}


@app.get("/bridge/list")
async def list_apps(
    caller_user_id: int | None = Depends(require_user_or_admin),
):
    """Alle bridge-verwalteten Apps. User sieht nur eigene Apps."""
    await asyncio.to_thread(lxc_manager.sync_status)
    if caller_user_id is not None:
        apps = lxc_manager.list_apps_for_user(caller_user_id)
    else:
        apps = lxc_manager.list_apps()
    return {
        "count": len(apps),
        "apps": [
            {
                "app_id": a.app_id,
                "lxc_id": a.lxc_id,
                "ip": a.ip,
                "hostname": a.hostname,
                "port": a.port,
                "url": f"http://{a.ip}:{a.port}",
                "status": a.status,
            }
            for a in apps
        ],
    }


@app.get("/bridge/status")
async def app_status(appid: str = Query(...)):
    apps = lxc_manager.list_apps()
    for a in apps:
        if a.app_id == appid:
            return {"app_id": a.app_id, "lxc_id": a.lxc_id, "ip": a.ip, "status": a.status}
    raise HTTPException(404, detail=f"App '{appid}' nicht gefunden")


@app.post("/bridge/sync")
async def sync():
    """Synchronisiert DB-Status mit tatsächlichem Proxmox-LXC-Status."""
    await asyncio.to_thread(lxc_manager.sync_status)
    return {"success": True, "message": "Status synchronisiert"}


# ---------------------------------------------------------------------------
# Katalog
# ---------------------------------------------------------------------------

@app.get("/bridge/catalog")
async def catalog(
    source: str = Query("all", description="'all', 'casaos', 'umbrel', 'custom'"),
    category: str = Query("", description="Kategorie-Filter (case-insensitiv)"),
    q: str = Query("", description="Suchbegriff"),
):
    """
    Verfügbare Apps aus allen Stores.
    Gibt gecachte Ergebnisse zurück (Cache-TTL: 6h).
    """
    apps = _catalog_cache["apps"]
    if not apps:
        # Fallback: synchron laden wenn Cache noch leer
        apps = await asyncio.to_thread(app_resolver.list_all_apps_with_meta)

    if source != "all":
        apps = [a for a in apps if a.get("source") == source]
    if category:
        apps = [a for a in apps if a.get("category", "").lower() == category.lower()]
    if q:
        q_lower = q.lower()
        apps = [a for a in apps if q_lower in a.get("app_id", "").lower() or q_lower in a.get("name", "").lower()]

    return {
        "count": len(apps),
        "apps": apps,
        "cached_at": _catalog_cache["last_update"] or None,
    }


@app.post("/bridge/catalog/refresh")
async def catalog_refresh():
    """Erzwingt sofortigen Katalog-Cache-Refresh."""
    await _refresh_catalog_cache()
    return {"success": True, "count": len(_catalog_cache["apps"])}


@app.get("/bridge/catalog/sources")
async def catalog_sources():
    """Aktive Store-Quellen und ihre Konfiguration."""
    return {
        "casaos_official": True,
        "umbrel_official": app_resolver.UMBREL_STORE_ENABLED,
        "custom_stores": app_resolver._parse_custom_stores(),
    }


# ---------------------------------------------------------------------------
# CasaOS Pseudo-Store-API (/casaos-store/)
# ---------------------------------------------------------------------------

@app.get("/casaos-store/Apps")
async def casaos_store_index():
    """
    GitHub-API-kompatibler App-Index.
    CasaOS liest diesen Endpoint wenn die Bridge als Custom Store registriert ist.
    """
    apps = _catalog_cache["apps"]
    if not apps:
        apps = await asyncio.to_thread(app_resolver.list_all_apps_with_meta)

    all_ids = sorted({a["app_id"] for a in apps})
    return [{"name": app_id, "type": "dir"} for app_id in all_ids]


@app.get("/casaos-store/{app_id}/docker-compose.yml")
async def casaos_store_app(app_id: str):
    """
    Liefert CasaOS-kompatibles docker-compose.yml (mit x-casaos Block).
    Für Umbrel-Apps wird ein synthetischen x-casaos Block generiert.
    """
    try:
        meta = await asyncio.to_thread(app_resolver.resolve, app_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))

    compose = _to_casaos_format(meta)
    return PlainTextResponse(compose, media_type="text/plain")


@app.api_route("/casaos-store.zip", methods=["GET", "HEAD"])
async def casaos_store_zip(request: Request):
    """
    GitHub-Archive-kompatibler ZIP-Download des Custom Stores.
    CasaOS v0.4.15+ erwartet eine ZIP-URL beim Registrieren von Custom Stores.
    HEAD antwortet sofort aus dem Cache (CasaOS-Timeout-sicher).
    Struktur: casaos-store/Apps/{app_id}/docker-compose.yml
    """
    zip_bytes = _store_zip_cache["zip_bytes"]

    # Fallback: ZIP synchron bauen wenn Cache noch leer (Erststart)
    if not zip_bytes:
        apps = _catalog_cache["apps"]
        if not apps:
            apps = await asyncio.to_thread(app_resolver.list_all_apps_with_meta)
            _catalog_cache["apps"] = apps
        zip_bytes = await asyncio.to_thread(_build_store_zip_sync, apps)
        _store_zip_cache["zip_bytes"] = zip_bytes
        _store_zip_cache["last_update"] = time.time()

    headers = {
        "Content-Disposition": "attachment; filename=casaos-store.zip",
        "Content-Length": str(len(zip_bytes)),
    }
    if request.method == "HEAD":
        return Response(headers=headers, media_type="application/zip")
    return Response(content=zip_bytes, media_type="application/zip", headers=headers)


# ---------------------------------------------------------------------------
# Admin-Endpoints — nur mit X-API-Key: $ADMIN_KEY
# ---------------------------------------------------------------------------

@app.post("/admin/users")
async def create_user(
    username: str = Query(..., description="Eindeutiger Username"),
    quota: str = Query("100G", description="ZFS-Quota z.B. '50G', '200G'"),
    _: None = Depends(require_admin),
):
    """
    Legt einen neuen User an und startet die vollständige Provisionierung.
    Gibt user_id + api_key zurück. Provisionierung dauert ~5–10 Minuten.
    """
    try:
        result = await asyncio.to_thread(user_manager.provision_user, username, quota)
    except RuntimeError as e:
        raise HTTPException(409 if "vergeben" in str(e) else 500, detail=str(e))
    return result


@app.get("/admin/users")
async def admin_list_users(_: None = Depends(require_admin)):
    """Alle User mit Status auflisten."""
    users = user_manager.list_users()
    return {"count": len(users), "users": users}


@app.get("/admin/users/{user_id}/status")
async def admin_user_status(
    user_id: int,
    _: None = Depends(require_admin),
):
    """Detaillierter User-Status inkl. CasaOS-URL, SMB-Shares, VPN-Infos."""
    try:
        return user_manager.get_user(user_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))


@app.get("/admin/users/{user_id}/quota")
async def admin_user_quota(
    user_id: int,
    _: None = Depends(require_admin),
):
    """ZFS-Quota + aktueller Speicherverbrauch des Users."""
    try:
        return await asyncio.to_thread(user_manager.get_user_quota, user_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))
    except Exception as e:
        raise HTTPException(500, detail=str(e))


@app.delete("/admin/users/{user_id}")
async def admin_delete_user(
    user_id: int,
    _: None = Depends(require_admin),
):
    """
    Löscht User + alle Ressourcen (LXCs, ZFS-Datasets, Bridge, iptables-Regeln).
    Fehler-tolerant: einzelne fehlschlagende Cleanup-Schritte werden geloggt.
    """
    try:
        await asyncio.to_thread(user_manager.deprovision_user, user_id)
    except FileNotFoundError as e:
        raise HTTPException(404, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(500, detail=str(e))
    return {"success": True, "user_id": user_id, "message": "User + alle Ressourcen entfernt"}
