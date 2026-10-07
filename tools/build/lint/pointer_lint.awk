# pointer_lint.awk -- the reader behind lint kind "pointer_lint" (lint.sh).
#
# usage: busybox awk -v PUBLIC_ROOT=<dir/> -f pointer_lint.awk <file.mojo>...
#
# Prints one line per site, `<rule>\t<file>\t<line>\t<text>`, for the pointer
# rules of docs/design/mojo_safety_and_idioms.md:
#
#   wildcard_origin  a wildcard origin named in code: MutAnyOrigin,
#                    ImmutAnyOrigin, MutExternalOrigin or MutUntrackedOrigin
#                    (the Mojo 1.1 name of MutExternalOrigin). One site per
#                    occurrence. lint.sh drops the sites of a file its FFI
#                    ledger lists: a module's FFI internals may name them.
#   from_address     `unsafe_from_address=`: a pointer made from an integer.
#   partial_move     a move out of a field through its address:
#                    `UnsafePointer(to=<expr>.<field>).take_pointee()`, or
#                    `p.take_pointee()` where an earlier statement of the same
#                    function bound `p = UnsafePointer(to=<expr>.<field>)`
#                    (the two-statement form; the site is the take).
#                    `UnsafePointer[...](to=...)` counts the same. A pointer to
#                    a whole value (`to=x`, `to=p[]`) is not a partial move.
#   parallelize      the standard library's `parallelize[`.
#   libc_redeclare   `external_call["read", ...]` or `external_call["open", ...]`:
#                    a second declaration of a libc function the standard
#                    library already binds.
#   public_pointer   a public function whose signature names UnsafePointer or
#                    OpaquePointer, in a library file: a file under
#                    PUBLIC_ROOT, not under its package's `tests` directory
#                    (a package is PUBLIC_ROOT<pkg> or, test-only,
#                    PUBLIC_ROOT tests/<kind>/<pkg>), and with no
#                    path segment that starts with `_` (`__init__.mojo` is
#                    public). Public: a module-level `def`/`fn` whose name
#                    does not start with `_`, or a method (four spaces in) of a
#                    module-level struct or trait whose name does not start
#                    with `_`, the method named without a leading `_` or
#                    `__<name>__` (a dunder is reached through syntax, so it is
#                    public). Nested functions are not public.
#
# Text is read as code only: docstrings and string literals are blanked and
# comments dropped first, so a sentence naming a banned spelling is not a
# site (libc_redeclare reads the function name in its string, from the same
# statement with only comments and docstrings dropped). A statement written
# over several lines is joined until its brackets close, then matched as one
# and reported at its first line.
#
# Limits (a text reader's): a wildcard origin or a pointer type reached
# through an alias or a type parameter is not seen; a pointer bound in one
# function and taken in another, or through a second name, is not seen; a
# partial move through a subscript (`to=x[i]`) is not counted.

