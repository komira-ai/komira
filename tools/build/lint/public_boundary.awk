# public_boundary.awk -- the reader behind lint kind "public_boundary" (lint.sh).
#
# usage: busybox awk -F '\t' -v HN=<holds name> -v AN=<hosts name> -v P=<prefix>
#            -v FROM=<year> -v PUBLIC=<YYYY-MM-01>
#            -f public_boundary.awk <file list> <path list> <hosts> <deny list or /dev/null> <holds>
#
# Reads every file <file list> names (paths relative to the working
# directory, one per line), and every path <path list> names (every staged
# file, those not read included), and prints the findings no row of <holds>
# holds, then each defect of the two ledgers. A path is read for the date,
# home_path and deny rules; its findings are at line 0, marked `(in the
# path)`. A file that cannot be read (getline fails) is a finding. Every rule is generic: it names no word, host
# or person of any owner, so this file can be public. A private consumer
# passes words of its own in <deny list>, kept outside the repository.
#
# The rules. One finding per rule and line; a line's finding shows the first
# match. Comparisons ignore case unless the rule says otherwise.
#
#   date        A calendar date in the window from the first day of the year
#               FROM up to PUBLIC, the day the public history starts: what
#               the repository says happened before it is not public (the
#               root target reads from 2025 to 2026-09-01). Spellings:
#               Y-M-D with `-`, `_`, `/` or `.` between the parts and a
#               two-digit month and day, or a one-digit month or day between
#               two `-` or two `/` (a dotted Y.M.D of one digit is read as a
#               version); Y-M
#               (not followed by a digit or `-`); the eight digits YYYYMMDD
#               standing alone (no letter or digit before it, no digit
#               after); a month name or its three-letter form, with or
#               without a day, before the year (`Mon D, YYYY`, `D Month
#               YYYY`, `Month YYYY`); and D/M/YYYY or M/D/YYYY (`/`, `.` or `-`),
#               when either of the first two numbers can be a month of the
#               window. The year must not touch another digit.
#               Years before FROM are not read: a date there is data (epochs,
#               certificates, standards, the date and time libraries' test
#               cases), which a rule of this kind cannot tell from history.
#   home_path   /home/<name>/, /Users/<name>/ or <drive>:\Users\<name>\, unless
#               <name> is a placeholder: user, username, u, me, you, runner,
#               alice, bob, example, nobody, shared, name, someone, or a name
#               starting with `$`, `<`, `{`, `*` or `.`.
#   ip          A dotted IPv4 address (four numbers up to 255, not part of a
#               longer dotted run) in a private (10/8, 172.16/12,
#               192.168/16), shared (100.64/10) or link-local (169.254/16)
#               range, or any address written as one (after `://` or `@`,
#               or followed by `:<port>`), except loopback (127/8), 0.0.0.0,
#               255.255.255.255, the documentation ranges (192.0.2/24,
#               198.51.100/24, 203.0.113/24), and the metadata and
#               credential services the clouds publish at fixed link-local
#               addresses (169.254.169.254, 169.254.170.2, 169.254.170.23).
#               A dotted number not in a private range and not written as an
#               address is read as a section number or an OID.
#   host        The host of a URL whose scheme reaches a network (http,
#               https, ws, wss, grpc, grpcs, ftp, ftps, sftp, ssh, git,
#               postgres, postgresql, mysql, redis, rediss, amqp, amqps, mqtt,
#               nats, kafka, mongodb, tcp, udp, smtp, imap, ldap, ldaps): a
#               name (port and user dropped) that is not one of the names
#               reserved for examples and tests (localhost, example, test,
#               invalid and their subdomains, RFC 2606 and RFC 6761;
#               example.com, example.net, example.org and their subdomains)
#               and is neither a domain of <hosts> nor under one. An IPv6
#               host must be [::1] or one of the documented cloud metadata
#               addresses [fd00:ec2::254] and [fd00:ec2::23]. A host holding
#               anything but letters, digits, `_`, `.` and `-` (a template
#               such as `{host}` or `$HOST`, an ellipsis, a pattern) is not
#               read; an IPv4 host is the ip rule's.
#   email       An address local@domain, unless the domain is reserved
#               (example.com, example.net, example.org, *.example, *.test,
#               *.invalid, *.localhost), the local part is noreply or
#               no-reply (a commit trailer's address names no person), or
#               the local part starts right after `://` and the domain is a
#               domain of <hosts> or under one: that is the user of a URL's
#               authority on a host the ledger names (`scheme://user@host`,
#               such as Hadoop ABFS's
#               abfss://<container>@<account>.dfs.core.windows.net). A
#               user before any other host (`s3://<user>@<host>/k`,
#               `git+ssh://<user>@<host>/r`) is read, as are `mailto:` and an
#               address elsewhere in a URL.
#   commit_sha  In prose, a hex string shaped like a commit id: 7 to 12, or
#               40, lowercase hex digits holding at least two changes
#               between digit and letter, standing alone (no letter, digit,
#               `_`, `/`, `.`, `@`, `:`, `\` or `-` before it, no letter,
#               digit, `_` or `-` after it: a UUID's group is not one), not
#               followed by `...` or `…` (a
#               digest abbreviated), not quoted, not a binary (0b...) or
#               float (1e30) literal. Prose is a whole line of a Markdown or
#               text file (.md, .txt, .rst), the comment of a line of a `#`
#               language (from a `#` at the start or after a space or tab)
#               with a Mojo or Python docstring, and the comment of a line
#               of a `//` language (from a `//` at the start or after a space
#               or tab, or a line starting `*` or `/*`). Code is not prose:
#               a 40-hex pin in code names an upstream commit.
#   deny        A word of <deny list> (one per line; `#` lines and blank
#               lines are comments), matched as a fixed string ignoring case
#               anywhere in the line. Not holdable: <holds> may not name it,
#               so a public ledger never says where a private word was.
#
# <hosts>: rows `<domain>\t<reason>`; a host is allowed when it is the domain
# or ends in `.<domain>`. A row no URL host of the tree is under, a repeated
# row, a reserved name or an empty reason is a finding: the list only names
# what the tree uses.
#
# <holds>: rows `<rule>\t<file>\t<count>\t<reason>`: <file> (a path of the
# list) must have exactly <count> findings of <rule>. More is a new finding;
# fewer is a row to lower or delete, so the holds only shrink. A malformed,
# repeated or unknown-rule row, a file the list does not name, a count that
# is not a positive whole number and an empty reason are findings.
#
# Limits (a text reader's):
# - Vocabulary is not a shape, so a name of the owner's systems is found only
#   through <deny list>.
# - A host outside a URL (a bare name, `name:port`) is not read; a host under
#   an allowed cloud domain may name a resource of its own (a bucket, a
#   function URL); an IPv6 address outside a URL is not read.
# - Object-store URLs (s3://, gs://, az://, abfs://, and any scheme not listed
#   under host) are not host-checked: their authority is a bucket or
#   container name, which the object-store clients' tests make up by the
#   hundred and which no allow-list of domains could name. A deny-list word
#   still finds a real bucket name.
# - A commit id inside a URL (after a `/`, as in a link to an upstream
#   commit) is not read, nor one in code.
# - commit_sha needs two switches between digit and letter, so a real id
#   with fewer is missed: for random ids about 14% of 7-hex ones, 9% of 8,
#   6% of 9, 4% of 10, 1.4% of 12, and none of 40.
# - A date before FROM is not read; Y-M with a one-digit month is not read.
# - A home directory written as `~name/` (the shell's shorthand) is not read:
#   `~` before a word is as common in code, patterns and prose as in paths,
#   so it is left to review and the deny list.
# - "Only shrinks" is held by exact counts: a site more or one fewer fails.
#   A row added or a count raised in the same change as the site passes the
#   build, so review of the ledger's diff is the other half of the rule.
# - Binary data is skipped by suffix (lint.sh says which); its path is read.

