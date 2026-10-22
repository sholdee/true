#!/usr/bin/env bash
# Publish the minimal OCI images (mkimage.py) to a registry, blobs and manifest byte for
# byte, then pull each tag back and run it.
#   ./publish.sh REGISTRY/REPO        e.g. ./publish.sh ghcr.io/sholdee/true
# Log in first (skopeo login + docker login). A localhost registry is pushed over plain HTTP.
# Tags are the binary name without its `true-` prefix (true-103 -> :103, pause-103 -> :pause-103);
# :latest and :pause point at the 103-byte variants, the smallest that also run under Rosetta.
# Pushing again from the same machine is a no-op: mkimage.py is deterministic for a given Python/zlib
# build (the gzip bytes, hence the digests, differ between e.g. macOS and Ubuntu at equal sizes).
set -euo pipefail
cd "$(dirname "$0")"
repo=${1:?usage: publish.sh REGISTRY/REPO}
images=(                              # binary, then its tags
  "true-112 112"
  "true-104 104"
  "true-103 103 latest"
  "true-80 80"
  "true-75 75"
  "pause-112 pause-112"
  "pause-104 pause-104"
  "pause-103 pause-103 pause"
  "pause-80 pause-80"
  "pause-75 pause-75"
  "pause-128-sigterm pause-128-sigterm"
)
tls=true; [[ $repo == localhost* || $repo == 127.* ]] && tls=false
plat=--platform=linux/amd64
mkdir -p out/oci
fail=0
printf '%-18s %5s  %-7s  %-5s  %s\n' tag bytes regbytes run digest
for entry in "${images[@]}"; do
  read -r bin tags <<<"$entry"
  tar=out/oci/$bin.tar
  sizes=$(python3 mkimage.py "out/$bin" "$tar" --ref "$repo:${tags%% *}")
  regbytes=${sizes##*registry-bytes=}
  local_digest=$(skopeo inspect --raw "oci-archive:$tar" | sha256sum | cut -c1-64)
  for tag in $tags; do
    ref=$repo:$tag
    skopeo copy -q --dest-tls-verify=$tls "oci-archive:$tar" "docker://$ref"
    remote_digest=$(skopeo inspect --raw --tls-verify=$tls "docker://$ref" | sha256sum | cut -c1-64)
    note=
    [ "$remote_digest" = "$local_digest" ] || { note=" DIGEST MISMATCH local=$local_digest"; fail=1; }
    docker pull -q $plat "$ref" >/dev/null
    if [[ $bin == pause-* ]]; then                 # must still be running after 2 s
      cid=$(docker run -d $plat "$ref"); code=$(timeout 2 docker wait "$cid" 2>/dev/null) && got=0 || got=$?
      docker rm -f "$cid" >/dev/null; run=alive; [ "$got" = 124 ] || { run="exit:${code:-?}"; fail=1; }
    else                                           # must exit 0
      docker run --rm $plat "$ref" && got=0 || got=$?; run="exit:$got"; [ "$got" = 0 ] || fail=1
    fi
    printf '%-18s %5d  %-7s  %-5s  sha256:%s%s\n' "$tag" "$(wc -c <"out/$bin")" "$regbytes" "$run" "$remote_digest" "$note"
  done
done
exit $fail
