# surface_capability_matrix.sh -- the action behind surface_capability_matrix.bzl.
# shellcheck shell=busybox
#
# usage: busybox sh surface_capability_matrix.sh census <busybox> <findings.txt>
#            <matrix.tsv> <report.txt> <surfaces.txt> <capabilities.tsv>
#            <not_capabilities.tsv> <rows.tsv> <families.tsv> <grounding dir>
#            <cell//root> <floor>
#            <expected matrix.tsv|-> <its name|-> <expected report.txt|-> <its name|->
#        busybox sh surface_capability_matrix.sh verdict <busybox> <result.json> <findings.txt> <report.txt>
#
# Two actions, because a validation's action writes exactly one file: the
# census writes the outputs below and the findings, one per line; the verdict
# turns them into <result.json>.
#
# The inputs, written by the rule's analysis (one record per line, fields
# separated by tabs):
#   <surfaces.txt>          a surface name per line, in report order;
#   <capabilities.tsv>      `name grounding meaning`, in report order;
#                           grounding is `contract` or comma-separated identifiers;
#   <not_capabilities.tsv>  `identifiers reason`: plan constants that are no capability;
#   <rows.tsv>              `n surface capability target note package test made ident`:
#                           the ledger's row n as written, then what the build
#                           graph says of its target: the package Buck2 puts it
#                           in (`cell//path`), whether it is a test (yes or no),
#                           the comma-separated packages whose targets made
#                           its default outputs (`-` when none has a maker),
#                           and which test it is however spelt (the targets that
#                           made its outputs, else its label), all `-` when the
#                           target is `-`;
#   <families.tsv>          `path prefixes`: a grounding file (under the
#                           grounding dir) and its comma-separated identifier
#                           prefixes, `-` for none.
#
# The rules (docs/surface_capability_matrix.md says the same). A finding,
# failing the build, is:
#   - a surface or capability name that is not [a-z][a-z0-9_]*, or listed twice;
#     a capability with no meaning; a not_capabilities row with no reason;
#   - a grounding identifier (of a capability or a not_capabilities row) that
#     no grounding file declares at column 0 as `comptime <ID>: UInt8 = ...`
#     or `comptime <ID> = UInt8(...)`;
#   - an identifier a grounding file declares that starts with one of its
#     prefixes and that no capability and no not_capabilities row names, or
#     that it declares in neither form and with no other type annotation;
#   - a row with an empty surface, capability or target, an unknown surface or
#     capability, or a pair that already has a row; a (surface, capability)
#     pair with no row;
#   - a row whose target is not in <cell//root>/tests/e2e/<surface>_e2e (the
#     surface's own package, exactly: not a subpackage, not a longer name), or
#     whose default outputs another package's target made (an alias of a test
#     elsewhere), or that is no test; a target that fills a second cell of the
#     same surface;
#   - fewer filled cells than <floor>.
# A missing cell (target `-`) is never a finding: the census lists it.
#
# Outputs. <matrix.tsv>: a header, then `surface capability status target
# note` for every known pair that has a row, by surface then capability in
# list order; status `filled` or `missing`. <report.txt>: the human summary;
# its third line is the totals. <result.json>: the validation result Buck2
# reads, "failure" with the findings, else "success" with the totals. With an
# expected file given, the output must equal it byte for byte (a fixture's
# assertion). Fails, checking nothing, with no surface or no capability. Only
# the pinned busybox runs: PATH is its applets.
set -eu
if [ "$1" = verdict ]; then
    BB=$2 RESULT=$3 FINDINGS=$4 REPORT=$5
    totals=$("$BB" sed -n 3p "$REPORT")
    if [ -s "$FINDINGS" ]; then
        msg=$("$BB" head -200 "$FINDINGS" | "$BB" tr -d '\000-\010\013-\037' |
            "$BB" awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); printf "%s\\n", $0 }')
        printf '{"version": 1, "data": {"status": "failure", "message": "surface_capability_matrix: %s finding line(s)\\n%s"}}\n' \
            "$("$BB" wc -l < "$FINDINGS" | "$BB" tr -d ' ')" "$msg" > "$RESULT"
    else
        printf '{"version": 1, "data": {"status": "success", "message": "surface_capability_matrix: %s"}}\n' "$totals" > "$RESULT"
    fi
    exit 0
