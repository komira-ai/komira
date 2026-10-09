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
# of a refused module is one finding, whatever it names. A statement that
# is no import and names a refused module by its dotted path
# (`komira_x.y.Z()` after `import komira_x`) is a finding too:
# "<F>:<line>: names <name>, a module this package refuses (<name>)".
#
# Each line is first reduced to its code: string literals (one-line '...'
# and "...", with backslash escapes, and triple-quoted strings over any
# lines, closed only by the delimiter that opened them) and the comment
# (`#` outside a string, to the end of the line) are removed. Then a code
# line ending in `\` is joined with the next and the rest splits on `;`
# into statements. A finding names the line where its statement starts,
# or, inside parentheses, the line of the name.
#
# It reads characters, not Mojo tokens: a string prefix is an ordinary
# character before the quote, and a one-line string left open at the end
# of its line ends there. A Mojo tokenizer in a Zig tool is to replace
# this reader (#1175).

BEGIN { n = split(R, r, ",") }

function check(m, l,   i, hit) {
    for (i = 1; i <= n; i++)
        if (m == r[i] || index(m, r[i] ".") == 1) {
            print F ":" l ": imports " m ", a module this package refuses (" r[i] ")"
            hit = 1
        }
    return hit
}

# A dotted path of a refused module in the code of a statement that is no
# import: not inside a longer name on either side (`x.M`, `M_x` are not it).
function qualified(s, l,   i, t, p, b, a) {
    for (i = 1; i <= n; i++) {
        t = s
        while ((p = index(t, r[i])) > 0) {
            b = p > 1 ? substr(t, p - 1, 1) : ""
            a = substr(t, p + length(r[i]), 1)
            if (b !~ /[A-Za-z0-9_.]/ && a !~ /[A-Za-z0-9_]/) {
                print F ":" l ": names " r[i] ", a module this package refuses (" r[i] ")"
                break
            }
            t = substr(t, p + length(r[i]))
        }
    }
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
    } else {
        qualified(s, l)
    }
}

# The code of line s: strings become "" and the comment is dropped. tq
# holds the delimiter of a triple-quoted string still open at the end of
# the line before.
function code(s,   out, i, len, c) {
    out = ""
    i = 1
    len = length(s)
    while (i <= len) {
        if (tq != "") {
            if (substr(s, i, 3) == tq) {
                tq = ""
                out = out "\"\""
                i += 3
            } else if (substr(s, i, 1) == "\\") {
                i += 2
            } else {
                i++
            }
            continue
        }
        c = substr(s, i, 1)
        if (c == "#") break
        if (c == "\"" || c == "'") {
            if (substr(s, i, 3) == c c c) {
                tq = c c c
                i += 3
                continue
            }
            i++
            while (i <= len && substr(s, i, 1) != c) {
                if (substr(s, i, 1) == "\\") i++
                i++
            }
            i++
            out = out "\"\""
            continue
        }
        out = out c
        i++
    }
    return out
}

{
    s = code($0)
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
