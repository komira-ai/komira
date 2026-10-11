//! The rules of the public boundary lint: what each one matches on a line.
//! check.zig runs them over a tree; main.zig is the tool.
//!
//! One finding per rule and line; a line's finding is its first match. Every
//! rule is generic: it names no word, host or person of any owner, so this
//! file can be public. A private consumer passes words of its own in a deny
//! list kept outside the repository (check.zig). Comparisons ignore case
//! unless a rule says otherwise.
//!
//!   date        A calendar date in the window from the first day of the year
//!               `from` up to `public`, the day the public history starts:
//!               what the repository says happened before it is not public.
//!               Spellings: Y-M-D with `-`, `_`, `/` or `.` between the parts
//!               and a two-digit month and day, or a one-digit month or day
//!               between two `-` or two `/` (a dotted Y.M.D of one digit is
//!               read as a version); Y-M (not followed by a digit or `-`); the
//!               eight digits YYYYMMDD standing alone (no letter or digit
//!               before it, no digit after); a month name or its three-letter
//!               form, with or without a day, before the year (`Mon D, YYYY`,
//!               `D Month YYYY`, `Month YYYY`); and D/M/YYYY or M/D/YYYY (`/`,
//!               `.` or `-`), when either of the first two numbers can be a
//!               month of the window. The year must not touch another digit.
//!               Years before `from` are not read: a date there is data
//!               (epochs, certificates, standards, the date and time
//!               libraries' test cases), which a rule of this kind cannot tell
//!               from history.
//!   home_path   /home/<name>/, /Users/<name>/ or <drive>:\Users\<name>\,
//!               unless <name> is a placeholder: user, username, u, me, you,
//!               runner, alice, bob, example, nobody, shared, name, someone,
//!               or a name starting with `$`, `<`, `{`, `*` or `.`.
//!   ip          A dotted IPv4 address (four numbers up to 255, not part of a
//!               longer dotted run) in a private (10/8, 172.16/12,
//!               192.168/16), shared (100.64/10) or link-local (169.254/16)
//!               range, or any address written as one (after `://` or `@`, or
//!               followed by `:<port>`), except loopback (127/8), 0.0.0.0,
//!               255.255.255.255, the documentation ranges (192.0.2/24,
//!               198.51.100/24, 203.0.113/24), and the metadata and credential
//!               services the clouds publish at fixed link-local addresses
//!               (169.254.169.254, 169.254.170.2, 169.254.170.23). A dotted
//!               number not in a private range and not written as an address
//!               is read as a section number or an OID.
//!   host        The host of a URL whose scheme reaches a network (SCHEMES
//!               below): a name (port and user dropped) that is not one of the
//!               names reserved for examples and tests (localhost, example,
//!               test, invalid and their subdomains, RFC 2606 and RFC 6761;
//!               example.com, example.net, example.org and their subdomains)
//!               and is neither a domain of the hosts ledger nor under one. An
//!               IPv6 host must be [::1] or one of the documented cloud
//!               metadata addresses [fd00:ec2::254] and [fd00:ec2::23]. A host
//!               holding anything but letters, digits, `_`, `.` and `-` (a
//!               template such as `{host}` or `$HOST`, an ellipsis, a pattern)
//!               is not read; an IPv4 host is the ip rule's.
//!   email       An address local@domain, unless the domain is reserved (as
//!               for hosts, and *.example, *.test, *.invalid, *.localhost),
//!               the local part is noreply or no-reply (a commit trailer's
//!               address names no person), or the local part starts right
//!               after `://` and the domain is a domain of the hosts ledger or
//!               under one: that is the user of a URL's authority on a host
//!               the ledger names (Hadoop ABFS's
//!               abfss://<container>@<account>.dfs.core.windows.net). A user
//!               before any other host (`s3://<user>@<host>/k`) is read, as
//!               are `mailto:` and an address elsewhere in a URL.
//!   commit_sha  In prose, a hex string shaped like a commit id: 7 to 12, or
//!               40, lowercase hex digits holding at least two changes between
//!               digit and letter, standing alone (no letter, digit, `_`, `/`,
//!               `.`, `@`, `:`, `\` or `-` before it, no letter, digit, `_` or
//!               `-` after it: a UUID's group is not one), not followed by
//!               `...` or an ellipsis (a digest abbreviated), not quoted, not a
//!               binary (0b...) or float (1e30) literal. Prose (`prose`) is a
//!               whole line of a Markdown or text file, the comment of a line
//!               of a `#` language with a Mojo or Python docstring, and the
//!               comment of a line of a `//` language. Code is not prose: a
//!               40-hex pin in code names an upstream commit.
//!
//! Limits (a text reader's):
//! - Vocabulary is not a shape, so a name of the owner's systems is found only
//!   through the deny list.
//! - A host outside a URL (a bare name, `name:port`) is not read; a host under
//!   an allowed cloud domain may name a resource of its own (a bucket, a
//!   function URL); an IPv6 address outside a URL is not read.
//! - Object-store URLs (s3://, gs://, az://, abfs://, and any scheme not in
//!   SCHEMES) are not host-checked: their authority is a bucket or container
//!   name, which the object-store clients' tests make up by the hundred and
//!   which no allow-list of domains could name. A deny-list word still finds
//!   a real bucket name.
//! - A commit id inside a URL (after a `/`, as in a link to an upstream
//!   commit) is not read, nor one in code.
//! - commit_sha needs two switches between digit and letter, so a real id
//!   with fewer is missed: for random ids about 14% of 7-hex ones, 9% of 8,
//!   6% of 9, 4% of 10, 1.4% of 12, and none of 40.
//! - A date before `from` is not read; Y-M with a one-digit month is not read.
//! - A home directory written as `~name/` (the shell's shorthand) is not read:
//!   `~` before a word is as common in code, patterns and prose as in paths,
//!   so it is left to review and the deny list.
//!
//! Every finder takes the line and returns the text of its first match, a
//! slice of the line (of its lowercase copy where the rule ignores case).

