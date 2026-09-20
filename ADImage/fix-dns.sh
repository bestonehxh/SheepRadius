#!/bin/bash
# Make the DC advertise the Mac's current LAN address and NOTHING else.
#
# Why this is more than "set the A record": a LAN client that resolves the DC to the vmnet
# bridge address (192.168.64.1), to an IPv6 ULA, or to the address of a network the Mac has
# since left, cannot reach the DC at all — and the failure it reports never mentions DNS.
# During the real Windows 11 join it was `gc._msdcs` that was still pointing at a stale
# bridge address, long after everything else had been corrected by hand.
#
# So this does three things:
#   1. re-points the five names the DC owns at $HOST_IP (A),
#   2. deletes every AAAA on those names — the Mac's LAN service is IPv4 and an AAAA will be
#      preferred by a dual-stack client and then time out,
#   3. walks the whole zone and deletes any A/AAAA anywhere that is not $HOST_IP.
#
# Runs in the background from entrypoint.sh once samba is up.
set -uo pipefail

REALM_LC="$(echo "${REALM:-LAB.SHEEP}" | tr '[:upper:]' '[:lower:]')"
DCNAME_LC="$(echo "${DCNAME:-dc1}" | tr '[:upper:]' '[:lower:]')"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
HOST_IP="${HOST_IP:?HOST_IP required}"
CRED=(-U "Administrator%${ADMIN_PASSWORD}")
S=127.0.0.1

echo "=== fix-dns $(date -u +%FT%TZ) HOST_IP=$HOST_IP ==="

# Wait for the DNS server inside samba to answer.
for i in $(seq 1 90); do
    if samba-tool dns query $S "$REALM_LC" @ SOA "${CRED[@]}" >/dev/null 2>&1; then break; fi
    sleep 1
done

delete_record() {  # delete_record <zone> <name> <type> <value>
    samba-tool dns delete $S "$1" "$2" "$3" "$4" "${CRED[@]}" >/dev/null 2>&1 \
        && echo "deleted $2.$1 $3 $4"
}

repoint() {   # repoint <zone> <name>
    local zone="$1" name="$2" old
    # Every A that is not HOST_IP, including ones from networks the Mac has left.
    for old in $(samba-tool dns query $S "$zone" "$name" A "${CRED[@]}" 2>/dev/null \
                 | sed -n 's/.*A: \([0-9.]*\) .*/\1/p' | sort -u); do
        [ "$old" = "$HOST_IP" ] && continue
        delete_record "$zone" "$name" A "$old"
    done
    # Every AAAA, unconditionally: the published service is IPv4 only.
    for old in $(samba-tool dns query $S "$zone" "$name" AAAA "${CRED[@]}" 2>/dev/null \
                 | sed -n 's/.*AAAA: \([0-9a-fA-F:]*\) .*/\1/p' | sort -u); do
        delete_record "$zone" "$name" AAAA "$old"
    done
    if ! samba-tool dns query $S "$zone" "$name" A "${CRED[@]}" 2>/dev/null | grep -q "A: $HOST_IP"; then
        samba-tool dns add $S "$zone" "$name" A "$HOST_IP" "${CRED[@]}" >/dev/null 2>&1 \
            && echo "added   $name.$zone A $HOST_IP"
    fi
}

for n in "@" "$DCNAME_LC" "gc._msdcs" "DomainDnsZones" "ForestDnsZones"; do
    repoint "$REALM_LC" "$n"
done

# ---------------------------------------------------------------- zone sweep
# Anything left anywhere in the zone that does not answer $HOST_IP. `samba-tool dns query
# <zone> @ ALL` prints a "Name=<node>" header followed by that node's records.
echo "--- zone sweep ---"
samba-tool dns query $S "$REALM_LC" @ ALL "${CRED[@]}" 2>/dev/null | {
    node=""
    while IFS= read -r line; do
        case "$line" in
            *Name=*)
                node="${line#*Name=}"
                node="${node%%,*}"
                [ -z "$node" ] && node="@"
                ;;
            *"A: "*|*"AAAA: "*)
                type=A
                case "$line" in *"AAAA: "*) type=AAAA ;; esac
                value="${line#*$type: }"
                value="${value%% *}"
                [ -z "$value" ] && continue
                if [ "$type" = AAAA ] || [ "$value" != "$HOST_IP" ]; then
                    delete_record "$REALM_LC" "$node" "$type" "$value"
                fi
                ;;
        esac
    done
}

echo "--- final records ---"
for n in "@" "$DCNAME_LC" "gc._msdcs"; do
    samba-tool dns query $S "$REALM_LC" "$n" A "${CRED[@]}" 2>/dev/null | sed -n 's/^  /'"$n"'  /p'
done
echo "=== fix-dns done ==="
