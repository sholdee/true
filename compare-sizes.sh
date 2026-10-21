#!/usr/bin/env bash
# Registry bytes (manifest + config + compressed layer) for one binary, three ways:
# the Dockerfile via `docker buildx build --output type=oci`, and mkimage.py with a
# standard and a truncated layer tar.   usage: ./compare-sizes.sh [true-103]
set -euo pipefail
cd "$(dirname "$0")"; bin=${1:-true-103}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# The classic image store's default buildx driver has no OCI (or docker) file exporter;
# fall back to a docker-container builder, which does. BUILDER=<name> forces one.
builder=${BUILDER:-}
build() { docker buildx build -q ${builder:+--builder "$builder"} --platform linux/amd64 \
            --build-arg BIN="$bin" --output "type=oci,dest=$tmp/buildx.tar" . >/dev/null 2>"$tmp/err"; }
if ! build; then
  grep -q "not supported for the docker driver" "$tmp/err" || { cat "$tmp/err" >&2; exit 1; }
  builder=true-sizes
  docker buildx inspect "$builder" >/dev/null 2>&1 || docker buildx create --name "$builder" --driver docker-container >/dev/null
  build || { cat "$tmp/err" >&2; exit 1; }
fi
mkdir "$tmp/bx" && tar -xf "$tmp/buildx.tar" -C "$tmp/bx"
bx=$(python3 - "$tmp/bx" <<'PY'
import json, os, sys
d = sys.argv[1] + "/blobs/sha256"; sz = {}
for n in os.listdir(d):
    b = open(os.path.join(d, n), "rb").read()
    if b[:2] == b"\x1f\x8b": sz["layer"] = len(b)
    else:
        try: j = json.loads(b)
        except ValueError: continue
        sz["manifest" if "layers" in j else "config" if "rootfs" in j else "other"] = len(b)
print(f"layer={sz.get('layer',0)} config={sz.get('config',0)} manifest={sz.get('manifest',0)} "
      f"registry-bytes={sz.get('layer',0)+sz.get('config',0)+sz.get('manifest',0)}")
PY
)
std=$(python3 mkimage.py "out/$bin" "$tmp/min.tar")
trc=$(python3 mkimage.py "out/$bin" "$tmp/min-trunc.tar" --truncate-tar)
row() { local label=$1 s=$2; printf '%-28s %6s %7s %9s %10s\n' "$label" \
  "$(sed -E 's/.*layer=([0-9]+).*/\1/' <<<"$s")" "$(sed -E 's/.*config=([0-9]+).*/\1/' <<<"$s")" \
  "$(sed -E 's/.*manifest=([0-9]+).*/\1/' <<<"$s")" "$(sed -E 's/.*registry-bytes=([0-9]+).*/\1/' <<<"$s")"; }
printf '%-28s %6s %7s %9s %10s\n' "$bin ($(wc -c <"out/$bin" | tr -d ' ') B) via" layer config manifest total
row "Dockerfile (buildx oci export)" "$bx"
row "mkimage.py" "$std"
row "mkimage.py --truncate-tar" "$trc"
