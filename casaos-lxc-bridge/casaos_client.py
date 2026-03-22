"""
casaos_client.py — CasaOS /v2/apps Registration

Registriert installierte Apps im CasaOS-Dashboard damit sie
in der UI als "installierte Apps" erscheinen.

Analog zu casaos.py im GitHub-Deployment-Connector — hier als
schlanker Client ohne Dateisystem-Fallback (Bridge läuft nicht
auf dem CasaOS-Host selbst).
"""
from __future__ import annotations
import os
import json
import textwrap
import urllib.request
import urllib.error
from lxc_manager import AppRecord
from app_resolver import AppMeta

CASAOS_API = os.getenv("CASAOS_API_URL", "http://192.168.10.141/v2/apps")
CASAOS_TOKEN = os.getenv("CASAOS_API_TOKEN", "")


def _xcasaos_block(meta: AppMeta, rec: AppRecord) -> str:
    """Generiert den x-casaos Extension-Block für docker-compose.yml."""
    return textwrap.dedent(f"""

        x-casaos:
          architectures: {json.dumps(meta.architectures)}
          main: {meta.app_id}
          category: {meta.category}
          description:
            en_US: "{meta.description.strip().splitlines()[0] if meta.description else meta.name}"
          icon: "{meta.icon}"
          tagline:
            en_US: "{meta.tagline}"
          title:
            en_US: "{meta.name}"
          port_map: "{rec.ip}:{rec.port}"
          developer: "{meta.developer}"
          author: "{meta.developer}"
          # managed-by: casaos-lxc-bridge
          # lxc-id: {rec.lxc_id}
          # lxc-ip: {rec.ip}
    """)


def _minimal_compose(meta: AppMeta, rec: AppRecord) -> str:
    """
    Erstellt eine minimale docker-compose.yml für die CasaOS-Registrierung.
    CasaOS zeigt die App anhand des x-casaos-Blocks an — der eigentliche
    Container läuft im LXC und wird hier nur als "extern" referenziert.
    """
    compose = textwrap.dedent(f"""\
        # Auto-generiert von casaos-lxc-bridge
        # Echter Container läuft in LXC {rec.lxc_id} ({rec.ip})
        version: "3"
        services:
          {meta.app_id}:
            image: "alpine:3"
            labels:
              casaos.lxc.managed: "true"
              casaos.lxc.ip: "{rec.ip}"
              casaos.lxc.port: "{rec.port}"
        """)
    compose += _xcasaos_block(meta, rec)
    return compose


def register(meta: AppMeta, rec: AppRecord) -> str:
    """Registriert die App im CasaOS-Dashboard via /v2/apps POST."""
    compose_content = _minimal_compose(meta, rec)
    payload = json.dumps({"compose_app": compose_content}).encode()
    req = urllib.request.Request(
        CASAOS_API,
        data=payload,
        headers={
            "Content-Type": "application/json",
            **({"Authorization": f"Bearer {CASAOS_TOKEN}"} if CASAOS_TOKEN else {}),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return f"CasaOS registriert: HTTP {resp.status}"
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise RuntimeError(f"CasaOS Registration fehlgeschlagen: HTTP {e.code} — {body}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"CasaOS nicht erreichbar: {e.reason}") from e


def unregister(app_id: str) -> str:
    """Entfernt die App aus dem CasaOS-Dashboard."""
    req = urllib.request.Request(
        f"{CASAOS_API}/{app_id}",
        headers={
            **({"Authorization": f"Bearer {CASAOS_TOKEN}"} if CASAOS_TOKEN else {}),
        },
        method="DELETE",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return f"CasaOS Eintrag entfernt: HTTP {resp.status}"
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return f"App '{app_id}' war nicht in CasaOS registriert"
        raise RuntimeError(f"CasaOS Unregister fehlgeschlagen: HTTP {e.code}") from e
