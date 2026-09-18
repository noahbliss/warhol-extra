#!/usr/bin/env bash
# =============================================================================
# gen-apex-keys.sh — give every APEX in the build its own signing keys, and
#                    re-sign the target_files with them.
#
#     ./tools/gen-apex-keys.sh gen                 generate the missing key pairs
#     ./tools/gen-apex-keys.sh verify              check every pair is complete + matched
#     ./tools/gen-apex-keys.sh verify-signed <zip> check the SIGNED build really uses them
#     ./tools/gen-apex-keys.sh args                print the sign_target_files args
#     ./tools/gen-apex-keys.sh sign [out.zip]      print the re-sign + OTA commands
#
# WHY
#   PRODUCT_DEFAULT_DEV_CERTIFICATE re-signs APKs, but it does NOT reach APEXes
#   that ship with their own in-tree keys. Measured from META/apexkeys.txt of the
#   first release-signed build: 36 APEXes, of which 2 picked up our release key,
#   1 is legitimately PRESIGNED (the CTS shim), and 33 were still signed with
#   AOSP's public dev keys -- art/build/apex/com.android.art.pk8 and friends.
#
#   A public key is a public key. Anyone can build an APEX that the running
#   system will accept as an update to one of those 33. Fine on a personal
#   device, not fine for anything published.
#
# TWO KEYS PER APEX, NOT ONE
#   payload   an AVB key (plain RSA .pem) over the APEX's filesystem image
#   container an APK-style key pair (.x509.pem + .pk8) over the zip itself
#   Both must be ours, and they are passed through different flags.
#
# WHAT IS DELIBERATELY LEFT ALONE
#   com.android.apex.cts.shim is PRESIGNED. It exists so CTS can verify that the
#   device REJECTS an APEX signed with the wrong key; re-signing it defeats the
#   test it embodies. apexkeys.txt marks it PRESIGNED and this script skips it.
# =============================================================================
set -euo pipefail

SRC="${SRC:-/run/media/local/4TB/warhol-los/src}"
KEYS="${KEYS:-/run/media/local/4TB/warhol-los/keys}"
TF="${TF:-$SRC/out/target/product/warhol/obj/PACKAGING/target_files_intermediates/lineage_warhol-target_files}"
SUBJECT_BASE="${SUBJECT_BASE:-/C=US/ST=California/L=Mountain View/O=Android/OU=Android/emailAddress=android@android.com}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$SRC" ]  || die "no source tree at $SRC (run this on the build host)"
[ -f "$TF/META/apexkeys.txt" ] || die "no apexkeys.txt at $TF/META -- build first"
mkdir -p "$KEYS/apex"

# The list comes from the BUILD, never from a hardcoded table: APEXes appear and
# disappear between Android releases, and a stale table would silently leave new
# ones on public keys -- the exact failure this script exists to prevent.
apex_names() {
    sed -E 's/^name="([^"]+)\.apex".*/\1/' "$TF/META/apexkeys.txt" | sort -u
}
is_presigned() {  # is_presigned <apex-name>
    grep -q "^name=\"$1\.apex\".*private_key=\"PRESIGNED\"" "$TF/META/apexkeys.txt"
}
is_ours() {       # already signed with our release key by the build itself
    grep -q "^name=\"$1\.apex\".*private_key=\"vendor/lineage-priv/keys/" "$TF/META/apexkeys.txt"
}