function strip(s,    out, i, q) {
    # Blank docstrings (state across lines), then string literals, then drop
    # the comment. Sets `lit`: the same line with string literals kept.
    out = ""
    while (s != "") {
        if (indoc) {
            i = index(s, docq)
            if (i == 0) { lit = out; return out }
            s = substr(s, i + 3); indoc = 0
            continue
        }
        i = match(s, /"""|'''/)
        if (i == 0) { out = out s; break }
        q = substr(s, i, 3)
        # A `#` before the opening quote starts a comment: stop there.
        if (index(substr(s, 1, i - 1), "#")) { out = out s; break }
        out = out substr(s, 1, i - 1) "\"\""
        s = substr(s, i + 3); indoc = 1; docq = q
    }
    lit = out
    gsub(/"([^"\\]|\\.)*"/, "\"\"", out)
    gsub(/'([^'\\]|\\.)*'/, "''", out)
    sub(/#.*/, "", out)
    # The literal-keeping copy loses its comment where the code copy does:
    # the code before the first `#` outside a literal.
    lit = cut_comment(lit)
    return out
}

function cut_comment(s,    i, c, q) {
    # `s` up to its first `#` outside a string literal.
    i = index(s, "#")
    if (i == 0) return s
    if (s !~ /["']/) return substr(s, 1, i - 1)
    q = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") {
            if (c == "\\") { i++; continue }
            if (c == q) q = ""
            continue
        }
        if (c == "\"" || c == "'") { q = c; continue }
        if (c == "#") return substr(s, 1, i - 1)
    }
    return s
}

function depth(s,    t, d1, d2) {
    t = s; d1 = gsub(/[[(]/, "", t)
    t = s; d2 = gsub(/[])]/, "", t)
    return d1 - d2
}

function emit(rule, ln, text) {
    gsub(/[\t ]+/, " ", text)
    sub(/^ /, "", text)
    printf "%s\t%s\t%d\t%s\n", rule, file, ln, substr(text, 1, 160)
}

function count(s, re,    t) {
    t = s
    return gsub(re, "", t)
}

# The index in `s` of the bracket closing the one at `at`, or 0.
function closing(s, at,    i, c, d) {
    d = 0
    for (i = at; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "(" || c == "[") d++
        else if (c == ")" || c == "]") { d--; if (d == 0) return i }
    }
    return 0
}

# Each `UnsafePointer(to=<expr>.<field>)` in `s`: a site when
# `.take_pointee(` follows it; else, when it is the whole right-hand side of
# `[var] <name> = ...`, `name` is bound to a field's address.
function pointers(s, ln,    rest, off, i, j, arg, after, lhs, nm) {
    rest = s; off = 0
    while (match(rest, /(^|[^A-Za-z0-9_])UnsafePointer[ \t]*[[(]/)) {
        i = off + RSTART + RLENGTH - 1      # the bracket, in s
        if (substr(s, i, 1) == "[") {
            j = closing(s, i)
            if (j == 0) return
            i = j + 1
            while (substr(s, i, 1) ~ /[ \t]/) i++
            if (substr(s, i, 1) != "(") { off = i - 1; rest = substr(s, i); continue }
        }
        j = closing(s, i)
        if (j == 0) return
        arg = substr(s, i + 1, j - i - 1)
        after = substr(s, j + 1)
        if (arg ~ /^[ \t]*to[ \t]*=/ && arg ~ /\.[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*$/) {
            if (after ~ /^[ \t]*\.[ \t]*take_pointee[ \t]*\(/) {
                emit("partial_move", ln, s)
            } else if (after ~ /^[ \t]*$/) {
                lhs = substr(s, 1, off + RSTART)
                if (lhs ~ /^[ \t]*(var[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*(:[^=]*)?=[ \t]*$/) {
                    nm = lhs; sub(/^[ \t]*(var[ \t]+)?/, "", nm); sub(/[^A-Za-z0-9_].*/, "", nm)
                    bound[nm] = ln
                    fresh = nm
                }
            }
        }
        off = j; rest = substr(s, j + 1)
    }
}

function statement(s, raw, ln, ind,    nm, pub, k, n, re) {
    fresh = ""
    if (ind == 0 && s !~ /^@/) {
        # A module-level line: decides what the indented lines below belong to.
        container = 0; cpriv = 0
        for (k in bound) delete bound[k]
        if (s ~ /^(struct|trait)[ \t]/) {
            container = 1
            nm = s; sub(/^(struct|trait)[ \t]+/, "", nm)
            cpriv = (nm ~ /^_/)
        }
    }
    if (s ~ /^[ \t]*(fn|def)[ \t]+[A-Za-z_]/) {
        # A new function: the two-statement form is read within one.
        for (k in bound) delete bound[k]
        if (libfile && (ind == 0 || (ind == 4 && container && !cpriv))) {
            nm = s; sub(/^[ \t]*(fn|def)[ \t]+/, "", nm)
            pub = (nm ~ /^__[A-Za-z0-9_]*__/) || (nm !~ /^_/)
            if (pub && s ~ PTR) emit("public_pointer", ln, s)
        }
    }
    n = count(s, WILD)
    for (k = 0; k < n; k++) emit("wildcard_origin", ln, s)
    n = count(s, "unsafe_from_address[ \t]*=")
    for (k = 0; k < n; k++) emit("from_address", ln, s)
    n = count(s, "(^|[^A-Za-z0-9_])parallelize[ \t]*\\[")
    for (k = 0; k < n; k++) emit("parallelize", ln, s)
    if (s ~ /external_call[ \t]*\[/) {
        n = count(raw, LIBC)
        for (k = 0; k < n; k++) emit("libc_redeclare", ln, raw)
    }
    # The two-statement form: a take through a name bound to a field's address.
    for (k in bound) {
        re = "(^|[^A-Za-z0-9_.])" k "[ \t]*\\.[ \t]*take_pointee[ \t]*\\("
        if (s ~ re) emit("partial_move", ln, s " (bound to a field's address at line " bound[k] ")")
    }
    pointers(s, ln)
    # A name assigned anything else is no longer bound.
    if (s ~ /^[ \t]*(var[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*(:[^=]*)?=[^=]/) {
        nm = s; sub(/^[ \t]*(var[ \t]+)?/, "", nm); sub(/[^A-Za-z0-9_].*/, "", nm)
        if (nm != fresh && (nm in bound)) delete bound[nm]
    }
}

function flush() {
    if (pend) statement(buf, rbuf, pline, pind)
    pend = 0; buf = ""; rbuf = ""
}

BEGIN {
    WILD = "(^|[^A-Za-z0-9_])(MutAnyOrigin|ImmutAnyOrigin|MutExternalOrigin|MutUntrackedOrigin)([^A-Za-z0-9_]|$)"
    LIBC = "external_call[ \t]*\\[[ \t]*\"(read|open)\"[ \t]*[],]"
    PTR = "(^|[^A-Za-z0-9_])(Unsafe|Opaque)Pointer([^A-Za-z0-9_]|$)"
}

FNR == 1 {
    flush()
    file = FILENAME; indoc = 0; container = 0; cpriv = 0
    for (k in bound) delete bound[k]
    p = file; sub(/^\.\//, "", p)
    # A library file: under PUBLIC_ROOT, outside its package's `tests`
    # directory, and no path segment starting with `_` but a final
    # `__init__.mojo`. A package is PUBLIC_ROOT<pkg>, or a test-only one
    # PUBLIC_ROOT tests/<kind>/<pkg> (docs/architecture.md#end-to-end-tests):
    # only a `tests` directory below the package root is skipped.
    q = p; sub(/(^|\/)__init__\.mojo$/, "/init.mojo", q)
    r = substr(q, length(PUBLIC_ROOT) + 1)
    if (r ~ /^tests\/[^\/]+\/[^\/]+\//) sub(/^tests\/[^\/]+\/[^\/]+\//, "", r)
    else if (r ~ /^tests\//) r = "tests/" r
    else sub(/^[^\/]+\//, "", r)
    libfile = PUBLIC_ROOT != "" && index(p, PUBLIC_ROOT) == 1 && ("/" r) !~ /\/tests\// && q !~ /(^|\/)_/
}

{
    code = strip($0)
    if (pend) {
        buf = buf " " code; rbuf = rbuf " " lit; dep += depth(code)
        if (dep <= 0) flush()
        next
    }
    if (code ~ /^[ \t]*$/) next
    pend = 1; buf = code; rbuf = lit; pline = FNR; dep = depth(code)
    t = code; sub(/[^ \t].*/, "", t); pind = length(t)
    if (dep <= 0) flush()
}

END { flush() }