# A regular expression with a `/` or a backslash in a bracket expression is a
# string, so no awk reads the escape its own way; a backslash or `]` is found
# with index(). The patterns matched on every line are literals.

function month_of(w) { return (index("janfebmaraprmayjunjulaugsepoctnovdec", substr(w, 1, 3)) + 2) / 3 }

function in_window(y, m) { return (y >= FROM && y < PY) || (y == PY && m >= 1 && m < PM) }

function add(rule, file, line, text, msg,    k) {
    k = rule SUBSEP file
    n[k]++
    site[k, n[k]] = P file ":" line ": " rule ": " text " -- " msg
}

# The first date of the window on line s (lowercased), or "".
function find_date(s,    rest, off, pos, y, pre, post, m, tail, a, b, sfx, mm, dd, sep) {
    rest = s; off = 0
    while (match(rest, YEARS)) {
        pos = off + RSTART
        rest = substr(rest, RSTART + 4); off = pos + 3
        y = substr(s, pos, 4) + 0
        pre = pos > 1 ? substr(s, pos - 1, 1) : ""
        post = substr(s, pos + 4)
        if (pre ~ "[0-9]") continue
        if (match(post, "^[-_/.][0-9][0-9]?[-_/.][0-9][0-9]?([^0-9]|$)")) {
            # Y-M-D: two-digit month and day with any separator, or one-digit
            # ones between `-` or `/` (a dotted 2031.1.5 is a version).
            mm = substr(post, 2); sub("[^0-9].*", "", mm)
            dd = substr(post, length(mm) + 3); sub("[^0-9].*", "", dd)
            sep = substr(post, 1, 1)
            if ((length(mm) == 2 && length(dd) == 2) || (sep ~ "[-/]" && substr(post, length(mm) + 2, 1) == sep))
                if (mm + 0 >= 1 && mm + 0 <= 12 && dd + 0 >= 1 && dd + 0 <= 31 && in_window(y, mm + 0))
                    return substr(s, pos, 6 + length(mm) + length(dd))
            continue
        }
        if (match(post, "^-(0[1-9]|1[0-2])([^-0-9]|$)")) {
            if (in_window(y, substr(post, 2, 2) + 0)) return substr(s, pos, 7)
            continue
        }
        if (pre !~ "[a-z]" && match(post, "^(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])([^0-9]|$)")) {
            if (in_window(y, substr(post, 1, 2) + 0)) return substr(s, pos, 8)
            continue
        }
        if (post ~ "^[0-9]") continue
        tail = substr(s, 1, pos - 1)
        if (match(tail, "(^|[^a-z])" MON "[.]?[ ]+[0-9]?[0-9](st|nd|rd|th)?,?[ ]+$") ||
            match(tail, "(^|[^0-9])[0-9]?[0-9](st|nd|rd|th)?[ ]+" MON "[.]?,?[ ]+$") ||
            match(tail, "(^|[^a-z])" MON "[.]?,?[ ]+$")) {
            sfx = substr(tail, RSTART)
            if (sfx ~ "^[^0-9a-z]") sfx = substr(sfx, 2)
            match(sfx, "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)")
            m = month_of(substr(sfx, RSTART, 3))
            if (in_window(y, m)) return sfx substr(s, pos, 4)
            continue
        }
        if (match(tail, "(^|[^0-9./-])[0-9]?[0-9][-/.][0-9]?[0-9][-/.]$")) {
            sfx = substr(tail, RSTART)
            if (sfx ~ "^[^0-9]") sfx = substr(sfx, 2)
            a = sfx; sub("[-/.].*", "", a)
            b = substr(sfx, length(a) + 2); sub("[-/.].*", "", b)
            if ((a + 0 <= 12 && in_window(y, a + 0)) || (b + 0 <= 12 && in_window(y, b + 0)))
                return sfx substr(s, pos, 4)
        }
    }
    return ""
}

