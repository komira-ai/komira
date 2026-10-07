# test_weld.sh -- the action behind test_weld.bzl.
# shellcheck shell=busybox
#
# usage: busybox sh test_weld.sh <busybox> <result.json> <mojo> <prefix> <root>
#            <known_untested.tsv> <its name> <welded>
#
# <mojo> lists the .mojo files of the tree, one path in the cell per line;
# <welded> the welded test files, likewise (test_weld.bxl writes both). Reads
# the packages under <root> and requires two things. Each directory directly
# under <root> is one package, except <root>/tests, which is not a package but
# holds them by kind: each directory <root>/tests/<kind>/<name> is one (the
# test-only packages, docs/architecture.md#end-to-end-tests). A .mojo file
# directly in <root>/tests or in <root>/tests/<kind> is in no package.
#
#   1. Every test file is welded. A test file is a `test_*.mojo` under a
#      `tests/` directory of the package, at any depth. It is welded when its
#      path is a line of <welded>: the test files the targets of the build
#      graph run (a mojo_library's `test_srcs`, a mojo_test's `main`). A test
#      no target runs never runs.
#   2. Every package with a `.mojo` source (a `.mojo` file outside `tests/`)
#      welds at least one test.
#
# A test file or a package that may break rule 1 or 2 has a row in
# <known_untested.tsv>, with the reason. The ledger only shrinks: a row whose
# test file is welded, or whose package welds a test, is a finding, so the
# change that welds it deletes the row. A row naming nothing that exists is a
# finding.
#
# Ledger lines are `<path><TAB><reason>`, the path being `<root>/<package>`
# (`<root>/tests/<kind>/<name>` for a test-only one) or a test file's path;
# blank lines and lines starting with `#` are comments.
#
# Writes <result.json> (status "success") when it finds nothing. A finding
# fails the action instead, printing the findings on stderr (which is how
# test_weld.bxl reports them): <result.json> is not written. Checks
# nothing, so fails, when <root> holds no package. Findings name a file as
# <prefix><path>. Only the pinned busybox runs: PATH is its
# applets.
set -eu
BB=$1 RESULT=$2 MOJO=$3 PREFIX=$4 ROOT=$5 LEDGER=$6 LEDGER_NAME=$7 WELDED=$8
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "$RESULT" in /*) ;; *) RESULT="$PWD/$RESULT" ;; esac
case "$LEDGER" in /*) ;; *) LEDGER="$PWD/$LEDGER" ;; esac
case "$MOJO" in /*) ;; *) MOJO="$PWD/$MOJO" ;; esac
case "$WELDED" in /*) ;; *) WELDED="$PWD/$WELDED" ;; esac
# Scratch is per action, as in lint.sh: BUCK_SCRATCH_PATH, unset on a remote
# worker, whose root is the action's own.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH
: > "$T/report"

# The .mojo files under <root>, from the list.
awk -v root="$ROOT/" 'index($0, root) == 1 && /\.mojo$/' "$MOJO" | sort -u > "$T/mojo"
# The welded test files, from the graph; blank lines are none.
grep -v '^$' "$WELDED" | sort -u > "$T/named" || true

# Each .mojo file, classified: `src <package>`, or `test <package> welded|unwelded <path>`.
awk -v root="$ROOT" -v named="$T/named" '
    BEGIN { while ((getline n < named) > 0) w[n] = 1 }
    {
        rest = substr($0, length(root) + 2)
        pkg = rest; sub(/\/.*/, "", pkg)
        if (pkg == rest) next
        if (pkg == "tests") {
            # <root>/tests holds packages by kind: the package is tests/<kind>/<name>.
            n = split(rest, part, "/")
            if (n < 4) next
            pkg = part[1] "/" part[2] "/" part[3]
        }
        inpkg = substr(rest, length(pkg) + 2)
        intests = ("/" inpkg) ~ /\/tests\//
        base = $0; sub(/.*\//, "", base)
        if (!intests) print "src", pkg
        else if (base ~ /^test_.*\.mojo$/) print "test", pkg, (($0 in w) ? "welded" : "unwelded"), $0
    }' "$T/mojo" > "$T/classes"

# One line per package: <package> <sources> <welded test files>.
awk '
    { seen[$2] = 1 }
    $1 == "src" { src[$2]++ }
    $1 == "test" && $3 == "welded" { welded[$2]++ }
    END { for (p in seen) print p, src[p] + 0, welded[p] + 0 }' "$T/classes" | sort > "$T/packages"
checked=$(wc -l < "$T/packages" | tr -d ' ')

# The ledger, with its line numbers; a malformed row is a finding.
awk -F '\t' -v name="$LEDGER_NAME" -v out="$T/ledger" -v rep="$T/report" '
    /^[[:space:]]*(#|$)/ { next }
    NF != 2 || $1 == "" || $2 !~ /[^[:space:]]/ {
        print name ":" NR ": a row is <path><TAB><reason>, with a reason" >> rep; next
    }
    $1 in row { print name ":" NR ": " $1 " has a row already, on line " row[$1] >> rep; next }
    { row[$1] = NR; print NR, $1 > out }' "$LEDGER"
[ -f "$T/ledger" ] || : > "$T/ledger"

awk -v root="$ROOT" -v prefix="$PREFIX" -v lname="$LEDGER_NAME" \
    -v pk="$T/packages" -v cl="$T/classes" -v lg="$T/ledger" '
    BEGIN {
        while ((getline < pk) > 0) { src[$1] = $2; welded[$1] = $3 }
        while ((getline < cl) > 0) if ($1 == "test") state[$4] = $3
        while ((getline < lg) > 0) { lrow[$2] = $1 }
        for (path in lrow) {
            at = lname ":" lrow[path] ": " path
            if (index(path, root "/") != 1) {
                print at ": not under " root "/"
            } else if (path in state) {
                if (state[path] == "welded")
                    print at ": the test is welded now; delete the row (the ledger only shrinks)"
            } else {
                p = substr(path, length(root) + 2)
                if (!(p in src) || src[p] == 0)
                    print at ": names neither a test file nor a package with a .mojo source; delete the row"
                else if (welded[p] > 0)
                    print at ": the package welds " welded[p] " test(s) now; delete the row (the ledger only shrinks)"
            }
        }
        for (path in state)
            if (state[path] == "unwelded" && !(path in lrow))
                print prefix path ": a test file no target welds (test_srcs or a mojo_test), so it never runs; weld it, delete it, or give it a row in " lname
        for (p in src)
            if (src[p] > 0 && welded[p] == 0 && !((root "/" p) in lrow))
                print prefix root "/" p ": " src[p] " .mojo source(s) and no welded test; weld one in test_srcs, or give the package a row in " lname
    }' | sort >> "$T/report"

[ "$checked" -gt 0 ] || echo "test_weld: checked nothing (no package under $ROOT)" >> "$T/report"
status=0
if [ -s "$T/report" ]; then
    echo "test_weld: $(wc -l < "$T/report" | tr -d ' ') finding line(s)" >&2
    head -200 "$T/report" >&2
    status=1
else
    printf '{"version": 1, "data": {"status": "success", "message": "test_weld: %s packages checked"}}\n' "$checked" > "$RESULT"
fi
rm -rf "$T"
exit "$status"
