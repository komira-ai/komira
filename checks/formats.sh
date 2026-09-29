#!/usr/bin/env bash
# formats.sh -- checks of the package formats of //examples:hello (//package).
#
# usage: checks/formats.sh   (from anywhere; BUCK2 overrides)
#
#   tarball   hello-0.1.0-linux-x86_64.tar.gz holds the bundle under
#             hello-0.1.0/: entries sorted, directories explicit, mtime and
#             uid/gid 0, empty user/group names, modes 0755/0644, the fixed
#             gzip header; its files equal the bundle's, modes included.
#   image     the OCI layout of //examples:hello_image: every blob hashes to
#             its name and has its descriptor's size; one manifest, platform
#             linux/amd64, and [digest] names it; the base layers are exactly
#             the pinned ones, in order; one diff_id per layer, the last the
#             sha256 of the uncompressed bundle layer, which holds the bundle
#             at /opt/hello/ under the tarball's rules; the config has
#             entrypoint /opt/hello/bin/hello, no Cmd, linux/amd64, every
#             timestamp 1970-01-01T00:00:00Z, sorted compact JSON; the docker
#             archive holds the layout's files plus a manifest.json naming the
#             same config and layers.
#   pinned    the base is pinned by digest and fetched only by declared
#             downloads: the checked-in base manifest hashes to its pin; the
#             only `download_file` in the rules is pinned_file's; no rule or
#             action script names a network tool; komira_pack runs as a static
#             executable with no shell.
#   run       `docker load` of [docker_archive], then `docker run --rm
#             --network none` prints the greeting and exits 0. Needs docker
#             usable without sudo; otherwise SKIP (the image checks above still
#             run).
#
# The uncached reproducibility of these files is checked by checks/bundle.sh.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
if [ -z "${BUCK2:-}" ]; then
    if command -v buck2 > /dev/null; then BUCK2=buck2; else BUCK2="$ROOT/tools/buck2"; fi
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_formats.XXXXXX")
fails=0
pass() { echo "PASS  formats $1"; }
fail() { echo "FAIL  formats $1"; fails=$((fails + 1)); }
INSPECT="$ROOT/checks/formats/inspect_formats.py"

built() { # target -> path of its (materialized) default output
    "$BUCK2" build "$1" --materializations all --show-full-simple-output 2>> "$W/build.log" | tail -n 1
}

B=$(built //examples:hello_bundle)
TB=$(built //examples:hello_tarball)
IMG=$(built //examples:hello_image)
AR=$(built "//examples:hello_image[docker_archive]")
DG=$(built "//examples:hello_image[digest]")
if [ ! -d "$B" ] || [ ! -f "$TB" ] || [ ! -d "$IMG" ] || [ ! -f "$AR" ] || [ ! -f "$DG" ]; then
    fail "build: cannot build the formats of //examples:hello (see $W/build.log)"
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
sed -n '/^oci_base(/,/^)/p' toolchains/BUCK | grep -oE 'sha256:[0-9a-f]{64}' > "$W/pins.txt"
if python3 "$INSPECT" image "$B" "$IMG" "$AR" "$DG" "$W/pins.txt" hello > "$W/image.txt" 2>&1; then
    pass "image: $(tail -n 1 "$W/image.txt")"
else
    fail "image: $(head -n 4 "$W/image.txt" | tr '\n' ' ')"
fi

# ---- pinned ------------------------------------------------------------------
problems=""
mf=$(sed -n '/^oci_base(/,/^)/p' toolchains/BUCK | sed -nE 's/.*manifest_file = "([^"]+)".*/\1/p')
[ "sha256:$(sha256sum < "toolchains/$mf" | cut -c1-64)" = "$(head -n 1 "$W/pins.txt")" ] ||
    problems="$problems base-manifest-does-not-hash-to-its-pin"
[ "$(wc -l < "$W/pins.txt")" -ge 3 ] || problems="$problems fewer-than-3-pins"
dl=$(grep -rlF 'download_file' --include='*.bzl' mojo package toolchains platforms 2> /dev/null | grep -vx 'mojo/download.bzl' | tr '\n' ' ')
[ -z "$dl" ] || problems="$problems download_file-outside-pinned_file:[$dl]"
net=$(grep -rlwE 'wget|curl|nc|ssh|git' --include='*.bzl' --include='*.sh' mojo package 2> /dev/null | tr '\n' ' ')
[ -z "$net" ] || problems="$problems network-tool-named-in:[$net]"
grep -qE 'ctx\.attrs\._pack\[RunInfo\],' package/defs.bzl || problems="$problems komira_pack-not-run-directly"
file_out=$(head -c 20 "$(built //package:komira_pack)" | od -An -c | tr -d ' \n')
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
    if ! timeout 180 docker load -i "$AR" > "$W/load.log" 2>&1; then
        problems="$problems load-failed:[$(tail -n 2 "$W/load.log" | tr '\n' ' ')]"
    else
        id=$(docker image inspect "$ref" --format '{{.Id}}' 2> /dev/null)
        [ "$id" = "$(cat "$DG")" ] || problems="$problems loaded-id-[$id]-is-not-[digest]"
        rc=0
        timeout 120 docker run --rm --network none --memory 2g "$ref" > "$W/run.out" 2>&1 || rc=$?
        [ "$rc" = 0 ] && [ "$(cat "$W/run.out")" = "hello from mojo" ] ||
            problems="$problems run:rc=$rc:[$(head -c 300 "$W/run.out")]"
        docker rmi "$ref" > /dev/null 2>&1
    fi
    if [ -n "$problems" ]; then fail "run:$problems"; else pass "run: docker load + docker run --network none $ref prints the greeting, image id = [digest]"; fi
else
    echo "SKIP  formats run: no docker usable without sudo (the tarball, image and pinned checks above still ran)"
fi

echo "logs: $W"
[ "$fails" = 0 ]