function placeholder(name) {
    name = tolower(name)
    return name == "" || name ~ "^[$<{*.]" || name ~ "^(user|username|u|me|you|runner|alice|bob|example|nobody|shared|name|someone)$"
}

# The first home directory on line s that names a person, or "".
function find_home(s,    rest, name, i, j, c) {
    rest = s
    while (match(rest, "/(home|Users)/[^/ \t\"'`)<>,;:]+")) {
        name = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        i = index(name, "\\"); if (i) name = substr(name, 1, i - 1)
        c = name; sub("^/(home|Users)/", "", c)
        if (!placeholder(c)) return name
    }
    # <drive>:\Users\<name>, with each backslash single or doubled (a string
    # literal in code).
    rest = s
    while (i = index(rest, "Users\\")) {
        j = i + 6
        while (substr(rest, j, 1) == "\\") j++
        c = ""
        while (j <= length(rest) && index("\\ \t\"'`/", substr(rest, j, 1)) == 0) { c = c substr(rest, j, 1); j++ }
        name = substr(rest, i, j - i)
        rest = substr(rest, j)
        if (!placeholder(c)) return name
    }
    return ""
}

function find_ip(s,    rest, off, pos, ip, pre, pre3, post, q, a, b, c, d) {
    rest = s; off = 0
    while (match(rest, /[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+/)) {
        pos = off + RSTART
        ip = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH); off = pos + length(ip) - 1
        pre = pos > 1 ? substr(s, pos - 1, 1) : ""
        pre3 = pos > 3 ? substr(s, pos - 3, 3) : ""
        post = substr(s, pos + length(ip), 2)
        if (pre ~ "[0-9A-Za-z.]" || post ~ "^[.][0-9]") continue
        split(ip, q, ".")
        a = q[1] + 0; b = q[2] + 0; c = q[3] + 0; d = q[4] + 0
        if (a > 255 || b > 255 || c > 255 || d > 255) continue
        if (a == 127 || ip == "0.0.0.0" || ip == "255.255.255.255") continue
        if ((a == 192 && b == 0 && c == 2) || (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113)) continue
        if (ip == "169.254.169.254" || ip == "169.254.170.2" || ip == "169.254.170.23") continue
        if (a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b <= 127) || (a == 169 && b == 254)) return ip
        if (pre3 == "://" || pre == "@" || post ~ "^:[0-9]") return ip
    }
    return ""
}

