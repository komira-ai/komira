# readme_api_coverage.sh -- the action behind readme_api_coverage.bzl.
# shellcheck shell=busybox
#
# usage: busybox sh readme_api_coverage.sh census <busybox> <readme tool> <findings.txt>
#            <packages.tsv> <symbols.tsv> <report.txt> <tree> <prefix> <root>
#            <exceptions.tsv> <its name> <enforce 0|1>
#            <expected packages.tsv|-> <its name|-> <expected symbols.tsv|-> <its name|->
#            <expected report.txt|-> <its name|->
#        busybox sh readme_api_coverage.sh verdict <busybox> <result.json> <findings.txt> <report.txt>
#
# Two actions, because a validation's action writes exactly one file: the
# census writes the outputs below and the findings, one per line; the verdict
# turns them into <result.json>.
#
# The census of README API coverage over the packages under <tree>/<root>
# (each directory directly under <root> holding a file is one package, except
# <root>/tests, which holds the test-only packages: they publish no API, so
# the census skips them). The
# rules (docs/readme_api_coverage.md says the same):
#
#   Public API. A package's public API is read from <root>/<package>/__init__.mojo:
#     - every name an import of the package's own modules binds at column 0,
#       relative (`from .x import A, B`) or by the package's name
#       (`from <package>.x import A`): the parenthesised and
#       backslash-continued forms, `from .x import A as B` binding B, and
#       `from . import x` binding the module x. An import from another
#       package (`from komira_log import X`) is not an export: the name is
#       counted in its own package;
#     - every column-0 `def`, `fn`, `struct`, `trait`, `comptime` or `alias`
#       declared in the `__init__.mojo` itself;
#     - for each exported struct, its public methods, named `<Exported>.<method>`:
#       a `def`/`fn` at four spaces in the struct's body (its header may
#       span lines), in the module the import names (`.x` -> x.mojo or x/),
#       else in any file of the package outside tests/. Overloads are one
#       symbol, at the first one's line. Struct-level `comptime` members
#       are not counted.
#   Only the top-level __init__.mojo is read: a package whose __init__.mojo
#   exports nothing (its users import its submodules) exports nothing here,
#   and the report names it.
#   A leading underscore is private (so dunder methods are not counted: they
#   are reached through syntax, not by name; for the same reason write_to and
#   write_repr_to, which print and String call, are not). Lines in comments and in
#   triple-quoted strings are not read. `from .x import *` cannot be listed:
#   the report names it and counts nothing for it.
#
#   Used. The README is <root>/<package>/README.md, read by the readme tool's
#   `generate`, the programs the welded `[tests][readme]` test runs (one per
#   example), so hidden lines are read and prose and non-`mojo` fences are
#   not. The generated lines (the header comment, a ```mojo example's
#   `def main() raises:`) are dropped, and the runner is not read; comments and string literals are blanked; `from`/`import` lines
#   are not uses (an imported name must also appear in code), nor is the
#   name a `def`, `fn`, `struct`, `trait`, `comptime`, `alias` or `var`
#   declares. A name is used when its identifier appears there as a token;
#   a method when `.<method>` does. Conservative by design: a use counts for
#   all overloads, and for every exported struct's method of that name.
#
#   Per package: exported N (names and methods), used U, U/N as a percentage
#   with one decimal ("-" when N is 0), the ledger rows that apply, and the
#   undocumented list. A package with no README scores 0 and says `none`; one
#   with no `__init__.mojo` (generated sources, or no Mojo) exports nothing
#   and says `init` no.
#
# The ledger <exceptions.tsv>: `<package><TAB><symbol><TAB><reason>`, blank
# lines and `#` lines are comments. A finding, failing the build, is a row
# that is malformed, repeats a row, names a symbol that is not exported, or
# names a symbol a README uses now (the ledger only shrinks). With enforce 1,
# an undocumented symbol with no row is a finding; with 0 (report-only) it
# is only listed.
#
# Outputs. <packages.tsv>: a header, then `package init readme exported used
# percent names names_used methods methods_used excepted undocumented`, by
# package; readme is `none`, `refused` (the tool refused it; its library's
# gate would too), `no-example`, or `examples:<n>`. <symbols.tsv>: a header,
# then `package symbol kind status where`, kind `name` or `method`, status
# `used`, `excepted` or `undocumented`, where `<path>:<line>` under the tree.
# <report.txt>: the human summary. <result.json>: the validation result
# Buck2 reads (ValidationInfo), "failure" with the findings, else "success"
# with the totals (the report's third line). With an expected file given,
# the output must equal it byte for byte (a fixture's assertion). Fails, checking nothing, when <root>
# holds no package. Only the pinned busybox and the readme tool run: PATH is
# the busybox applets.
set -eu
if [ "$1" = verdict ]; then
    BB=$2 RESULT=$3 FINDINGS=$4 REPORT=$5
    totals=$("$BB" sed -n 3p "$REPORT")
    if [ -s "$FINDINGS" ]; then
        msg=$("$BB" head -200 "$FINDINGS" | "$BB" tr -d '\000-\010\013-\037' |
            "$BB" awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); printf "%s\\n", $0 }')
        printf '{"version": 1, "data": {"status": "failure", "message": "readme_api_coverage: %s finding line(s)\\n%s"}}\n' \
            "$("$BB" wc -l < "$FINDINGS" | "$BB" tr -d ' ')" "$msg" > "$RESULT"
    else
        printf '{"version": 1, "data": {"status": "success", "message": "readme_api_coverage: %s"}}\n' "$totals" > "$RESULT"
    fi
    exit 0
