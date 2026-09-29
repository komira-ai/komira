#!/usr/bin/env python3
"""Reads the tarball and the OCI image of a bundle and reports what is wrong.

usage:
  inspect_formats.py tarball <bundle dir> <file.tar.gz> <top dir>
  inspect_formats.py image <bundle dir> <layout dir> <docker archive> <digest file> <pins file> <name>

Prints one line per problem and exits 1 if there is any; otherwise prints one
summary line and exits 0. <pins file> holds the base image's pinned manifest,
config and layer digests, one per line, in that order.
"""

import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

EPOCH = "1970-01-01T00:00:00Z"
problems = []


def bad(msg):
    problems.append(msg)


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def bundle_listing(bundle):
    """path -> (mode, sha256) for every file; path/ -> (0o755, None) for every directory."""
    out = {}
    for root, dirs, files in os.walk(bundle):
        rel = os.path.relpath(root, bundle)
        for d in dirs:
            out[os.path.normpath(os.path.join(rel, d)) + "/"] = (0o755, None)
        for f in files:
            p = os.path.join(root, f)
            mode = 0o755 if os.stat(p).st_mode & 0o111 else 0o644
            with open(p, "rb") as fh:
                out[os.path.normpath(os.path.join(rel, f))] = (mode, sha(fh.read()))
    return out


def tar_listing(data, prefix, what):
    """Checks the determinism rules of one tar; returns path -> (mode, sha256) under prefix."""
    t = tarfile.open(fileobj=io.BytesIO(data), mode="r:")
    names = []
    out = {}
    for m in t.getmembers():
        name = m.name + ("/" if m.isdir() else "")
        names.append(name)
        if m.mtime != 0 or m.uid != 0 or m.gid != 0 or m.uname or m.gname:
            bad(f"{what}: {name}: mtime/uid/gid/uname/gname {m.mtime}/{m.uid}/{m.gid}/{m.uname!r}/{m.gname!r}")
        if not (m.isdir() or m.isfile()):
            bad(f"{what}: {name}: neither a file nor a directory")
            continue
        want = 0o755 if m.isdir() or m.mode & 0o111 else 0o644
        if m.mode != want:
            bad(f"{what}: {name}: mode {oct(m.mode)}, want {oct(want)}")
        if not name.startswith(prefix):
            if not prefix.startswith(name):
                bad(f"{what}: {name} is outside {prefix}")
            continue
        rel = name[len(prefix):]
        if rel:
            out[rel] = (m.mode, None if m.isdir() else sha(t.extractfile(m).read()))
    if names != sorted(names, key=lambda n: n.encode()):
        bad(f"{what}: entries are not in sorted order")
    if len(set(names)) != len(names):
        bad(f"{what}: duplicate entries")
    return out


def same_tree(got, want, what):
    for p in sorted(set(got) | set(want)):
        if got.get(p) != want.get(p):
            bad(f"{what}: {p}: {got.get(p)} in the archive, {want.get(p)} in the bundle")


def check_gzip_header(data, what):
    if data[:10] != bytes([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 255]):
        bad(f"{what}: gzip header {data[:10].hex()} is not the fixed one (mtime 0, OS 255)")


def tarball(bundle, path, top):
    data = open(path, "rb").read()
    check_gzip_header(data, "tarball")
    listing = tar_listing(gzip.decompress(data), top + "/", "tarball")
    same_tree(listing, bundle_listing(bundle), "tarball")
    return f"{len(listing)} entries under {top}/, sorted, mtime/uid/gid 0, gzip header fixed, equal to the bundle"