function reserved(h) {
    return h ~ "(^|[.])(localhost|example|test|invalid)$" || h ~ "(^|[.])example[.](com|net|org)$"
}

function allowed(h,    d) {
    for (d in allow)
        if (h == d || (length(h) > length(d) && substr(h, length(h) - length(d)) == "." d)) { used[d] = 1; return 1 }
    return 0
}

function find_host(s,    rest, off, pos, scheme, h, i) {
    rest = s; off = 0
    while (i = index(rest, "://")) {
        pos = off + i
        rest = substr(rest, i + 3); off = pos + 2
        scheme = tolower(substr(s, 1, pos - 1))
        if (!match(scheme, "[a-z][a-z0-9+.-]*$")) continue
        scheme = substr(scheme, RSTART)
        if (scheme !~ "^(https?|wss?|grpcs?|ftps?|sftp|ssh|git|postgres(ql)?|mysql|rediss?|amqps?|mqtt|nats|kafka|mongodb|tcp|udp|smtp|imap|ldaps?)$") continue
        h = rest
        if (substr(h, 1, 1) == "[") {
            sub("[/?#\"'`)>,;| \t].*", "", h)
            i = index(h, "]"); if (i) h = substr(h, 1, i)
            h = tolower(h)
            # Brackets without a `:` (a regular expression's class) are no address.
            if (h !~ /^[[][0-9a-z.%]*:[0-9a-z:.%]*[]]?$/) continue
            if (h == "[::1]" || h == "[fd00:ec2::254]" || h == "[fd00:ec2::23]") continue
            return h
        }
        i = index(h, "\\"); if (i) h = substr(h, 1, i - 1)
        i = index(h, "]"); if (i) h = substr(h, 1, i - 1)
        sub("[/?#\"'`)>,;| \t].*", "", h)
        sub("^.*@", "", h)
        sub(":.*", "", h)
        h = tolower(h); sub("[.]$", "", h)
        # A template (`{host}`, `$HOST`, `<host>`), an ellipsis or a pattern
        # is not a host.
        if (h !~ /^[a-z0-9_.-]+$/) continue
        if (h ~ "^[0-9.]+$" || reserved(h) || allowed(h)) continue
        return h
    }
    return ""
}

