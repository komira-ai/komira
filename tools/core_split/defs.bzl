"""The two standing gates of the komira_core split, as test targets.

`core_frozen` holds a package's content to a recorded digest: the sha256 of
the listing `<sha256 of the file>  <path>` of every file, one per line, paths
sorted bytewise (check.py digest records and checks the same value).
`map_total` holds a map file to the package: one row per file, no row without
a file. Both read the package through its `doc_tree` (a package's every file;
tools/build/lint/doc_tree.bzl), so neither edits the package and both run
hermetically under the repository's busybox.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

# $1 busybox, $2 tree, $3 package directory in the tree, $4 digest file.
_FROZEN = """
BB="$1"; TREE="$2"; PKG="$3"; WANT="$4"
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "$TREE" in /*) ;; *) TREE="$PWD/$TREE" ;; esac
case "$WANT" in /*) ;; *) WANT="$PWD/$WANT" ;; esac
export LC_ALL=C
cd "$TREE/$PKG"
N=$("$BB" find -L . -type f | "$BB" wc -l)
HAVE=$("$BB" find -L . -type f | "$BB" cut -c3- | "$BB" sort | while IFS= read -r f; do
    printf '%s  %s\\n' "$("$BB" sha256sum "$f" | "$BB" cut -d' ' -f1)" "$f"
done | "$BB" sha256sum | "$BB" cut -d' ' -f1)
WANT=$("$BB" cut -d' ' -f1 "$WANT")
if [ "$HAVE" = "$WANT" ]; then
    echo "core_frozen GREEN $PKG $N files"
    exit 0
fi
echo "core_frozen RED: $PKG differs from the recorded freeze digest ($N files)"
echo "  want $WANT"
echo "  have $HAVE"
exit 1
"""

# $1 busybox, $2 tree, $3 package directory in the tree, $4 map file.
_MAP_TOTAL = """
BB="$1"; TREE="$2"; PKG="$3"; MAP="$4"
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "$TREE" in /*) ;; *) TREE="$PWD/$TREE" ;; esac
case "$MAP" in /*) ;; *) MAP="$PWD/$MAP" ;; esac
export LC_ALL=C
T="${TMPDIR:-/tmp}/map_total.$$"; "$BB" mkdir -p "$T"; trap '"$BB" rm -rf "$T"' EXIT
( cd "$TREE/$PKG" && "$BB" find -L . -type f | "$BB" cut -c3- | "$BB" sort ) > "$T/have"
"$BB" awk -F'\\t' '/^#/ { next } !header { header = 1; next } { print $1 }' "$MAP" | "$BB" sort > "$T/listed"
"$BB" uniq -d "$T/listed" > "$T/dup"
"$BB" uniq "$T/listed" > "$T/rows"
"$BB" comm -13 "$T/rows" "$T/have" > "$T/missing"
"$BB" comm -23 "$T/rows" "$T/have" > "$T/nofile"
if [ -s "$T/dup" ] || [ -s "$T/missing" ] || [ -s "$T/nofile" ]; then
    echo "map_total RED: $PKG against $(basename "$MAP")"
    echo "  duplicate rows: $("$BB" tr '\\n' ' ' < "$T/dup")"
    echo "  missing rows: $("$BB" tr '\\n' ' ' < "$T/missing")"
    echo "  rows with no file: $("$BB" tr '\\n' ' ' < "$T/nofile")"
    exit 1
fi
echo "map_total GREEN $PKG $("$BB" wc -l < "$T/rows") rows = $("$BB" wc -l < "$T/have") files"
exit 0
"""

def _test(script):
    def impl(ctx):
        bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
        tree = ctx.attrs.package[DefaultInfo].default_outputs[0]
        command = cmd_args(bb, "sh", "-euc", script, "sh", bb, tree, ctx.attrs.directory, ctx.attrs.record)
        return [
            DefaultInfo(),
            ExternalRunnerTestInfo(type = "custom", command = [command], labels = ["core_split"]),
        ]
    return impl

_ATTRS = {
    "directory": attrs.string(doc = "The package's directory in the repository, e.g. src/komira_core."),
    "package": attrs.dep(doc = "The package's :doc_tree."),
    "record": attrs.source(doc = "The digest file (core_frozen) or the map file (map_total)."),
    "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
}

_core_frozen = rule(
    impl = _test(_FROZEN),
    doc = "Fails while the package's files differ from the digest in `record`.",
    attrs = _ATTRS,
)

_map_total = rule(
    impl = _test(_MAP_TOTAL),
    doc = "Fails while `record` (a map) has a row twice, a row with no file, or misses a file of the package.",
    attrs = _ATTRS,
)

core_frozen = declares_docs(_core_frozen)
map_total = declares_docs(_map_total)
