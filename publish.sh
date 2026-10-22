#!/usr/bin/env bash
# Publish the minimal OCI images (mkimage.py) as two images, `true` and `pause`, blobs and
# manifest byte for byte via skopeo, then pull each tag back and run it.
#   ./publish.sh REGISTRY/NAMESPACE        e.g. ./publish.sh ghcr.io/sholdee   -> ghcr.io/sholdee/true, .../pause
# Log in first (skopeo login + docker login). A localhost registry is pushed over plain HTTP.
# Tags name where the image runs, not its byte count (the README table has the sizes):
#   latest  runs everywhere a linux/amd64 image can, including under Rosetta/binfmt_misc
#   native  any real x86-64 Linux kernel only
#   min     native only, and maps ~4 GiB of address space
# pause:latest is the SIGTERM-handler variant so `docker stop` and pod deletion return at once.
# Pushing again from the same machine is a no-op: mkimage.py is deterministic for a given Python/zlib
# build (the gzip bytes, hence the digests, differ between e.g. macOS and Ubuntu at equal sizes).
set -euo pipefail
cd "$(dirname "$0")"
ns=${1:?usage: publish.sh REGISTRY/NAMESPACE}
images=(                              # binary  image:tag
  "true-103           true:latest"
  "true-80            true:native"
  "true-75            true:min"
  "pause-128-sigterm  pause:latest"
  "pause-80           pause:native"
  "pause-75           pause:min"
)
tls=true; [[ $ns == localhost* || $ns == 127.* ]] && tls=false
plat=--platform=linux/amd64
mkdir -p out/oci
fail=0
printf '%-6s %-7s %5s  %-7s  %-5s  %s\n' image tag bytes regbytes run digest
for entry in "${images[@]}"; do
  read -r bin target <<<"$entry"
  image=${target%%:*}; tag=${target#*:}; ref=$ns/$target
  tar=out/oci/$bin.tar
  sizes=$(python3 mkimage.py "out/$bin" "$tar" --ref "$ref")
  regbytes=${sizes##*registry-bytes=}
  local_digest=$(skopeo inspect --raw "oci-archive:$tar" | sha256sum | cut -c1-64)
  skopeo copy -q --dest-tls-verify=$tls "oci-archive:$tar" "docker://$ref"
  remote_digest=$(skopeo inspect --raw --tls-verify=$tls "docker://$ref" | sha256sum | cut -c1-64)
  note=
  [ "$remote_digest" = "$local_digest" ] || { note=" DIGEST MISMATCH local=$local_digest"; fail=1; }
  docker pull -q $plat "$ref" >/dev/null
  if [[ $image == pause ]]; then                   # must still be running after 2 s
    cid=$(docker run -d $plat "$ref"); code=$(timeout 2 docker wait "$cid" 2>/dev/null) && got=0 || got=$?
    docker rm -f "$cid" >/dev/null; run=alive; [ "$got" = 124 ] || { run="exit:${code:-?}"; fail=1; }
  else                                             # must exit 0
    docker run --rm $plat "$ref" && got=0 || got=$?; run="exit:$got"; [ "$got" = 0 ] || fail=1
  fi
  printf '%-6s %-7s %5d  %-7s  %-5s  sha256:%s%s\n' "$image" "$tag" "$(wc -c <"out/$bin")" "$regbytes" "$run" "$remote_digest" "$note"
done
exit $fail