function find_email(s,    rest, off, pos, e, at, local, dom) {
    rest = s; off = 0
    while (match(rest, /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+([.][A-Za-z0-9-]+)*[.][A-Za-z][A-Za-z]+/)) {
        pos = off + RSTART
        e = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH); off = pos + length(e) - 1
        at = index(e, "@")
        local = tolower(substr(e, 1, at - 1)); dom = tolower(substr(e, at + 1))
        if (local == "noreply" || local == "no-reply" || reserved(dom)) continue
        # The user of a URL's authority, right after `://`, is no address when
        # the host is a domain of <hosts> or under one.
        if (pos > 3 && substr(s, pos - 3, 3) == "://" && allowed(dom)) continue
        return e
    }
    return ""
}

function transitions(t,    i, k, prev, nt) {
    nt = 0; prev = ""
    for (i = 1; i <= length(t); i++) {
        k = index("0123456789", substr(t, i, 1)) ? "d" : "l"
        if (prev != "" && k != prev) nt++
        prev = k
    }
    return nt
}

function find_sha(s,    rest, off, pos, t, len, pre, post) {
    rest = s; off = 0
    while (match(rest, /[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+/)) {
        pos = off + RSTART
        t = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH); off = pos + length(t) - 1
        len = length(t)
        if (!((len >= 7 && len <= 12) || len == 40)) continue
        pre = pos > 1 ? substr(s, pos - 1, 1) : ""
        post = substr(s, pos + len, 3)
        if ((pre != "" && index(SHA_BEFORE, pre)) || (post != "" && index(SHA_AFTER, substr(post, 1, 1)))) continue
        if (post == "..." || post == "…") continue
        if ((pre == "\"" || pre == "'") && substr(post, 1, 1) == pre) continue
        if (t ~ "^0b[01]+$" || t ~ "^[0-9]+e[0-9]+$" || transitions(t) < 2) continue
        return t
    }
    return ""
}

