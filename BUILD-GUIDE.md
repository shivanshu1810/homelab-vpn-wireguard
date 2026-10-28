# Build Guide — WireGuard Homelab VPN

Follow this top to bottom. Each section ends with a **✅ Checkpoint** — don't
move on until it passes. If something fails, jump to
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**The design you'll build**

| Thing | Value used in this guide |
|---|---|
| Server | Linux VM (Ubuntu Server), hostname `vpn.lab.local` |
| Server LAN IP | `192.168.1.50` (example — use your server's real LAN IP) |
| Tunnel subnet | `10.8.0.0/24` |
| Server tunnel IP | `10.8.0.1` |
| First client tunnel IP | `10.8.0.2` |
| WireGuard port | `51820` UDP |
| Server config file | `/etc/wireguard/wg0.conf` |

> Examples use the 192.168.1.x home LAN. If your LAN is different
> (192.168.0.x, 10.0.0.x…), substitute your own ranges everywhere.

---

## Step 0 — Prepare the lab server VM

1. Create a small Linux VM (Ubuntu Server LTS is a good choice):
   1–2 vCPU, 1–2 GB RAM, 10–20 GB disk is plenty.
2. **Networking matters:** set the VM's network adapter to **Bridged** mode
   (VirtualBox/Hyper-V/VMware all offer this) so the VM gets its own IP on
   your home LAN, like a real machine. NAT mode inside the hypervisor will
   make the port-forward step much harder.
3. Give the VM a **static LAN IP** (or a DHCP reservation in your router).
   This guide uses `192.168.1.50`.
4. Set the hostname (optional but tidy):
   ```bash
   sudo hostnamectl set-hostname vpn.lab.local
   ```
5. Update the OS:
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

**✅ Checkpoint:** from another device on your LAN, `ping 192.168.1.50`
(use your IP) answers, and you can SSH into the VM.

---

## Step 1 — Install WireGuard on the server

```bash
sudo apt install -y wireguard
```

This gives you the `wg` and `wg-quick` tools.

**✅ Checkpoint:** `wg --version` prints a version number.

---

## Step 2 — Generate the server keys

WireGuard authenticates with key pairs instead of passwords. Generate the
server's pair:

```bash
cd /etc/wireguard
sudo umask 077
sudo wg genkey | sudo tee server_private.key
sudo cat server_private.key | wg pubkey | sudo tee server_public.key
```

- `server_private.key` — **secret. Never share it, screenshot it, or commit
  it to git.**
- `server_public.key` — safe to share; clients need it.

View the public key (you'll need it for the client config later):

```bash
sudo cat /etc/wireguard/server_public.key
```

**✅ Checkpoint:** both files exist —
`ls -l /etc/wireguard/` shows `server_private.key` and `server_public.key`,
and the private key file has tight permissions (`-rw-------`).

---

## Step 3 — Write the server config (`wg0.conf`)

Create `/etc/wireguard/wg0.conf`. This guide uses **iptables NAT** — one
clear path, used in the template in `configs/server-wg0.conf.template`.

First, find your server's LAN network interface name:

```bash
ip route | grep default
```

It prints something like `default via 192.168.1.1 dev eth0 ...` — the name
after `dev` (often `eth0` or `ens33`) is your interface. Use it in the
`PostUp`/`PostDown` lines below.

Now write the config. Replace `<SERVER_PRIVATE_KEY>` with the contents of
`server_private.key`, and `eth0` with your interface if different:

```bash
sudo nano /etc/wireguard/wg0.conf
```

```ini
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <SERVER_PRIVATE_KEY>

# NAT: let tunnel clients reach the LAN and the internet via this server
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# Peers (clients) are added in Step 6 — one [Peer] block each.
```

Lock the file down (it contains a private key):

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
```

**✅ Checkpoint:** `sudo cat /etc/wireguard/wg0.conf` shows your real server
private key in place of the placeholder, the correct interface name, and no
typos. (`%i` in the PostUp lines is normal — wg-quick replaces it with the
interface name, `wg0`.)

---

## Step 4 — Enable IP forwarding

The server must be allowed to pass packets between the tunnel and the LAN:

```bash
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wireguard.conf
sudo sysctl -p /etc/sysctl.d/99-wireguard.conf
```

**✅ Checkpoint:** the second command prints `net.ipv4.ip_forward = 1`.

(If your server also runs a firewall like `ufw`, allow the port:
`sudo ufw allow 51820/udp`.)

---

## Step 5 — Start WireGuard and make it start on boot

```bash
sudo systemctl enable --now wg-quick@wg0
sudo wg show
```

**✅ Checkpoint:** `wg show` prints an `interface: wg0` block with
`listening port: 51820`. `systemctl status wg-quick@wg0` shows **active**.

---

## Step 6 — Create the first client peer

Each device gets its **own** key pair and tunnel IP. Create the client keys
on the server (you'll move the *client config* to the device in Step 8;
writing keys down anywhere else is a leak — see the warning in the
PowerShell script).

```bash
cd /etc/wireguard
sudo wg genkey | sudo tee client1_private.key
sudo cat client1_private.key | wg pubkey | sudo tee client1_public.key
sudo cat client1_public.key     # you'll paste this into the server config
sudo cat client1_private.key    # you'll paste this into the client config
```

Now add the peer to the **server** config — append this block to
`/etc/wireguard/wg0.conf`, replacing the placeholder with the contents of
`client1_public.key`:

```ini
[Peer]
# client1 — phone / Windows PC
PublicKey = <CLIENT1_PUBLIC_KEY>
AllowedIPs = 10.8.0.2/32
```

Apply it without dropping the interface:

```bash
sudo wg syncconf wg0 <(sudo wg-quick strip wg0)
```

**✅ Checkpoint:** `sudo wg show` now lists one `peer:` block. It will say
nothing about a handshake yet — the client hasn't connected.

> **Shortcut for Windows users:** `scripts/New-WireGuardPeer.ps1` generates a
> key pair with the WireGuard for Windows tools and prints a ready-to-paste
> `[Peer]` block plus a client config draft, so you don't do this by hand for
> every new device.

---

## Step 7 — Port-forward 51820/UDP on the home router

This is how the internet reaches your server. Generic steps (every router's
menus differ slightly — look for "Port Forwarding", "Virtual Servers", or
"NAT" in the admin page, usually at `192.168.1.1`):

1. Log in to the router admin page.
2. Add a new port-forward rule:
   - **Service/Name:** `WireGuard`
   - **Protocol:** **UDP** (not TCP — WireGuard doesn't use TCP)
   - **External/WAN port:** `51820`
   - **Internal/LAN IP:** your server's LAN IP — `192.168.1.50` in this guide
   - **Internal port:** `51820`
3. Save/apply the rule.

**Dynamic DNS (important if your home IP changes):** most ISPs hand out a
public IP that changes from time to time. When it changes, your client config
(which points at the old IP) stops working. Fix it once, now:

1. Create a free DDNS hostname (e.g. Duck DNS, No-IP, or the DDNS built into
   many routers).
2. Enable the DDNS updater (in the router if it supports it, or the provider's
   update client on the server).
3. Use the **hostname** (e.g. `myhomelab.duckdns.org`) as the client
   `Endpoint` in Step 8 instead of a raw IP.

**✅ Checkpoint:** the rule exists in the router and points at the server's
LAN IP with UDP/51820. (You can't truly test it until the client connects
from outside — that's Step 9.)

> ⚠️ **CGNAT warning:** if your ISP puts you behind carrier-grade NAT, port
> forwarding will never work no matter how correct the rule is. Quick check:
> compare the "WAN/Internet IP" shown in your router's status page with the
> IP a "what is my IP" website shows. If they differ — or the WAN IP is in
> the `100.64.x.x`–`100.127.x.x` range — you're behind CGNAT. Options: ask
> your ISP for a public IP, or use a relay design (out of scope for this
> guide). See TROUBLESHOOTING.md.

---

## Step 8 — Install WireGuard on the client and import the config

### The client config

Create a file named e.g. `homelab.conf` with this content (a ready template
lives in `configs/client.conf.template`). Replace the placeholders:

```ini
[Interface]
PrivateKey = <CLIENT1_PRIVATE_KEY>
Address = 10.8.0.2/32
# DNS = 192.168.1.1        # optional: use your home router/LAN DNS over the tunnel

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
Endpoint = <HOME_PUBLIC_IP_OR_DDNS_HOSTNAME>:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
```

- `AllowedIPs = 10.8.0.0/24` = **split tunnel**: only lab traffic goes
  through the tunnel; the client's normal internet traffic stays direct.
  Change it to `0.0.0.0/0` later if you want a **full tunnel** (all traffic
  via home).
- `PersistentKeepalive = 25` keeps NAT mappings alive so the tunnel survives
  idle periods — important for clients behind home routers/phones.

### Windows client

1. Install **WireGuard for Windows** from
   [wireguard.com/install](https://www.wireguard.com/install/).
2. Open it → **Import tunnel(s) from file** → pick `homelab.conf`.
3. Click **Activate**.

### Phone client (fastest way to test "remote")

1. Install the **WireGuard** app (App Store / Google Play).
2. On the server, turn the config into a QR code:
   ```bash
   sudo apt install -y qrencode
   qrencode -t ansiutf8 < /path/to/homelab.conf
   ```
   (or build the file from the template values and QR that file).
3. In the app: **+ → Create from QR code** → scan → name it → save.

**✅ Checkpoint:** the tunnel shows in the client app, and **turn off Wi-Fi
on the phone / disconnect the Windows client from home Wi-Fi** so you're
truly testing from "outside" (mobile data or another network) in Step 9.

---

## Step 9 — VERIFY the connection (the important part)

Do these in order:

1. **Handshake.** On the server:
   ```bash
   sudo wg show
   ```
   The peer should show `latest handshake: 12 seconds ago` (any recent time)
   and growing `transfer:` counters. A handshake within the last ~2 minutes =
   the tunnel is alive.

   On Windows, the client app shows handshake/transfer in the tunnel status.

2. **Ping the server's tunnel IP** from the client:
   ```
   ping 10.8.0.1
   ```
   Replies = routing works end to end.

3. **Use a lab service through the tunnel.** From the client, try something
   real:
   - RDP to the server/LAN machine by its tunnel or LAN IP, or
   - browse a file share, e.g. `\\10.8.0.1\<sharename>` or the lab machine's
     LAN IP (works because the server NATs/forward tunnel traffic onto the
     LAN), or
   - open a service you run in the lab (a test web page, NAS UI, etc.).

4. **Speed check.** Run a normal speed test from the client with the tunnel
   ON (full-tunnel mode) or copy a large file from a lab share and watch the
   rate. On a typical home connection this lab lands around **~90+ Mbps**
   through the tunnel (your uplink speed is the usual ceiling).

**✅ Final checkpoint:** recent handshake in `wg show` ✅, ping to `10.8.0.1`
✅, a real service used through the tunnel ✅. **The lab works.** 🎉

---

## Step 10 — Tidy up and make it a habit

- Restart the server once and confirm the tunnel reconnects by itself
  (that's `systemctl enable` doing its job).
- Delete the temporary copy of the client config from anywhere public
  (downloads folders get synced — the config contains a private key).
- Back up `/etc/wireguard/` somewhere secure and offline.
- Adding another device? Repeat Step 6 with the next tunnel IP
  (`10.8.0.3`, `.4`, …) and a fresh key pair — or use
  `scripts/New-WireGuardPeer.ps1`. Never reuse a peer config on two devices.

## If it doesn't work

Work through **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — it's organised
by the exact symptoms you'll see ("handshake never completes", "connected
but nothing loads", and so on), in helpdesk format.
