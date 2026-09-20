#!/bin/bash
# Samba 4 AD DC entrypoint for Apple `container`, as SheepRadius drives it.
#
# Contract:
#   * state lives in /var/lib/samba  (a named ext4 volume is mounted there — a virtiofs
#     bind mount of a macOS folder is case-insensitive and Samba cannot survive that)
#   * smb.conf is kept in the state volume and symlinked to /etc/samba/smb.conf, so
#     rebuilding the image never loses settings
#   * HOST_IP is the *Mac's* current LAN address; every start re-points the DC's DNS at it
#     so LAN clients are handed an address they can actually reach
#   * TLS_{CERT,KEY,CA}_B64, when present, are PEM files from the app's own test CA; they
#     travel as environment variables rather than a mount for the same case-sensitivity
#     reason as the state volume
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REALM="${REALM:-LAB.SHEEP}"
DOMAIN="${DOMAIN:-LABSHEEP}"
DCNAME="${DCNAME:-dc1}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
DNS_FORWARDER="${DNS_FORWARDER:-1.1.1.1}"
RPC_PORT_RANGE="${RPC_PORT_RANGE:-49152-49172}"
REQUIRE_STRONG_AUTH="${REQUIRE_STRONG_AUTH:-no}"
HOST_IP="${HOST_IP:-}"

STATE=/var/lib/samba
CONF_DIR="$STATE/etc"
CONF="$CONF_DIR/smb.conf"
TLS_DIR="$STATE/tls"

log() { echo "[entrypoint] $*"; }

mkdir -p "$CONF_DIR"
hostname "$DCNAME" 2>/dev/null || true

# ---------------------------------------------------------------- provisioning
# Only ever when there is no domain here. An existing volume is ADOPTED: it holds the
# machine accounts of every device that has joined, and re-provisioning would throw them
# away while looking like a successful start.
if [ ! -f "$STATE/private/sam.ldb" ]; then
    [ -n "$ADMIN_PASSWORD" ] || { log "no ADMIN_PASSWORD and no existing domain — refusing to provision"; exit 1; }
    log "no sam.ldb in $STATE -> provisioning realm $REALM (netbios $DOMAIN)"
    rm -f /etc/samba/smb.conf
    PROV_HOST_IP_ARG=()
    [ -n "$HOST_IP" ] && PROV_HOST_IP_ARG=(--host-ip="$HOST_IP")
    samba-tool domain provision \
        --server-role=dc \
        --use-rfc2307 \
        --dns-backend=SAMBA_INTERNAL \
        --realm="$REALM" \
        --domain="$DOMAIN" \
        --host-name="$DCNAME" \
        "${PROV_HOST_IP_ARG[@]}" \
        --adminpass="$ADMIN_PASSWORD" \
        --option="interfaces=lo eth0" \
        --option="bind interfaces only=no"
    cp /etc/samba/smb.conf "$CONF"
    log "provision complete"
else
    log "existing domain found in $STATE (adopted, not reprovisioned)"
fi

if [ ! -f "$CONF" ] && [ -f /etc/samba/smb.conf ]; then cp /etc/samba/smb.conf "$CONF"; fi
rm -f /etc/samba/smb.conf
ln -sf "$CONF" /etc/samba/smb.conf

# ------------------------------------------------------------- smb.conf tuning
set_param() {  # set_param <section> <key> <value>
    python3 - "$CONF" "$1" "$2" "$3" <<'PY'
import sys, re
path, section, key, value = sys.argv[1:5]
lines = open(path).read().splitlines()
out, in_sec, done = [], False, False
sec_re = re.compile(r'^\s*\[(.+)\]\s*$')
for ln in lines:
    m = sec_re.match(ln)
    if m:
        if in_sec and not done:
            out.append(f"\t{key} = {value}"); done = True
        in_sec = (m.group(1).lower() == section.lower())
        out.append(ln); continue
    if in_sec and re.match(r'^\s*' + re.escape(key) + r'\s*=', ln, re.I):
        if not done:
            out.append(f"\t{key} = {value}"); done = True
        continue
    out.append(ln)
if not done:
    if in_sec:
        out.append(f"\t{key} = {value}")
    else:
        out.append(f"[{section}]"); out.append(f"\t{key} = {value}")
open(path, 'w').write("\n".join(out) + "\n")
PY
}

