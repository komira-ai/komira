# fs_registry_deps.awk -- the reader of lint kind fs_registry_deps (lint.sh).
#
# usage: awk -v LN=<ledger name> -v P=<stage>/ -v CF=<count file> -f fs_registry_deps.awk <ledger> <file list>
#
# Run from the staged tree. <file list> holds the BUCK and .mojo files under
# src/, one path per line. A package is a directory src/<name> holding a
# BUCK file; the BUCK and .mojo files below it (subpackages included) are
# its own. The physical-plan set is every package named by the <ledger>: one
# whose name starts with a `prefix` row's name, or that a `package` row names.
#
# The dependency graph is read from the BUCK files as text: every label
# `//src/<name>...` (any cell, any target of the package, deps or not) on a
# line outside a `#` comment and outside a `visibility = [...]` list is an
# edge from the BUCK file's package to <name>. A finding is a physical-plan
# package from which komira_fs_registry is reachable, named with the
# shortest path and the line of each end; and a .mojo file of one that
# imports komira_fs_registry (which reaches the compiler only through deps,
# so this catches a dep the text does not show, e.g. one a loaded .bzl
# constant adds). Each is one line: the file and line, the package, the dep
# and the rule. Prints the findings (paths under P), writes the number of
# physical-plan packages checked to CF.

function why(p) {
    return (p in listed) ? "listed at " LN ":" listed[p] : "prefix " pfx_of[p]
}

function rule() {
    return "must never depend on " REG ": take a FileSystem-generic parameter and let the caller pass the concrete backend, so a compiled plan instantiates one file system"
}

# The code of one line of a BUCK file: up to a `#` outside a string.
function code(s,    i, c, q, out) {
    q = ""
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") {
            if (c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
            if (c == q) q = ""
        } else if (c == "\"" || c == "'") {
            q = c
        } else if (c == "#") {
            break
        }
        out = out c
    }
    return out
}

