# Troubleshooting — Helpdesk VPN Playbook

The issues below are the ones real VPN users report every day — learning to
fix them is half the value of this lab. Each one is written the helpdesk way:

**Symptom → Likely cause → Fix → Verify**

Golden rule before anything else: check the **handshake**.

- On the server: `sudo wg show` — look for `latest handshake:` on the peer.
  - **Recent handshake (under ~2 minutes)** = tunnel is up; the problem is
    routing, DNS, or the service you're reaching for.
  - **No handshake at all** = the client's packets never got authenticated —
    think port forward, endpoint, firewall, keys.
- Also check `transfer:` counters are moving when you generate traffic.

---

## 1. "Connected but nothing loads"

**Symptom:** The client app says the tunnel is active and the handshake is
recent, but no lab page, share, or RDP session will open.

**Likely causes:**

- `AllowedIPs` on the **client** doesn't include the network you're trying to
  reach (e.g. you set `10.8.0.0/24` but the service lives on the LAN at
  `192.168.1.x`, or the server isn't NATing/forwarding tunnel traffic).
- `AllowedIPs` on the **server's** `[Peer]` block is wrong — the server
  drops the client's packets because their source address isn't allowed.
- IP forwarding is off on the server, or the NAT (MASQUERADE) rule is missing.
- The target service itself is down or firewalled on the LAN machine.

**Fix:**

1. Confirm the server peer block says `AllowedIPs = 10.8.0.2/32` (the
   client's exact tunnel IP) for this device.
2. On the client, make sure `AllowedIPs` covers what you're reaching for:
   `10.8.0.0/24` for tunnel-side services; add your LAN range or use a full
   tunnel (`0.0.0.0/0`) as a **test** — if full tunnel works, it was a
   routing/`AllowedIPs` scope issue.
3. On the server, confirm forwarding is on:
   `sysctl net.ipv4.ip_forward` must print `1`. If not, redo Step 4 of the
   build guide.
4. Confirm the NAT rules appear when the tunnel is up:
   `sudo iptables -t nat -L POSTROUTING -v` should list a `MASQUERADE` rule —
   if not, your `PostUp` line has a typo or the wrong interface name
   (check with `ip route | grep default`).

**Verify:** from the client, `ping 10.8.0.1` (server tunnel IP) works, then
ping/reach the actual LAN service. Generate traffic and watch `transfer:`
grow in `wg show`.

---

## 2. Handshake never completes

**Symptom:** Tunnel "activates" on the client, but `wg show` on the server
shows the peer with **no `latest handshake`** and `0 B received`.

**Likely causes:**

- The **port forward** is missing/wrong: protocol not UDP, wrong internal IP,
  or wrong port (it's **51820/UDP**, end to end).
- The client's `Endpoint` is wrong — outdated public IP (no DDNS), typo, or
  wrong port.
- Keys are mismatched: the public key in the server's `[Peer]` block isn't
  the pair of the private key in the client config (very common when juggling
  several peers).
- A firewall on the server is dropping UDP 51820 (`ufw`, cloud-style rules).
- The server's WireGuard service isn't actually running.
- **ISP CGNAT** — port forwarding cannot work at all (see below).

**Fix:**

1. Server first: `sudo systemctl status wg-quick@wg0` (active?) and
   `sudo wg show` (interface `wg0` up, `listening port: 51820`?).
2. Re-check the router rule: **UDP**, external 51820 → server LAN IP,
   internal 51820. Reboot-level mistakes happen; delete and re-add the rule
   if unsure.
3. Check the endpoint from the client side: browse a "what is my IP" site
   from home and compare it with the client's `Endpoint` (or confirm your
   DDNS hostname resolves to it: `nslookup yourname.duckdns.org`).
4. Compare keys: the `PublicKey` in the server's peer block must equal the
   public key derived from the client's private key. When in doubt, generate
   a **fresh pair** for that device (see `scripts/New-WireGuardPeer.ps1`) and
   replace the peer block — 2 minutes, removes all doubt.
5. If you run `ufw`: `sudo ufw allow 51820/udp`.

**Verify:** activate the tunnel on a client that is **off** the home Wi-Fi
(mobile data) and watch `sudo wg show` — a `latest handshake` timestamp and
non-zero `transfer:` should appear within seconds.

### The CGNAT trap (check this early if nothing works)

**Check:** router's status page shows a WAN/Internet IP. A "what is my IP"
website shows a *different* address — or the WAN IP falls in
`100.64.0.0`–`100.127.255.255`. **Cause:** your ISP uses carrier-grade NAT;
your router isn't actually on the public internet, so no port forward can
reach it. **Fix:** ask the ISP for a public/dynamic IP (sometimes free,
sometimes a small fee or a business plan), or redesign around an outbound
relay/VPS (out of scope for this guide). No router setting fixes CGNAT.

---

## 3. Handshake works, then the tunnel "drops" when idle

**Symptom:** Everything works right after connecting, but after some minutes
of inactivity the tunnel silently stops passing traffic until you toggle it
off/on.

**Likely cause:** NAT/firewall state on the client's network times out.
WireGuard is quiet when idle, so middleboxes forget the mapping — and the
server's replies then have nowhere to go. One-way street: the client can
usually "wake it" by sending traffic, but push/return traffic stalls.

**Fix:**

1. Add (or confirm) in the **client** config:
   ```ini
   PersistentKeepalive = 25
   ```
   This sends a tiny packet every 25 seconds to keep the mapping alive.
2. On phones, also check battery settings: aggressive battery savers that
   freeze the WireGuard app can produce the same symptom — exempt the app.
3. If the client is a laptop, check sleep settings: a sleeping machine has
   no tunnel; on wake, give it a few seconds to re-handshake before judging.

**Verify:** connect, use the tunnel, then leave it idle for 10–15 minutes
and use it again **without** toggling — traffic should flow immediately,
and `wg show` should show a recent handshake.

---

## 4. DNS not resolving over the tunnel

**Symptom:** IP addresses work (`ping 10.8.0.1`, browsing by IP is fine) but
names — especially lab names like `vpn.lab.local` or LAN hostnames — fail
to resolve when the tunnel is up (or all name resolution breaks).

**Likely causes:**

- The client config has no `DNS =` line, so the client keeps using the
  remote network's DNS, which knows nothing about your lab names.
- The `DNS =` line points at a server the tunnel can't reach (wrong IP, or
  not covered by `AllowedIPs`).
- Split-tunnel subtlety: a DNS server on the LAN (e.g. `192.168.1.1`) needs
  its traffic routed into the tunnel; with `AllowedIPs = 10.8.0.0/24` only,
  queries to `192.168.1.1` go direct and fail/return nothing useful when
  remote.

**Fix:**

1. Set DNS explicitly in the client `[Interface]`:
   ```ini
   DNS = 192.168.1.1
   ```
   (use your router or LAN DNS server's real IP).
2. Make sure that DNS IP is reachable through the tunnel: either add the LAN
   range to the client's `AllowedIPs` (e.g. `AllowedIPs = 10.8.0.0/24,
   192.168.1.0/24`), or test with a full-tunnel `0.0.0.0/0` config.
3. Confirm the DNS server actually answers tunnel clients (some routers only
   serve their "own" LAN subnet — the server's NAT/MASQUERADE normally makes
   tunnel traffic look LAN-local, which is why the guide's design works).

**Verify:** with the tunnel up, `nslookup vpn.lab.local 192.168.1.1` (or the
name of any LAN device) returns an answer, and browsing by name works.

---

## 5. Slow speeds over the tunnel

**Symptom:** The tunnel works, but throughput is far below expectations or
file copies crawl.

**Likely causes:**

- **Home upload speed is the ceiling.** From outside, "download" through
  your home = your home connection's *upload*. Many plans are asymmetric
  (e.g. 1 Gbps down / 30 Mbps up → the tunnel can never exceed ~30 Mbps in
  that direction).
- **Wi-Fi problems** on either end (weak signal, congested 2.4 GHz band).
- **MTU mismatch** — a classic: large packets get fragmented/dropped on some
  paths, showing up as "small things load, big things stall" as much as raw
  slowness. WireGuard's default MTU (usually 1420) occasionally needs
  lowering on PPPoE/DSL or double-NAT setups.
- The server VM is starved (1 vCPU shared with a busy host) — less common;
  WireGuard is light and ChaCha20 is fast even without AES hardware help.

**Fix:**

1. Measure the baseline: run a speed test at home (no VPN) and note **upload**
   — that's your tunnel's realistic max from outside. The reference build for
   this lab showed **~94 Mbps** through the tunnel on a connection whose
   upload allowed it.
2. Test wired vs Wi-Fi on the client and, if possible, near the router —
   if wired is fast, it's a Wi-Fi issue, not a VPN issue.
3. If big transfers stall while pings/web snippets work, try lowering MTU
   on the client `[Interface]`:
   ```ini
   MTU = 1280
   ```
   If that fixes the stall, you can walk it up (1380, 1400…) to find the
   best value. (MTU tuning is also the first fix to try for "some sites load,
   others hang" in issue #1.)

**Verify:** repeat the same speed test / file copy and compare. Consistent
speed near the home-upload ceiling = healthy tunnel.

---

## Quick reference — first three checks for ANY VPN ticket

1. **Handshake?** `sudo wg show` → `latest handshake` recent?
2. **Right network path?** Port forward (51820/UDP), endpoint/DDNS current,
   client testing from *outside* the LAN?
3. **Routing scope?** `AllowedIPs` on both ends covers what the user is
   trying to reach?

Those three questions resolve the large majority of "the VPN is broken"
reports — in this lab, and on a real service desk.