set_param global "dns forwarder"                  "$DNS_FORWARDER"
set_param global "rpc server dynamic port range"  "$RPC_PORT_RANGE"
# Lab NAC appliances (Aruba ClearPass et al.) frequently do a *simple* bind, and some do it
# over plain 389, which Samba refuses by default. The app exposes this as a toggle with the
# warning it deserves: "no" means a bind password can cross the LAN in the clear.
set_param global "ldap server require strong auth" "$REQUIRE_STRONG_AUTH"
# NetBIOS/WINS is not needed by modern AD clients; disabling frees 137-139.
set_param global "disable netbios"                 "yes"
set_param global "smb ports"                       "445"
set_param global "server services"                 "-nbt"
# samba_dnsupdate would re-register the *container's* private IP on every start; the A
# records are managed against HOST_IP by fix-dns.sh instead.
set_param global "dns update command"              "/bin/true"
set_param global "nsupdate command"                "/bin/true"
set_param global "bind interfaces only"            "no"
# The authentication log, and the whole reason for image tag :3.
#
# Samba's stock `log level = 1` records **no authentication at all** — not a successful logon,
# not a wrong password, nothing. On 18 Sep 2026 that was what "I don't see the log in the app"
# meant: the DC was genuinely silent, and the coordinator had to turn the class on by hand with
# `smbcontrol all debug`, which is lost on the next restart. `auth_audit:3` is what produces the
# `Auth: [...] status [NT_STATUS_...]` lines the app parses into Status ▸ Recent authentications.
#
# `ldap_server:10` was on alongside it that afternoon and is deliberately NOT here: it prints
# every search a NAC makes, and iMaster NCE-Campus polls every thirty seconds, so it buries the
# authentication it was turned on to show.
set_param global "log level"                       "${SAMBA_LOG_LEVEL:-1 auth_audit:3}"
# NTLM for NAC boxes.
#
# Samba's default is `ntlmv2-only`, which refuses a bare MSCHAPv2 Netlogon request. A NAC doing
# PEAP-MSCHAPv2 — Huawei iMaster NCE-Campus, Aruba ClearPass — asks the DC over Netlogon with
# exactly that, so the default can turn a correct password into NT_STATUS_NTLM_BLOCKED for
# reasons nothing in the NAC's own log mentions. Measured on this domain on 18 Sep 2026: it was
# **not** the cause of the failure being chased that day (that was a genuine wrong password),
# but it is the right setting for a DC a NAC authenticates against, so it is set here rather
# than left to be rediscovered.
set_param global "ntlm auth"                       "mschapv2-and-ntlmv2-only"

# ------------------------------------------------------------------------- TLS
# LDAPS on 636 (and the GC on 3269) with a leaf from the app's own test CA, so a device that
# already trusts this lab's CA for RADIUS and OpenLDAP needs nothing new.
if [ -n "${TLS_CERT_B64:-}" ] && [ -n "${TLS_KEY_B64:-}" ]; then
    mkdir -p "$TLS_DIR"
    printf '%s' "$TLS_CERT_B64" | base64 -d > "$TLS_DIR/cert.pem"
    printf '%s' "$TLS_KEY_B64"  | base64 -d > "$TLS_DIR/key.pem"
    [ -n "${TLS_CA_B64:-}" ] && printf '%s' "$TLS_CA_B64" | base64 -d > "$TLS_DIR/ca.pem"
    chmod 700 "$TLS_DIR"; chmod 600 "$TLS_DIR"/*.pem
    set_param global "tls enabled"  "yes"
    set_param global "tls certfile" "$TLS_DIR/cert.pem"
    set_param global "tls keyfile"  "$TLS_DIR/key.pem"
    [ -f "$TLS_DIR/ca.pem" ] && set_param global "tls cafile" "$TLS_DIR/ca.pem"
    log "TLS configured from the lab CA ($(openssl x509 -in "$TLS_DIR/cert.pem" -noout -subject 2>/dev/null || echo 'subject unknown'))"
else
    log "no TLS material supplied; Samba will use its self-signed certificate"
fi

cp -f "$STATE/private/krb5.conf" /etc/krb5.conf 2>/dev/null || true

# ------------------------------------------------------- DNS re-point on start
if [ -n "$HOST_IP" ]; then
    ( /usr/local/sbin/fix-dns.sh >>/var/log/fix-dns.log 2>&1 ) &
fi

# Wait for eth0's SLAAC IPv6 address to leave DAD/tentative state. Samba enumerates every
# address at startup and dies with
#   "Failed to bind to ipv6:... - NT_STATUS_ADDRESS_NOT_ASSOCIATED"
# if it races duplicate-address-detection. Seen about one start in five.
for i in $(seq 1 30); do
    if ip -6 addr show dev eth0 2>/dev/null | grep -q 'scope global' \
       && ! ip -6 addr show dev eth0 2>/dev/null | grep -q tentative; then
        break
    fi
    sleep 1
done

log "starting samba (realm=$REALM host_ip=${HOST_IP:-unset})"
exec /usr/sbin/samba -i --debug-stdout
