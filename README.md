# Homelab VPN — WireGuard Remote Access Lab

A beginner-friendly homelab project that builds a **real, working VPN** with
[WireGuard](https://www.wireguard.com/) — the same technology behind a lot of
modern remote-access setups — so a "remote user" (your phone or a second PC)
can tunnel securely into a home lab and use its services as if they were
sitting on the home network.

> **Honest note:** This is a self-directed homelab learning project, built at
> home on personal equipment to practise VPN and remote-access skills. It is
> not production work for an employer, and nothing in this repo is connected
> to any real company network.

---

## What this project is

You build a small VPN:

- A lab **server** (hostname `vpn.lab.local`) runs the WireGuard service.
- A **client** (a Windows PC or a phone) connects in from "outside" — for
  example, on mobile data or a coffee-shop Wi-Fi.
- The client and server complete a **WireGuard handshake** (you can watch the
  peer show as connected, with a "latest handshake" timestamp).
- All traffic between them travels inside an encrypted tunnel using
  **ChaCha20** encryption (WireGuard's built-in cipher — there is nothing to
  configure, it is always on).
- Once connected, the client can reach the lab server at its **tunnel IP**
  (`10.8.0.1`) — ping it, RDP into it, open a file share — exactly like real
  remote-access support work.

In testing, a tunnel like this on a typical home connection runs at roughly
**~90+ Mbps** — fast enough that remote work over it feels normal.

## Why it matters (the job angle)

Every hybrid workplace runs on VPN, and **the helpdesk owns those tickets**:
"VPN won't connect", "connected but nothing loads", "it worked yesterday".
This lab teaches you to build the thing you're supporting, which makes those
tickets far easier:

- You learn what a **handshake** is and how to check it (`wg show`).
- You learn why a tunnel can be "connected" but still pass no traffic
  (routing and `AllowedIPs`).
- You learn the classic home-network gotchas: **port forwarding**, **NAT**,
  **dynamic DNS**, and **CGNAT**.
- You get a troubleshooting playbook (see `TROUBLESHOOTING.md`) written the
  way a service desk actually works: symptom → cause → fix → verify.

## Design (in words)

```
  Remote client                     Home network
  (phone / laptop)                    ┌──────────────────────────────────┐
        │                             │                                  │
        │   encrypted WireGuard       │   Lab server (Linux VM)          │
        │   tunnel over the           │   hostname: vpn.lab.local        │
        │   internet                  │   WireGuard: wg0, 10.8.0.1       │
        ▼                             │   LAN IP: 192.168.1.50 (example)  │
  ┌────────────┐    UDP 51820    ┌────┴─────────┐                        │
  │  Internet  ├────────────────►│  Home router │  port forward          │
  └────────────┘                 │              │  51820/UDP ────────┐   │
                                 └──────────────┘                  ▼   │
                                 │                     WireGuard server │
                                 │                     + lab services   │
                                 └──────────────────────────────────┘
```

- The client starts the connection to the home router's public IP (or DDNS
  hostname) on **UDP port 51820**.
- The router **forwards 51820/UDP** to the lab server — the only inbound hole
  in the home firewall.
- WireGuard authenticates the client by its **key pair** (no usernames or
  passwords), builds the tunnel, and the client gets tunnel IP `10.8.0.2`.
- Tunnel traffic uses its own subnet, **10.8.0.0/24**, kept separate from the
  home LAN (192.168.1.0/24 in the examples).

## Skills demonstrated

- WireGuard installation and configuration on Linux (`wg`, `wg-quick`)
- Public/private key authentication and peer management
- Linux networking: IP forwarding, NAT (iptables MASQUERADE), systemd services
- Router administration: UDP port forwarding, dynamic DNS (DDNS)
- Client setup on Windows and mobile (including QR-code provisioning)
- Structured troubleshooting: handshakes, routing, DNS, MTU, NAT timeouts
- Documentation and security hygiene (key handling, least-exposure design)

## What you need

| Item | Notes |
|---|---|
| WireGuard | Free — [wireguard.com/install](https://www.wireguard.com/install/) |
| Lab server | A small **Linux VM** (Ubuntu Server works great) on your home PC — e.g. in VirtualBox, Hyper-V, or VMware. This guide uses the Linux VM as the primary server path because it is the most reliable and the most common way WireGuard is run. |
| Remote client | Your **phone** (WireGuard app, QR-code setup) and/or a **second Windows PC** with the WireGuard for Windows app. |
| Home router access | You need to be able to add one port-forward rule (51820/UDP). |
| Optional | A free dynamic DNS hostname (e.g. Duck DNS or No-IP) if your home IP changes. |

**Two server options exist** — the *WireGuard for Windows* app can also act
as a server, and a Linux box/VM can too. **This project uses the Linux VM as
the server** (most reliable, best documented, and the setup you'll meet most
often in real jobs), with Windows and phones as clients.

## Repo structure

```
homelab-vpn-wireguard/
├── README.md                          ← you are here
├── BUILD-GUIDE.md                     ← full step-by-step build
├── TROUBLESHOOTING.md                 ← helpdesk-style VPN playbook
├── configs/
│   ├── server-wg0.conf.template       ← server config template (placeholders)
│   └── client.conf.template           ← client config template (placeholders)
└── scripts/
    └── New-WireGuardPeer.ps1          ← PowerShell helper: make a new peer
```

## Security notes — read before you build

- **Never publish private keys.** Not in this repo, not in screenshots, not in
  chat. A private key *is* the credential — anyone who has it can connect as
  that device. The templates in this repo contain placeholders only. If a
  private key ever leaks, delete that peer and generate a fresh key pair.
- **Keep the tunnel subnet separate from the LAN.** The tunnel uses
  `10.8.0.0/24` while the LAN stays on its own range. This keeps VPN traffic
  clearly separated, makes routing rules easy to reason about, and limits
  what a tunnel client can reach.
- **Only forward 51820/UDP.** That is the single inbound opening this design
  needs. WireGuard is silent to unauthenticated packets, so the port does not
  respond to scans — but still, forward nothing else "just in case".
- **`AllowedIPs` is the steering wheel.** On the server, a peer's
  `AllowedIPs = 10.8.0.2/32` means "this peer is allowed to send from that
  one tunnel address". On the client, `AllowedIPs` decides what traffic goes
  *into* the tunnel: `10.8.0.0/24` sends only lab traffic through (split
  tunnel); `0.0.0.0/0` sends *everything* through (full tunnel). Most
  "connected but nothing loads" tickets are an `AllowedIPs` mistake.
- Give **every device its own peer and key pair** — never share one config
  across devices. If a phone is lost, you remove one peer and nothing else
  changes.
- Keep WireGuard and the server OS updated, and back up your configs
  (securely — they contain keys) before you change them.

## Where to go next

1. Follow **[BUILD-GUIDE.md](BUILD-GUIDE.md)** top to bottom.
2. Keep **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** open while you test —
   you *will* hit at least one of those issues, and fixing it is the learning.
3. Use `scripts/New-WireGuardPeer.ps1` to add a second device once the first
   one works.