fi
[ "$1" = census ] || { echo "surface_capability_matrix.sh: the first argument is census or verdict" >&2; exit 2; }
BB=$2 FINDINGS=$3 MATRIX=$4 REPORT=$5 SURFACES=$6 CAPS=$7 NOTS=$8 ROWS=$9
shift 9
FAMILIES=$1 GROUND=$2 ROOT=$3 FLOOR=$4 EXP_MX=$5 EXP_MX_NAME=$6 EXP_RP=$7 EXP_RP_NAME=$8
abs() { case "$1" in /* | -) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$BB") FINDINGS=$(abs "$FINDINGS") MATRIX=$(abs "$MATRIX") REPORT=$(abs "$REPORT")
SURFACES=$(abs "$SURFACES") CAPS=$(abs "$CAPS") NOTS=$(abs "$NOTS") ROWS=$(abs "$ROWS")
FAMILIES=$(abs "$FAMILIES") GROUND=$(abs "$GROUND") EXP_MX=$(abs "$EXP_MX") EXP_RP=$(abs "$EXP_RP")
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
: > "$T/findings"
: > "$T/declared"

# The identifiers each grounding file declares: `id<TAB>path<TAB>line<TAB>family<TAB>form`,
# family 1 when the identifier starts with one of the file's prefixes. A
# column-0 `comptime <ID>` declares a constant as `comptime <ID>: UInt8 = ...`
# or `comptime <ID> = UInt8(...)` (form `tag`); with another type annotation
# (`comptime <ID>: Int = ...`) it is no tag and is not listed; in any other
# form (no annotation and no `UInt8(`) it is listed with form `unread`, and a
# family identifier so written is a finding: never skipped silently.
while IFS="$(printf '\t')" read -r path prefixes; do
    awk -v path="$path" -v prefixes="$prefixes" '
        BEGIN { n = (prefixes == "-") ? 0 : split(prefixes, pre, ",") }
        /^comptime[ \t]+[A-Za-z_][A-Za-z0-9_]*/ {
            rest = $0; sub(/^comptime[ \t]+/, "", rest)
            match(rest, /^[A-Za-z_][A-Za-z0-9_]*/); id = substr(rest, 1, RLENGTH)
            rest = substr(rest, RLENGTH + 1); sub(/^[ \t]+/, "", rest)
            if (rest ~ /^:[ \t]*UInt8[ \t]*=/ || rest ~ /^=[ \t]*UInt8[ \t]*\(/) form = "tag"
            else if (rest ~ /^:/) next
            else form = "unread"
            fam = 0
            for (i = 1; i <= n; i++) if (index(id, pre[i]) == 1) fam = 1
            print id "\t" path "\t" FNR "\t" fam "\t" form
        }' "$GROUND/$path" >> "$T/declared"
done < "$FAMILIES"

# The checks and the census.
awk -F '\t' -v OFS='\t' -v surf="$SURFACES" -v caps="$CAPS" -v nots="$NOTS" -v rows="$ROWS" \
    -v decl="$T/declared" -v root="$ROOT" -v floor="$FLOOR" -v rep="$T/findings" \
    -v matrix="$MATRIX" -v cells="$T/cells" -v counts="$T/counts" '
    function bad(s) { print s >> rep }
    function isname(s) { return s ~ /^[a-z][a-z0-9_]*$/ }
    function grounded(what, list,   k, ids, i) {
        k = split(list, ids, ",")
        if (k == 0) bad(what ": no grounding identifier")
        for (i = 1; i <= k; i++) {
            if (ids[i] !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { bad(what ": grounding `" ids[i] "` is not an identifier"); continue }
            named[ids[i]] = 1
            if (!(ids[i] in declared)) bad(what ": grounding `" ids[i] "` is declared by no grounding file (as comptime " ids[i] ": UInt8)")
        }
    }
    BEGIN {
        while ((getline l < decl) > 0) {
            split(l, a, "\t")
            if (a[5] == "unread") {
                if (a[4] == 1) bad(a[2] ":" a[3] ": " a[1] " is a constant of a grounding family in a form this lint cannot read; declare it as `comptime " a[1] ": UInt8 = <n>`")
                continue
            }
            declared[a[1]] = 1
            if (a[4] == 1) { nf++; fid[nf] = a[1]; fwhere[nf] = a[2] ":" a[3] }
        }
        while ((getline l < surf) > 0) {
            if (!isname(l)) { bad("surfaces: `" l "` is not a name ([a-z][a-z0-9_]*)"); continue }
            if (l in isurf) { bad("surfaces: " l " is listed twice"); continue }
            ns++; isurf[l] = ns; sname[ns] = l
        }
        while ((getline l < caps) > 0) {
            split(l, a, "\t")
            if (!isname(a[1])) { bad("capabilities: `" a[1] "` is not a name ([a-z][a-z0-9_]*)"); continue }
            if (a[1] in icap) { bad("capabilities: " a[1] " is listed twice"); continue }
            nc++; icap[a[1]] = nc; cname[nc] = a[1]
            if (a[3] !~ /[^[:space:]]/) bad("capability " a[1] ": no meaning")
            if (a[2] != "contract") grounded("capability " a[1], a[2])
        }
        while ((getline l < nots) > 0) {
            split(l, a, "\t"); nn++
            if (a[2] !~ /[^[:space:]]/) bad("not_capabilities row " nn " (" a[1] "): no reason")
            grounded("not_capabilities row " nn, a[1])
        }
        for (i = 1; i <= nf; i++) if (!(fid[i] in named))
            bad(fwhere[i] ": " fid[i] " is a plan constant that no capability and no not_capabilities row names; ground a capability on it, or say in not_capabilities why it is none")

        filled = 0
        while ((getline l < rows) > 0) {
            split(l, a, "\t")
            n = a[1]; s = a[2]; c = a[3]; t = a[4]; note = a[5]; pkg = a[6]; test = a[7]; made = a[8]; ident = a[9]
            where = "matrix row " n " (" s ", " c ")"
            if (s == "" || c == "" || t == "") {
                bad(where ": an empty field (surface, capability and target are required; the target is `-` when none)")
                # The pair has its row, a malformed one: not also "no row".
                if (!((s SUBSEP c) in first)) { first[s SUBSEP c] = n; status[s SUBSEP c] = "missing"; target[s SUBSEP c] = t; nnote[s SUBSEP c] = note }
                continue
            }
            ok = 1
            if (!(s in isurf)) { bad(where ": unknown surface `" s "`"); ok = 0 }
            if (!(c in icap)) { bad(where ": unknown capability `" c "`"); ok = 0 }
            if (!ok) continue
            key = s SUBSEP c
            if (key in first) { bad(where ": a second row for the pair, first at row " first[key]); continue }
            first[key] = n
            if (t != "-") {
                want = root "/tests/e2e/" s "_e2e"
                if (pkg != want) bad(where ": " t " is in " pkg ", not " want ", the surface" "\047" "s own package")
                else if (made != "-") {
                    k = split(made, mk, ",")
                    for (i2 = 1; i2 <= k; i2++) if (mk[i2] != want)
                        bad(where ": " t " stands for a target of " mk[i2] " (its outputs are made there, as an alias" "\047" "s are), not of " want)
                }
                if (test != "yes") bad(where ": " t " is no test (it has no ExternalRunnerTestInfo and welds no test_srcs)")
                if ((s SUBSEP ident) in filler) bad(where ": " t " fills (" s ", " fillcap[s SUBSEP ident] ") already, at row " filler[s SUBSEP ident] "; each filled cell of a surface names a test of its own")
                else { filler[s SUBSEP ident] = n; fillcap[s SUBSEP ident] = c }
                filled++; status[key] = "filled"
            } else status[key] = "missing"
            target[key] = t; nnote[key] = note
        }
        print "surface", "capability", "status", "target", "note" > matrix
        printf "" > cells
        for (i = 1; i <= ns; i++) for (j = 1; j <= nc; j++) {
            key = sname[i] SUBSEP cname[j]
            if (!(key in status)) { bad("matrix: no row for (" sname[i] ", " cname[j] "); every pair has one, its target `-` when no test exercises it"); continue }
            print sname[i], cname[j], status[key], target[key], nnote[key] >> matrix
            print sname[i], cname[j], status[key] >> cells
        }
        if (filled < floor + 0)
            bad("floor: " filled " cell(s) are filled and the floor is " floor ": a filled cell was emptied or lost its test (lowering the floor is for review to refuse)")
        if (ns == 0 || nc == 0) bad("surface_capability_matrix: checked nothing (no surface or no capability)")
        print ns, nc, filled > counts
    }' /dev/null

# The human summary, from the matrix written above.
awk -F '\t' -v counts="$T/counts" -v floor="$FLOOR" '
    function pct(x, y) { if (y + 0 == 0) return "-"; return sprintf("%.1f%%", 100 * x / y) }
    NR == 1 { next }
    {
        if (!($1 in sseen)) { ns++; sseen[$1] = ns; sname[ns] = $1 }
        if (!($2 in cseen)) { nc++; cseen[$2] = nc; cname[nc] = $2 }
        N++; scell[$1]++; ccell[$2]++
        if ($3 == "filled") { F++; sfill[$1]++; cfill[$2]++; cby[$2] = cby[$2] " " $1 }
        else miss[++nm] = $1 " " $2
    }
    END {
        print "Surface capability matrix (floor " floor ")"
        print ""
        printf "cells: %d; filled: %d (%s); missing: %d\n", N, F, pct(F, N), N - F
        print ""
        print "by surface: filled/cells, percent"
        for (i = 1; i <= ns; i++) printf "  %-16s %4d/%-4d %7s\n", sname[i], sfill[sname[i]], scell[sname[i]], pct(sfill[sname[i]], scell[sname[i]])
        print ""
        print "by capability: filled/surfaces, the surfaces filled"
        for (i = 1; i <= nc; i++) printf "  %-16s %4d/%-4d %s\n", cname[i], cfill[cname[i]], ccell[cname[i]], (cby[cname[i]] == "" ? " -" : cby[cname[i]])
        print ""
        print "missing (surface capability):"
        for (i = 1; i <= nm; i++) print "  " miss[i]
    }' "$MATRIX" > "$REPORT"

# A fixture's assertion: the census equals the expected files.
for pair in "$MATRIX|$EXP_MX|$EXP_MX_NAME" "$REPORT|$EXP_RP|$EXP_RP_NAME"; do
    got=${pair%%|*} rest=${pair#*|}
    want=${rest%%|*} want_name=${rest#*|}
    [ "$want" = - ] && continue
    if ! cmp -s "$want" "$got"; then
        echo "the census differs from $want_name (- expected, + got):" >> "$T/findings"
        diff -u "$want" "$got" | sed '1,2d' | head -60 >> "$T/findings" || true
    fi
done

cp "$T/findings" "$FINDINGS"
rm -rf "$T"
