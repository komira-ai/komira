#!/usr/bin/env bash
# formats.sh -- tests of the package formats of //tools/build/examples:hello (//tools/build/package).
#
# usage: tools/build/tests/functional/formats.sh   (from anywhere; BUCK2 overrides)
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
#   long-path tests//functional/formats:long_bundle holds a file whose path in the
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
# The uncached reproducibility of these files is checked by tools/build/tests/functional/bundle.sh.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$ROOT" || exit 2
if [ -z "${BUCK2:-}" ]; then
    BUCK2="$ROOT/buck2"
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_formats.XXXXXX")
fails=0
pass() { echo "PASS  formats $1"; }
fail() { echo "FAIL  formats $1"; fails=$((fails + 1)); }
# shellcheck source=tools/build/tests/tool_lib.sh
. "$ROOT/tools/build/tests/tool_lib.sh"
export INSPECT_LOG="$W/inspect_build.log"
EPOCH=1970-01-01T00:00:00Z
TAB=$(printf '\t')

# The reads of a tarball or an image print one line per problem into $P, and
# a summary on success; `inspect_tool` (tools/build/inspect) reads the tar
# headers and the JSON.
problem() { echo "$1" >> "$P"; }

bundle_listing() { # dir: "<path>\t<mode>\t<sha256>" per file, "<path>/\t755\t-" per directory
    (
        cd "$1" || exit 2
        find . -mindepth 1 -type d -printf '%P/\t755\t-\n'
        find . -mindepth 1 ! -type d \( -perm /111 -printf '%P\t755\n' -o -printf '%P\t644\n' \) |
            while IFS="$TAB" read -r p m; do
                printf '%s\t%s\t%s\n' "$p" "$m" "$(sha256sum < "$p" | cut -c1-64)"
            done
    ) | LC_ALL=C sort
}

gzip_header() { # file what: the fixed gzip header (mtime 0, OS 255)
    local h
    h=$(head -c 10 "$1" | od -An -tx1 | tr -d ' \n')
    [ "$h" = 1f8b08000000000000ff ] || problem "$2: gzip header $h is not the fixed one (mtime 0, OS 255)"
}

tar_listing() { # file.tar prefix what: checks the determinism rules; prints "<rel>\t<mode>\t<sha256>" under prefix
    local rows
    : > "$P.names"
    if ! rows=$(inspect_tool tar "$1"); then
        problem "$3: $rows"
        return
    fi
    printf '%s\n' "$rows" | awk -F '\t' -v prefix="$2" -v what="$3" -v P="$P" '
        NF < 10 { next }
        {
            name = $1; names[++n] = name
            if ($8 != "0" || $4 != "0" || $5 != "0" || $6 != "" || $7 != "")
                print what ": " name ": mtime/uid/gid/uname/gname " $8 "/" $4 "/" $5 "/\047" $6 "\047/\047" $7 "\047" >> P
            if ($2 != "f" && $2 != "d") { print what ": " name ": neither a file nor a directory" >> P; next }
            mode = 0
            for (i = 1; i <= length($3); i++) mode = mode * 8 + substr($3, i, 1)
            want = ($2 == "d" || int(mode / 64) % 2 || int(mode / 8) % 2 || mode % 2) ? "755" : "644"
            if ($3 != want) print what ": " name ": mode 0o" $3 ", want 0o" want >> P
            if (substr(name, 1, length(prefix)) != prefix) {
                if (substr(prefix, 1, length(name)) != name) print what ": " name " is outside " prefix >> P
                next
            }
            rel = substr(name, length(prefix) + 1)
            if (rel != "") print rel "\t" $3 "\t" $10
        }
        END { for (i = 1; i <= n; i++) print names[i] > (P ".names") }'
    if ! LC_ALL=C sort -c "$P.names" 2> /dev/null; then
        problem "$3: entries are not in sorted order"
    fi
    if [ -n "$(LC_ALL=C sort "$P.names" | uniq -d)" ]; then
        problem "$3: duplicate entries"
    fi
    rm -f "$P.names"
}

same_tree() { # archive listing, bundle listing, what
    LC_ALL=C diff <(LC_ALL=C sort "$1") "$2" | sed -n 's/^< /in the archive only: /p; s/^> /in the bundle only: /p' |
        while IFS= read -r line; do problem "$3: $line"; done
}

tarball_check() { # bundle file.tar.gz top
    : > "$P"
    gzip_header "$2" tarball
    gzip -dc "$2" > "$W/t.tar" || problem "tarball: cannot decompress"
    tar_listing "$W/t.tar" "$3/" tarball > "$W/t.list"
    bundle_listing "$1" > "$W/b.list"
    same_tree "$W/t.list" "$W/b.list" tarball
    [ -s "$P" ] && return 1
    echo "$(grep -c . "$W/t.list") entries under $3/, sorted, mtime/uid/gid 0, gzip header fixed, equal to the bundle"
}

