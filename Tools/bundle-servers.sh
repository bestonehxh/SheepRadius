#!/bin/sh
# Copies FreeRADIUS and OpenLDAP out of Homebrew into the .app and makes them relocatable,
# so the app runs on a Mac that has never heard of Homebrew. Same idea as SheepTerm's
# "Bundle libssh" phase, but with two extra problems that one did not have:
#
#   1. The rlm_*.dylib modules are dlopen'd by name from `libdir` in radiusd.conf — they are
#      NOT in radiusd's load commands, so a link-time-only fix-up misses them entirely.
#   2. These binaries carry an absolute LC_RPATH (/opt/homebrew/opt/talloc/lib) as well as
#      absolute LC_LOAD_DYLIB entries. `otool -L` does not show rpaths, so the leak check at
#      the bottom has to look at `otool -l` too.
#
# Run from the Xcode "Bundle servers" build phase. It is also runnable by hand for testing:
#   TARGET_BUILD_DIR=<dir> EXECUTABLE_PATH=SheepRadius.app/Contents/MacOS/SheepRadius \
#   FRAMEWORKS_FOLDER_PATH=SheepRadius.app/Contents/Frameworks \
#   WRAPPER_NAME=SheepRadius.app ./Tools/bundle-servers.sh
set -e

FR="/opt/homebrew/opt/freeradius-server"
OL="/opt/homebrew/opt/openldap"
SSL="/opt/homebrew/opt/openssl@3/lib"
OSSLMOD="$(/opt/homebrew/opt/openssl@3/bin/openssl version -m 2>/dev/null | sed -E 's/.*"(.*)".*/\1/')"

APP="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
FW="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
HELPERS="$APP/Contents/Helpers"
RES="$APP/Contents/Resources"

# Named, not globbed: if Homebrew moves a soname or a module, fail HERE saying which file
# went missing, rather than shipping an app that cannot launch on the other Mac.
need() {  # need <path> <what to do about it>
  [ -e "$1" ] || { echo "error: $1 is missing. $2" >&2; exit 1; }
}
need "$FR/bin/radiusd"              "Run 'brew install freeradius-server'."
need "$FR/bin/radclient"            "Run 'brew install freeradius-server'."
need "$FR/share/freeradius/dictionary" "Run 'brew install freeradius-server'."
need "$OL/libexec/slapd"            "Run 'brew install openldap' (keg-only)."
need "$OL/bin/ldapsearch"           "Run 'brew install openldap' (keg-only)."
need "$OL/bin/ldapwhoami"          "Run 'brew install openldap' (keg-only)."
# The write half, added in build 16. The directory is edited **online** from now on —
# ldapadd/ldapmodify/ldapdelete/ldapmodrdn/ldappasswd against the running slapd — instead of
# the wipe-and-slapadd that made every edit an outage. `ldapmodrdn` is the one that moves a
# user between OUs, and `ldappasswd` the one that sets {SSHA} without the app hashing it.
for t in ldapadd ldapmodify ldapdelete ldapmodrdn ldappasswd; do
  need "$OL/bin/$t"                "Run 'brew install openldap' (keg-only)."
done
need "/opt/homebrew/opt/openssl@3/bin/openssl" "Run 'brew install openssl@3'."
need "$SSL/libcrypto.3.dylib"       "Run 'brew install openssl@3'. A new OpenSSL major (libcrypto.4) needs this script updated."
# radiusd loads the legacy provider explicitly: MS-CHAP needs MD4 and DES, which OpenSSL 3
# moved out of the default provider. Without this module MS-CHAP fails on a Mac that has no
# Homebrew — and silently works on one that does, which is the worst kind of bug.
need "$OSSLMOD/legacy.dylib"        "Run 'brew install openssl@3'. MS-CHAP needs the legacy provider (MD4/DES)."
need "$SSL/libssl.3.dylib"          "Run 'brew install openssl@3'."
need "/opt/homebrew/opt/talloc/lib/libtalloc.dylib"     "Run 'brew install talloc'."
need "/opt/homebrew/opt/readline/lib/libreadline.8.dylib" "Run 'brew install readline'. A new readline major needs this script updated."
# The one helper that is NOT copied out of Homebrew: there is no Homebrew eapol_test, so it
# is built once from the wpa_supplicant source by Tools/build-eapol-test.sh and the ~900 KB
# result is committed to Vendor/. That is what keeps an ordinary `xcodebuild` on either Mac
# from needing the source, a network connection, or that script.
need "${SRCROOT}/Vendor/eapol_test" "Run ./Tools/build-eapol-test.sh once (it fetches the wpa_supplicant source and builds it)."