const std = @import("std");

pub const Window = struct {
    /// The first year read.
    from: u32,
    /// The year and month of `public`, the first day of the public history.
    py: u32,
    pm: u32,

    /// `from` is a four-digit year and `public` a first day of a month
    /// (YYYY-MM-01) of that year or later; null otherwise.
    pub fn parse(from: []const u8, public: []const u8) ?Window {
        if (from.len != 4 or !allDigits(from)) return null;
        if (public.len != 10 or public[4] != '-' or public[7] != '-') return null;
        if (!allDigits(public[0..4]) or !allDigits(public[5..7]) or !std.mem.eql(u8, public[8..10], "01")) return null;
        const pm = number(public[5..7]);
        if (pm < 1 or pm > 12) return null;
        const w = Window{ .from = number(from), .py = number(public[0..4]), .pm = pm };
        if (w.py < w.from) return null;
        return w;
    }

    pub fn contains(w: Window, y: u32, m: u32) bool {
        return (y >= w.from and y < w.py) or (y == w.py and m >= 1 and m < w.pm);
    }
};

/// The domains of the hosts ledger, lowercase, and which of them a URL host
/// (or a URL's user, for email) of the tree was under.
pub const Hosts = struct {
    domains: []const []const u8,
    used: []bool,

    /// h is a domain of the ledger or under one; marks each such domain used.
    pub fn allowed(self: Hosts, h: []const u8) bool {
        var any = false;
        for (self.domains, 0..) |d, i| {
            if (std.mem.eql(u8, h, d) or (h.len > d.len and std.mem.endsWith(u8, h, d) and h[h.len - d.len - 1] == '.')) {
                self.used[i] = true;
                any = true;
            }
        }
        return any;
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn oneOf(c: u8, set: []const u8) bool {
    return std.mem.indexOfScalar(u8, set, c) != null;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!isDigit(c)) return false;
    return s.len > 0;
}

/// The value of a run of digits, saturating at 100000 (no rule reads more).
fn number(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| {
        v = v * 10 + (c - '0');
        if (v > 100000) return 100000;
    }
    return v;
}

fn digitRun(s: []const u8, i: usize) usize {
    var k = i;
    while (k < s.len and isDigit(s[k])) k += 1;
    return k - i;
}

fn spaceRun(s: []const u8, i: usize) usize {
    var k = i;
    while (k < s.len and s[k] == ' ') k += 1;
    return k - i;
}

// ---------------------------------------------------------------- date

const MONTHS = "janfebmaraprmayjunjulaugsepoctnovdec";

/// Every spelling of a month the date rule reads.
const MONTH_FORMS = [_][]const u8{
    "january", "jan", "february", "feb", "march",     "mar",  "april", "apr",
    "may",     "june", "jun",     "july", "jul",      "august", "aug", "september",
    "sept",    "sep", "october",  "oct", "november", "nov",  "december", "dec",
};

/// The end of the month name at t[j], when one is there and is followed by
/// `.`, `,` or a space (no other character can follow one in a date). The
/// forms of a month are prefixes of each other, so at most one ends so.
fn monthEnd(t: []const u8, j: usize) ?usize {
    if (j > t.len) return null;
    for (MONTH_FORMS) |f| {
        if (j + f.len < t.len and std.mem.startsWith(u8, t[j..], f) and oneOf(t[j + f.len], ". ,")) return j + f.len;
    }
    return null;
}

/// Skips an ordinal suffix (st, nd, rd, th) at t[k].
fn ordinal(t: []const u8, k: usize) usize {
    if (k + 2 <= t.len) {
        const two = t[k .. k + 2];
        for ([_][]const u8{ "st", "nd", "rd", "th" }) |o| if (std.mem.eql(u8, two, o)) return k + 2;
    }
    return k;
}

/// `[.]?,?[ ]+` running to the end of t.
fn closes(t: []const u8, k0: usize) bool {
    var k = k0;
    if (k < t.len and t[k] == '.') k += 1;
    if (k < t.len and t[k] == ',') k += 1;
    const sp = spaceRun(t, k);
    return sp > 0 and k + sp == t.len;
}

/// `[0-9]?[0-9](st|nd|rd|th)?` at t[k], its end; the digits start a run.
fn day(t: []const u8, k: usize) ?usize {
    const dl = digitRun(t, k);
    if (dl == 0 or dl > 2) return null;
    return ordinal(t, k + dl);
}

/// After the month: `[.]?[ ]+` a day `,?[ ]+` to the end (`Mon D, `).
fn monthDayRest(t: []const u8, k0: usize) bool {
    var k = k0;
    if (k < t.len and t[k] == '.') k += 1;
    const sp = spaceRun(t, k);
    if (sp == 0) return false;
    k = day(t, k + sp) orelse return false;
    if (k < t.len and t[k] == ',') k += 1;
    const sp2 = spaceRun(t, k);
    return sp2 > 0 and k + sp2 == t.len;
}

/// A day, spaces, a month name and `[.]?,?[ ]+` from t[k] to the end (`D Month `).
fn dayMonthRest(t: []const u8, k0: usize) bool {
    var k = day(t, k0) orelse return false;
    const sp = spaceRun(t, k);
    if (sp == 0) return false;
    k = monthEnd(t, k + sp) orelse return false;
    return closes(t, k);
}

const Shape = enum { month_day, day_month, month };

/// Where the tail before a year starts its month-name date of `shape`: the
/// first index j of t from which `(^|[^a-z])` (or `(^|[^0-9])` for a day
/// first) and the shape run to the end of t.
fn monthDate(t: []const u8, shape: Shape) ?usize {
    var j: usize = 0;
    while (j < t.len) : (j += 1) {
        if (shape == .day_month) {
            if (j == 0 and isDigit(t[0]) and dayMonthRest(t, 0)) return 0;
            if (!isDigit(t[j]) and dayMonthRest(t, j + 1)) return j;
            continue;
        }
        const rest = if (shape == .month_day) &monthDayRest else &closes;
        if (j == 0) {
            if (monthEnd(t, 0)) |k| {
                if (rest(t, k)) return 0;
            }
        }
        if (!isLower(t[j])) {
            if (monthEnd(t, j + 1)) |k| {
                if (rest(t, k)) return j;
            }
        }
    }
    return null;
}

/// D/M/ or M/D/ (with `/`, `.` or `-`) ending t: where it starts, and the
/// two numbers.
fn numericDate(t: []const u8) ?struct { start: usize, a: u32, b: u32 } {
    const n = t.len;
    if (n < 4 or !oneOf(t[n - 1], "-/.")) return null;
    var bs = n - 1;
    while (bs > 0 and isDigit(t[bs - 1])) bs -= 1;
    const bl = n - 1 - bs;
    if (bl == 0 or bl > 2 or bs == 0 or !oneOf(t[bs - 1], "-/.")) return null;
    const ae = bs - 1;
    var a_start = ae;
    while (a_start > 0 and isDigit(t[a_start - 1])) a_start -= 1;
    const al = ae - a_start;
    if (al == 0 or al > 2) return null;
    if (a_start > 0 and oneOf(t[a_start - 1], "./-")) return null;
    // The date starts at its first digit.
    return .{ .start = a_start, .a = number(t[a_start..ae]), .b = number(t[bs .. n - 1]) };
}

/// The first date of the window on line s (lowercase), or null.
pub fn findDate(w: Window, s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 4 <= s.len) {
        const pos = i;
        if (!allDigits(s[pos .. pos + 4]) or number(s[pos .. pos + 4]) < w.from or number(s[pos .. pos + 4]) > w.py) {
            i += 1;
            continue;
        }
        i = pos + 4;
        const y = number(s[pos .. pos + 4]);
        const post = s[pos + 4 ..];
        if (pos > 0 and isDigit(s[pos - 1])) continue;
        // Y-M-D: two-digit month and day with any separator, or one-digit
        // ones between `-` or `/` (a dotted 2031.1.5 is a version).
        if (post.len >= 4 and oneOf(post[0], "-_/.")) {
            const ml = digitRun(post, 1);
            if (ml >= 1 and ml <= 2 and 1 + ml < post.len and oneOf(post[1 + ml], "-_/.")) {
                const dl = digitRun(post, 2 + ml);
                if (dl >= 1 and dl <= 2) {
                    const mm = number(post[1 .. 1 + ml]);
                    const dd = number(post[2 + ml .. 2 + ml + dl]);
                    if ((ml == 2 and dl == 2) or (oneOf(post[0], "-/") and post[1 + ml] == post[0]))
                        if (mm >= 1 and mm <= 12 and dd >= 1 and dd <= 31 and w.contains(y, mm))
                            return s[pos .. pos + 6 + ml + dl];
                    continue;
                }
            }
        }
        // Y-M, not followed by a digit or `-`.
        if (post.len >= 3 and post[0] == '-' and digitRun(post, 1) >= 2 and validMonth(post[1..3]) and (post.len == 3 or !oneOf(post[3], "-0123456789"))) {
            if (w.contains(y, number(post[1..3]))) return s[pos .. pos + 7];
            continue;
        }
        // YYYYMMDD standing alone.
        if (!(pos > 0 and isLower(s[pos - 1])) and post.len >= 4 and allDigits(post[0..4]) and validMonth(post[0..2]) and validDay(post[2..4]) and (post.len == 4 or !isDigit(post[4]))) {
            if (w.contains(y, number(post[0..2]))) return s[pos .. pos + 8];
            continue;
        }
        if (post.len > 0 and isDigit(post[0])) continue;
        const tail = s[0..pos];
        const found = monthDate(tail, .month_day) orelse monthDate(tail, .day_month) orelse monthDate(tail, .month);
        if (found) |j| {
            const start = if (!isDigit(tail[j]) and !isLower(tail[j])) j + 1 else j;
            const m = firstMonth(tail[start..]);
            if (w.contains(y, m)) return s[start .. pos + 4];
            continue;
        }
        if (numericDate(tail)) |r| {
            if ((r.a <= 12 and w.contains(y, r.a)) or (r.b <= 12 and w.contains(y, r.b))) return s[r.start .. pos + 4];
        }
    }
    return null;
}