jv() { # flattened-json key path (tab-separated) -> value
    awk -F '\t' -v k="$2" 'index($0, k "\t") == 1 && NF == split(k, parts, "\t") + 1 { print $NF }' "$1"
}

blob() { # digest [size]: the path of that blob of $LAYOUT, checked against its name and size
    local f="$LAYOUT/blobs/sha256/${1#sha256:}"
    if [ ! -f "$f" ]; then
        problem "blob $1 is missing"
        return
    fi
    [ "sha256:$(sha256sum < "$f" | cut -c1-64)" = "$1" ] || problem "blob $1 does not hash to its name"
    if [ -n "${2:-}" ] && [ "$(wc -c < "$f")" != "$2" ]; then
        problem "blob $1: size $(wc -c < "$f"), descriptor says $2"
    fi
    echo "$f"
}

image_check() { # bundle layout docker-archive digest-file pins-file name
    local bundle=$1 archive=$3 name=$6 f md mdsize digest manifest config nlayers base diffs last ours
    LAYOUT=$2
    : > "$P"
    for f in "$LAYOUT"/blobs/sha256/*; do blob "sha256:${f##*/}" > /dev/null; done
    [ "$(inspect_tool json-canon "$LAYOUT/oci-layout")" = '{"imageLayoutVersion":"1.0.0"}' ] || problem "oci-layout is not version 1.0.0"
    inspect_tool json "$LAYOUT/index.json" > "$W/index.tsv" || problem "index.json: $(head -n 1 "$W/index.tsv")"
    if [ "$(awk -F '\t' '$1 == "manifests" { print $2 }' "$W/index.tsv" | sort -u | grep -c .)" != 1 ]; then
        problem "index.json does not name exactly one manifest"
        return 1
    fi
    local arch os nplat
    arch=$(jv "$W/index.tsv" "manifests${TAB}0${TAB}platform${TAB}architecture")
    os=$(jv "$W/index.tsv" "manifests${TAB}0${TAB}platform${TAB}os")
    nplat=$(awk -F '\t' '$1 == "manifests" && $3 == "platform"' "$W/index.tsv" | grep -c .)
    [ "$os/$arch/$nplat" = linux/amd64/2 ] || problem "index platform $os/$arch ($nplat keys), want linux/amd64"
    md=$(jv "$W/index.tsv" "manifests${TAB}0${TAB}digest")
    mdsize=$(jv "$W/index.tsv" "manifests${TAB}0${TAB}size")
    digest=$(tr -d '[:space:]' < "$4")
    [ "$digest" = "$md" ] || problem "[digest] $digest is not the index's manifest $md"
    manifest=$(blob "$md" "$mdsize")
    inspect_tool json "$manifest" > "$W/manifest.tsv" || problem "manifest: $(head -n 1 "$W/manifest.tsv")"
    config=$(blob "$(jv "$W/manifest.tsv" "config${TAB}digest")" "$(jv "$W/manifest.tsv" "config${TAB}size")")
    inspect_tool json "$config" > "$W/config.tsv" || problem "config: $(head -n 1 "$W/config.tsv")"
    awk -F '\t' '$1 == "layers" && $3 == "digest" { print $4 }' "$W/manifest.tsv" > "$W/layers.txt"
    nlayers=$(grep -c . "$W/layers.txt")
    base=$(head -n $((nlayers - 1)) "$W/layers.txt")
    # pins: the base manifest, the base config (replaced by ours), the layers.
    [ "$base" = "$(tail -n +3 "$5")" ] || problem "base layers $((nlayers - 1)) differ from the $(($(grep -c . "$5") - 2)) pinned ones"
    diffs=$(awk -F '\t' '$1 == "rootfs" && $2 == "diff_ids" { print $4 }' "$W/config.tsv")
    [ "$(printf '%s\n' "$diffs" | grep -c .)" = "$nlayers" ] || problem "$(printf '%s\n' "$diffs" | grep -c .) diff_ids for $nlayers layers"
    last=$((nlayers - 1))
    ours=$(blob "$(tail -n 1 "$W/layers.txt")" "$(jv "$W/manifest.tsv" "layers${TAB}${last}${TAB}size")")
    if [ -n "$ours" ]; then
        gzip_header "$ours" "image layer"
        gzip -dc "$ours" > "$W/layer.tar" || problem "image layer: cannot decompress"
        [ "sha256:$(sha256sum < "$W/layer.tar" | cut -c1-64)" = "$(printf '%s\n' "$diffs" | tail -n 1)" ] ||
            problem "the last diff_id is not the sha256 of the uncompressed layer"
        tar_listing "$W/layer.tar" "opt/$name/" "image layer" > "$W/l.list"
        bundle_listing "$bundle" > "$W/b.list"
        same_tree "$W/l.list" "$W/b.list" "image layer"
    fi
    for i in $(seq 0 $((nlayers - 2))); do
        blob "$(sed -n "$((i + 1))p" "$W/layers.txt")" "$(jv "$W/manifest.tsv" "layers${TAB}${i}${TAB}size")" > /dev/null
    done
    [ "$(awk -F '\t' '$1 == "config" && $2 == "Entrypoint"' "$W/config.tsv")" = "config${TAB}Entrypoint${TAB}0${TAB}/opt/$name/bin/$name" ] ||
        problem "Entrypoint $(awk -F '\t' '$1 == "config" && $2 == "Entrypoint" { print $NF }' "$W/config.tsv" | paste -sd ' ' -)"
    ! grep -q "^config${TAB}Cmd${TAB}" "$W/config.tsv" || problem "Cmd is set"
    [ "$(jv "$W/config.tsv" architecture)/$(jv "$W/config.tsv" os)" = amd64/linux ] ||
        problem "config platform $(jv "$W/config.tsv" os)/$(jv "$W/config.tsv" architecture), want linux/amd64"
    if [ "$(jv "$W/config.tsv" created)" != "$EPOCH" ] ||
        awk -F '\t' -v e="$EPOCH" '
            $1 == "history" { entry[$2] = 1 }
            $1 == "history" && $3 == "created" && NF == 4 && $4 == e { ok[$2] = 1 }
            END { for (i in entry) if (!(i in ok)) bad = 1; exit !bad }' "$W/config.tsv"; then
        problem "a timestamp in the config is not $EPOCH"
    fi
    inspect_tool json-canon "$config" | cmp -s - "$config" || problem "the config is not compact JSON with sorted keys"
    # The docker archive: the layout's files, plus manifest.json.
    rm -rf "$W/dock" && mkdir -p "$W/dock" && tar -xf "$archive" -C "$W/dock" || problem "docker archive: cannot unpack"
    (cd "$LAYOUT" && find . -type f -printf '%P\n') | while IFS= read -r f; do
        cmp -s "$LAYOUT/$f" "$W/dock/$f" || problem "docker archive: $f missing or different"
    done
    inspect_tool json "$W/dock/manifest.json" > "$W/dm.tsv" || problem "docker archive manifest.json: $(head -n 1 "$W/dm.tsv")"
    if [ "$(jv "$W/dm.tsv" "0${TAB}Config")" != "blobs/sha256/$(jv "$W/manifest.tsv" "config${TAB}digest" | cut -c8-)" ] ||
        [ "$(awk -F '\t' '$1 == "0" && $2 == "Layers" { print $4 }' "$W/dm.tsv")" != "$(sed 's|^sha256:|blobs/sha256/|' "$W/layers.txt")" ]; then
        problem "docker archive: manifest.json does not name the image's config and layers in order"
    fi
    tar_listing "$archive" "" "docker archive" > /dev/null
    [ -s "$P" ] && return 1
    echo "$(printf '%s' "$digest" | cut -c1-19): $nlayers layers ($((nlayers - 1)) pinned base + the bundle at /opt/$name/), every blob hashes to its name, entrypoint /opt/$name/bin/$name, linux/amd64, timestamps $EPOCH"
}