def image(bundle, layout, archive, digest_file, pins_file, name):
    pins = open(pins_file).read().split()
    blobs = os.path.join(layout, "blobs", "sha256")

    def blob(d, size=None):
        p = os.path.join(blobs, d.split(":", 1)[1])
        b = open(p, "rb").read()
        if sha(b) != d:
            bad(f"blob {d} does not hash to its name")
        if size is not None and len(b) != size:
            bad(f"blob {d}: size {len(b)}, descriptor says {size}")
        return b

    for f in sorted(os.listdir(blobs)):
        blob("sha256:" + f)
    if json.load(open(os.path.join(layout, "oci-layout"))) != {"imageLayoutVersion": "1.0.0"}:
        bad("oci-layout is not version 1.0.0")
    index = json.load(open(os.path.join(layout, "index.json")))
    if len(index.get("manifests", [])) != 1:
        bad("index.json does not name exactly one manifest")
        return ""
    md = index["manifests"][0]
    if md.get("platform") != {"architecture": "amd64", "os": "linux"}:
        bad(f"index platform {md.get('platform')}, want linux/amd64")
    digest = open(digest_file).read().strip()
    if digest != md["digest"]:
        bad(f"[digest] {digest} is not the index's manifest {md['digest']}")
    manifest = json.loads(blob(md["digest"], md["size"]))
    config_bytes = blob(manifest["config"]["digest"], manifest["config"]["size"])
    config = json.loads(config_bytes)
    layers = manifest["layers"]
    base = [l["digest"] for l in layers[:-1]]
    # pins: the base manifest, the base config (replaced by ours), the layers.
    if base != pins[2:]:
        bad(f"base layers {len(base)} differ from the {len(pins) - 2} pinned ones")
    diff_ids = config["rootfs"]["diff_ids"]
    if len(diff_ids) != len(layers):
        bad(f"{len(diff_ids)} diff_ids for {len(layers)} layers")
    ours = blob(layers[-1]["digest"], layers[-1]["size"])
    check_gzip_header(ours, "image layer")
    ours_tar = gzip.decompress(ours)
    if sha(ours_tar) != diff_ids[-1]:
        bad("the last diff_id is not the sha256 of the uncompressed layer")
    same_tree(tar_listing(ours_tar, f"opt/{name}/", "image layer"), bundle_listing(bundle), "image layer")
    for l in layers[:-1]:
        blob(l["digest"], l["size"])
    c = config.get("config", {})
    if c.get("Entrypoint") != [f"/opt/{name}/bin/{name}"]:
        bad(f"Entrypoint {c.get('Entrypoint')}")
    if "Cmd" in c:
        bad(f"Cmd {c['Cmd']} is set")
    if (config.get("architecture"), config.get("os")) != ("amd64", "linux"):
        bad(f"config platform {config.get('os')}/{config.get('architecture')}, want linux/amd64")
    if config.get("created") != EPOCH or any(h.get("created") != EPOCH for h in config.get("history", [])):
        bad("a timestamp in the config is not " + EPOCH)
    if json.dumps(config, sort_keys=True, separators=(",", ":")).encode() != config_bytes:
        bad("the config is not compact JSON with sorted keys")
    # The docker archive: the layout's files, plus manifest.json.
    t = tarfile.open(archive)
    members = {m.name: m for m in t.getmembers()}
    for root, _, files in os.walk(layout):
        for f in files:
            p = os.path.relpath(os.path.join(root, f), layout)
            if p not in members or t.extractfile(members[p]).read() != open(os.path.join(root, f), "rb").read():
                bad(f"docker archive: {p} missing or different")
    dm = json.loads(t.extractfile(members["manifest.json"]).read())
    if dm[0]["Config"] != "blobs/sha256/" + manifest["config"]["digest"][7:] or dm[0]["Layers"] != [
        "blobs/sha256/" + l["digest"][7:] for l in layers
    ]:
        bad("docker archive: manifest.json does not name the image's config and layers in order")
    tar_listing(open(archive, "rb").read(), "", "docker archive")
    return (
        f"{digest[:19]}: {len(layers)} layers ({len(base)} pinned base + the bundle at /opt/{name}/), "
        f"every blob hashes to its name, entrypoint /opt/{name}/bin/{name}, linux/amd64, timestamps {EPOCH}"
    )


def main():
    if sys.argv[1] == "tarball":
        summary = tarball(*sys.argv[2:5])
    elif sys.argv[1] == "image":
        summary = image(*sys.argv[2:8])
    else:
        sys.exit("usage: see the docstring")
    for p in problems[:20]:
        print(p)
    if problems:
        sys.exit(1)
    print(summary)


if __name__ == "__main__":
    main()