fn validMonth(two: []const u8) bool {
    const m = number(two);
    return allDigits(two) and two.len == 2 and m >= 1 and m <= 12;
}

fn validDay(two: []const u8) bool {
    const d = number(two);
    return allDigits(two) and two.len == 2 and d >= 1 and d <= 31;
}

/// The month (1 to 12) of the first three-letter month name in s, 0 if none.
fn firstMonth(s: []const u8) u32 {
    var i: usize = 0;
    while (i + 3 <= s.len) : (i += 1) {
        var m: usize = 0;
        while (m < 12) : (m += 1) if (std.mem.eql(u8, s[i .. i + 3], MONTHS[3 * m .. 3 * m + 3])) return @intCast(m + 1);
    }
    return 0;
}

// ---------------------------------------------------------------- home_path

const PLACEHOLDERS = [_][]const u8{ "user", "username", "u", "me", "you", "runner", "alice", "bob", "example", "nobody", "shared", "name", "someone" };

pub fn placeholder(name: []const u8) bool {
    if (name.len == 0 or oneOf(name[0], "$<{*.")) return true;
    for (PLACEHOLDERS) |p| if (std.ascii.eqlIgnoreCase(name, p)) return true;
    return false;
}

/// The first home directory on line s that names a person, or null. Case
/// matters: `/home/`, `/Users/` and `Users\` as written.
pub fn findHome(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const plen: usize = if (std.mem.startsWith(u8, s[i..], "/home/")) 6 else if (std.mem.startsWith(u8, s[i..], "/Users/")) 7 else 0;
        if (plen == 0) {
            i += 1;
            continue;
        }
        var e = i + plen;
        while (e < s.len and !oneOf(s[e], "/ \t\"'`)<>,;:")) e += 1;
        if (e == i + plen) {
            i += 1;
            continue;
        }
        var name = s[i..e];
        if (std.mem.indexOfScalar(u8, name, '\\')) |b| name = name[0..b];
        if (!placeholder(name[plen..])) return name;
        i = e;
    }
    // <drive>:\Users\<name>, with each backslash single or doubled (a string
    // literal in code).
    var r: usize = 0;
    while (std.mem.indexOfPos(u8, s, r, "Users\\")) |k| {
        var j = k + 6;
        while (j < s.len and s[j] == '\\') j += 1;
        const cs = j;
        while (j < s.len and !oneOf(s[j], "\\ \t\"'`/")) j += 1;
        if (!placeholder(s[cs..j])) return s[k..j];
        r = j;
    }
    return null;
}