# Exactly the rlm modules the generated radiusd.conf loads — confirmed against the module
# list `radiusd -CX` dlopens for that config. Anything else is dead weight in the bundle.
# rlm_date is here for one reason: a Policy rule with a weekday window. Measured on
# 3.2.10, neither &Current-Time nor &Time-Of-Day is ever true in an unlang condition
# (they are paircompare virtuals, usable only in the users file) and no % expansion
# yields a weekday, so `date sheep_weekday { format = "%a" }` is the way to get one.
RLM="rlm_always.dylib rlm_chap.dylib rlm_date.dylib rlm_eap.dylib rlm_eap_gtc.dylib rlm_eap_md5.dylib rlm_eap_mschapv2.dylib rlm_eap_peap.dylib rlm_eap_tls.dylib rlm_eap_ttls.dylib rlm_files.dylib rlm_mschap.dylib rlm_pap.dylib"
FRLIBS="libfreeradius-server.dylib libfreeradius-radius.dylib libfreeradius-eap.dylib"
EXTLIBS="libcrypto.3.dylib libssl.3.dylib libtalloc.dylib libreadline.8.dylib"
# core/cosine/inetorgperson/nis are the four the generated slapd.conf includes.
SCHEMAS="core cosine inetorgperson nis"

for m in $RLM $FRLIBS; do need "$FR/lib/$m" "Reinstall freeradius-server."; done
for s in $SCHEMAS; do need "/opt/homebrew/etc/openldap/schema/$s.schema" "Reinstall openldap."; done

rm -rf "$HELPERS" "$RES/freeradius" "$RES/openldap" "$RES/openssl" "$FW/ossl-modules" "$RES/Licenses"
mkdir -p "$FW" "$FW/ossl-modules" "$HELPERS" "$RES/freeradius" "$RES/openldap/schema" "$RES/openssl" "$RES/ad-image"

# ---- copy -------------------------------------------------------------------

cp -f "$FR/bin/radiusd" "$FR/bin/radclient" "$HELPERS/"
# radeapclient is only needed for the EAP-MD5 self-test, so its absence is not fatal.
if [ -e "$FR/bin/radeapclient" ]; then cp -f "$FR/bin/radeapclient" "$HELPERS/"; fi
# slapd, and the 2.7.1 client tools: both link libldap/liblber statically, so they
# need no OpenLDAP dylibs of their own — only openssl@3, which is bundled anyway.
cp -f "$OL/libexec/slapd" "$OL/bin/ldapsearch" "$OL/bin/ldapwhoami" \
      "$OL/bin/ldapadd" "$OL/bin/ldapmodify" "$OL/bin/ldapdelete" \
      "$OL/bin/ldapmodrdn" "$OL/bin/ldappasswd" "$HELPERS/"