# The code of a line with any `visibility = [...]` list (possibly spanning
# lines: vis is the bracket depth carried between lines) removed.
function unvisible(s,    out, c) {
    out = ""
    while (s != "") {
        if (vis > 0) {
            c = substr(s, 1, 1)
            if (c == "[") vis++
            else if (c == "]") vis--
            s = substr(s, 2)
            continue
        }
        if (match(s, /visibility[[:space:]]*=[[:space:]]*\[/)) {
            out = out substr(s, 1, RSTART - 1)
            s = substr(s, RSTART + RLENGTH)
            vis = 1
            continue
        }
        out = out s
        s = ""
    }
    return out
}

function pkg_of(path,    a) {
    split(path, a, "/")
    return a[2]
}

BEGIN {
    REG = "komira_fs_registry"
    FS = "\t"
}

FILENAME == ARGV[1] {
    if ($0 ~ /^[[:space:]]*(#|$)/) next
    nrows++
    row_line[nrows] = FNR
    row_nf[nrows] = NF
    row_kind[nrows] = $1
    row_name[nrows] = $2
    row_reason[nrows] = $3
    next
}

FILENAME == ARGV[2] {
    if ($0 !~ /^src\/[^\/]+\/./) next
    p = pkg_of($0)
    if ($0 == "src/" p "/BUCK") pkgs[p] = 1
    if ($0 ~ /(^|\/)BUCK$/) bucks[++nbucks] = $0
    else if ($0 ~ /\.mojo$/) mojos[++nmojos] = $0
    next
}

END {
    # The ledger: prefixes first, so a package row a prefix covers is found
    # whatever the order.
    for (i = 1; i <= nrows; i++) {
        where = LN ":" row_line[i] ": "
        bad[i] = 1
        if (row_nf[i] != 3) { print where "a row has 3 tab-separated fields (kind, name, reason), not " row_nf[i]; continue }
        if (row_kind[i] != "prefix" && row_kind[i] != "package") { print where "unknown kind `" row_kind[i] "` (kinds: prefix, package)"; continue }
        if (row_name[i] !~ /^[A-Za-z0-9_]+$/) { print where "`" row_name[i] "` is not a package name or prefix"; continue }
        if (row_reason[i] !~ /[^[:space:]]/) { print where "empty reason: say why " row_name[i] " is physical-plan execution"; continue }
        k = row_kind[i] SUBSEP row_name[i]
        if (k in seen) { print where "a second row for " row_kind[i] " " row_name[i] ", first on line " seen[k]; continue }
        seen[k] = row_line[i]
        if (index(REG, row_name[i]) == 1 && (row_kind[i] == "prefix" || row_name[i] == REG)) {
            print where row_kind[i] " " row_name[i] " covers " REG " itself, which the rule is about; narrow or delete the row"
            continue
        }
        bad[i] = 0
        if (row_kind[i] == "prefix") prefix_line[row_name[i]] = row_line[i]
    }
    for (i = 1; i <= nrows; i++) {
        if (bad[i] || row_kind[i] != "package") continue
        n = row_name[i]
        where = LN ":" row_line[i] ": "
        if (!(n in pkgs)) { print where n " is not a package of the tree (no src/" n "/BUCK); delete the row"; continue }
        for (x in prefix_line)
            if (index(n, x) == 1) { print where n " is covered by prefix " x " (line " prefix_line[x] "); delete the row"; n = "" ; break }
        if (n != "") listed[n] = row_line[i]
    }

    # The physical-plan set.
    checked = 0
    for (p in pkgs) {
        if (p == REG) continue
        if (p in listed) { phys[p] = 1; checked++; continue }
        for (x in prefix_line)
            if (index(p, x) == 1) { phys[p] = 1; pfx_of[p] = x; checked++; break }
    }
    print checked > CF

    # The graph: edge[a, b] is the first line of a's BUCK files naming b.
    for (i = 1; i <= nbucks; i++) {
        f = bucks[i]
        a = pkg_of(f)
        vis = 0
        ln = 0
        while ((getline line < f) > 0) {
            ln++
            s = unvisible(code(line))
            while (match(s, /[A-Za-z0-9_@]*\/\/src\/[A-Za-z0-9_]+[A-Za-z0-9_\/:.+=-]*/)) {
                label = substr(s, RSTART, RLENGTH)
                s = substr(s, RSTART + RLENGTH)
                b = label
                sub(/^.*\/\/src\//, "", b)
                sub(/[^A-Za-z0-9_].*$/, "", b)
                k = a SUBSEP b
                if (b == a || (k in edge)) continue
                edge[k] = P f ":" ln
                edge_label[k] = label
                nout[a]++
                out[a, nout[a]] = b
            }
        }
        close(f)
    }

    # Breadth first from every physical-plan package; the first path to
    # reach the registry is a shortest one.
    for (p in phys) {
        split("", dist)
        split("", from)
        qh = 1
        qt = 1
        q[1] = p
        dist[p] = 0
        found = 0
        while (qh <= qt && !found) {
            a = q[qh++]
            for (j = 1; j <= nout[a]; j++) {
                b = out[a, j]
                if (b in dist) continue
                dist[b] = dist[a] + 1
                from[b] = a
                if (b == REG) { found = 1; break }
                q[++qt] = b
            }
        }
        if (!found) continue
        # The path p -> ... -> last -> REG.
        last = from[REG]
        chain = ""
        for (c = last; c != p; c = from[c]) chain = (chain == "" ? c : c " -> " chain)
        first = (chain == "") ? REG : chain
        sub(/ .*/, "", first)
        if (last == p)
            print edge[p, REG] ": " p " depends on " REG " (" edge_label[p, REG] "), but a physical-plan package (" why(p) ") " rule()
        else
            print edge[p, first] ": " p " depends on " REG " through " chain " (" edge[last, REG] ": " edge_label[last, REG] "), but a physical-plan package (" why(p) ") " rule()
    }

    # Imports in the physical-plan packages' own files.
    for (i = 1; i <= nmojos; i++) {
        f = mojos[i]
        p = pkg_of(f)
        if (!(p in phys)) continue
        ln = 0
        while ((getline line < f) > 0) {
            ln++
            if (line ~ /^[[:space:]]*(from|import)[[:space:]]+komira_fs_registry([^A-Za-z0-9_]|$)/)
                print P f ":" ln ": " p " imports " REG ", but a physical-plan package (" why(p) ") " rule()
        }
        close(f)
    }
}