// ---------------------------------------------------------------- ip

/// The first address on line s that the ip rule refuses, or null.
pub fn findIp(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len) {
        if (!isDigit(s[i])) {
            i += 1;
            continue;
        }
        var q: [4]u32 = undefined;
        var k = i;
        var whole = true;
        for (0..4) |g| {
            const dl = digitRun(s, k);
            if (dl == 0) {
                whole = false;
                break;
            }
            q[g] = if (dl > 3) 1000 else number(s[k .. k + dl]);
            k += dl;
            if (g < 3) {
                if (k < s.len and s[k] == '.') {
                    k += 1;
                } else {
                    whole = false;
                    break;
                }
            }
        }
        if (!whole) {
            // No address starts in this run of digits.
            i += digitRun(s, i);
            continue;
        }
        const pos = i;
        const end = k;
        i = end;
        const ip = s[pos..end];
        const post = s[end..@min(end + 2, s.len)];
        if (pos > 0 and (isAlnum(s[pos - 1]) or s[pos - 1] == '.')) continue;
        if (post.len == 2 and post[0] == '.' and isDigit(post[1])) continue;
        const a = q[0];
        const b = q[1];
        const c = q[2];
        if (a > 255 or b > 255 or c > 255 or q[3] > 255) continue;
        if (a == 127 or std.mem.eql(u8, ip, "0.0.0.0") or std.mem.eql(u8, ip, "255.255.255.255")) continue;
        if ((a == 192 and b == 0 and c == 2) or (a == 198 and b == 51 and c == 100) or (a == 203 and b == 0 and c == 113)) continue;
        if (std.mem.eql(u8, ip, "169.254.169.254") or std.mem.eql(u8, ip, "169.254.170.2") or std.mem.eql(u8, ip, "169.254.170.23")) continue;
        if (a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) or (a == 100 and b >= 64 and b <= 127) or (a == 169 and b == 254)) return ip;
        if ((pos >= 3 and std.mem.eql(u8, s[pos - 3 .. pos], "://")) or (pos > 0 and s[pos - 1] == '@') or (post.len == 2 and post[0] == ':' and isDigit(post[1]))) return ip;
    }
    return null;
}