fi
[ "$1" = census ] || { echo "readme_api_coverage.sh: the first argument is census or verdict" >&2; exit 2; }
BB=$2 TOOL=$3 FINDINGS=$4 PACKAGES=$5 SYMBOLS=$6 REPORT=$7 TREE=$8 PREFIX=$9
shift 9
ROOT=$1
shift
LEDGER=$1 LEDGER_NAME=$2 ENFORCE=$3 EXP_PK=$4 EXP_PK_NAME=$5 EXP_SY=$6 EXP_SY_NAME=$7 EXP_RP=$8 EXP_RP_NAME=$9
abs() { case "$1" in /* | -) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BB=$(abs "$BB") TOOL=$(abs "$TOOL") FINDINGS=$(abs "$FINDINGS") PACKAGES=$(abs "$PACKAGES")
SYMBOLS=$(abs "$SYMBOLS") REPORT=$(abs "$REPORT") LEDGER=$(abs "$LEDGER")
EXP_PK=$(abs "$EXP_PK") EXP_SY=$(abs "$EXP_SY") EXP_RP=$(abs "$EXP_RP")
# Scratch is per action, as in lint.sh: BUCK_SCRATCH_PATH, unset on a remote
# worker, whose root is the action's own.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/gen"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH
: > "$T/findings"
: > "$T/notes"
: > "$T/syms"
: > "$T/ids"
: > "$T/pkgs"
cd "$TREE"

# The exports of one __init__.mojo: `name<TAB>defined as<TAB>module path<TAB>line`.
# The module path is where a struct of that name is looked for: x/y for
# `from .x.y import`, `__init__` for a declaration here, `-` for a module.
EXPORTS_AWK='
function closed(s,   o, c) {
    if (s ~ /\\[ \t]*$/) return 0
    o = gsub(/\(/, "(", s); c = gsub(/\)/, ")", s)
    return o == c
}
function emit(s, ln,   mod, rest, k, items, i, it, w, nn, orig, name, path) {
    sub(/^from[ \t]+/, "", s)
    mod = s; sub(/[ \t].*/, "", mod)
    rest = s
    if (!sub(/^[^ \t]+[ \t]+import[ \t]+/, "", rest)) return
    gsub(/[()\\]/, " ", rest)
    k = split(rest, items, ",")
    for (i = 1; i <= k; i++) {
        it = items[i]; gsub(/^[ \t]+|[ \t]+$/, "", it)
        if (it == "") continue
        if (it == "*") { print "*\t*\t" mod "\t" ln; continue }
        nn = split(it, w, /[ \t]+/)
        orig = w[1]; name = (nn >= 3 && w[2] == "as") ? w[3] : orig
        if (name ~ /^_/ || name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) continue
        if (mod == ".") path = "-"
        else { path = substr(mod, 2); gsub(/\./, "/", path) }
        print name "\t" orig "\t" path "\t" ln
    }
}
{
    line = $0
    n = gsub(/"""/, "&", line)
    if (instr) { if (n % 2 == 1) instr = 0; next }
    if (n % 2 == 1) { instr = 1; next }
    if (pending != "") {
        s = $0; sub(/#.*/, "", s); sub(/\\[ \t]*$/, "", pending)
        pending = pending " " s
        if (closed(pending)) { emit(pending, start); pending = "" }
        next
    }
    if ($0 ~ /^from[ \t]+\./ || index($0, "from " pkg ".") == 1) {
        s = $0; sub(/#.*/, "", s)
        if (index(s, "from " pkg ".") == 1) s = "from ." substr(s, length(pkg) + 7)
        if (closed(s)) emit(s, NR); else { pending = s; start = NR }
        next
    }
    if ($0 ~ /^(def|fn|struct|trait|comptime|alias)[ \t]+[A-Za-z_]/) {
        s = $0; sub(/^[a-z]+[ \t]+/, "", s)
        match(s, /^[A-Za-z_][A-Za-z0-9_]*/); s = substr(s, 1, RLENGTH)
        if (s !~ /^_/) print s "\t" s "\t__init__\t" NR
    }
}'

# Every public method of every column-0 struct, in the files named on stdin:
# `struct<TAB>method<TAB>file<TAB>line`. A struct's header may span lines
# (`struct X[\n    T: AnyType,\n](Traits):`): its body starts after the line
# that closes its brackets and ends with `:`, so a column-0 `](...):` does not
# end it. write_to and write_repr_to are not counted: like the dunders, print
# and String reach them, not their names.
METHODS_AWK='
function depth(s,   o, c) { o = gsub(/[[(]/, "&", s); c = gsub(/[])]/, "&", s); return o - c }
FNR == 1 { instr = 0; cur = ""; hdr = 0 }
{
    line = $0
    n = gsub(/"""/, "&", line)
    if (instr) { if (n % 2 == 1) instr = 0; next }
    if (n % 2 == 1) { instr = 1; next }
    if (hdr) {
        s = $0; sub(/#.*/, "", s); d += depth(s)
        if (d <= 0 && s ~ /:[ \t]*$/) hdr = 0
        next
    }
    if ($0 ~ /^[^ \t#]/) {
        cur = ""
        if ($0 ~ /^struct[ \t]+[A-Za-z_]/) {
            s = $0; sub(/^struct[ \t]+/, "", s)
            match(s, /^[A-Za-z_][A-Za-z0-9_]*/); cur = substr(s, 1, RLENGTH)
            s = $0; sub(/#.*/, "", s); d = depth(s)
            hdr = !(d <= 0 && s ~ /:[ \t]*$/)
        }
        next
    }
    if (cur != "" && $0 ~ /^    (def|fn)[ \t]+[A-Za-z_]/) {
        s = $0; sub(/^    (def|fn)[ \t]+/, "", s)
        match(s, /^[A-Za-z_][A-Za-z0-9_]*/); s = substr(s, 1, RLENGTH)
        if (s !~ /^_/ && s != "write_to" && s != "write_repr_to") print cur "\t" s "\t" FILENAME "\t" FNR
    }
}'

# The uses in the generated README programs' copied code, one per line:
# `n<TAB>id` for an identifier, and also `a<TAB>id` when it is an attribute
# (`.id`). `def main() raises:` at column 0 is dropped (a ```mojo
# example's generated line; a ```mojo module example's own `main` declares
# a name, which is no use either), comments and string literals are blanked,
# `from`/`import` lines (and a parenthesised import's continuation) are not
# uses, and neither is the name a `def`, `fn`, `struct`, `trait`, `comptime`,
# `alias` or `var` declares.
IDS_AWK='
function scan(s,   i, c, out, d) {
    out = ""; i = 1
    while (i <= length(s)) {
        if (q != "") {
            if (substr(s, i, length(q)) == q) { i += length(q); q = ""; out = out " "; continue }
            if (substr(s, i, 1) == "\\") { i += 2; continue }
            i++; continue
        }
        c = substr(s, i, 1)
        if (c == "#") break
        if (c == "\"" || c == "\047") {
            d = c c c
            q = (substr(s, i, 3) == d) ? d : c
            i += length(q); out = out " "; continue
        }
        out = out c; i++
    }
    if (length(q) == 1) q = ""
    return out
}
function depth(s,   o, c) { o = gsub(/\(/, "(", s); c = gsub(/\)/, ")", s); return o - c }
{ l[NR] = $0 }
END {
    for (i = 1; i <= NR; i++) {
        if (l[i] == "def main() raises:") continue
        instr = (q != "")
        s = scan(l[i])
        if (imp > 0) { imp += depth(s); continue }
        if (!instr && l[i] ~ /^[ \t]*(from|import)[ \t]/) { imp = depth(s); if (imp < 0) imp = 0; continue }
        gsub(/\./, " .", s)
        gsub(/[^A-Za-z0-9_.]+/, " ", s)
        k = split(s, w, " ")
        prev = ""
        for (j = 1; j <= k; j++) {
            t = w[j]; attr = (substr(t, 1, 1) == ".")
            if (attr) t = substr(t, 2)
            if (t !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { prev = ""; continue }
            if (!attr && prev ~ /^(def|fn|struct|trait|comptime|alias|var)$/) { prev = t; continue }
            print "n\t" t
            if (attr) print "a\t" t
            prev = attr ? "" : t
        }
    }
}'

# The packages: every directory directly under the root that holds a file,
# except tests (the test-only packages, which publish no API).
if [ -d "$ROOT" ]; then
    find "$ROOT" \( -type f -o -type l \) -print |
        awk -F/ -v n="$(printf '%s' "$ROOT" | awk -F/ '{ print NF }')" 'NF > n + 1 && $(n + 1) != "tests" { print $(n + 1) }' |
        sort -u > "$T/packages"
else
    : > "$T/packages"
fi

while read -r p; do
    dir="$ROOT/$p"
    init=no
    if [ -f "$dir/__init__.mojo" ]; then
        init=yes
        awk -v pkg="$p" "$EXPORTS_AWK" "$dir/__init__.mojo" > "$T/exports"
        awk -F '\t' -v p="$p" -v f="$dir/__init__.mojo" '$1 == "*" {
            print p ": `from " $3 " import *` at " f ":" $4 ": its names cannot be listed, so none is counted" }' \
            "$T/exports" >> "$T/notes"
        find "$dir" \( -type f -o -type l \) -name '*.mojo' -print | grep -v '/tests/' | sort > "$T/srcs" || true
        : > "$T/methods"
        if [ -s "$T/srcs" ]; then
            xargs awk "$METHODS_AWK" < "$T/srcs" > "$T/methods"
        fi
        # Names, then the methods of the exported structs, in the module the
        # import names when a struct of that name is there.
        awk -F '\t' -v p="$p" -v dir="$dir/" -v me="$T/methods" '
            BEGIN { while ((getline l < me) > 0) { nm++; split(l, a, "\t"); ms[nm] = a[1]; mm[nm] = a[2]; mf[nm] = a[3]; ml[nm] = a[4] } }
            function inmod(f, path) {
                f = substr(f, length(dir) + 1)
                return f == path ".mojo" || index(f, path "/") == 1
            }
            $1 == "*" || ($1 in seen) { next }
            {
                seen[$1] = 1
                print p "\tname\t" $1 "\t" $1 "\t" dir "__init__.mojo:" $4
                if ($3 == "-") next
                local = 0
                for (i = 1; i <= nm; i++) if (ms[i] == $2 && inmod(mf[i], $3)) local = 1
                split("", got)
                for (i = 1; i <= nm; i++) {
                    if (ms[i] != $2 || (local && !inmod(mf[i], $3)) || (mm[i] in got)) continue
                    got[mm[i]] = 1
                    print p "\tmethod\t" $1 "." mm[i] "\t" mm[i] "\t" mf[i] ":" ml[i]
                }
            }' "$T/exports" >> "$T/syms"
    fi
    readme=none
    if [ -f "$dir/README.md" ]; then
        rc=0
        "$TOOL" generate --readme "$dir/README.md" --display "$dir/README.md" --package "$p" \
            --links allow --out-dir "$T/gen/$p" --examples "$T/gen/$p.examples" > "$T/gen/$p.log" 2>&1 || rc=$?
        if [ "$rc" -ne 0 ]; then
            readme=refused
            printf '%s: the readme tool refused %s/README.md (exit %s): %s\n' "$p" "$dir" "$rc" \
                "$(head -3 "$T/gen/$p.log" | tr '\n' ' ' | sed 's/ *$//')" >> "$T/notes"
        elif [ ! -s "$T/gen/$p.examples" ]; then
            readme=no-example
        else
            readme="examples:$(grep -c . "$T/gen/$p.examples")"
            sed "s|.*|$T/gen/$p/readme_${p}_&.mojo|" "$T/gen/$p.examples" | xargs awk "$IDS_AWK" |
                sort -u | awk -v p="$p" '{ print p "\t" $0 }' >> "$T/ids"
        fi
    fi
    printf '%s\t%s\t%s\n' "$p" "$init" "$readme" >> "$T/pkgs"
done < "$T/packages"
checked=$(wc -l < "$T/pkgs" | tr -d ' ')

# The ledger, with its line numbers; a malformed or repeated row is a finding.
awk -F '\t' -v name="$LEDGER_NAME" -v out="$T/ledger" -v rep="$T/findings" '
    BEGIN { printf "" > out }
    /^[[:space:]]*(#|$)/ { next }
    NF != 3 || $1 !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || $2 !~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$/ || $3 !~ /[^[:space:]]/ {
        print name ":" NR ": a row is <package><TAB><symbol><TAB><reason>, with a reason" >> rep; next
    }
    ($1 "\t" $2) in row { print name ":" NR ": " $1 " " $2 " has a row already, on line " row[$1 "\t" $2] >> rep; next }
    { row[$1 "\t" $2] = NR; print $1 "\t" $2 "\t" NR > out }' "$LEDGER"

# The census: symbols, packages, the report, and the ledger's findings.
printf 'package\tsymbol\tkind\tstatus\twhere\n' > "$SYMBOLS"
printf 'package\tinit\treadme\texported\tused\tpercent\tnames\tnames_used\tmethods\tmethods_used\texcepted\tundocumented\n' > "$PACKAGES"
awk -F '\t' -v OFS='\t' -v sy="$T/syms" -v ids="$T/ids" -v pk="$T/pkgs" -v lg="$T/ledger" \
    -v lname="$LEDGER_NAME" -v enforce="$ENFORCE" -v prefix="$PREFIX" -v root="$ROOT" \
    -v symbols="$SYMBOLS" -v packages="$PACKAGES" -v rep="$T/findings" -v undoc="$T/undoc" '
    function pct(x, y) { if (y + 0 == 0) return "-"; return sprintf("%.1f", 100 * x / y) }
    BEGIN {
        printf "" > undoc
        while ((getline l < ids) > 0) { split(l, a, "\t"); id[a[1] "\t" a[2] "\t" a[3]] = 1 }
        while ((getline l < lg) > 0) { split(l, a, "\t"); lrow[a[1] "\t" a[2]] = a[3] }
        while ((getline l < sy) > 0) {
            split(l, a, "\t")
            p = a[1]; kind = a[2]; s = a[3]; key = p "\t" s
            exported[key] = 1
            used = ((p "\t" (kind == "name" ? "n" : "a") "\t" a[4]) in id)
            status = used ? "used" : ((key in lrow) ? "excepted" : "undocumented")
            print p, s, kind, status, a[5] >> symbols
            n[p]++; if (used) u[p]++
            if (kind == "name") { nn[p]++; if (used) nu[p]++ } else { mn[p]++; if (used) mu[p]++ }
            if (status == "excepted") ex[p]++
            if (status == "undocumented") {
                un[p]++
                print p "\t" s "\t" a[5] > undoc
                if (enforce == 1)
                    print prefix a[5] ": " p " " s ": exported and used by no README example; use it in a ```mojo example of " root "/" p "/README.md, or give it a row in " lname >> rep
            }
            if (used && (key in lrow))
                print lname ":" lrow[key] ": " p " " s ": " root "/" p "/README.md uses it now; delete the row (the ledger only shrinks)" >> rep
        }
        for (key in lrow) if (!(key in exported)) {
            split(key, a, "\t")
            print lname ":" lrow[key] ": " a[1] " " a[2] ": not exported by " root "/" a[1] "/__init__.mojo; delete the row" >> rep
        }
        while ((getline l < pk) > 0) {
            split(l, a, "\t"); p = a[1]
            print p, a[2], a[3], n[p] + 0, u[p] + 0, pct(u[p] + 0, n[p] + 0), nn[p] + 0, nu[p] + 0, mn[p] + 0, mu[p] + 0, ex[p] + 0, un[p] + 0 >> packages
        }
    }' /dev/null

# The human summary.
awk -F '\t' -v notes="$T/notes" -v undoc="$T/undoc" -v enforce="$ENFORCE" '
    function pct(x, y) { if (y + 0 == 0) return "-"; return sprintf("%.1f%%", 100 * x / y) }
    NR == 1 { next }
    {
        np++; N += $4; U += $5; NN += $7; NU += $8; MN += $9; MU += $10; EX += $11; UN += $12
        if ($2 == "no") noinit = noinit " " $1
        else if ($4 == 0) noexp = noexp " " $1
        else if ($3 == "none") { noreadme++; noreadme_list = noreadme_list " " $1 }
        row[np] = sprintf("%-40s %6s %5d/%-5d names %d/%d methods %d/%d  %s", $1, pct($5, $4), $5, $4, $8, $7, $10, $9, $3)
    }
    END {
        print "README API coverage (" (enforce == 1 ? "enforcing" : "report-only") ")"
        print ""
        printf "packages: %d; exported: %d; used: %d (%s); names %d/%d (%s); methods %d/%d (%s); excepted: %d; undocumented: %d\n", np, N, U, pct(U, N), NU, NN, pct(NU, NN), MU, MN, pct(MU, MN), EX, UN
        print "packages with no __init__.mojo (nothing exported):" (noinit == "" ? " none" : noinit)
        print "packages whose __init__.mojo exports nothing (their API is their submodules, not counted):" (noexp == "" ? " none" : noexp)
        print "packages with an __init__.mojo and no README (0%): " noreadme + 0 (noreadme_list == "" ? "" : ":" noreadme_list)
        print ""
        print "by package: percent used/exported, names, methods, readme"
        for (i = 1; i <= np; i++) print "  " row[i]
        print ""
        print "notes:"
        while ((getline l < notes) > 0) print "  " l
        print ""
        print "undocumented (package, symbol, where):"
        while ((getline l < undoc) > 0) print "  " l
    }' "$PACKAGES" > "$REPORT"

# A fixture's assertion: the census equals the expected files.
for pair in "$PACKAGES|$EXP_PK|$EXP_PK_NAME" "$SYMBOLS|$EXP_SY|$EXP_SY_NAME" "$REPORT|$EXP_RP|$EXP_RP_NAME"; do
    got=${pair%%|*} rest=${pair#*|}
    want=${rest%%|*} want_name=${rest#*|}
    [ "$want" = - ] && continue
    if ! cmp -s "$want" "$got"; then
        echo "the census differs from $want_name (- expected, + got):" >> "$T/findings"
        diff -u "$want" "$got" | sed '1,2d' | head -60 >> "$T/findings" || true
    fi
done

[ "$checked" -gt 0 ] || echo "readme_api_coverage: checked nothing (no package under $ROOT)" >> "$T/findings"
cp "$T/findings" "$FINDINGS"
rm -rf "$T"
