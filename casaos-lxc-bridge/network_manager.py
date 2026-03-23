"""
network_manager.py — User-Bridge + iptables-Verwaltung

Erstellt/entfernt pro User:
  - Linux-Bridge vmbrU auf dem Proxmox-Host
  - NAT/Masquerade für Internet-Zugang
  - iptables-Isolation (kein Zugang zu anderen User-Subnetzen + Management-Netz)

Isolation-Design:
  - Jeder User ist vollständig isoliert: kein Zugang zu 10.0.0.0/8 (andere User)
  - Kein Zugang zu 192.168.10.0/24 (Management-Netz, Proxmox, bestehende LXCs)
  - Nur Internet-Zugang via NAT/Masquerade über vmbr0
  - Headscale-Ausnahme: falls TAILSCALE_ENABLED, erlaubt Port 8080 nach 192.168.10.115
"""
from __future__ import annotations
import os
import textwrap


HEADSCALE_LXC_IP = os.getenv("HEADSCALE_LXC_IP", "192.168.10.115")
HEADSCALE_PORT = int(os.getenv("HEADSCALE_PORT", "8080"))
TAILSCALE_ENABLED = os.getenv("TAILSCALE_ENABLED", "true").lower() == "true"


def get_user_network(user_id: int) -> tuple[str, str, str]:
    """
    Gibt (subnetz, gateway, bridge) für user_id zurück.

    User 1 → ('10.1.0.0/24', '10.1.0.1', 'vmbr1')
    User 2 → ('10.2.0.0/24', '10.2.0.1', 'vmbr2')
    """
    subnet = f"10.{user_id}.0.0/24"
    gateway = f"10.{user_id}.0.1"
    bridge = f"vmbr{user_id}"
    return subnet, gateway, bridge


def get_user_casaos_ip(user_id: int) -> str:
    return f"10.{user_id}.0.10"


def get_user_app_ip(user_id: int, offset: int) -> str:
    """App-IP: offset 0 → .20, offset 1 → .21, ..."""
    return f"10.{user_id}.0.{20 + offset}"


def create_bridge(user_id: int, proxmox) -> str:
    """
    Legt vmbr{user_id} auf dem Proxmox-Host an und konfiguriert iptables.
    Idempotent: existierende Bridge wird übersprungen.

    Rückgabe: Bridge-Name (z.B. 'vmbr1')
    """
    subnet, gateway, bridge = get_user_network(user_id)
    u = user_id

    # Tailscale-Ausnahme: Zugang zum Headscale-Server erlauben
    headscale_rule = ""
    if TAILSCALE_ENABLED:
        headscale_rule = (
            f"    post-up   iptables -A FORWARD -i {bridge} "
            f"-d {HEADSCALE_LXC_IP} -p tcp --dport {HEADSCALE_PORT} -j ACCEPT "
            f"-m comment --comment openclaw-user-{u}-headscale\n"
        )

    iface_block = textwrap.dedent(f"""

        auto {bridge}
        iface {bridge} inet static
            address {gateway}
            netmask 255.255.255.0
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            # Internet: NAT/Masquerade
            post-up   iptables -t nat -A POSTROUTING -s 10.{u}.0.0/24 -o vmbr0 -j MASQUERADE -m comment --comment openclaw-user-{u}
            post-up   iptables -A FORWARD -i {bridge} -o vmbr0 -j ACCEPT -m comment --comment openclaw-user-{u}
            post-up   iptables -A FORWARD -i vmbr0 -o {bridge} -m state --state RELATED,ESTABLISHED -j ACCEPT -m comment --comment openclaw-user-{u}
            # Isolation: Management-Netz (192.168.10.0/24) → DROP
            post-up   iptables -A FORWARD -i {bridge} -d 192.168.10.0/24 -j DROP -m comment --comment openclaw-user-{u}-mgmt
            # Isolation: andere User-Subnetze (10.0.0.0/8) → DROP
            post-up   iptables -A FORWARD -i {bridge} -d 10.0.0.0/8 -j DROP -m comment --comment openclaw-user-{u}-iso
            # Cleanup
            post-down iptables -t nat -D POSTROUTING -s 10.{u}.0.0/24 -o vmbr0 -j MASQUERADE -m comment --comment openclaw-user-{u} || true
    """)

    # Headscale-Ausnahme VOR der 192.168.10.0/24-DROP-Regel einfügen
    if headscale_rule:
        # Ersetze die mgmt-DROP-Regel durch Ausnahme + DROP
        iface_block = iface_block.replace(
            f"            # Isolation: Management-Netz (192.168.10.0/24) → DROP\n"
            f"            post-up   iptables -A FORWARD -i {bridge} -d 192.168.10.0/24 -j DROP -m comment --comment openclaw-user-{u}-mgmt\n",
            f"            # Tailscale: Headscale-Zugang erlauben (vor Management-DROP)\n"
            f"            post-up   iptables -A FORWARD -i {bridge} -d {HEADSCALE_LXC_IP} -p tcp --dport {HEADSCALE_PORT} -j ACCEPT -m comment --comment openclaw-user-{u}-headscale\n"
            f"            # Isolation: Management-Netz (192.168.10.0/24) → DROP\n"
            f"            post-up   iptables -A FORWARD -i {bridge} -d 192.168.10.0/24 -j DROP -m comment --comment openclaw-user-{u}-mgmt\n"
        )

    proxmox._ssh_run(
        f"grep -q 'auto {bridge}' /etc/network/interfaces || "
        f"printf '%s' '{iface_block}' >> /etc/network/interfaces"
    )
    # Bridge aktivieren (idempotent)
    proxmox._ssh_run(f"ifup {bridge} 2>/dev/null || ip link set {bridge} up 2>/dev/null || true")
    return bridge


def destroy_bridge(user_id: int, proxmox) -> None:
    """
    Entfernt vmbr{user_id} und alle zugehörigen iptables-Regeln.
    Schlägt nicht fehl wenn Bridge nicht existiert.
    """
    _, _, bridge = get_user_network(user_id)
    proxmox._ssh_run(f"ifdown {bridge} 2>/dev/null || true")
    # Netzwerk-Konfiguration aus /etc/network/interfaces entfernen
    proxmox._ssh_run(
        f"python3 -c \""
        f"import re; "
        f"content = open('/etc/network/interfaces').read(); "
        f"cleaned = re.sub(r'\\nauto {bridge}.*?(?=\\nauto |\\Z)', '', content, flags=re.DOTALL); "
        f"open('/etc/network/interfaces', 'w').write(cleaned)"
        f"\" 2>/dev/null || true"
    )
    # iptables-Regeln mit User-Kommentar entfernen
    proxmox._ssh_run(
        f"iptables-save | grep -v 'openclaw-user-{user_id}' | iptables-restore 2>/dev/null || true"
    )