// ---------------------------------------------------------------- host

/// The schemes whose URLs reach a network.
pub const SCHEMES = [_][]const u8{
    "http",  "https", "ws",    "wss",  "grpc",  "grpcs", "ftp",  "ftps",    "sftp", "ssh", "git", "postgres", "postgresql",
    "mysql", "redis", "rediss", "amqp", "amqps", "mqtt",  "nats", "kafka", "mongodb", "tcp", "udp", "smtp",     "imap",
    "ldap",  "ldaps",
};

/// A name reserved for examples and tests (lowercase).
pub fn reserved(h: []const u8) bool {
    for ([_][]const u8{ "localhost", "example", "test", "invalid", "example.com", "example.net", "example.org" }) |r| {
        if (std.mem.eql(u8, h, r) or (h.len > r.len and std.mem.endsWith(u8, h, r) and h[h.len - r.len - 1] == '.')) return true;
    }
    return false;
}

fn isSchemeChar(c: u8) bool {
    return isLower(c) or isDigit(c) or oneOf(c, "+.-");
}

const HOST_END = "/?#\"'`)>,;| \t";

/// The first URL host on line s (lc: s in lowercase) the host rule refuses,
/// or null; a slice of lc.
pub fn findHost(s: []const u8, lc: []const u8, hosts: Hosts) ?[]const u8 {
    var off: usize = 0;
    while (std.mem.indexOfPos(u8, s, off, "://")) |k| {
        off = k + 3;
        // The scheme: the letters, digits, `+`, `.` and `-` before `://`,
        // from the first letter.
        var a = k;
        while (a > 0 and isSchemeChar(lc[a - 1])) a -= 1;
        while (a < k and !isLower(lc[a])) a += 1;
        if (a == k) continue;
        const scheme = lc[a..k];
        var known = false;
        for (SCHEMES) |sc| known = known or std.mem.eql(u8, scheme, sc);
        if (!known) continue;
        const rest = s[off..];
        if (rest.len > 0 and rest[0] == '[') {
            var e = std.mem.indexOfAny(u8, rest, HOST_END) orelse rest.len;
            if (std.mem.indexOfScalar(u8, rest[0..e], ']')) |b| e = b + 1;
            const h = lc[off .. off + e];
            // Brackets without a `:` (a regular expression's class) are no address.
            const body = if (h.len > 1 and h[h.len - 1] == ']') h[1 .. h.len - 1] else h[1..];
            var v6 = std.mem.indexOfScalar(u8, body, ':') != null;
            for (body) |c| v6 = v6 and (isLower(c) or isDigit(c) or oneOf(c, ".%:"));
            if (!v6) continue;
            if (std.mem.eql(u8, h, "[::1]") or std.mem.eql(u8, h, "[fd00:ec2::254]") or std.mem.eql(u8, h, "[fd00:ec2::23]")) continue;
            return h;
        }
        var e = std.mem.indexOfAny(u8, rest, "\\]" ++ HOST_END) orelse rest.len;
        var b: usize = 0;
        if (std.mem.lastIndexOfScalar(u8, rest[0..e], '@')) |at| b = at + 1;
        if (std.mem.indexOfScalarPos(u8, rest[0..e], b, ':')) |colon| e = colon;
        if (e > b and rest[e - 1] == '.') e -= 1;
        const h = lc[off + b .. off + e];
        // A template (`{host}`, `$HOST`, `<host>`), an ellipsis or a pattern
        // is not a host.
        if (h.len == 0) continue;
        var name = true;
        var numeric = true;
        for (h) |c| {
            name = name and (isLower(c) or isDigit(c) or oneOf(c, "_.-"));
            numeric = numeric and (isDigit(c) or c == '.');
        }
        if (!name or numeric or reserved(h) or hosts.allowed(h)) continue;
        return h;
    }
    return null;
}