# NOT development/tools/make_key.
#
# make_key builds the pair through two named pipes and three backgrounded openssl
# processes, then ends with a bare `wait`. It produced correct output here every
# time, and still exited 1 -- which under `set -e` silently truncated a 33-key run
# after 2 keys, with an empty log. Its own trailing `wait` picks up a status from a
# background job that did its work fine, and `read -p` on a closed stdin does not
# help either.
#
# Doing it directly is three deterministic openssl calls with a real exit status,
# and produces byte-for-byte the same kind of artifacts: a self-signed X.509 cert
# valid for 10000 days and an unencrypted PKCS#8 DER private key.
make_pair() {  # make_pair <apex-name>
    local n="$1" d="$KEYS/apex" tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    # payload key: plain RSA for avbtool
    [ -f "$d/$n.pem" ] || openssl genrsa -out "$d/$n.pem" 4096 2>/dev/null
    # container key pair
    openssl genrsa -f4 -out "$tmp/key.pem" 2048 2>/dev/null
    openssl req -new -x509 -sha256 -key "$tmp/key.pem" -out "$tmp/$n.x509.pem" \
        -days 10000 -subj "$SUBJECT_BASE/CN=$n" 2>/dev/null
    openssl pkcs8 -in "$tmp/key.pem" -topk8 -outform DER -out "$tmp/$n.pk8" -nocrypt 2>/dev/null
    verify_pair "$tmp/$n.x509.pem" "$tmp/$n.pk8" || die "generated pair for $n does not match"
    mv "$tmp/$n.x509.pem" "$d/$n.x509.pem"
    mv "$tmp/$n.pk8"      "$d/$n.pk8"
}

# A cert paired with the wrong private key signs nothing that verifies, and the
# failure would only surface at install time on someone else's device. Cheap to
# check, so check.
verify_pair() {  # verify_pair <x509.pem> <pk8>
    local a b
    a=$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null)
    b=$(openssl pkcs8 -inform DER -nocrypt -in "$2" 2>/dev/null \
        | openssl rsa -pubout 2>/dev/null | openssl md5 2>/dev/null)
    [ -n "$a" ] && [ "$a" = "$b" ]
}

cmd_verify() {
    local n bad=0 ok=0
    for n in $(apex_names); do
        is_presigned "$n" && continue
        is_ours "$n" && continue
        if [ ! -f "$KEYS/apex/$n.pk8" ]; then echo "  MISSING $n"; bad=$((bad+1)); continue; fi
        if ! openssl rsa -in "$KEYS/apex/$n.pem" -noout -check >/dev/null 2>&1; then
            echo "  BAD payload key $n"; bad=$((bad+1)); continue
        fi
        if ! verify_pair "$KEYS/apex/$n.x509.pem" "$KEYS/apex/$n.pk8"; then
            echo "  MISMATCHED container pair $n"; bad=$((bad+1)); continue
        fi
        ok=$((ok+1))
    done
    echo "$ok complete and self-consistent, $bad problems"
    [ $bad -eq 0 ]
}

