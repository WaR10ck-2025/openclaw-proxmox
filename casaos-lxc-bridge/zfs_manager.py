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


def setup_nfs_export(username: str, user_subnet: str, proxmox) -> str | None:
    """
    Exportiert User-ZFS-Datasets via NFS für UGOS-VM.
    NFS-Server läuft auf dem Proxmox-Host (Adresse = Bridge-Gateway 10.U.0.1).
    Gibt den Basis-Exportpfad zurück oder None wenn ZFS deaktiviert.

    user_subnet: z.B. '10.1.0.0/24' — nur VMs in diesem Subnetz dürfen mounten.
    """
    if not zfs_enabled():
        return None

    base = f"/{ZFS_POOL}/users/{username}"

    # nfs-kernel-server einmalig installieren (idempotent)
    proxmox._ssh_run(
        "which exportfs >/dev/null 2>&1 || "
        "(apt-get update -qq && apt-get install -y -qq nfs-kernel-server)"
    )

    for subdir in ("appdata", "files"):
        path = f"{base}/{subdir}"
        export_line = (
            f"{path} {user_subnet}"
            f"(rw,no_root_squash,no_subtree_check,async)"
        )
        # Idempotent: nur hinzufügen wenn noch nicht vorhanden
        proxmox._ssh_run(
            f"grep -qxF '{export_line}' /etc/exports "
            f"|| echo '{export_line}' >> /etc/exports"
        )

    proxmox._ssh_run("exportfs -ar && systemctl enable nfs-server --now 2>/dev/null || true")
    return base


def mount_nfs_in_vm(
    username: str,
    vm_id: int,
    nfs_host: str,
    proxmox,
) -> None:
    """
    Mountet User-ZFS-NFS-Shares in der UGOS-VM via QEMU Guest Agent.
    nfs_host: Proxmox-Bridge-IP für das User-Subnetz (z.B. '10.1.0.1').

    Mountpunkte:
      {nfs_host}:/ZFS_POOL/users/NAME/appdata  →  /DATA/AppData
      {nfs_host}:/ZFS_POOL/users/NAME/files    →  /DATA/Gallery
    """
    if not zfs_enabled():
        return

    base = f"/{ZFS_POOL}/users/{username}"

    # nfs-common im VM installieren (falls nicht vorhanden)
    proxmox.exec_in_vm(vm_id,
        "which mount.nfs >/dev/null 2>&1 || "
        "(apt-get update -qq && apt-get install -y -qq nfs-common)"
    )

    # Verzeichnisse anlegen + mounten
    for subdir, mountpoint in (("appdata", "/DATA/AppData"), ("files", "/DATA/Gallery")):
        nfs_share = f"{nfs_host}:{base}/{subdir}"
        fstab_line = f"{nfs_share} {mountpoint} nfs defaults,_netdev,nofail 0 0"
        proxmox.exec_in_vm(vm_id, f"mkdir -p {mountpoint}")
        proxmox.exec_in_vm(vm_id,
            f"grep -qxF '{fstab_line}' /etc/fstab "
            f"|| echo '{fstab_line}' >> /etc/fstab"
        )
        proxmox.exec_in_vm(vm_id,
            f"mount {mountpoint} 2>/dev/null || true"
        )


def remove_nfs_export(username: str, proxmox) -> None:
    """Entfernt NFS-Exports des Users aus /etc/exports."""
    if not zfs_enabled():
        return
    proxmox._ssh_run(
        f"sed -i '/\\/{ZFS_POOL}\\/users\\/{username}\\//d' /etc/exports 2>/dev/null; "
        "exportfs -ar 2>/dev/null || true"
    )


def destroy_user_dataset(username: str, proxmox) -> None:
    """
    Entfernt alle User-Datasets rekursiv + NFS-Exports.
    Überspringt wenn ZFS deaktiviert oder Dataset nicht existiert.
    """
    if not zfs_enabled():
        return

    remove_nfs_export(username, proxmox)
    base = f"{ZFS_POOL}/users/{username}"
    proxmox._ssh_run(f"zfs destroy -r '{base}' 2>/dev/null || true")


def set_dataset_quota(username: str, quota: str, proxmox) -> None:
    """
    Setzt ZFS-Quota für den User-Dataset (z.B. '200G').
    Überspringt wenn ZFS deaktiviert.
    """
    if not zfs_enabled():
        return
    base = f"{ZFS_POOL}/users/{username}"
    proxmox._ssh_run(f"zfs set quota={quota} '{base}'")


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