// ---------------------------------------------------------------- email

fn isLocalChar(c: u8) bool {
    return isAlnum(c) or oneOf(c, "._%+-");
}

fn isLabelChar(c: u8) bool {
    return isAlnum(c) or c == '-';
}

/// The end of the longest `label(.label)*.LL+` domain at s[p] (the last part
/// two or more letters, which may stop inside a label), or null.
fn domainEnd(s: []const u8, p: usize) ?usize {
    var k = p;
    while (k < s.len and isLabelChar(s[k])) k += 1;
    if (k == p) return null;
    var best: ?usize = null;
    while (k + 1 < s.len and s[k] == '.' and isLabelChar(s[k + 1])) {
        const ls = k + 1;
        var lp = ls;
        while (lp < s.len and std.ascii.isAlphabetic(s[lp])) lp += 1;
        if (lp - ls >= 2) best = lp;
        k = ls;
        while (k < s.len and isLabelChar(s[k])) k += 1;
    }
    return best;
}

/// The first email address on line s (lc: s in lowercase) the email rule
/// refuses, or null.
pub fn findEmail(s: []const u8, lc: []const u8, hosts: Hosts) ?[]const u8 {
    var start: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, from, '@')) |at| {
        from = at + 1;
        var a = at;
        while (a > start and isLocalChar(s[a - 1])) a -= 1;
        if (a == at) continue;
        const end = domainEnd(s, at + 1) orelse continue;
        start = end;
        from = end;
        const local = lc[a..at];
        const dom = lc[at + 1 .. end];
        if (std.mem.eql(u8, local, "noreply") or std.mem.eql(u8, local, "no-reply") or reserved(dom)) continue;
        // The user of a URL's authority, right after `://`, is no address
        // when the host is a domain of the hosts ledger or under one.
        if (a >= 3 and std.mem.eql(u8, s[a - 3 .. a], "://") and hosts.allowed(dom)) continue;
        return s[a..end];
    }
    return null;
}