cmd_gen() {
    local n skipped=0 made=0 kept=0
    for n in $(apex_names); do
        if is_presigned "$n"; then
            echo "  skip $n (PRESIGNED -- CTS shim, must stay as it is)"
            skipped=$((skipped+1)); continue
        fi
        if is_ours "$n"; then
            echo "  skip $n (already signed with our release key by the build)"
            skipped=$((skipped+1)); continue
        fi
        if [ -f "$KEYS/apex/$n.pem" ] && [ -f "$KEYS/apex/$n.pk8" ]; then
            kept=$((kept+1)); continue
        fi
        make_pair "$n"
        made=$((made+1)); echo "  made $n"
    done
    echo "generated $made, already present $kept, skipped $skipped"
    chmod 600 "$KEYS/apex"/*.pem "$KEYS/apex"/*.pk8 2>/dev/null || true
}

cmd_args() {
    local n
    for n in $(apex_names); do
        is_presigned "$n" && continue
        is_ours "$n" && continue
        [ -f "$KEYS/apex/$n.pk8" ] || die "missing key for $n -- run '$0 gen' first"
        printf -- '--extra_apks %s.apex=%s/apex/%s ' "$n" "$KEYS" "$n"
        printf -- '--extra_apex_payload_key %s.apex=%s/apex/%s.pem ' "$n" "$KEYS" "$n"
    done
    echo
}

# The tree-relative key directory. sign_target_files_apks runs inside the build
# container, which mounts the source tree and NOT the key store, so every key path
# it is given has to be one the container can see.
TREE_KEYS="${TREE_KEYS:-vendor/lineage-priv/keys}"

cmd_container_args() {
    local n
    for n in $(apex_names); do
        is_presigned "$n" && continue
        is_ours "$n" && continue
        printf -- '--extra_apks %s.apex=%s/apex/%s ' "$n" "$TREE_KEYS" "$n"
        printf -- '--extra_apex_payload_key %s.apex=%s/apex/%s.pem ' "$n" "$TREE_KEYS" "$n"
    done
    echo
}

# Verify the RESULT, not the recipe.
#
# META/apexkeys.txt records what the BUILD used and sign_target_files_apks does
# not rewrite it -- so a signed target_files still lists the old in-tree key paths
# and reading that file "proves" nothing changed. The only honest check is the
# container certificate inside each APEX.
cmd_verify_signed() {  # cmd_verify_signed <signed-target_files.zip>
    local z="${1:-$SRC/out/warhol-signed-target_files.zip}" tmp n a c ours=0 foreign=0 subj
    [ -f "$z" ] || die "usage: $0 verify-signed <signed-target_files.zip>"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    for n in $(apex_names); do
        is_presigned "$n" && continue
        unzip -o -q "$z" "SYSTEM/apex/$n.*" -d "$tmp" 2>/dev/null || true
        # `set -o pipefail` makes `ls missing | head -1` return ls's status (2), and
        # the assignment then inherits it, so `set -e` kills the script mid-loop --
        # with no output, because stdout was still buffered. The `|| true` is what
        # keeps an APEX that simply is not in this build from looking like a crash.
        a=$(ls "$tmp/SYSTEM/apex/$n".* 2>/dev/null | head -1 || true)
        [ -n "$a" ] || { echo "  not in this build: $n"; continue; }
        rm -rf "$tmp/mi"; mkdir -p "$tmp/mi"
        unzip -o -q "$a" "META-INF/*" -d "$tmp/mi" 2>/dev/null || true
        subj=""
        for c in "$tmp"/mi/META-INF/*; do
            case "$c" in *.RSA|*.EC|*.DSA) ;; *) continue ;; esac
            subj=$(openssl pkcs7 -inform DER -in "$c" -print_certs 2>/dev/null \
                   | openssl x509 -noout -subject 2>/dev/null)
            break
        done
        # Two shapes are both correct. An APEX we re-signed carries CN=<apex name>.
        # The two the BUILD already signed via PRODUCT_DEFAULT_DEV_CERTIFICATE carry
        # the release key's CN=warhol, and are deliberately skipped by cmd_gen -- so
        # accepting only the first shape reports them as foreign, which they are not.
        case "$subj" in
            *"CN = $n"*|*"CN=$n"*)         ours=$((ours+1)) ;;
            *"CN = warhol"*|*"CN=warhol"*) ours=$((ours+1)); echo "  release key: $n" ;;
            *) foreign=$((foreign+1)); echo "  NOT ours: $n -> ${subj:-<no signature found>}" ;;
        esac
        rm -rf "$tmp/SYSTEM"
    done
    echo "$ours signed with our keys, $foreign not"
    [ $foreign -eq 0 ]
}

cmd_sign() {
    local out="${1:-/aosp/out/warhol-signed-target_files.zip}"
    local tf_rel="out/target/product/warhol/obj/PACKAGING/target_files_intermediates/lineage_warhol-target_files.zip"
    [ -f "$SRC/$tf_rel" ] || die "no target_files zip at $SRC/$tf_rel -- build first"
    [ -d "$SRC/$TREE_KEYS/apex" ] || die "APEX keys not installed into the tree at $SRC/$TREE_KEYS/apex
       remote-build.sh install_keys copies them there; run a build step first."
    local args; args=$(cmd_container_args)
    cat <<EOF
Run this inside the build container (remote-build.sh shell):

  ./out/host/linux-x86/bin/sign_target_files_apks \\
      -o -d $TREE_KEYS \\
      $args \\
      $tf_rel $out

then build the OTA from the signed target_files:

  ./out/host/linux-x86/bin/ota_from_target_files --block \\
      $out /aosp/out/lineage-warhol-signed.zip
EOF
}

case "${1:-}" in
    gen) cmd_gen ;; args) cmd_args ;; verify) cmd_verify ;; sign) shift; cmd_sign "$@" ;;
    verify-signed) shift; cmd_verify_signed "$@" ;;
    container-args) cmd_container_args ;;
    *) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
