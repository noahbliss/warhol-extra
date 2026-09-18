#!/usr/bin/env bash
# =============================================================================
# build-super.sh — assemble a full super.img for warhol.
#
#     ./tools/build-super.sh --images-dir <dir-with-system.img-etc>
#     ./tools/build-super.sh --target-files <signed-target_files.zip>
#     ./tools/build-super.sh --images-dir <dir> --product-size 1536   # for GApps
#
# READ THIS BEFORE USING IT.
#
# This builds a WHOLE 12.5 GiB super image. That is the right tool for exactly
# two jobs: disaster recovery, and re-provisioning the logical layout (e.g.
# growing product_a for GApps). It is the WRONG tool for a normal ROM update.
#
#   For a normal update, write the three partitions IN PLACE instead. The layout
#   does not change, so nothing has to move and no metadata is rewritten:
#   read the live extents with `lpdump` on the first 16 MiB of super, then write
#   each image at start_sector*512 and hash-verify the range. That was done
#   successfully on 2026-09-10 in about a minute per partition. See
#   NEXT_STEPS.md section 11 and docs/PARTITIONS.md.
#
# 2026-09-10 REWRITE. The previous version of this file was actively dangerous
# and its header stated the opposite of the truth. Two things were wrong:
#
#   1. SLOT. It built every partition as *_b in group main_b, on the stated
#      premise that "the device runs slot b; slot a has never had a working OS".
#      That inverted: slot _b has NO lk and cannot boot, and the device now runs
#      slot _a. A _b layout would have produced an unbootable super.
#
#   2. SIZES. It sized each partition to its image
#      (--partition name:readonly:$sz:main_b), which silently destroys the
#      headroom design in docs/PARTITIONS.md — the whole point of which is that
#      a ROM update never needs a repartition, and therefore never risks
#      userdata. Sizes are now FIXED and declared below.
#
# Ordering is stock-first (vendor, odm, the dlkms, then ours) so growth in our
# partitions never shifts stock content. product_a is deliberately LAST: it is
# the one most likely to need growing, and with ~6 GiB of super free after it,
# growing it moves nothing else.
#
# WHY THIS EXISTS AT ALL
#   warhol keeps the stock vendor, so the build produces only system,
#   system_ext and product. A full super has to combine those three with the
#   five stock partitions pulled off the device: vendor, odm, vendor_dlkm,
#   odm_dlkm, system_dlkm.
#
# THE TRIM AT THE END IS NOT OPTIONAL. See trim_sparse() below.
# =============================================================================
set -euo pipefail

SRC="${SRC:-/run/media/local/4TB/warhol-los/src}"
STOCK="${STOCK:-/run/media/local/4TB/warhol-los/superbuild}"
OUTDIR="${OUTDIR:-/run/media/local/4TB/warhol-los/out}"
BIN="$SRC/out/host/linux-x86/bin"

# Geometry, read off the device's own super with `lpdump` -- not invented.
DEVICE_SIZE=13421772800        # the super partition, 12.5 GiB
GROUP_SIZE=13411287040         # main_a's maximum
METADATA_SIZE=65536
METADATA_SLOTS=3

# FIXED partition sizes in MiB, matching the live layout (docs/PARTITIONS.md).
# Verified against lpdump of the running device on 2026-09-10:
#   system_a      start 7405568   len 3145728 sectors = 1536 MiB
#   system_ext_a  start 10551296  len 1572864 sectors =  768 MiB
#   product_a     start 12124160  len 1572864 sectors =  768 MiB
SYSTEM_MIB=1536
SYSTEM_EXT_MIB=768
PRODUCT_MIB=768

TF=""; IMAGES_DIR=""; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target-files)    TF="$2"; shift 2 ;;
        --images-dir)      IMAGES_DIR="$2"; shift 2 ;;
        --stock)           STOCK="$2"; shift 2 ;;
        --out)             OUT="$2"; shift 2 ;;
        --system-size)     SYSTEM_MIB="$2"; shift 2 ;;
        --system-ext-size) SYSTEM_EXT_MIB="$2"; shift 2 ;;
        --product-size)    PRODUCT_MIB="$2"; shift 2 ;;
        -h|--help)         sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
[ -x "$BIN/lpmake" ] || die "lpmake not built; run a build first ($BIN)"

WS=$(mktemp -d); trap 'rm -rf "$WS"' EXIT

if [ -n "$TF" ]; then
    [ -f "$TF" ] || die "no such target_files: $TF"
    unzip -o -q "$TF" "IMAGES/system.img" "IMAGES/system_ext.img" "IMAGES/product.img" -d "$WS"
    IMAGES_DIR="$WS/IMAGES"
elif [ -z "$IMAGES_DIR" ]; then
    die "pass --target-files <zip> or --images-dir <dir>"
fi
OUT="${OUT:-$OUTDIR/super.img}"
mkdir -p "$(dirname "$OUT")"

# name:source-file:fixed-size-MiB   (0 = size to the image, stock partitions only)
# STOCK FIRST so our growth never shifts stock content. product_a LAST.
PARTS=(
    "vendor_a:$STOCK/vendor_a.img:0"
    "odm_a:$STOCK/odm_a.img:0"
    "vendor_dlkm_a:$STOCK/vendor_dlkm_a.img:0"
    "odm_dlkm_a:$STOCK/odm_dlkm_a.img:0"
    "system_dlkm_a:$STOCK/system_dlkm_a.img:0"
    "system_a:$IMAGES_DIR/system.img:$SYSTEM_MIB"
    "system_ext_a:$IMAGES_DIR/system_ext.img:$SYSTEM_EXT_MIB"
    "product_a:$IMAGES_DIR/product.img:$PRODUCT_MIB"
)