// ---------------------------------------------------------------- commit_sha

fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f');
}

/// The number of changes between digit and letter in t.
pub fn transitions(t: []const u8) usize {
    var n: usize = 0;
    var i: usize = 1;
    while (i < t.len) : (i += 1) {
        if (isDigit(t[i]) != isDigit(t[i - 1])) n += 1;
    }
    return n;
}

const ELLIPSIS = "\xe2\x80\xa6";

/// The first commit id in prose p, or null.
pub fn findSha(p: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < p.len) {
        if (!isHex(p[i])) {
            i += 1;
            continue;
        }
        const pos = i;
        while (i < p.len and isHex(p[i])) i += 1;
        const t = p[pos..i];
        if (t.len < 7) continue;
        if (!((t.len >= 7 and t.len <= 12) or t.len == 40)) continue;
        const post = p[i..@min(i + 3, p.len)];
        if (pos > 0 and (isAlnum(p[pos - 1]) or oneOf(p[pos - 1], "_/.@:\\-"))) continue;
        if (post.len > 0 and (isAlnum(post[0]) or oneOf(post[0], "_-"))) continue;
        if (std.mem.eql(u8, post, "...") or std.mem.eql(u8, post, ELLIPSIS)) continue;
        if (pos > 0 and (p[pos - 1] == '"' or p[pos - 1] == '\'') and post.len > 0 and post[0] == p[pos - 1]) continue;
        if (binaryLiteral(t) or floatLiteral(t) or transitions(t) < 2) continue;
        return t;
    }
    return null;
}

fn binaryLiteral(t: []const u8) bool {
    if (t.len < 3 or !std.mem.startsWith(u8, t, "0b")) return false;
    for (t[2..]) |c| if (c != '0' and c != '1') return false;
    return true;
}

fn floatLiteral(t: []const u8) bool {
    const e = std.mem.indexOfScalar(u8, t, 'e') orelse return false;
    return allDigits(t[0..e]) and allDigits(t[e + 1 ..]);
}

// ---------------------------------------------------------------- prose

pub const Kind = enum { text, hash, slash, none };

