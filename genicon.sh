#!/bin/bash
# Generate a full-bleed .icns app icon (solid color + subtle gradient).
# macOS applies rounded corners automatically — the icon fills the entire frame.
# Usage: ./genicon.sh <shortname> <r> <g> <b> [optional: r2 g2 b2 for gradient]
#   ./genicon.sh F1TV 220 30 30           # flat color
#   ./genicon.sh HBO 100 20 160 60 10 100  # gradient

set -e
SDIR="$(cd "$(dirname "$0")" && pwd)/$1"
shift
R=$1; G=$2; B=$3
R2=${4:-$R}; G2=${5:-$G}; B2=${6:-$B}

ICONSET="/tmp/${SDIR##*/}_icon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"

python3 -c "
import struct, zlib

def write_png(path, w, h, r1, g1, b1, r2, g2, b2):
    pixels = bytearray()
    for y in range(h):
        for x in range(w):
            t = y / h
            pr = min(255, max(0, int(r1 * (1-t) + r2 * t)))
            pg = min(255, max(0, int(g1 * (1-t) + g2 * t)))
            pb = min(255, max(0, int(b1 * (1-t) + b2 * t)))
            pixels.extend([pr, pg, pb, 255])

    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(bytes(pixels))))
        f.write(chunk(b'IEND', b''))

write_png('$ICONSET/icon_1024.png', 1024, 1024, $R, $G, $B, $R2, $G2, $B2)
"

for SIZE in 16 32 128 256 512; do
    SRC="$ICONSET/icon_1024.png"
    sips -z $SIZE $SIZE "$SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" &>/dev/null
    S2=$((SIZE * 2))
    sips -z $S2 $S2 "$SRC" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" &>/dev/null
done

iconutil -c icns "$ICONSET" --output "$SDIR/AppIcon.icns"
rm -rf "$ICONSET"
echo "  -> $SDIR/AppIcon.icns"
