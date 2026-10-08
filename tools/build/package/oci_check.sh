#!/bin/sh
# Reads an OCI image layout back and checks what an image must hold
# (oci_check.bzl, `oci_image_check`):
#   sh oci_check.sh <busybox> <out> <layout dir> <layer list> <entrypoint> [exec <path> | file <path>]...
# Red, naming each failure, unless:
#   * index.json names one manifest, and the layer list holds that manifest's
#     layer digests, one per line, in the manifest's order;
#   * the image config's Entrypoint is exactly [<entrypoint>];
#   * <entrypoint> and each `exec` path is a regular file with mode 0755, and
#     each `file` path a regular file of one byte or more, in the image's
#     filesystem: the layers applied in order (a later entry replaces an
#     earlier one, a `.wh.<name>` entry deletes <name>), symbolic links
#     followed (a path is relative to /, as in a layer);
#   * no entry of the last layer (the one the build adds) has another type
#     than the same path in a base layer: a directory over a base symlink
#     (`bin/` over `bin -> usr/bin`) would hide everything behind the link.
# Writes <out>, the list of what was checked, when nothing failed. Uses only
# the busybox applets, no network.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$1")
OUT=$(abs "$2")
LAYOUT=$(abs "$3")
LIST=$(abs "$4")
EP=$5
shift 5
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.oci_check" ;;
    /*) T="$BUCK_SCRATCH_PATH/oci_check" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/oci_check" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH

die() { printf 'oci_check: %s\n' "$*" >&2; exit 1; }
blob() { printf '%s/blobs/sha256/%s' "$LAYOUT" "${1#sha256:}"; }
digests() { grep -o '"digest":"sha256:[0-9a-f]\{64\}"' "$1" | sed 's/^"digest":"//; s/"$//'; }

digests "$LAYOUT/index.json" > "$T/index"
[ "$(wc -l < "$T/index")" -eq 1 ] || die "index.json names $(wc -l < "$T/index") manifests, want 1"
M=$(blob "$(cat "$T/index")")
# komira_pack writes JSON with sorted keys, so the config descriptor comes
# first and every later digest is a layer's, in order.
case "$(head -c 10 "$M")" in '{"config":') ;; *) die "the manifest does not begin with its config descriptor" ;; esac
digests "$M" > "$T/all"
C=$(blob "$(head -n 1 "$T/all")")
tail -n +2 "$T/all" > "$T/layers"
N=$(wc -l < "$T/layers")
[ "$N" -ge 1 ] || die "the manifest names no layer"

FAILED=""
fail() { FAILED="$FAILED
  $*"; }

cmp -s "$T/layers" "$LIST" || fail "the layer list is not the manifest's layers in order: list $(tr '\n' ' ' < "$LIST")| manifest $(tr '\n' ' ' < "$T/layers")"

GOT=$(grep -o '"Entrypoint":[^]]*]' "$C" || echo "no Entrypoint")
[ "$GOT" = "\"Entrypoint\":[\"$EP\"]" ] || fail "the config's Entrypoint is not [\"$EP\"]: $GOT"

# One line per layer entry: <layer index> <type> <permissions> <size> <path>[ -> <target>].
: > "$T/listing"
i=0
while IFS= read -r d; do
    tar -tvzf "$(blob "$d")" | awk -v L="$i" '{
        line = $0
        for (k = 0; k < 5; k++) sub(/^[ ]*[^ ]+[ ]+/, "", line)
        print L, substr($1, 1, 1), substr($1, 2), $3, line
    }' >> "$T/listing"
    i=$((i + 1))
done < "$T/layers"

WANT=$(printf '%s\n' exec "${EP#/}" "$@")
printf '%s\n' "$WANT" > "$T/want"
awk -v last="$((N - 1))" '
function norm(p,    n, a, k, out, m) {
    n = split(p, a, "/"); m = 0
    for (k = 1; k <= n; k++) {
        if (a[k] == "" || a[k] == ".") continue
        if (a[k] == "..") { if (m > 0) m--; continue }
        out[++m] = a[k]
    }
    p = ""
    for (k = 1; k <= m; k++) p = p (k > 1 ? "/" : "") out[k]
    return p
}
function dirn(p,    k) { k = match(p, /\/[^\/]*$/); return k ? substr(p, 1, k - 1) : "" }
function resolve(p,    n, a, k, cur, hops, t) {
    n = split(norm(p), a, "/"); cur = ""
    for (k = 1; k <= n; k++) {
        cur = (cur == "" ? a[k] : cur "/" a[k])
        for (hops = 0; (cur in type) && type[cur] == "l" && hops < 32; hops++) {
            t = link[cur]
            cur = (t ~ /^\//) ? norm(t) : norm(dirn(cur) "/" t)
        }
    }
    return cur
}
FNR == NR {
    want[++nw] = $0
    next
}
{
    layer = $1; ty = $2; perm = $3; size = $4
    rest = $0
    for (k = 0; k < 4; k++) sub(/^[^ ]+ /, "", rest)
    tgt = ""
    if (ty == "l") { k = index(rest, " -> "); tgt = substr(rest, k + 4); rest = substr(rest, 1, k - 1) }
    if (ty == "h") ty = "-"
    p = norm(rest)
    base = p; sub(/^.*\//, "", base)
    if (base ~ /^\.wh\./) {
        if (base != ".wh..wh..opq") { gone = dirn(p); gone = (gone == "" ? "" : gone "/") substr(base, 5); delete type[gone] }
        next
    }
    if (layer == last && (p in basetype) && basetype[p] != ty)
        printf "the last layer turns %s from type %s into type %s\n", p, basetype[p], ty
    if (layer != last) basetype[p] = ty
    type[p] = ty; mode[p] = perm; bytes[p] = size; link[p] = tgt
}
END {
    for (k = 1; k + 1 <= nw; k += 2) {
        kind = want[k]; p = want[k + 1]; r = resolve(p)
        if (!(r in type)) { printf "%s %s: not in the image\n", kind, p; continue }
        if (type[r] != "-") { printf "%s %s: %s is of type %s, not a regular file\n", kind, p, r, type[r]; continue }
        if (kind == "exec" && mode[r] != "rwxr-xr-x") printf "exec %s: %s has mode %s, want rwxr-xr-x\n", p, r, mode[r]
        else if (kind == "file" && bytes[r] + 0 < 1) printf "file %s: %s is empty\n", p, r
        else if (kind != "exec" && kind != "file") printf "unknown check %s\n", kind
        else printf "ok %s %s -> %s\n", kind, p, r
    }
}' "$T/want" "$T/listing" > "$T/found"
grep '^ok ' "$T/found" > "$T/ok" || true
while IFS= read -r line; do
    case "$line" in ok\ *) ;; *) fail "$line" ;; esac
done < "$T/found"

if [ -n "$FAILED" ]; then
    printf 'oci_check: %s:%s\n' "$LAYOUT" "$FAILED" >&2
    exit 1
fi
{
    printf 'entrypoint %s\nlayers %s\n' "$EP" "$N"
    cat "$T/ok"
} > "$OUT"
rm -rf "$T"
