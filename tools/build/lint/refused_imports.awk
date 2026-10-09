# refused_imports.awk -- the reader of the refused imports of lint kind
# mojo_deps (lint.sh; the rule is mojo_deps in defs.bzl).
#
# usage: awk -v F=<name> -v R=<refused> -f refused_imports.awk <.mojo file>
#
# R is a comma-separated list of dotted module names. Prints one finding,
# "<F>:<line>: imports <module>, a module this package refuses (<name>)",
# for each import of a refused name or of a module under one (`M.sub`, not
# `M_x`): `import M` (with `as p` or not, in a comma list or not),
# `from M import ...`, and `from P import N` where P.N is refused, the names
# on the line or inside parentheses over any number of lines. A from-import
# of a refused module is one finding, whatever it names.
#
# Per line, in order: a line inside a triple-quoted string (""" or ''') is
# skipped, and so is the line that opens one; the comment (`#` to the end)
# is dropped; a line ending in `\` is joined with the next; the rest splits
# on `;` into statements. A finding names the line where its statement
# starts, or, inside parentheses, the line of the name.
#
# It reads text, not Mojo tokens. Misread, and not covered: a `#`, `;` or
# triple quote inside a one-line string literal on a line that also imports,
# and an import after a docstring that closes on the same line. A Mojo
# tokenizer in a Zig tool is to replace this reader (#1175).

BEGIN { n = split(R, r, ",") }

function check(m, l,   i, hit) {
    for (i = 1; i <= n; i++)
        if (m == r[i] || index(m, r[i] ".") == 1) {
            print F ":" l ": imports " m ", a module this package refuses (" r[i] ")"
            hit = 1
        }
    return hit
}

# The names of an import list (`a, b as c, (d)`), each prefixed with base.
function names(s, base, l,   k, a, i, t) {
    gsub(/[()]/, " ", s)
    k = split(s, a, ",")
    for (i = 1; i <= k; i++) {
        t = a[i]
        sub(/^[ \t]+/, "", t)
        sub(/[ \t].*$/, "", t)
        if (t != "") check(base t, l)
    }
}

function stmt(s, l,   m, rest) {
    if (s ~ /^[ \t]*from[ \t]+komira_[A-Za-z0-9_.]*[ \t]+import([ \t(]|$)/) {
        m = s
        sub(/^[ \t]*from[ \t]+/, "", m)
        sub(/[ \t].*$/, "", m)
        rest = s
        sub(/^[ \t]*from[ \t]+[^ \t]+[ \t]+import/, "", rest)
        skip = check(m, l)
        base = m "."
        if (!skip) names(rest, base, l)
        if (rest ~ /\(/ && rest !~ /\)/) open = 1
    } else if (s ~ /^[ \t]*import[ \t]+komira_/) {
        rest = s
        sub(/^[ \t]*import[ \t]+/, "", rest)
        names(rest, "", l)
    }
}

{
    s = $0
    q = gsub(/"""/, "&", s) + gsub(/'''/, "&", s)
    if (doc) {
        if (q % 2) doc = 0
        next
    }
    if (q % 2) {
        doc = 1
        next
    }
    sub(/#.*$/, "", s)
    l = NR
    if (cont) {
        s = held " " s
        l = heldl
    }
    if (s ~ /\\[ \t]*$/) {
        sub(/\\[ \t]*$/, "", s)
        held = s
        heldl = l
        cont = 1
        next
    }
    cont = 0
    if (open) {
        c = index(s, ")")
        if (!c) {
            if (!skip) names(s, base, l)
            next
        }
        if (!skip) names(substr(s, 1, c - 1), base, l)
        open = 0
        s = substr(s, c + 1)
    }
    k = split(s, part, ";")
    for (i = 1; i <= k; i++) stmt(part[i], l)
}
