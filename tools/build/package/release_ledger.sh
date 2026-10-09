# release_ledger.sh -- the action behind release_ledger.bzl.
# shellcheck shell=busybox
#
# usage: busybox sh release_ledger.sh <busybox> <out> <census.tsv> \
#            <artifacts.textproto> <unreleased.textproto> "<REASON> ..."
#
# <census.tsv> (library_census): `<dir>\t<native 0|1>\t<readme 0|1>\t<deps>`
# per library directory under src/. A directory is declared when an
# `artifacts { }` block of <artifacts.textproto> holds
# `targets: "//src/<dir>:<target>_conda"` (a conda package of a library of
# that directory). Every
# other line of <unreleased.textproto> that is not blank or a `#` comment is
# one row, exactly
#
#     libraries { name: "<dir>" reason: <REASON> }
#     libraries { name: "<dir>" reason: PENDING_DECLARE pr: <N> }
#
# with <REASON> one of the last argument's words. Refused, one line each on
# stderr, exit 1, <out> not written:
#
#   * a library in neither file; one in both; a directory listed or declared
#     twice; a row or a declared artifact whose directory holds no library;
#   * a line that is not a row; rows not sorted by name; a reason outside
#     the set; `pr:` missing on PENDING_DECLARE or present on another reason;
#   * a reason that disagrees with the census. NATIVE, DLOPEN and NO_README
#     take precedence in that order, so: NATIVE if and only if its closure
#     links native code; otherwise, unless it is DLOPEN, NO_README if and
#     only if it has no README; UNDECLARED_DEP only if one of its deps is not
#     declared. DLOPEN (its own source opens a shared library at run time,
#     which the packer refuses: pack/conda.zig) is read from no input here, so
#     it is not checked; nor are NO_CLOUD_CHECK, TEST_SUPPORT and the PR
#     number of PENDING_DECLARE;
#   * an empty census, or an artifacts file that declares no library: a check
#     that read nothing.
#
# On success <out> holds the counts per reason. Only the pinned busybox runs.
set -eu
BB=$1 OUT=$2 CENSUS=$3 ARTIFACTS=$4 LEDGER=$5 REASONS=$6
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_release_ledger" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH
awk -v reasons="$REASONS" -v census_f="$CENSUS" -v art_f="$ARTIFACTS" -v led_f="$LEDGER" -v sum_f="$T/summary" '
function finding(s) { print "release ledger: " s; bad = 1 }
BEGIN {
    nr = split(reasons, rl, " ")
    for (i = 1; i <= nr; i++) known[rl[i]] = i
    while ((getline line < census_f) > 0) {
        n = split(line, f, "\t")
        if (n != 4 || f[2] !~ /^[01]$/ || f[3] !~ /^[01]$/) { finding("census line is not <dir> <native> <readme> <deps>: " line); continue }
        if (f[1] in lib) { finding("census lists " f[1] " twice"); continue }
        lib[f[1]] = 1; native[f[1]] = f[2]; readme[f[1]] = f[3]; deps[f[1]] = f[4]; nlib++
    }
    inart = 0
    while ((getline line < art_f) > 0) {
        if (line ~ /^artifacts[ \t]*\{/) { inart = 1; continue }
        if (line ~ /^\}/) { inart = 0; continue }
        if (!inart || line !~ /^[ \t]*targets:[ \t]*"\/\/src\/[^\/:"]+:[^"]*_conda"/) continue
        t = line; sub(/^[ \t]*targets:[ \t]*"\/\/src\//, "", t); sub(/".*/, "", t)
        d = t; sub(/:.*/, "", d)
        if (t in decl_t) finding(d ": " t " is declared twice in the artifacts file")
        decl_t[t] = 1
        if (!(d in decl)) ndecl++
        decl[d] = 1
    }
    ln = 0
    while ((getline line < led_f) > 0) {
        ln++
        if (line ~ /^[ \t]*(#.*)?$/) continue
        n = split(line, f, " ")
        ok = (n == 7 || n == 9) && f[1] == "libraries" && f[2] == "{" && f[3] == "name:" && f[4] ~ /^"[a-z][a-z0-9_]*"$/ && f[5] == "reason:" && f[n] == "}"
        if (ok && n == 9) ok = f[7] == "pr:" && f[8] ~ /^[1-9][0-9]*$/
        if (!ok) { finding("line " ln " of the ledger is not `libraries { name: \"<dir>\" reason: <REASON> }` (`pr: <N>` before the `}` for PENDING_DECLARE): " line); continue }
        d = substr(f[4], 2, length(f[4]) - 2); r = f[6]
        if (!(r in known)) { finding(d ": unknown reason " r " (the reasons: " reasons ")"); continue }
        if (r == "PENDING_DECLARE" && n != 9) finding(d ": PENDING_DECLARE names the pull request that declares it (`pr: <N>`)")
        if (r != "PENDING_DECLARE" && n == 9) finding(d ": only PENDING_DECLARE takes `pr:`")
        if (d in row) { finding(d ": listed twice in the ledger"); continue }
        if (d < prev) finding(d ": the ledger is not sorted by name (" d " after " prev ")")
        prev = d
        row[d] = r; nrow++
    }
    if (nlib == 0) finding("the census lists no library: the check would read nothing")
    if (ndecl == 0) finding("the artifacts file declares no library (no `targets: \"//src/<dir>:<target>_conda\"` in an artifacts block)")
    for (d in lib) {
        if (!(d in decl) && !(d in row)) finding(d ": src/" d " is a library in neither release/artifacts.textproto nor the ledger; declare it or list it with its reason")
        if ((d in decl) && (d in row)) finding(d ": declared in release/artifacts.textproto and listed in the ledger (" row[d] "); remove its row")
    }
    for (d in decl) if (!(d in lib)) finding(d ": declared in release/artifacts.textproto, but src/" d " holds no library")
    for (d in row) {
        if (!(d in lib)) { finding(d ": listed in the ledger (" row[d] "), but src/" d " holds no library; remove its row"); continue }
        if (d in decl) continue
        r = row[d]
        if (r == "NATIVE" && native[d] == "0") finding(d ": listed NATIVE, but its closure links no native code")
        if (r != "NATIVE" && native[d] == "1") finding(d ": its closure links native code, so its reason is NATIVE, not " r)
        if (native[d] == "1" || r == "DLOPEN") continue
        if (r == "NO_README" && readme[d] == "1") finding(d ": listed NO_README, but it has a README")
        if (r != "NO_README" && readme[d] == "0") finding(d ": it has no README, so its reason is NO_README, not " r)
        if (r == "UNDECLARED_DEP") {
            nd = split(deps[d] == "-" ? "" : deps[d], dl, ",")
            waiting = 0
            for (i = 1; i <= nd; i++) if (!(dl[i] in decl)) waiting = 1
            if (!waiting) finding(d ": listed UNDECLARED_DEP, but every library it depends on is declared")
        }
    }
    if (bad) exit 1
    for (d in row) count[row[d]]++
    printf "libraries %d declared %d listed %d\n", nlib, ndecl, nrow > sum_f
    for (i = 1; i <= nr; i++) printf "%s %d\n", rl[i], count[rl[i]] + 0 > sum_f
}' > "$T/report" || true
if [ -s "$T/report" ]; then
    sort "$T/report" >&2
    rm -rf "$T"
    exit 1
fi
cp "$T/summary" "$OUT"
rm -rf "$T"
