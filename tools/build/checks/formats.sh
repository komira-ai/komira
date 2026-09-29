#!/usr/bin/env bash
# formats.sh -- checks of the package formats of //tools/build/examples:hello (//tools/build/package).
#
# usage: tools/build/checks/formats.sh   (from anywhere; BUCK2 overrides)
#
#   tarball   hello-0.1.0-linux-x86_64.tar.gz holds the bundle under
#             hello-0.1.0/: entries sorted, directories explicit, mtime and
#             uid/gid 0, empty user/group names, modes 0755/0644, the fixed
#             gzip header; its files equal the bundle's, modes included.
#   image     the OCI layout of //tools/build/examples:hello_image: every blob hashes to
#             its name and has its descriptor's size; one manifest, platform
#             linux/amd64, and [digest] names it; the base layers are exactly
#             the pinned ones, in order; one diff_id per layer, the last the
#             sha256 of the uncompressed bundle layer, which holds the bundle
#             at /opt/hello/ under the tarball's rules; the config has
#             entrypoint /opt/hello/bin/hello, no Cmd, linux/amd64, every
#             timestamp 1970-01-01T00:00:00Z, sorted compact JSON; the docker
#             archive holds the layout's files plus a manifest.json naming the
#             same config and layers.
#   long-path checks//formats:long_bundle holds a file whose path in the
#             tarball and in the image layer is over 100 bytes: both still
#             hold exactly the bundle (the same checks as above), that file
#             under its full name through a PAX header; with docker, `docker
#             load` of its archive restores the full name (`docker cp`).
#   pinned    the base is pinned by digest and fetched only by declared
#             downloads: the checked-in base manifest hashes to its pin; the
#             only `download_file` in the rules is pinned_file's; no rule or
#             action script names a network tool; komira_pack runs as a static
#             executable with no shell.
#   run       `docker load` of [docker_archive] names the image
#             komira/hello:0.1.0 and gives it the expected id (the manifest
#             digest, [digest], on docker's containerd image store; the config
#             digest on the classic store); `docker run --rm --network none`
#             prints the greeting and exits 0. Load, run and remove hold a
#             lock, so two concurrent runs on one docker daemon cannot remove
#             each other's image. Needs docker usable without sudo; otherwise
#             SKIP (the image checks above still run).
#
# The uncached reproducibility of these files is checked by tools/build/checks/bundle.sh.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT"
if [ -z "${BUCK2:-}" ]; then
    if command -v buck2 > /dev/null; then BUCK2=buck2; else BUCK2="$ROOT/tools/buck2"; fi
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_formats.XXXXXX")
fails=0
pass() { echo "PASS  formats $1"; }
fail() { echo "FAIL  formats $1"; fails=$((fails + 1)); }
INSPECT="$ROOT/tools/build/checks/formats/inspect_formats.py"

built() { # target -> path of its (materialized) default output
    "$BUCK2" build "$1" --materializations all --show-full-simple-output 2>> "$W/build.log" | tail -n 1
}