ARGS=(--metadata-size "$METADATA_SIZE" --metadata-slots "$METADATA_SLOTS"
      --super-name super --device "super:$DEVICE_SIZE"
      --group "main_a:$GROUP_SIZE" --sparse)
# No --virtual-ab: `lpdump` on the device's own super reports "Header flags: none",
# so the metadata does not carry VIRTUAL_AB_DEVICE. Virtual A/B is configured by
# the product makefiles and snapuserd, not by a bit in the liblp header, and
# setting one the stock layout does not have would be a gratuitous difference.

echo "=== partition table ==="
total=0
for p in "${PARTS[@]}"; do
    name="${p%%:*}"; rest="${p#*:}"
    file="${rest%:*}"; fixed="${rest##*:}"
    [ -f "$file" ] || die "missing partition image: $file"
    imgsz=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file")
    if [ "$fixed" = "0" ]; then
        sz=$imgsz; note="sized to image (stock)"
    else
        sz=$((fixed * 1024 * 1024))
        [ "$imgsz" -le "$sz" ] || die "$name: image is ${imgsz}B but the partition is only ${sz}B - raise --${name%_a}-size"
        note="fixed ${fixed} MiB, image $((imgsz / 1048576)) MiB, headroom $(( (sz - imgsz) / 1048576 )) MiB"
    fi
    total=$((total+sz))
    printf "  %-16s %12d  %s\n" "$name" "$sz" "$note"
    ARGS+=(--partition "$name:readonly:$sz:main_a" --image "$name=$file")
done
echo "  total allocated: $total of $GROUP_SIZE ($((total*100/GROUP_SIZE))%)"
[ "$total" -le "$GROUP_SIZE" ] || die "partitions exceed the group; something is wrong"

echo "=== lpmake ==="
"$BIN/lpmake" "${ARGS[@]}" --output "$OUT.untrimmed"
ls -la "$OUT.untrimmed"

# ── The trim: a conditional repair, not something that always fires ─────────
# A sparse image can describe its unallocated tail two ways. DONT_CARE chunks
# carry no data and tell the flasher to skip the region; FILL chunks carry a
# 4-byte pattern that the flasher is expected to write out. warhol's bootloader
# handles the first and chokes on the second: given a long trailing run of
# zero-FILL chunks it rejects the transfer on the final chunk, and `fastboot
# flash super` fails at "42/42" after four minutes of apparently fine progress.
#
# The first super built for this device came out with 116 trailing zero-FILL
# chunks and hit exactly that. Built the way this script builds it -- raw input
# images, this lpmake, this geometry -- the tail comes out as a single DONT_CARE
# chunk instead and there is nothing to drop. So this is a safety net, and a
# "dropped 0" line is the expected result, not a sign it did not run.
#
# When it does fire, nothing allocated is removed: it stops at the first
# non-zero-FILL chunk from the end, and every extent lpdump reports survives.
trim_sparse() {  # trim_sparse <in> <out>
    python3 - "$1" "$2" <<'PY'
import struct, sys, shutil
src, dst = sys.argv[1], sys.argv[2]
RAW, FILL, DONT_CARE, CRC32 = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
with open(src,'rb') as f:
    magic,major,minor,fhs,chs,blk,tb,tc,crc = struct.unpack('<IHHHHIIII', f.read(28))
    assert magic == 0xED26FF3A, "not an Android sparse image"
    f.seek(fhs)
    chunks = []                      # (type, chunk_blocks, offset, total_sz)
    for _ in range(tc):
        off = f.tell()
        ct,_,cb,tsz = struct.unpack('<HHII', f.read(chs))
        chunks.append((ct, cb, off, tsz))
        f.seek(off + tsz)
    # Walk back over the trailing zero-FILL run.
    keep = len(chunks)
    while keep > 0:
        ct, cb, off, tsz = chunks[keep-1]
        if ct != FILL:
            break
        f.seek(off + chs)
        if f.read(4) != b'\x00\x00\x00\x00':
            break
        keep -= 1
    dropped = len(chunks) - keep
    blocks = sum(c[1] for c in chunks[:keep])
    with open(src,'rb') as fi, open(dst,'wb') as fo:
        fo.write(struct.pack('<IHHHHIIII', magic, major, minor, fhs, chs,
                             blk, blocks, keep, crc))
        fi.seek(fhs)
        if keep == len(chunks):
            shutil.copyfileobj(fi, fo, 1 << 22)          # nothing to drop
        else:
            remaining = chunks[keep][2] - fhs            # up to the first dropped chunk
            while remaining:
                b = fi.read(min(1 << 22, remaining))
                if not b:
                    break
                fo.write(b); remaining -= len(b)
    print(f"  dropped {dropped} trailing zero-FILL chunks "
          f"({tc} -> {keep} chunks, {tb} -> {blocks} blocks)")
PY
}

echo "=== trimming the zero tail ==="
trim_sparse "$OUT.untrimmed" "$OUT"
rm -f "$OUT.untrimmed"
ls -la "$OUT"
echo
cat <<'NOTE'

This is a WHOLE-super image: writing it replaces every logical partition,
including the stock vendor/odm/dlkm copies. Only do that for recovery or a
deliberate re-provision.

  Re-provision from TWRP (never while booted from super -- see NEXT_STEPS
  section 10, this corrupted a live /system once):
      adb push/dd this image to /dev/block/by-name/super, then verify by hash.

  For a NORMAL update, do not use this file. Write the three partitions in
  place at their live lpdump extents instead; it moves nothing and rewrites no
  metadata.

NOTE