/// How a file's prose is found, by its path: `text` (Markdown and text
/// files: every line), `hash` (`#` comments), `slash` (`//` and `/*`
/// comments), or `none` (no prose read).
pub fn kindOf(path: []const u8) Kind {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const ext = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base[i + 1 ..] else "";
    const has_ext = std.mem.indexOfScalar(u8, base, '.') != null;
    for ([_][]const u8{ "md", "txt", "rst" }) |x| if (has_ext and std.mem.eql(u8, ext, x)) return .text;
    for ([_][]const u8{ "BUCK", "BUILD", "Makefile", "Dockerfile" }) |x| if (std.mem.eql(u8, base, x)) return .hash;
    if (dotfile(base)) return .hash;
    if (has_ext) {
        for ([_][]const u8{ "mojo", "py", "sh", "bash", "bzl", "bxl", "yml", "yaml", "toml", "tsv", "txtpb", "textproto", "buckconfig", "cfg", "ini", "flags", "awk", "example", "cmake" }) |x|
            if (std.mem.eql(u8, ext, x)) return .hash;
        for ([_][]const u8{ "c", "h", "cc", "cpp", "hpp", "rs", "zig", "proto", "go", "js", "ts", "java", "S", "s", "inc" }) |x|
            if (std.mem.eql(u8, ext, x)) return .slash;
    }
    return .none;
}

/// A dotfile named in lowercase words: `.name` or `.name.more`.
fn dotfile(base: []const u8) bool {
    if (base.len < 2 or base[0] != '.') return false;
    var it = std.mem.splitScalar(u8, base[1..], '.');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!isLower(c)) return false;
    }
    return true;
}

/// The prose of each line of one file, in order: docstrings of Mojo and
/// Python files continue across lines.
pub const Prose = struct {
    kind: Kind,
    docstrings: bool,
    in_doc: bool = false,
    buf: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator, path: []const u8) Prose {
        return .{
            .kind = kindOf(path),
            .docstrings = std.mem.endsWith(u8, path, ".mojo") or std.mem.endsWith(u8, path, ".py"),
            .buf = std.ArrayList(u8).init(alloc),
        };
    }

    pub fn deinit(self: *Prose) void {
        self.buf.deinit();
    }

    /// The prose of the next line s, or "".
    pub fn line(self: *Prose, s: []const u8) ![]const u8 {
        switch (self.kind) {
            .none => return "",
            .text => return s,
            .hash => {
                if (self.docstrings) {
                    self.buf.clearRetainingCapacity();
                    var rest = s;
                    while (rest.len > 0) {
                        const i = std.mem.indexOf(u8, rest, "\"\"\"");
                        if (self.in_doc) {
                            try self.buf.append(' ');
                            if (i) |q| {
                                try self.buf.appendSlice(rest[0..q]);
                                rest = rest[q + 3 ..];
                                self.in_doc = false;
                            } else {
                                try self.buf.appendSlice(rest);
                                rest = "";
                            }
                        } else {
                            const q = i orelse break;
                            rest = rest[q + 3 ..];
                            self.in_doc = true;
                        }
                    }
                    if (self.in_doc or self.buf.items.len > 0) return self.buf.items;
                }
                // The first `#` at the start or after a space or tab; one
                // after an odd number of double quotes is in a string.
                var k: usize = 0;
                while (k < s.len) : (k += 1) {
                    if (s[k] != '#') continue;
                    if (k == 0) return s;
                    if (s[k - 1] != ' ' and s[k - 1] != '\t') continue;
                    if (std.mem.count(u8, s[0..k], "\"") % 2 == 0) return s[k - 1 ..];
                    return "";
                }
                return "";
            },
            .slash => {
                var k: usize = 0;
                while (k < s.len and (s[k] == ' ' or s[k] == '\t')) k += 1;
                if (k < s.len and (s[k] == '*' or std.mem.startsWith(u8, s[k..], "/*"))) return s;
                // The first `//` at the start or after a space or tab that is
                // not in a string literal (an even number of double quotes
                // before it).
                var from: usize = 0;
                while (std.mem.indexOfPos(u8, s, from, "//")) |i| {
                    if ((i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t') and std.mem.count(u8, s[0..i], "\"") % 2 == 0) return s[i..];
                    from = i + 2;
                }
                return "";
            },
        }
    }
};