# The prose of line s, a line of a file of kind fk, or "". Follows Mojo and
# Python docstrings across lines (`indoc`) when `dq` is set.
function prose(s, fk,    i, out, q, rest) {
    if (fk == "text") return s
    if (fk == "hash") {
        out = ""
        if (dq) {
            rest = s
            while (rest != "") {
                i = index(rest, "\"\"\"")
                if (indoc) {
                    if (i == 0) { out = out " " rest; rest = "" }
                    else { out = out " " substr(rest, 1, i - 1); rest = substr(rest, i + 3); indoc = 0 }
                } else {
                    if (i == 0) break
                    rest = substr(rest, i + 3); indoc = 1
                }
            }
            if (indoc || out != "") return out
        }
        if (match(s, /(^|[ \t])#/)) {
            # A `#` after an odd number of double quotes is in a string.
            q = substr(s, 1, RSTART)
            if (gsub("\"", "", q) % 2 == 0) return substr(s, RSTART)
        }
        return ""
    }
    if (fk == "slash") {
        if (s ~ /^[ \t]*([*]|\/[*])/) return s
        # The first `//` at the start or after a space or tab that is not in
        # a string literal (an even number of double quotes before it).
        out = 0
        while ((i = index(substr(s, out + 1), "//")) > 0) {
            i += out
            q = substr(s, 1, i - 1)
            if ((i == 1 || substr(s, i - 1, 1) ~ /[ \t]/) && gsub("\"", "", q) % 2 == 0) return substr(s, i)
            out = i + 1
        }
    }
    return ""
}

function kind_of(f) {
    if (f ~ "[.](md|txt|rst)$") return "text"
    if (f ~ "(^|/)(BUCK|BUILD|Makefile|Dockerfile)$" || f ~ "(^|/)[.][a-z]+([.][a-z]+)*$" || f ~ "[.](mojo|py|sh|bash|bzl|bxl|yml|yaml|toml|tsv|txtpb|textproto|buckconfig|cfg|ini|flags|awk|example|cmake)$") return "hash"
    if (f ~ "[.](c|h|cc|cpp|hpp|rs|zig|proto|go|js|ts|java|S|s|inc)$") return "slash"
    return ""
}

# The path of every staged file, read or not: a date, a home directory or a
# word of the deny list in a directory or file name is a finding at line 0.
function scan_path(f,    p, lc, t, y, w) {
    p = "/" f; lc = tolower(p)
    for (y = FROM; y <= PY && !index(p, y ""); y++) ;
    if (y <= PY && (t = find_date(lc)) != "")
        add("date", f, 0, t " (in the path)", "a date before " PUBLIC ", when the public history starts")
    if ((t = find_home(p)) != "")
        add("home_path", f, 0, t " (in the path)", "a home directory names a person: use a placeholder such as /home/user")
    for (w = 1; w <= ndeny; w++)
        if (index(lc, deny[w])) { add("deny", f, 0, deny[w] " (in the path)", "a word of the private deny list"); break }
}

function scan(f,    line, lno, lc, fk, t, p, w, y, r) {
    fk = kind_of(f)
    dq = f ~ "[.](mojo|py)$"
    indoc = 0; lno = 0
    while ((r = (getline line < f)) > 0) {
        lno++
        for (y = FROM; y <= PY && !index(line, y ""); y++) ;
        lc = (ndeny || y <= PY) ? tolower(line) : ""
        if (y <= PY && (t = find_date(lc)) != "")
            add("date", f, lno, t, "a date before " PUBLIC ", when the public history starts")
        if ((index(line, "/home/") || index(line, "/Users/") || index(line, "Users\\")) && (t = find_home(line)) != "")
            add("home_path", f, lno, t, "a home directory names a person: use a placeholder such as /home/user")
        if (line ~ /[0-9][.][0-9]+[.][0-9]+[.][0-9]/ && (t = find_ip(line)) != "")
            add("ip", f, lno, t, "an address of a private, shared or link-local network, or one written as an address: use 127.0.0.1 or a documentation range (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24)")
        if (index(line, "://") && (t = find_host(line)) != "")
            add("host", f, lno, t, "a URL host that is neither a reserved example name nor under a domain of " AN)
        if (index(line, "@") && line ~ /@[A-Za-z0-9-]+[.]/ && (t = find_email(line)) != "")
            add("email", f, lno, t, "an email address outside the reserved example domains")
        p = prose(line, fk)
        if (p ~ /[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/ && (t = find_sha(p)) != "")
            add("commit_sha", f, lno, t, "a commit id in prose: name the change by its pull request or release")
        for (w = 1; w <= ndeny; w++)
            if (index(lc, deny[w])) { add("deny", f, lno, deny[w], "a word of the private deny list"); break }
    }
    # getline returns -1 on a read error: a file not read is a finding, never
    # a file without findings.
    if (r < 0) problems[++np] = P f ": cannot be read (getline failed after line " lno "); the lint read nothing more of it"
    close(f)
}

BEGIN {
    # The window: the years FROM to PY, and the months before PM of PY.
    if (FROM !~ /^[0-9][0-9][0-9][0-9]$/ || PUBLIC !~ /^[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-01$/ || substr(PUBLIC, 1, 4) + 0 < FROM + 0) {
        print "public_boundary: the window is from year `" FROM "` to `" PUBLIC "`; name a year and a later first day of a month (YYYY-MM-01)"
        bad = 1
        exit 1
    }
    FROM += 0; PY = substr(PUBLIC, 1, 4) + 0; PM = substr(PUBLIC, 6, 2) + 0
    YEARS = FROM ""
    for (y = FROM + 1; y <= PY; y++) YEARS = YEARS "|" y
    YEARS = "(" YEARS ")"
    MON = "(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?)"
    SHA_BEFORE = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_/.@:\\-"
    SHA_AFTER = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-"
    rules = "date, home_path, ip, host, email, commit_sha"
    split(rules, rl, ", ")
    for (i in rl) rule[rl[i]] = 1
    ndeny = 0
}

FILENAME == ARGV[1] { if ($0 != "") files[++nf] = $0; next }

FILENAME == ARGV[2] { if ($0 != "") { paths[++npaths] = $0; known[$0] = 1 } next }

FILENAME == ARGV[3] {
    if ($0 ~ "^[ \t]*(#|$)") next
    where = AN ":" FNR ": "
    if (NF != 2) { problems[++np] = where "a row has 2 tab-separated fields (domain, reason), not " NF; next }
    d = tolower($1)
    if ($2 !~ "[^ \t]") { problems[++np] = where "empty reason: say whose service " d " is"; next }
    if (reserved(d)) { problems[++np] = where d " is reserved for examples and needs no row; delete the row"; next }
    if (d in allow) { problems[++np] = where "a second row for " d; next }
    allow[d] = FNR
    next
}

FILENAME == ARGV[4] {
    if ($0 ~ "^[ \t]*(#|$)") next
    w = tolower($0); sub("^[ \t]+", "", w); sub("[ \t]+$", "", w)
    deny[++ndeny] = w
    next
}

FILENAME == ARGV[5] {
    if ($0 ~ "^[ \t]*(#|$)") next
    where = HN ":" FNR ": "
    if (NF != 4) { problems[++np] = where "a row has 4 tab-separated fields (rule, file, count, reason), not " NF; next }
    if (!($1 in rule)) { problems[++np] = where "unknown rule `" $1 "` (the rules a row can hold: " rules ")"; next }
    if (!($2 in known)) { problems[++np] = where $2 " is not a file of the tree; delete the row"; next }
    if ($3 !~ "^[1-9][0-9]*$") { problems[++np] = where "count `" $3 "` is not a positive whole number"; next }
    if ($4 !~ "[^ \t]") { problems[++np] = where "empty reason: say why the file holds it"; next }
    k = $1 SUBSEP $2
    if (k in held) { problems[++np] = where "a second row for " $1 " in " $2; next }
    held[k] = $3; hrow[k] = FNR
    next
}

END {
    if (bad) exit 1
    for (i = 1; i <= npaths; i++) scan_path(paths[i])
    for (i = 1; i <= nf; i++) scan(files[i])
    for (k in n) {
        h = (k in held) ? held[k] : 0
        if (n[k] <= h) continue
        for (i = 1; i <= n[k]; i++) print site[k, i] (h ? " (" n[k] " findings, held " h ")" : "")
    }
    for (k in held) {
        c = (k in n) ? n[k] : 0
        if (c >= held[k]) continue
        split(k, kf, SUBSEP)
        print HN ":" hrow[k] ": " kf[1] " in " kf[2] " is held at " held[k] " and has " c ": " (c ? "lower the count to " c : "delete the row")
    }
    for (d in allow) if (!(d in used)) print AN ":" allow[d] ": no URL host of the tree is " d " or under it; delete the row"
    for (i = 1; i <= np; i++) print problems[i]
}
