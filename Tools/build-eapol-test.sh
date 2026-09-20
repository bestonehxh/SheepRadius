#!/bin/zsh
# Builds `eapol_test` from the wpa_supplicant source release and drops the result in
# Vendor/eapol_test, which IS checked in. Run this by hand — never from a build phase:
#
#     ./Tools/build-eapol-test.sh
#
# The point of vendoring the binary is that an ordinary `xcodebuild` on either Mac must not
# need the wpa_supplicant source, a network connection, or this script. "Bundle servers"
# copies Vendor/eapol_test into the .app exactly the way it copies Homebrew's radiusd.
#
# WHAT eapol_test IS: a supplicant *simulator*. It speaks the full EAP peer state machine
# (PEAP, TTLS, TLS, MSCHAPv2, MD5, GTC) straight to a RADIUS server over UDP, skipping the
# 802.1X/EAPOL link entirely. That is exactly what we need — radclient and radeapclient only
# reach PAP / CHAP / MS-CHAP / EAP-MD5, so before this the tunnelled half of the server
# configuration had never been executed by anything. It does NOT test the Wi-Fi or switch
# port: nothing here proves an AP forwards EAPOL correctly.
#
# LICENCE: wpa_supplicant/hostap is BSD (see COPYING in the tarball). Redistribution is fine
# with the copyright notice; this app is not distributed anyway (see README).
#
# THE SOURCE IS NOT IN THIS REPO. It is fetched once, here, and verified:
#
#     https://w1.fi/releases/wpa_supplicant-2.11.tar.gz
#     sha256 912ea06f74e30a8e36fbb68064d6cdff218d8d591db0fc5d75dee6c81ac7fc0a   (3841433 bytes)
#
# w1.fi publishes a detached PGP signature (.asc) next to the tarball. Checking it would mean
# fetching both the signature and Jouni Malinen's key, which is two more downloads than this
# is allowed to make, so the sha256 above is pinned here instead: it is compared on every run
# and a mismatch aborts.
set -e
set -u

VERSION="2.11"
URL="https://w1.fi/releases/wpa_supplicant-${VERSION}.tar.gz"
SHA256="912ea06f74e30a8e36fbb68064d6cdff218d8d591db0fc5d75dee6c81ac7fc0a"

ROOT="${0:A:h:h}"
OUT="$ROOT/Vendor/eapol_test"
# Deliberately OUTSIDE the project: the sources are ~18 MB unpacked and OneDrive would
# happily sync every object file.
WORK="${TMPDIR:-/tmp}/sheepradius-eapol"
SRC="$WORK/wpa_supplicant-${VERSION}"

OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || echo /opt/homebrew/opt/openssl@3)"
[[ -e "$OPENSSL_PREFIX/lib/libssl.3.dylib" ]] || {
  print -r -- "error: $OPENSSL_PREFIX/lib/libssl.3.dylib is missing. Run 'brew install openssl@3'." >&2
  exit 1
}

mkdir -p "$WORK"
cd "$WORK"

# ---- fetch + verify ---------------------------------------------------------

TARBALL="$WORK/wpa_supplicant-${VERSION}.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
  print -r -- "── downloading $URL ──"
  curl -fsSL -o "$TARBALL" "$URL"
fi
actual="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
if [[ "$actual" != "$SHA256" ]]; then
  print -r -- "error: $TARBALL does not match the pinned checksum." >&2
  print -r -- "  expected $SHA256" >&2
  print -r -- "  got      $actual" >&2
  print -r -- "Delete it and re-run, or update this script if you deliberately changed version." >&2
  exit 1
fi
file "$TARBALL" | grep -q 'gzip compressed' || {
  print -r -- "error: $TARBALL is not a gzip tarball." >&2; exit 1
}
print -r -- "sha256 ok: $SHA256"

rm -rf "$SRC"
tar xzf "$TARBALL" -C "$WORK"

# ---- the one source patch ---------------------------------------------------
#
# eapol_test takes the RADIUS shared secret as `-s<secret>`, i.e. in argv, where `ps` shows it
# to every process on the Mac. This app's rule is that no secret ever reaches a command line
# (radclient is driven with `-S <file>` and the OpenLDAP tools with `-y <file>` for the same
# reason, and Tests/run.sh greps `ps` to prove it), so `-s` learns the same trick:
#
#     -s @<path>    read the secret from <path>, first line, trailing newline stripped
#
# A plain `-s<secret>` still works, which keeps every eapol_test recipe on the internet valid.
print -r -- "── patching eapol_test.c (secret from a file) ──"
python3 - "$SRC/wpa_supplicant/eapol_test.c" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