pax_member() { # file.tar name what: prints the sha256 of the one PAX-named member called name
    local rows
    rows=$(inspect_tool tar "$1" | awk -F '\t' -v n="$2" '$1 == n')
    if [ "$(printf '%s\n' "$rows" | grep -c .)" != 1 ] || [ "$(printf '%s\n' "$rows" | cut -f 9)" != 1 ] || [ "${#2}" -le 100 ]; then
        echo "$3: $2 is not one PAX-named member" >&2
        return 1
    fi
    printf '%s\n' "$rows" | cut -f 10
}

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
P="$W/tarball.txt"
if tarball_check "$B" "$TB" hello-0.1.0 > "$W/tarball.sum"; then
    pass "tarball: $(basename "$TB"): $(cat "$W/tarball.sum")"
else
    fail "tarball: $(head -n 4 "$P" | tr '\n' ' ')"
fi

# ---- image -------------------------------------------------------------------
# The pins: the container base is a field of the linux-x86_64 row of the platform
# table, which toolchains/BUCK reads. In order: manifest, config, layers.
OCI=$(awk '/^    "linux-x86_64": \{/ { r = 1 } r && /^        "oci_base": \{/ { o = 1; next } o && /^        \},/ { exit } o { print }' tools/build/platforms/table.bzl)
{
    printf '%s\n' "$OCI" | sed -nE 's/^ +"manifest": "(sha256:[0-9a-f]{64})",$/\1/p'
    printf '%s\n' "$OCI" | sed -nE 's/^ +"config": "(sha256:[0-9a-f]{64})",$/\1/p'
    printf '%s\n' "$OCI" | sed -nE 's/^ +"(sha256:[0-9a-f]{64})",$/\1/p'
} > "$W/pins.txt"
P="$W/image.txt"
if image_check "$B" "$IMG" "$AR" "$DG" "$W/pins.txt" hello > "$W/image.sum"; then
    pass "image: $(cat "$W/image.sum")"