B=$(built //tools/build/examples:hello_bundle)
TB=$(built //tools/build/examples:hello_tarball)
IMG=$(built //tools/build/examples:hello_image)
AR=$(built "//tools/build/examples:hello_image[docker_archive]")
DG=$(built "//tools/build/examples:hello_image[digest]")
if [ ! -d "$B" ] || [ ! -f "$TB" ] || [ ! -d "$IMG" ] || [ ! -f "$AR" ] || [ ! -f "$DG" ]; then
    fail "build: cannot build the formats of //tools/build/examples:hello (see $W/build.log)"
    echo "logs: $W"; exit 1
fi

# ---- tarball -----------------------------------------------------------------
if python3 "$INSPECT" tarball "$B" "$TB" hello-0.1.0 > "$W/tarball.txt" 2>&1; then
    pass "tarball: $(basename "$TB"): $(tail -n 1 "$W/tarball.txt")"
else
    fail "tarball: $(head -n 4 "$W/tarball.txt" | tr '\n' ' ')"
fi

# ---- image -------------------------------------------------------------------
# The pins, in declaration order: manifest, config, layers.
sed -n '/^oci_base(/,/^)/p' tools/build/toolchains/BUCK | grep -oE 'sha256:[0-9a-f]{64}' > "$W/pins.txt"
if python3 "$INSPECT" image "$B" "$IMG" "$AR" "$DG" "$W/pins.txt" hello > "$W/image.txt" 2>&1; then
    pass "image: $(tail -n 1 "$W/image.txt")"
else
    fail "image: $(head -n 4 "$W/image.txt" | tr '\n' ' ')"
fi

# ---- long-path ---------------------------------------------------------------
LONG_REL="share/a-directory-name-long-enough-that/the-path-of-this-file-inside-a-tar-archive/is-over-one-hundred-bytes/long.txt"
LB=$(built checks//formats:long_bundle)
LTB=$(built checks//formats:long_tarball)
LIMG=$(built checks//formats:long_image)
LAR=$(built "checks//formats:long_image[docker_archive]")
LDG=$(built "checks//formats:long_image[digest]")
problems=""
if [ ! -f "$LB/$LONG_REL" ] || [ ! -f "$LTB" ] || [ ! -f "$LAR" ]; then
    problems=" build-failed(see $W/build.log)"
else
    python3 "$INSPECT" tarball "$LB" "$LTB" hello-0.1.0 > "$W/long_tarball.txt" 2>&1 ||
        problems="$problems tarball:[$(head -n 3 "$W/long_tarball.txt" | tr '\n' ' ')]"
    python3 "$INSPECT" image "$LB" "$LIMG" "$LAR" "$LDG" "$W/pins.txt" hello > "$W/long_image.txt" 2>&1 ||
        problems="$problems image:[$(head -n 3 "$W/long_image.txt" | tr '\n' ' ')]"
    python3 - "$LTB" "hello-0.1.0/$LONG_REL" "$LAR" "opt/hello/$LONG_REL" > "$W/long_pax.txt" 2>&1 << 'PY' || problems="$problems pax:[$(head -n 3 "$W/long_pax.txt" | tr '\n' ' ')]"
import io, json, sys, tarfile
def member(t, name, what):
    m = [x for x in t.getmembers() if x.name == name]
    if len(m) != 1 or "path" not in m[0].pax_headers or len(name) <= 100:
        sys.exit(f"{what}: {name} is not one PAX-named member")
    return t.extractfile(m[0]).read()
tb, tname, ar, iname = sys.argv[1:5]
want = member(tarfile.open(tb), tname, "tarball")
a = tarfile.open(ar)
layer = json.load(a.extractfile("manifest.json"))[0]["Layers"][-1]
got = member(tarfile.open(fileobj=io.BytesIO(a.extractfile(layer).read())), iname, "image layer")
if got != want:
    sys.exit("the image layer's copy differs from the tarball's")
PY
fi
if [ -n "$problems" ]; then fail "long-path:$problems"; else pass "long-path: a ${#LONG_REL}-byte bundle path is kept whole (PAX) in the tarball and the image layer, which still hold exactly the bundle"; fi

# ---- pinned ------------------------------------------------------------------
problems=""
mf=$(sed -n '/^oci_base(/,/^)/p' tools/build/toolchains/BUCK | sed -nE 's/.*manifest_file = "([^"]+)".*/\1/p')
[ "sha256:$(sha256sum < "tools/build/toolchains/$mf" | cut -c1-64)" = "$(head -n 1 "$W/pins.txt")" ] ||
    problems="$problems base-manifest-does-not-hash-to-its-pin"
[ "$(wc -l < "$W/pins.txt")" -ge 3 ] || problems="$problems fewer-than-3-pins"
# The directories searched below must exist: a grep over a missing directory
# finds nothing, which would read as "no download outside pinned_file".
for d in tools/build/mojo tools/build/package tools/build/toolchains tools/build/platforms; do
    [ -d "$d" ] || problems="$problems searched-directory-missing:$d"
done
dl=$(grep -rlF 'download_file' --include='*.bzl' tools/build/mojo tools/build/package tools/build/toolchains tools/build/platforms 2> /dev/null | grep -vx 'tools/build/mojo/download.bzl' | tr '\n' ' ')
[ -z "$dl" ] || problems="$problems download_file-outside-pinned_file:[$dl]"
net=$(grep -rlwE 'wget|curl|nc|ssh|git' --include='*.bzl' --include='*.sh' tools/build/mojo tools/build/package 2> /dev/null | tr '\n' ' ')
[ -z "$net" ] || problems="$problems network-tool-named-in:[$net]"
grep -qE 'ctx\.attrs\._pack\[RunInfo\],' tools/build/package/defs.bzl || problems="$problems komira_pack-not-run-directly"
file_out=$(head -c 20 "$(built //tools/build/package:komira_pack)" | od -An -c | tr -d ' \n')
case "$file_out" in *ELF*) ;; *) problems="$problems komira_pack-not-an-ELF" ;; esac
if [ -n "$problems" ]; then
    fail "pinned:$problems"
else
    pass "pinned: base manifest hashes to its pin, $(($(wc -l < "$W/pins.txt") - 1)) blobs fetched by pinned downloads only, no network tool in any rule"
fi

# ---- run ---------------------------------------------------------------------
if command -v docker > /dev/null && timeout 30 docker info > /dev/null 2>&1; then
    problems=""
    ref=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["RepoTags"][0])' <(tar -xOf "$AR" manifest.json))
    config=$(python3 -c 'import json,sys; print("sha256:" + json.load(open(sys.argv[1]))[0]["Config"].split("/")[-1])' <(tar -xOf "$AR" manifest.json))
    if docker info --format '{{json .DriverStatus}}' 2> /dev/null | grep -q 'io.containerd.snapshotter'; then
        want_id=$(cat "$DG"); store=containerd
    else
        want_id=$config; store=classic
    fi
    # Serialize load/run/rmi of this shared tag across concurrent runs.
    if command -v flock > /dev/null; then
        exec 9> "${XDG_RUNTIME_DIR:-/tmp}/komira_formats_docker.lock" && flock -w 600 9
    fi
    if ! timeout 180 docker load -i "$AR" > "$W/load.log" 2>&1; then
        problems="$problems load-failed:[$(tail -n 2 "$W/load.log" | tr '\n' ' ')]"
    else
        id=$(docker image inspect "$ref" --format '{{.Id}}' 2> /dev/null)
        [ "$id" = "$want_id" ] || problems="$problems loaded-id-[$id]-is-not-[$want_id]-($store-store)"
        rc=0
        timeout 120 docker run --rm --network none --memory 2g "$ref" > "$W/run.out" 2>&1 || rc=$?
        [ "$rc" = 0 ] && [ "$(cat "$W/run.out")" = "hello from mojo" ] ||
            problems="$problems run:rc=$rc:[$(head -c 300 "$W/run.out")]"
        docker rmi "$ref" > /dev/null 2>&1
    fi
    lref=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["RepoTags"][0])' <(tar -xOf "$LAR" manifest.json))
    if ! timeout 180 docker load -i "$LAR" > "$W/load_long.log" 2>&1; then
        problems="$problems long-load-failed:[$(tail -n 2 "$W/load_long.log" | tr '\n' ' ')]"
    else
        cid=$(docker create "$lref" 2> "$W/create_long.log")
        if [ -z "$cid" ] || ! docker cp "$cid:/opt/hello/$LONG_REL" - 2> "$W/cp_long.log" | tar -xOf - > "$W/long_from_docker.txt"; then
            problems="$problems long-path-not-in-container:[$(head -c 200 "$W/cp_long.log")]"
        elif ! cmp -s "$W/long_from_docker.txt" tools/build/checks/formats/long.txt; then
            problems="$problems long-path-content-differs"
        fi
        [ -n "$cid" ] && docker rm "$cid" > /dev/null 2>&1
        docker rmi "$lref" > /dev/null 2>&1
    fi
    exec 9>&-
    if [ -n "$problems" ]; then fail "run:$problems"; else pass "run: docker load + docker run --network none $ref prints the greeting, image id = the $store store's ($(echo "$want_id" | cut -c1-19)); the long path survives docker load"; fi
else
    echo "SKIP  formats run: no docker usable without sudo (the tarball, image and pinned checks above still ran)"
fi

if [ "$fails" = 0 ]; then rm -rf "$W"; else echo "logs: $W"; fi
[ "$fails" = 0 ]
