# test_weld.sh -- the action behind test_weld.bzl.
# shellcheck shell=busybox
#
# usage: busybox sh test_weld.sh <busybox> <result.json> <tree> <prefix> <root>
#            <known_untested.tsv> <its name> <coverage_floor.tsv> <its name>
#
# Reads the packages under <tree>/<root> (each directory directly under
# <root> is one package) and requires three things:
#
#   1. Every test file is welded. A test file is a `test_*.mojo` under a
#      `tests/` directory of the package, at any depth. It is welded when the
#      BUCK file of its directory or of the nearest directory above it names
#      it as a string ("tests/test_x.mojo"), on a line that is not a comment:
#      in a mojo_library's `test_srcs` or in a mojo_test. A test named by no
#      BUCK file never runs.
#   2. Every package with a `.mojo` source (a `.mojo` file outside `tests/`)
#      welds at least one test.
#   3. Every package keeps the welded test files and test functions (lines
#      `fn test_...` or `def test_...` in its welded test files) that its row
#      in <coverage_floor.tsv> records, or more.
#
# A test file or a package that may break rule 1 or 2 has a row in
# <known_untested.tsv>, with the reason. The ledger only shrinks: a row whose
# test file is welded, or whose package welds a test, is a finding, so the
# change that welds it deletes the row. A row naming nothing that exists is a
# finding, and so is a floor row naming a package with no welded test.
#
# Ledger lines are `<path><TAB><reason>`, the path being `<root>/<package>`
# or a test file's path under <tree>; floor lines are
# `<package><TAB><test files><TAB><test functions>`. In both, blank lines
# and lines starting with `#` are comments.
#
# Writes <result.json>, the validation result Buck2 reads (ValidationInfo):
# status "failure" with the findings as the message, else "success". Checks
# nothing, so fails, when <root> holds no package. Findings name a file of
# the tree as <prefix><path>. Only the pinned busybox runs: PATH is its
# applets.
set -eu
BB=$1 RESULT=$2 TREE=$3 PREFIX=$4 ROOT=$5 LEDGER=$6 LEDGER_NAME=$7 FLOOR=$8 FLOOR_NAME=$9
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "$RESULT" in /*) ;; *) RESULT="$PWD/$RESULT" ;; esac
case "$LEDGER" in /*) ;; *) LEDGER="$PWD/$LEDGER" ;; esac
case "$FLOOR" in /*) ;; *) FLOOR="$PWD/$FLOOR" ;; esac
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

cd "$TREE"
if [ -d "$ROOT" ]; then
    find "$ROOT" \( -type f -o -type l \) \( -name BUCK -o -name '*.mojo' \) -print | sort > "$T/files"
else
    : > "$T/files"
fi
grep '/BUCK$' "$T/files" > "$T/bucks" || true
grep '\.mojo$' "$T/files" > "$T/mojo" || true

# Every .mojo path a BUCK file names on a line that is not a comment, as a
# path under the tree: <dir of the BUCK file>/<string>.
: > "$T/named"
if [ -s "$T/bucks" ]; then
    xargs awk '
        /^[[:space:]]*#/ { next }
        {
            d = FILENAME; sub(/\/[^\/]*$/, "", d)
            s = $0
            while (match(s, /"[^"]*\.mojo"/)) {
                print d "/" substr(s, RSTART + 1, RLENGTH - 2)
                s = substr(s, RSTART + RLENGTH)
            }
        }' < "$T/bucks" | sort -u > "$T/named"
fi

# Each .mojo file, classified: `src <package>`, or `test <package> welded|unwelded <path>`.
awk -v root="$ROOT" -v named="$T/named" '
    BEGIN { while ((getline n < named) > 0) w[n] = 1 }
    {
        rest = substr($0, length(root) + 2)
        pkg = rest; sub(/\/.*/, "", pkg)
        if (pkg == rest) next
        inpkg = substr(rest, length(pkg) + 2)
        intests = ("/" inpkg) ~ /\/tests\//
        base = $0; sub(/.*\//, "", base)
        if (!intests) print "src", pkg
        else if (base ~ /^test_.*\.mojo$/) print "test", pkg, (($0 in w) ? "welded" : "unwelded"), $0
    }' "$T/mojo" > "$T/classes"

