<#
.SYNOPSIS
    Generates a new WireGuard peer (key pair) for the homelab VPN and prints
    a ready-to-paste [Peer] block for the server plus a client .conf draft.

.DESCRIPTION
    Helper for the homelab-vpn-wireguard project. It uses wg.exe from the
    WireGuard for Windows installation to create a fresh key pair for a new
    device, then prints:

      1. A [Peer] block to paste into the server's wg0.conf
         (afterwards run:  sudo wg syncconf wg0 <(wg-quick strip wg0)
          on the server, or restart wg-quick@wg0).
      2. A draft client config the device can import.

    The script only PRINTS text. It does not change any server, write any
    config file, or connect anywhere.

    ************************************************************************
    ***  WARNING — PRIVATE KEYS ARE PASSWORDS.                           ***
    ***  The output of this script contains a PRIVATE KEY.               ***
    ***  NEVER share it, screenshot it, email it, or commit it to git.   ***
    ***  If a private key leaks, remove that peer and generate a new one.***
    ************************************************************************

.PARAMETER PeerName
    A friendly label for the device, e.g. "phone" or "laptop".
    Letters, numbers, dashes and underscores only. Used in comments and in
    the suggested client file name.

.PARAMETER TunnelIP
    The tunnel IP to assign to this peer, e.g. 10.8.0.3
    Must be inside the tunnel subnet (10.8.0.0/24 in this project), must not
    be the server's address (10.8.0.1), and must not be used by another peer.

.PARAMETER ServerPublicKey
    Optional. The server's public key (contents of server_public.key).
    If supplied, the client draft is complete; if not, the draft shows a
    <SERVER_PUBLIC_KEY> placeholder to fill in.

.PARAMETER Endpoint
    Optional. The server endpoint as host:port, e.g. "myhomelab.duckdns.org:51820".
    Defaults to a placeholder in the client draft.

.EXAMPLE
    .\New-WireGuardPeer.ps1 -PeerName laptop -TunnelIP 10.8.0.3

.EXAMPLE
    .\New-WireGuardPeer.ps1 -PeerName phone -TunnelIP 10.8.0.4 `
        -ServerPublicKey "abc123...=" -Endpoint "myhomelab.duckdns.org:51820"

.NOTES
    Requires: WireGuard for Windows installed (provides wg.exe).
    Compatible with Windows PowerShell 5.1.
    Project: homelab-vpn-wireguard (self-directed homelab).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$PeerName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^10\.8\.0\.([2-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$')]
    [string]$TunnelIP,

    [Parameter(Mandatory = $false)]
    [string]$ServerPublicKey = "",

    [Parameter(Mandatory = $false)]
    [string]$Endpoint = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# 1. Find wg.exe (installed with WireGuard for Windows)
# --------------------------------------------------------------------------
$wgCandidates = @(
    (Join-Path $env:ProgramFiles 'WireGuard\wg.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'WireGuard\wg.exe')
)
$wg = $null
foreach ($candidate in $wgCandidates) {
    if ($candidate -and (Test-Path $candidate)) { $wg = $candidate; break }
}
if (-not $wg) {
    $cmd = Get-Command wg.exe -ErrorAction SilentlyContinue
    if ($cmd) { $wg = $cmd.Source }
}
if (-not $wg) {
    Write-Host ""
    Write-Host "ERROR: wg.exe was not found." -ForegroundColor Red
    Write-Host "This script needs the WireGuard for Windows tools:"
    Write-Host "  1. Install WireGuard from https://www.wireguard.com/install/"
    Write-Host "  2. Re-run this script afterwards."
    Write-Host "Nothing was generated."
    exit 1
}

# --------------------------------------------------------------------------
# 2. Loud private-key warning (shown before any key material exists)
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  WARNING: The output below contains a PRIVATE KEY." -ForegroundColor Yellow
Write-Host "  A private key is a password for that device." -ForegroundColor Yellow
Write-Host "  NEVER share it, screenshot it, email it, or commit it to git." -ForegroundColor Yellow
Write-Host "  If it ever leaks: remove the peer and generate a new key pair." -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host ""

# --------------------------------------------------------------------------
# 3. Generate the key pair with wg.exe
# --------------------------------------------------------------------------
$privateKey = (& $wg genkey) | Select-Object -First 1
if (-not $privateKey) {
    Write-Host "ERROR: wg.exe genkey did not return a key. Nothing was generated." -ForegroundColor Red
    exit 1
}
$privateKey = $privateKey.Trim()
$publicKey = ($privateKey | & $wg pubkey) | Select-Object -First 1
if (-not $publicKey) {
    Write-Host "ERROR: wg.exe pubkey did not return a key. Nothing was generated." -ForegroundColor Red
    exit 1
}
$publicKey = $publicKey.Trim()

# Fill placeholders for anything not supplied
if ([string]::IsNullOrWhiteSpace($ServerPublicKey)) {
    $ServerPublicKey = "<SERVER_PUBLIC_KEY>"
}
if ([string]::IsNullOrWhiteSpace($Endpoint)) {
    $Endpoint = "<HOME_PUBLIC_IP_OR_DDNS_HOSTNAME>:51820"
}

# --------------------------------------------------------------------------
# 4. Print the [Peer] block for the SERVER config
# --------------------------------------------------------------------------
Write-Host "----------------------------------------------------------------"
Write-Host "STEP 1 of 2 - Paste this block into the server's wg0.conf"
Write-Host "(/etc/wireguard/wg0.conf), then apply it on the server with:"
Write-Host "    sudo wg syncconf wg0 <(wg-quick strip wg0)"
Write-Host "----------------------------------------------------------------"
Write-Host ""
Write-Host "[Peer]"
Write-Host "# $PeerName"
Write-Host "PublicKey = $publicKey"
Write-Host "AllowedIPs = $TunnelIP/32"
Write-Host ""

# --------------------------------------------------------------------------
# 5. Print the CLIENT config draft
# --------------------------------------------------------------------------
Write-Host "----------------------------------------------------------------"
Write-Host "STEP 2 of 2 - Save the text below as '$PeerName.conf' and import"
Write-Host "it into the WireGuard app on the '$PeerName' device."
Write-Host "(Contains the PRIVATE KEY - handle like a password, see warning.)"
Write-Host "----------------------------------------------------------------"
Write-Host ""
Write-Host "[Interface]"
Write-Host "PrivateKey = $privateKey"
Write-Host "Address = $TunnelIP/32"
Write-Host ""
Write-Host "[Peer]"
Write-Host "PublicKey = $ServerPublicKey"
Write-Host "Endpoint = $Endpoint"
Write-Host "AllowedIPs = 10.8.0.0/24"
Write-Host "PersistentKeepalive = 25"
Write-Host ""
Write-Host "Done. After importing, activate the tunnel on the device and verify"
Write-Host "on the server with:  sudo wg show   (look for a recent handshake)."