old = """		case 's':
			as_secret = optarg;
			break;
"""
new = """		case 's':
			if (optarg[0] == '@') {
				/* SheepRadius: read the secret from a file so it
				 * never appears in argv, where ps shows it to
				 * every process on the machine. */
				FILE *sf = fopen(optarg + 1, "r");
				static char sbuf[256];
				size_t sn;

				if (!sf) {
					printf("Could not open secret file "
					       "'%s'\\n", optarg + 1);
					return -1;
				}
				if (!fgets(sbuf, sizeof(sbuf), sf)) {
					fclose(sf);
					printf("Empty secret file '%s'\\n",
					       optarg + 1);
					return -1;
				}
				fclose(sf);
				sn = os_strlen(sbuf);
				while (sn > 0 && (sbuf[sn - 1] == '\\n' ||
						  sbuf[sn - 1] == '\\r'))
					sbuf[--sn] = '\\0';
				as_secret = sbuf;
			} else {
				as_secret = optarg;
			}
			break;
"""
if old not in src:
    sys.exit("eapol_test.c does not contain the expected `case 's':` block — "
             "the patch needs revisiting for this release.")
open(path, "w").write(src.replace(old, new, 1))
print("patched %s" % path)
PY

# ---- configure --------------------------------------------------------------
#
# FreeRADIUS ships scripts/ci/eapol_test/config_osx for exactly this job; it is not
# downloadable here, so this reproduces the idea. Everything is switched OFF except the EAP
# peer: no Wi-Fi drivers (CONFIG_DRIVER_NONE), no libnl, no D-Bus, no libpcap
# (CONFIG_L2_PACKET=none), no control interface consumers.
#
# CONFIG_OSX=y is not cosmetic: without it the Makefile adds `-lrt` for glibc's
# clock_gettime and the link fails with "library 'rt' not found". Its only other effect is
# `-framework PCSC`, which we never reach because CONFIG_PCSC is off.
#
# The three -Wno- flags exist because this release predates clang 17 and OpenSSL 3.6, and the
# Makefile compiles with -Werror:
#   gnu-folding-constant       os_unix.c:836 `char *argv[MAX_ARG + 1]`
#   deprecated-declarations    SSL_CTX_flush_sessions, deprecated in OpenSSL 3.4
#   unused-but-set-variable    kept as a pre-emptive relaxation of the same class
print -r -- "── writing wpa_supplicant/.config ──"
cat > "$SRC/wpa_supplicant/.config" <<CONFIG
# Generated by SheepRadius/Tools/build-eapol-test.sh — a supplicant simulator, nothing else.
CONFIG_DRIVER_NONE=y
CONFIG_L2_PACKET=none
CONFIG_OS=unix
CONFIG_OSX=y
CONFIG_ELOOP=eloop
CONFIG_EAPOL_TEST=y
CONFIG_IEEE8021X_EAPOL=y
CONFIG_TLS=openssl
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_NO_CONFIG_WRITE=y
CONFIG_NO_RANDOM_POOL=y

# The EAP methods the Test pane offers, and the two inner methods they carry.
CONFIG_EAP_MD5=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_EAP_TLS=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_TTLS=y
CONFIG_EAP_GTC=y
CONFIG_EAP_LEAP=y

CFLAGS += -I$OPENSSL_PREFIX/include
CFLAGS += -Wno-gnu-folding-constant -Wno-unused-but-set-variable -Wno-deprecated-declarations
LIBS += -L$OPENSSL_PREFIX/lib
LIBS_p += -L$OPENSSL_PREFIX/lib
CONFIG

# ---- build ------------------------------------------------------------------

print -r -- "── make eapol_test ──"
cd "$SRC/wpa_supplicant"
make eapol_test -j"$(sysctl -n hw.ncpu)"

[[ -x eapol_test ]] || { print -r -- "error: make produced no eapol_test binary." >&2; exit 1 }

# TLS 1.3 is available (proved against our own radiusd with tls_max_version = "1.3"), but
# wpa_supplicant disables it for EAP unless the network block asks — the Test pane writes
# phase1="tls_disable_tlsv1_3=0" when the server allows 1.3. No build flag is involved;
# CONFIG_TLSV13 is not a thing this Makefile reads.

# ---- install ----------------------------------------------------------------

mkdir -p "$ROOT/Vendor"
cp -f eapol_test "$OUT"
chmod 755 "$OUT"

print -r -- ""
print -r -- "built: $OUT"
print -r -- "  $(file -b "$OUT")"
print -r -- "  $(ls -l "$OUT" | awk '{print $5}') bytes"
print -r -- "  sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
print -r -- "  $(./eapol_test -v 2>&1 | head -1)"
print -r -- ""
print -r -- "links against (bundle-servers.sh rewrites these to @rpath):"
otool -L "$OUT" | tail -n +2