# Test functions per package, over the welded test files.
: > "$T/fns"
awk '$1 == "test" && $3 == "welded" { print $4 }' "$T/classes" > "$T/welded"
if [ -s "$T/welded" ]; then
    xargs awk -v root="$ROOT" '
        /^[[:space:]]*(fn|def)[[:space:]]+test_/ {
            p = substr(FILENAME, length(root) + 2); sub(/\/.*/, "", p); n[p]++
        }
        END { for (p in n) print p, n[p] }' < "$T/welded" > "$T/fns"
fi

# One line per package: <package> <sources> <welded> <test functions>.
awk -v f="$T/fns" '
    BEGIN { while ((getline l < f) > 0) { split(l, a, " "); fns[a[1]] += a[2] } }
    { seen[$2] = 1 }
    $1 == "src" { src[$2]++ }
    $1 == "test" && $3 == "welded" { welded[$2]++ }
    END { for (p in seen) print p, src[p] + 0, welded[p] + 0, fns[p] + 0 }' "$T/classes" | sort > "$T/packages"
checked=$(wc -l < "$T/packages" | tr -d ' ')

# The ledger and the floor, with their line numbers; a malformed row is a finding.
awk -F '\t' -v name="$LEDGER_NAME" -v out="$T/ledger" -v rep="$T/report" '
    /^[[:space:]]*(#|$)/ { next }
    NF != 2 || $1 == "" || $2 !~ /[^[:space:]]/ {
        print name ":" NR ": a row is <path><TAB><reason>, with a reason" >> rep; next
    }
    $1 in row { print name ":" NR ": " $1 " has a row already, on line " row[$1] >> rep; next }
    { row[$1] = NR; print NR, $1 > out }' "$LEDGER"
[ -f "$T/ledger" ] || : > "$T/ledger"
awk -F '\t' -v name="$FLOOR_NAME" -v out="$T/floor" -v rep="$T/report" '
    /^[[:space:]]*(#|$)/ { next }
    NF != 3 || $1 == "" || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ {
        print name ":" NR ": a row is <package><TAB><test files><TAB><test functions>" >> rep; next
    }
    $1 in row { print name ":" NR ": " $1 " has a row already, on line " row[$1] >> rep; next }
    { row[$1] = NR; print NR, $1, $2, $3 > out }' "$FLOOR"
[ -f "$T/floor" ] || : > "$T/floor"

awk -v root="$ROOT" -v prefix="$PREFIX" -v lname="$LEDGER_NAME" -v fname="$FLOOR_NAME" \
    -v pk="$T/packages" -v cl="$T/classes" -v lg="$T/ledger" -v fl="$T/floor" '
    BEGIN {
        while ((getline < pk) > 0) { src[$1] = $2; welded[$1] = $3; fns[$1] = $4 }
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
                if (index(p, "/") || !(p in src) || src[p] == 0)
                    print at ": names neither a test file nor a package with a .mojo source; delete the row"
                else if (welded[p] > 0)
                    print at ": the package welds " welded[p] " test(s) now; delete the row (the ledger only shrinks)"
            }
        }
        for (path in state)
            if (state[path] == "unwelded" && !(path in lrow))
                print prefix path ": a test file no BUCK file names (test_srcs or a mojo_test), so it never runs; weld it, delete it, or give it a row in " lname
        for (p in src)
            if (src[p] > 0 && welded[p] == 0 && !((root "/" p) in lrow))
                print prefix root "/" p ": " src[p] " .mojo source(s) and no welded test; weld one in test_srcs, or give the package a row in " lname
        while ((getline < fl) > 0) {
            at = fname ":" $1 ": " $2
            if (!($2 in welded) || welded[$2] == 0)
                print at ": no welded test in " root "/" $2 "; delete the row, or weld the tests back"
            else {
                if (welded[$2] < $3) print at ": " welded[$2] " welded test file(s), below the floor of " $3
                if (fns[$2] < $4) print at ": " fns[$2] " test function(s) in welded files, below the floor of " $4
            }
        }
    }' | sort >> "$T/report"

[ "$checked" -gt 0 ] || echo "test_weld: checked nothing (no package under $ROOT)" >> "$T/report"
if [ -s "$T/report" ]; then
    msg=$(head -200 "$T/report" | tr -d '\000-\010\013-\037' |
        awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); printf "%s\\n", $0 }')
    printf '{"version": 1, "data": {"status": "failure", "message": "test_weld: %s finding line(s)\\n%s"}}\n' \
        "$(wc -l < "$T/report" | tr -d ' ')" "$msg" > "$RESULT"
else
    printf '{"version": 1, "data": {"status": "success", "message": "test_weld: %s packages checked"}}\n' "$checked" > "$RESULT"
fi
rm -rf "$T"