for m in $RLM $FRLIBS; do cp -f "$FR/lib/$m" "$FW/"; done
cp -f "/opt/homebrew/opt/openssl@3/bin/openssl" "$HELPERS/"
# eapol_test links only libssl/libcrypto (already bundled) and libSystem, so it needs no
# dependency of its own — just the same @rpath fix-up as everything else below.
cp -f "${SRCROOT}/Vendor/eapol_test" "$HELPERS/"
cp -f "$SSL/libcrypto.3.dylib" "$SSL/libssl.3.dylib" "$FW/"
cp -f "$OSSLMOD/legacy.dylib" "$FW/ossl-modules/"
cp -f /opt/homebrew/opt/talloc/lib/libtalloc.dylib "$FW/"
cp -f /opt/homebrew/opt/readline/lib/libreadline.8.dylib "$FW/"
cp -f "$FR"/share/freeradius/* "$RES/freeradius/"
for s in $SCHEMAS; do cp -f "/opt/homebrew/etc/openldap/schema/$s.schema" "$RES/openldap/schema/"; done

# ---- licences (2.0 (2)) ------------------------------------------------------
# Every program and library above is distributed inside the .app, and every one of their
# licences requires its text to travel with the binary. Copied from each Homebrew keg, so the
# text is the one for the version bundled; eapol_test's comes from Vendor/, beside the binary.
# The exact sources (and Homebrew's patches) are attached to the `sources-2.0` GitHub Release.
LIC="$RES/Licenses"
mkdir -p "$LIC"
copy_licence() {  # copy_licence <name> <keg> <file>...
  local name="$1" keg="$2"; shift 2
  mkdir -p "$LIC/$name"
  for f in "$@"; do
    need "$keg/$f" "The $name licence is missing from Homebrew's keg."
    cp -f "$keg/$f" "$LIC/$name/"
  done
}
copy_licence "FreeRADIUS-3.2.10"  "$FR"                        COPYRIGHT LICENSE
copy_licence "OpenLDAP-2.7.1"     "$OL"                        COPYRIGHT LICENSE
copy_licence "OpenSSL-3.6.4"      /opt/homebrew/opt/openssl@3  LICENSE.txt
copy_licence "talloc-2.5.0"       /opt/homebrew/opt/talloc     LICENSE
copy_licence "readline-8.3"       /opt/homebrew/opt/readline   COPYING
need "${SRCROOT}/Vendor/eapol_test.COPYING" "Vendor/eapol_test.COPYING is missing."
mkdir -p "$LIC/wpa_supplicant-2.11"
cp -f "${SRCROOT}/Vendor/eapol_test.COPYING" "$LIC/wpa_supplicant-2.11/COPYING"
cat > "$LIC/README.txt" <<'TXT'
SheepRadius bundles these third-party programs and libraries, unmodified except that their
load paths are rewritten to point inside the app. Each remains under its own licence, whose
text is in the folder of the same name.

  FreeRADIUS 3.2.10     GPL-2.0-or-later (libfreeradius-radius: LGPL-2.1-or-later)
  OpenLDAP 2.7.1        OpenLDAP Public License 2.8
  OpenSSL 3.6.4         Apache-2.0
  talloc 2.5.0          LGPL-3.0-or-later
  GNU Readline 8.3 (+ patches 001-006)   GPL-3.0-or-later
  wpa_supplicant 2.11 (eapol_test)       BSD-3-Clause

radiusd, radclient and radeapclient link GNU Readline and are therefore distributed under the
terms of the GNU GPL version 3 (FreeRADIUS is GPL-2.0-or-later).

The complete corresponding source for every component above, with the patches Homebrew
applied when building it and SheepRadius's own build scripts, is published at:

  https://github.com/bestonehxh/SheepRadius/releases/tag/sources-2.0

SheepRadius itself is MIT-licensed: https://github.com/bestonehxh/SheepRadius
TXT

# AD Domain mode's build context: the Containerfile and the two scripts that go into the
# Samba AD DC image. They live OUTSIDE the synchronized source folder on purpose — Xcode
# would otherwise also drop them loose into Resources/ — and are copied here so a release
# .app can build the image on a second Mac with nothing but Homebrew's `container`.
for f in Containerfile entrypoint.sh fix-dns.sh; do
  need "${SRCROOT}/ADImage/$f" "The AD image build context is incomplete."
  cp -f "${SRCROOT}/ADImage/$f" "$RES/ad-image/"
done

chmod -R u+w "$HELPERS" "$FW" "$RES/freeradius" "$RES/openldap" "$RES/openssl" "$RES/ad-image" "$LIC"

# This OpenSSL has OPENSSLDIR=/opt/homebrew/etc/openssl@3 compiled in. On a Mac without
# Homebrew that path does not exist; on one WITH it, the user's own openssl.cnf would
# silently change our behaviour. Both are fixed by shipping this file and pointing
# OPENSSL_CONF at it for every child that links libcrypto (see Toolchain.childEnvironment).
cat > "$RES/openssl/openssl.cnf" <<'CNF'
# Generated by SheepRadius — the app sets OPENSSL_CONF to this file so that every Mac
# behaves identically. Only the built-in default provider is activated here; radiusd
# loads the legacy provider itself (MS-CHAP needs MD4/DES) from OPENSSL_MODULES.
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect

[default_sect]
activate = 1

# `openssl req` wants these to exist even when everything comes from -subj / -config.
[req]
distinguished_name = req_dn

[req_dn]
CNF

# ---- make relocatable -------------------------------------------------------

# Rewrite every absolute Homebrew reference to @rpath/<basename>, whatever prefix it used.
# FreeRADIUS uses TWO (…/Cellar/freeradius-server/<version>/lib for dependencies and
# …/opt/freeradius-server/lib for install names), so matching on the prefix is the only
# thing that keeps working across upgrades.
relocate() {  # relocate <mach-o> <rpath-to-add>...
  file="$1"; shift
  case "$(basename "$file")" in
    *.dylib) install_name_tool -id "@rpath/$(basename "$file")" "$file" 2>/dev/null || true ;;
  esac
  otool -L "$file" | tail -n +2 | awk '{print $1}' | grep '^/opt/homebrew' | while read -r dep; do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file" 2>/dev/null || true
  done
  # LC_RPATH entries are invisible to `otool -L`; these binaries really do carry one.
  otool -l "$file" | awk '/LC_RPATH/{r=1} r && /^ *path /{print $2; r=0}' | grep '^/opt/homebrew' | while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null || true
  done
  for add in "$@"; do install_name_tool -add_rpath "$add" "$file" 2>/dev/null || true; done
}

# Executables live in Contents/Helpers, so their siblings are ../Frameworks. The dylibs sit
# next to each other, so @loader_path alone resolves them.
for exe in "$HELPERS"/*; do relocate "$exe" "@loader_path/../Frameworks"; done
for lib in "$FW"/*.dylib; do relocate "$lib" "@loader_path"; done
# The provider module sits one level down, so its siblings are ..
for m in "$FW"/ossl-modules/*.dylib; do relocate "$m" "@loader_path/.."; done

# ---- sign -------------------------------------------------------------------

# Mutating a Mach-O invalidates its signature, and on Apple Silicon an invalidly-signed
# dylib simply will not load. Re-sign everything we touched, then re-seal the app itself
# (adding files to a signed bundle breaks its seal).
#
# Everything under Contents/MacOS is signed too, not just what this script copied: a Debug
# build drops an unsigned `__preview.dylib` (and a SheepRadius.debug.dylib) there, and
# re-sealing the bundle fails on ANY unsigned nested code, not only on ours.
sign() { [ -e "$1" ] && codesign --force --sign - "$1" >/dev/null 2>&1; return 0; }
for f in "$FW"/*.dylib "$FW"/ossl-modules/*.dylib "$HELPERS"/* "$APP"/Contents/MacOS/*.dylib; do sign "$f"; done
if ! codesign --force --sign - "$APP" >/dev/null 2>&1; then
  echo "error: could not re-seal the app bundle after adding the servers:" >&2
  codesign --force --sign - "$APP" >&2 || true
  exit 1
fi

# ---- prove it -----------------------------------------------------------------

# Every install_name_tool call above is allowed to fail quietly (they are no-ops on a build
# that was already fixed up), so THIS is what proves the job was done. An absolute Homebrew
# path left anywhere is an app that runs on this Mac and cannot launch on the other one —
# the failure that would otherwise be found by a user rather than by us.
LEAKS=""
for f in "$HELPERS"/* "$FW"/*.dylib "$FW"/ossl-modules/*.dylib "${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}"; do
  if otool -L "$f" | tail -n +2 | grep -q /opt/homebrew; then LEAKS="$LEAKS $f(dylib)"; fi
  if otool -l "$f" | awk '/LC_RPATH/{r=1} r && /^ *path /{print $2; r=0}' | grep -q /opt/homebrew; then
    LEAKS="$LEAKS $f(rpath)"
  fi
done
if [ -n "$LEAKS" ]; then
  echo "error: these still reference an absolute Homebrew path and would not launch elsewhere:$LEAKS" >&2
  for f in $LEAKS; do otool -L "${f%(*}" | grep /opt/homebrew >&2; done
  exit 1
fi

echo "note: bundled FreeRADIUS + OpenLDAP ($(du -sh "$APP" | cut -f1) app)"