else
    fail "image: $(head -n 4 "$P" | tr '\n' ' ')"
fi

# ---- long-path ---------------------------------------------------------------
LONG_REL="share/a-directory-name-long-enough-that/the-path-of-this-file-inside-a-tar-archive/is-over-one-hundred-bytes/long.txt"
LB=$(built tests//functional/formats:long_bundle)
LTB=$(built tests//functional/formats:long_tarball)
LIMG=$(built tests//functional/formats:long_image)
LAR=$(built "tests//functional/formats:long_image[docker_archive]")
LDG=$(built "tests//functional/formats:long_image[digest]")
problems=""
if [ ! -f "$LB/$LONG_REL" ] || [ ! -f "$LTB" ] || [ ! -f "$LAR" ]; then
    problems=" build-failed(see $W/build.log)"
else
    P="$W/long_tarball.txt"
    tarball_check "$LB" "$LTB" hello-0.1.0 > /dev/null ||
        problems="$problems tarball:[$(head -n 3 "$P" | tr '\n' ' ')]"
    P="$W/long_image.txt"
    image_check "$LB" "$LIMG" "$LAR" "$LDG" "$W/pins.txt" hello > /dev/null ||
        problems="$problems image:[$(head -n 3 "$P" | tr '\n' ' ')]"
    # The long file, under its full name through a PAX header, in both.
    gzip -dc "$LTB" > "$W/long_t.tar"
    tar -xOf "$LAR" manifest.json > "$W/long_dm.json"
    layer=$(inspect_tool json "$W/long_dm.json" | awk -F '\t' '$1 == "0" && $2 == "Layers" { l = $4 } END { print l }')
    tar -xOf "$LAR" "$layer" | gzip -dc > "$W/long_l.tar"
    if ! want=$(pax_member "$W/long_t.tar" "hello-0.1.0/$LONG_REL" tarball 2> "$W/long_pax.txt") ||
        ! got=$(pax_member "$W/long_l.tar" "opt/hello/$LONG_REL" "image layer" 2>> "$W/long_pax.txt"); then
        problems="$problems pax:[$(head -n 3 "$W/long_pax.txt" | tr '\n' ' ')]"
    elif [ "$want" != "$got" ]; then
        problems="$problems pax:[the image layer's copy differs from the tarball's]"
    fi
fi
if [ -n "$problems" ]; then fail "long-path:$problems"; else pass "long-path: a ${#LONG_REL}-byte bundle path is kept whole (PAX) in the tarball and the image layer, which still hold exactly the bundle"; fi

# ---- pinned ------------------------------------------------------------------
problems=""
mf=$(printf '%s\n' "$OCI" | sed -nE 's/^ +"manifest_file": "([^"]+)",$/\1/p')
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
    tar -xOf "$AR" manifest.json > "$W/dm_run.json"
    inspect_tool json "$W/dm_run.json" > "$W/dm_run.tsv"
    ref=$(jv "$W/dm_run.tsv" "0${TAB}RepoTags${TAB}0")
    config="sha256:$(jv "$W/dm_run.tsv" "0${TAB}Config" | sed 's|.*/||')"
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
    tar -xOf "$LAR" manifest.json > "$W/dm_long.json"
    lref=$(inspect_tool json "$W/dm_long.json" | awk -F '\t' '$1 == "0" && $2 == "RepoTags" && $3 == "0" { print $4 }')
    if ! timeout 180 docker load -i "$LAR" > "$W/load_long.log" 2>&1; then
        problems="$problems long-load-failed:[$(tail -n 2 "$W/load_long.log" | tr '\n' ' ')]"
    else
        cid=$(docker create "$lref" 2> "$W/create_long.log")
        if [ -z "$cid" ] || ! docker cp "$cid:/opt/hello/$LONG_REL" - 2> "$W/cp_long.log" | tar -xOf - > "$W/long_from_docker.txt"; then
            problems="$problems long-path-not-in-container:[$(head -c 200 "$W/cp_long.log")]"
        elif ! cmp -s "$W/long_from_docker.txt" tools/build/tests/functional/formats/long.txt; then
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
