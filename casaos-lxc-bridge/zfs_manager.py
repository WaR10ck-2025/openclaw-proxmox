"""
zfs_manager.py — ZFS-Dataset-Lifecycle pro User

Erstellt/entfernt ZFS-Datasets für User-Datenspeicher:
  tank/users/{username}/appdata  → /DATA/AppData im CasaOS-LXC
  tank/users/{username}/files    → /DATA/Gallery im CasaOS-LXC

ZFS wird übersprungen wenn ZFS_POOL_NAME leer ist (lokaler LXC-Storage als Fallback).
"""
from __future__ import annotations
import os

ZFS_POOL = os.getenv("ZFS_POOL_NAME", "")
USER_ZFS_QUOTA = os.getenv("USER_ZFS_QUOTA", "100G")


def zfs_enabled() -> bool:
    return bool(ZFS_POOL)


def create_user_dataset(username: str, quota: str, proxmox) -> str | None:
    """
    Erstellt ZFS-Datasets für User. Gibt Dataset-Pfad zurück oder None wenn ZFS deaktiviert.
    Idempotent: existierende Datasets werden übersprungen.
    """
    if not zfs_enabled():
        return None

    base = f"{ZFS_POOL}/users/{username}"
    for ds in [f"{ZFS_POOL}/users", base, f"{base}/appdata", f"{base}/files"]:
        proxmox._ssh_run(f"zfs create -p '{ds}' 2>/dev/null || true")

    # Quota setzen
    proxmox._ssh_run(f"zfs set quota={quota} '{base}'")
    return base


def mount_dataset_in_lxc(username: str, lxc_id: int, proxmox) -> None:
    """
    Mountet User-Datasets als Bindmounts in den LXC.
    Setzt mp0 (/DATA/AppData) und mp1 (/DATA/Gallery).
    Überspringt wenn ZFS deaktiviert.
    """
    if not zfs_enabled():
        return

    base = f"/{ZFS_POOL}/users/{username}"
    proxmox._ssh_run(
        f"pct set {lxc_id} "
        f"--mp0 {base}/appdata,mp=/DATA/AppData,backup=0 "
        f"--mp1 {base}/files,mp=/DATA/Gallery,backup=0"
    )


def destroy_user_dataset(username: str, proxmox) -> None:
    """
    Entfernt alle User-Datasets rekursiv.
    Überspringt wenn ZFS deaktiviert oder Dataset nicht existiert.
    """
    if not zfs_enabled():
        return

    base = f"{ZFS_POOL}/users/{username}"
    proxmox._ssh_run(f"zfs destroy -r '{base}' 2>/dev/null || true")


def get_dataset_usage(username: str, proxmox) -> dict:
    """
    Gibt ZFS-Quota + verwendeten Speicher zurück.
    Gibt leeres Dict zurück wenn ZFS deaktiviert.
    """
    if not zfs_enabled():
        return {"zfs_enabled": False}

    base = f"{ZFS_POOL}/users/{username}"
    result = proxmox._ssh_run(
        f"zfs get -Hp -o value used,quota '{base}' 2>/dev/null || echo '0\t0'"
    )
    lines = result.stdout.strip().split('\n') if result.stdout else ['0', '0']
    try:
        used = int(lines[0]) if lines[0].isdigit() else 0
        quota = int(lines[1]) if len(lines) > 1 and lines[1].isdigit() else 0
    except (ValueError, IndexError):
        used, quota = 0, 0

    return {
        "zfs_enabled": True,
        "dataset": base,
        "used_bytes": used,
        "quota_bytes": quota,
        "used_gb": round(used / 1024**3, 2) if used else 0,
        "quota_gb": round(quota / 1024**3, 2) if quota else 0,
    }
