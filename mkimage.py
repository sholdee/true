#!/usr/bin/env python3
"""Build a minimal single-layer OCI image around one binary, as a `docker load`-able tar.

The image is just what the OCI image spec requires: a config with architecture,
os, rootfs and Cmd; a manifest with two descriptors; one gzip layer holding the
binary. No history, timestamps, Env, WorkingDir or attestations. For a 103-byte
binary that is about 700 bytes of registry content versus ~1.4 KB from
`docker build` (and several KB more if buildx attaches provenance on push).

usage: mkimage.py BINARY OUT.tar [--ref docker.io/library/true:min] [--path /true]
                                 [--arch amd64] [--truncate-tar]

--truncate-tar  end the layer tar right after the file data, dropping the 512-byte
                padding and the two end-of-archive blocks. Go's archive/tar (Docker,
                containerd) tolerates this; the spec does not promise it.
"""
import argparse
import gzip
import hashlib
import io
import json
import tarfile

MANIFEST_MT = "application/vnd.oci.image.manifest.v1+json"


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def compact(obj):
    return json.dumps(obj, separators=(",", ":")).encode()


def layer_tar(path, data, truncate):
    hdr = tarfile.TarInfo(path.lstrip("/"))
    hdr.size, hdr.mode, hdr.mtime = len(data), 0o755, 0
    raw = hdr.tobuf(tarfile.USTAR_FORMAT) + data
    if not truncate:
        raw += b"\0" * ((-len(data)) % 512) + b"\0" * 1024
    return raw


def build(data, *, path="/true", arch="amd64", ref="docker.io/library/true:min", truncate=False):
    raw = layer_tar(path, data, truncate)
    gz = gzip.compress(raw, 9, mtime=0)
    config = compact({"architecture": arch, "os": "linux", "config": {"Cmd": [path]},
                      "rootfs": {"type": "layers", "diff_ids": [sha(raw)]}})
    manifest = compact({"schemaVersion": 2, "mediaType": MANIFEST_MT,
                        "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                                   "digest": sha(config), "size": len(config)},
                        "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                                    "digest": sha(gz), "size": len(gz)}]})
    index = compact({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json",
                     "manifests": [{"mediaType": MANIFEST_MT, "digest": sha(manifest),
                                    "size": len(manifest),
                                    "platform": {"architecture": arch, "os": "linux"},
                                    "annotations": {"org.opencontainers.image.ref.name": ref}}]})
    blobs = {"layer": gz, "config": config, "manifest": manifest}
    return blobs, index, len(raw)


def write_layout(out, blobs, index):
    with tarfile.open(out, "w") as t:
        def add(name, b):
            ti = tarfile.TarInfo(name)
            ti.size, ti.mtime = len(b), 0
            t.addfile(ti, io.BytesIO(b))
        add("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
        add("index.json", index)
        for b in blobs.values():
            add("blobs/sha256/" + sha(b)[7:], b)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("binary"); ap.add_argument("out")
    ap.add_argument("--ref", default="docker.io/library/true:min")
    ap.add_argument("--path", default="/true"); ap.add_argument("--arch", default="amd64")
    ap.add_argument("--truncate-tar", action="store_true")
    a = ap.parse_args()
    data = open(a.binary, "rb").read()
    blobs, index, rawlen = build(data, path=a.path, arch=a.arch, ref=a.ref, truncate=a.truncate_tar)
    write_layout(a.out, blobs, index)
    sizes = {k: len(v) for k, v in blobs.items()}
    print(f"binary={len(data)} raw-tar={rawlen} layer={sizes['layer']} config={sizes['config']} "
          f"manifest={sizes['manifest']} registry-bytes={sum(sizes.values())}")
