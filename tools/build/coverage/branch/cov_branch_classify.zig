//! cov_branch_classify: the branches of one test's annotated IR that fall in
//! the library's measured sources, each a source decision or a known
//! compiler-made branch, as lcov BRDA records in repository paths. README.md
//! ("cov_branch_classify") has the rules with their evidence; in brief:
//!
//! usage: cov_branch_classify --ir <test.ll> --out <file> --map <PREFIX>=<REPO>
//!            [--gen <REL>]... [--exclude <PREFIX>]... [--exclude-file <NAME>]...
//!
//! <test.ll> is the module cov_branch_annotate.sh prints after LLVM's
//! `pgo-instr-use`: each `br i1`, `select i1` and `switch` that ran carries
//! `!prof !{!"branch_weights", ...}`, the counts of its arms.
//!
//! Files. A branch is attributed to its innermost `!dbg` location. A file
//! name is measured when it starts with --map's PREFIX (the library's [src],
//! `.../<16 hex>/src/<lib>/`; a PREFIX with no such segment is bad usage) and
//! is not a --gen source; its repository path
//! is REPO followed by the rest. A name holding `/<16 hex>/src/<lib>/` but not
//! PREFIX (the library's sources under another [src]) is refused; one equal
//! to an --exclude-file or under an --exclude prefix is not measured; any
//! other name is refused. Every `.mojo` file under PREFIX is read for the
//! functions it declares `@always_inline("nodebug")`.
//!
//! Classes, by the token at the branch's line and column, and the instruction
//! kinds each takes: source decisions `if` (br, select, switch), `elif` (br,
//! select, switch), `while` (br), `and`/`or` (br, select), the `(` of
//! `range(` on a `for ... in range(` line (br); compiler-made `+` (br), `//`
//! and `%` (select), and the `(` of any other call off a `for` line (br),
//! unless the callee is a measured `@always_inline("nodebug")` function, whose
//! code carries its callers' locations. Anything else is refused.
//!
//! Records. `BRDA:<line>,<col>:<kind>:<n>/<N>,<arm>,<count>`: <kind> is `br`,
//! `select`, `switch` or `rhs` (the right operand of `and`/`or`); <N> is how
//! many decisions of that kind one copy of a function (an LLVM function, or
//! one inlined copy of it) holds at that location, <n> which one, in IR
//! order. Copies are summed arm by arm and must agree on <N> and on where
//! each one's condition is computed. A branch on the same condition value
//! with the same weights at the same location as another (a `range(` loop's
//! two, an `if` both branched on and selected on) is that one. A count of an
//! instruction that never ran is `-`. Every bool `and`/`or` must have its
//! right operand counted: derived from the left operand's branch or select
//! and the branch or select that tests the whole condition (directly, through
//! the phi of a short-circuit form whose deciding constant arrives from the
//! br's target for that left value, or through `xor ..., true`).
//!
//! Output: per measured file the IR holds code of, `SF:<repository path>`,
//! its records, `end_of_record` (a file with no decision: no record), files
//! sorted bytewise; empty when the IR holds no code of a measured file.
//!
//! Refused, exit 1, nothing written: see README.md. Exit 2: bad usage.
//! A static executable: no shell, no PATH, no network.

const std = @import("std");
const Alloc = std.mem.Allocator;
const source = @import("cov_branch_source.zig");
const fail = source.fail;
const oom = source.oom;
const Where = source.Where;
const File = source.File;
const Opts = source.Opts;
const Kind = source.Kind;
const Class = source.Class;
const classify = source.classify;
const decisionLine = source.decisionLine;
const hashTail = source.hashTail;
const placeFile = source.placeFile;
const nodebugNames = source.nodebugNames;

const usage =
    \\usage: cov_branch_classify --ir <test.ll> --out <file> --map <PREFIX>=<REPO>
    \\           [--gen <REL>]... [--exclude <PREFIX>]... [--exclude-file <NAME>]...
    \\
;

const header = "; *** IR Dump After PGOInstrumentationUse on [module] ***";
const max_ir = 1 << 31;
const max_errors_shown = 40;

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_branch_classify: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

// ---- metadata --------------------------------------------------------------

const Meta = union(enum) {
    location: struct { line: u64, col: u64, scope: u32, inlined_at: ?u32 },
    scope: struct { file: ?u32 },
    file: struct { name: []const u8 },
    weights: []const u64,
    not_counts: []const u8, // a !prof node that is not branch_weights of counts
    other,
};

/// The value of `key: ` in a metadata node's text: the key must follow '('
/// or ' ' (so `line` is not `scopeLine`), the value ends at ',' or ')'.
fn field(s: []const u8, key: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, key)) |at| {
        from = at + 1;
        const end = at + key.len;
        if (at == 0 or (s[at - 1] != '(' and s[at - 1] != ' ')) continue;
        if (!std.mem.startsWith(u8, s[end..], ": ")) continue;
        const v0 = end + 2;
        var v1 = v0;
        if (v1 < s.len and s[v1] == '"') {
            v1 = std.mem.indexOfScalarPos(u8, s, v0 + 1, '"') orelse return null;
            return s[v0 .. v1 + 1];
        }
        while (v1 < s.len and s[v1] != ',' and s[v1] != ')') v1 += 1;
        return s[v0..v1];
    }
    return null;
}

fn ref(s: []const u8, key: []const u8) ?u32 {
    const v = field(s, key) orelse return null;
    if (v.len < 2 or v[0] != '!') return null;
    return std.fmt.parseInt(u32, v[1..], 10) catch null;
}

fn decimal(s: []const u8, key: []const u8) ?u64 {
    const v = field(s, key) orelse return null;
    return std.fmt.parseInt(u64, v, 10) catch null;
}

fn quoted(alloc: Alloc, s: []const u8, key: []const u8) []const u8 {
    const v = field(s, key) orelse return "";
    if (v.len < 2 or v[0] != '"') return "";
    // LLVM writes a byte it cannot print as \XX; a file name holding one is
    // kept as written, and refused if it is ever measured.
    return alloc.dupe(u8, v[1 .. v.len - 1]) catch oom();
}

fn parseMeta(alloc: Alloc, text: []const u8) Meta {
    var t = text;
    if (std.mem.startsWith(u8, t, "distinct ")) t = t["distinct ".len..];
    if (std.mem.startsWith(u8, t, "!DILocation(")) {
        const scope = ref(t, "scope") orelse return .other;
        return .{ .location = .{ .line = decimal(t, "line") orelse 0, .col = decimal(t, "column") orelse 0, .scope = scope, .inlined_at = ref(t, "inlinedAt") } };
    }
    if (std.mem.startsWith(u8, t, "!DISubprogram(") or std.mem.startsWith(u8, t, "!DILexicalBlock(") or
        std.mem.startsWith(u8, t, "!DILexicalBlockFile("))
        return .{ .scope = .{ .file = ref(t, "file") } };
    if (std.mem.startsWith(u8, t, "!DIFile(")) {
        const name = quoted(alloc, t, "filename");
        const dir = quoted(alloc, t, "directory");
        if (dir.len == 0 or (name.len > 0 and name[0] == '/')) return .{ .file = .{ .name = name } };
        return .{ .file = .{ .name = std.mem.concat(alloc, u8, &.{ dir, "/", name }) catch oom() } };
    }
    if (std.mem.startsWith(u8, t, "!{!\"branch_weights\"")) {
        if (!std.mem.endsWith(u8, t, "}")) return .{ .not_counts = t };
        var ws = std.ArrayList(u64).init(alloc);
        var it = std.mem.splitSequence(u8, t["!{!\"branch_weights\"".len .. t.len - 1], ", ");
        _ = it.next(); // the empty piece before the first ", "
        while (it.next()) |e| {
            const n = if (std.mem.startsWith(u8, e, "i32 ")) e[4..] else if (std.mem.startsWith(u8, e, "i64 ")) e[4..] else return .{ .not_counts = t };
            ws.append(std.fmt.parseInt(u64, n, 10) catch return .{ .not_counts = t }) catch oom();
        }
        if (ws.items.len < 2) return .{ .not_counts = t };
        return .{ .weights = ws.items };
    }
    return .other;
}

// ---- branches --------------------------------------------------------------

/// A record: one decision summed over the copies of its function.
const Record = struct {
    repo: []const u8,
    line: u64,
    col: u64,
    kind: Kind,
    ordinal: usize,
    total: usize, // how many of this kind at this location one copy holds
    arms: usize,
    weights: ?[]const u64, // null: never ran
};

fn recordLess(_: void, a: Record, b: Record) bool {
    const o = std.mem.order(u8, a.repo, b.repo);
    if (o != .eq) return o == .lt;
    if (a.line != b.line) return a.line < b.line;
    if (a.col != b.col) return a.col < b.col;
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return a.ordinal < b.ordinal;
}

/// What an `and`/`or` still needs before its function ends.
const Need = enum { none, phi, observe };

/// One measured decision of the function being read.
const Dec = struct {
    file: *File,
    line: u64,
    col: u64,
    inl: ?u32,
    kind: Kind,
    class: Class,
    arms: usize,
    weights: ?[]const u64,
    cond: []const u8,
    prof: ?u32,
    fp: []const u8, // where its condition is computed in this copy, or "" (elsewhere)
    need: Need = .none,
    // A short-circuit and/or's br: its true and false targets (`%4`).
    targets: [2][]const u8 = .{ "", "" },
    parent: ?usize = null, // rhs: its and/or
    keep: bool = true,
    ordinal: usize = 0,
    total: usize = 0,
};

/// An SSA value whose outcomes give an and/or's right operand.
const Await = struct { dec: usize, negated: bool };

const Copy = struct { key: []const u8, where: []const u8, n: usize, fp: []const []const u8 };

const State = struct {
    alloc: Alloc,
    opts: *const Opts,
    meta: std.AutoHashMap(u32, Meta),
    files: std.StringHashMap(*File),
    nodebug: std.StringHashMap([]const u8),
    records: std.ArrayList(Record),
    errors: std.ArrayList([]const u8),
    unmapped: std.StringHashMap(void),
    counts: [@typeInfo(Class).Enum.fields.len]usize = [_]usize{0} ** @typeInfo(Class).Enum.fields.len,
    outside: usize = 0,
    derived: usize = 0,
    same: usize = 0,
    function: usize = 0,
    // The function being read: its decisions, the !dbg of each SSA value's
    // definition, and the values whose outcomes an and/or awaits.
    decs: std.ArrayList(Dec),
    defs: std.StringHashMap(?u32),
    awaits: std.StringHashMap(Await),
    // Every copy of a function's decisions at one location and kind.
    copies: std.StringHashMap(Copy),

    fn err(self: *State, comptime fmt: []const u8, args: anytype) void {
        self.errors.append(std.fmt.allocPrint(self.alloc, fmt, args) catch oom()) catch oom();
    }

    fn fileOf(self: *State, name: []const u8) *File {
        const slot = self.files.getOrPut(name) catch oom();
        if (!slot.found_existing) {
            const f = self.alloc.create(File) catch oom();
            f.* = placeFile(self.alloc, self.opts, name);
            slot.value_ptr.* = f;
            if (f.where == .unmapped) self.unmapped.put(name, {}) catch oom();
            if (f.where == .other_src) self.err("'{s}' is the library's source under another [src] than --map's ('{s}'): the IR was compiled from other sources than the ones measured", .{ name, self.opts.prefix });
        }
        return slot.value_ptr.*;
    }

    const At = struct { file: *File, line: u64, col: u64, inlined_at: ?u32 };

    /// The file and location of metadata id `loc` (a DILocation), or null.
    fn locate(self: *State, loc: u32) ?At {
        const m = self.meta.get(loc) orelse return null;
        if (m != .location) return null;
        const s = self.meta.get(m.location.scope) orelse return null;
        if (s != .scope) return null;
        const fid = s.scope.file orelse return null;
        const f = self.meta.get(fid) orelse return null;
        if (f != .file) return null;
        return .{ .file = self.fileOf(f.file.name), .line = m.location.line, .col = m.location.col, .inlined_at = m.location.inlined_at };
    }

    fn weightsOf(self: *State, prof: ?u32, arms: usize, what: []const u8) ?[]const u64 {
        const p = prof orelse return null;
        const m = self.meta.get(p) orelse {
            self.err("{s}: !prof !{d} is not in the module", .{ what, p });
            return null;
        };
        switch (m) {
            .weights => |w| {
                if (w.len != arms) self.err("{s}: {d} branch weights for {d} arms", .{ what, w.len, arms });
                return w;
            },
            .not_counts => |t| self.err("{s}: !prof is not branch weights of counts: {s}", .{ what, t }),
            else => self.err("{s}: !prof !{d} is not branch weights", .{ what, p }),
        }
        return null;
    }

    fn whereOf(self: *State, d: Dec) []const u8 {
        return std.fmt.allocPrint(self.alloc, "{s}:{d}:{d}", .{ d.file.repo, d.line, d.col }) catch oom();
    }
};

fn afterKey(s: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, s, key) orelse return null;
    return s[at + key.len ..];
}

fn metaId(s: []const u8, key: []const u8) ?u32 {
    const rest = afterKey(s, key) orelse return null;
    var j: usize = 0;
    while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
    return std.fmt.parseInt(u32, rest[0..j], 10) catch null;
}

fn operand(s: []const u8) []const u8 {
    const e = std.mem.indexOf(u8, s, ", ") orelse s.len;
    return s[0..e];
}

fn constant(x: []const u8) bool {
    return std.mem.eql(u8, x, "i1 true") or std.mem.eql(u8, x, "i1 false");
}

const fmf = [_][]const u8{ "nnan ", "ninf ", "nsz ", "arcp ", "contract ", "afn ", "reassoc ", "fast " };

/// What one branch instruction is: a measured decision (`dec`, an index into
/// st.decs), or not; its weights when it is in a measured file (`parsed`),
/// else its `!prof`, read only when an and/or awaits its outcomes.
const Seen = struct { dec: ?usize = null, weights: ?[]const u64 = null, prof: ?u32 = null, parsed: bool = true };

/// One branch instruction: `kind` with `arms` arms on condition `cond`, its
/// `!dbg` and `!prof` on `text`.
fn branch(st: *State, kind: Kind, arms: usize, cond: []const u8, text: []const u8, ln: usize) Seen {
    const prof = metaId(text, "!prof !");
    const dbg = metaId(text, "!dbg !") orelse {
        st.err("IR line {d}: a {s} with no !dbg location: no file can be named for it", .{ ln, @tagName(kind) });
        return .{};
    };
    const at = st.locate(dbg) orelse {
        st.err("IR line {d}: the !dbg !{d} of a {s} is not a DILocation whose scope names a DIFile", .{ ln, dbg, @tagName(kind) });
        return .{};
    };
    if (at.file.where != .measured) {
        st.outside += 1;
        return .{ .prof = prof, .parsed = false };
    }
    at.file.branches += 1;
    const where = std.fmt.allocPrint(st.alloc, "{s}:{d}:{d}", .{ at.file.repo, at.line, at.col }) catch oom();
    const src: []const u8 = if (at.line >= 1 and at.line <= at.file.lines.len) at.file.lines[@intCast(at.line - 1)] else "";
    const c = classify(src, at.col);
    st.counts[@intFromEnum(c.class)] += 1;
    const w = st.weightsOf(prof, arms, where);
    if (c.class == .unknown) {
        st.err("{s}: a {s} at '{s}' is neither a source decision nor a known compiler-made branch: {s}", .{ where, @tagName(kind), c.token, std.mem.trim(u8, src, " ") });
        return .{ .weights = w };
    }
    if (!c.class.takes(kind)) {
        st.err("{s}: a {s} at '{s}': no {s} has been seen at this token, so what it is is not known: {s}", .{ where, @tagName(kind), c.token, @tagName(kind), std.mem.trim(u8, src, " ") });
        return .{ .weights = w };
    }
    if (c.class == .call) {
        if (st.nodebug.get(c.token[0 .. c.token.len - 1])) |decl| {
            st.err("{s}: a {s} at '{s}' may be a decision of {s}, which {s} declares @always_inline(\"nodebug\"): its code carries the call's location, so its decisions cannot be told from the compiler's here: {s}", .{ where, @tagName(kind), c.token, c.token[0 .. c.token.len - 1], decl, std.mem.trim(u8, src, " ") });
            return .{ .weights = w };
        }
    }
    if (!c.class.decision()) return .{ .weights = w };
    // Where its condition is computed, when in this copy of the function.
    var fp: []const u8 = "";
    if (st.defs.get(cond)) |dd| {
        if (dd) |d| {
            if (st.locate(d)) |ca| {
                if (ca.inlined_at == at.inlined_at) fp = std.fmt.allocPrint(st.alloc, "{d}:{d}", .{ ca.line, ca.col }) catch oom();
            }
        }
    }
    st.decs.append(.{ .file = at.file, .line = at.line, .col = at.col, .inl = at.inlined_at, .kind = kind, .class = c.class, .arms = arms, .weights = w, .cond = cond, .prof = prof, .fp = fp }) catch oom();
    return .{ .dec = st.decs.items.len - 1, .weights = w };
}

/// The right operand of and/or `d`: s = its own weights (the left operand:
/// true, false), b = the whole condition's (true, false).
fn derive(st: *State, di: usize, b_or_null: ?[]const u64) void {
    const p = st.decs.items[di];
    st.decs.items[di].need = .none;
    const where = st.whereOf(p);
    var rhs = p;
    rhs.need = .none;
    rhs.kind = .rhs;
    rhs.parent = di;
    rhs.arms = 2;
    if (p.weights == null and b_or_null == null) {
        rhs.weights = null;
        st.decs.append(rhs) catch oom();
        st.derived += 1;
        return;
    }
    const s = p.weights orelse return st.err("{s}: the '{s}' never ran but the test of its result did", .{ where, @tagName(p.class)[0 .. @tagName(p.class).len - 1] });
    const b = b_or_null orelse return st.err("{s}: the '{s}' ran but the test of its result never did", .{ where, @tagName(p.class)[0 .. @tagName(p.class).len - 1] });
    if (s.len != 2 or b.len != 2) return;
    if (s[0] + s[1] != b[0] + b[1]) return st.err("{s}: the left operand ran {d} times and the test of the result {d}: the right operand cannot be derived", .{ where, s[0] + s[1], b[0] + b[1] });
    var w = st.alloc.alloc(u64, 2) catch oom();
    if (p.class == .or_) {
        // true = left true + (left false, right true); false = both false.
        if (b[0] < s[0]) return st.err("{s}: 'or' is true {d} times but its left operand {d}", .{ where, b[0], s[0] });
        w[0] = b[0] - s[0];
        w[1] = b[1];
    } else {
        // true = both true; left true, right false = left true - true.
        if (s[0] < b[0]) return st.err("{s}: 'and' is true {d} times but its left operand {d}", .{ where, b[0], s[0] });
        w[0] = b[0];
        w[1] = s[0] - b[0];
    }
    rhs.weights = w;
    st.decs.append(rhs) catch oom();
    st.derived += 1;
}

/// A branch or select `seen` tested `cond`: the whole condition of an
/// and/or that awaits it.
fn observe(st: *State, cond: []const u8, seen: Seen) void {
    const a = st.awaits.get(cond) orelse return;
    if (st.decs.items[a.dec].need != .observe) return;
    const w = if (seen.parsed) seen.weights else st.weightsOf(seen.prof, 2, st.whereOf(st.decs.items[a.dec]));
    var b = w;
    if (a.negated) {
        if (w) |x| {
            if (x.len == 2) {
                const sw = st.alloc.alloc(u64, 2) catch oom();
                sw[0] = x[1];
                sw[1] = x[0];
                b = sw;
            }
        }
    }
    derive(st, a.dec, b);
}

/// The phi of a short-circuit and/or: `%r = phi i1 [ x, %a ], [ y, %b ]` at
/// the token of an and/or `br` of this copy, one of x and y the constant that
/// decides it (`true` for or, `false` for and), arriving from the br's target
/// for that value of the left operand (true for or, false for and).
fn phi(st: *State, t: []const u8, ln: usize) void {
    const eq = std.mem.indexOf(u8, t, " = phi ") orelse return;
    const dbg = metaId(t, "!dbg !") orelse return;
    const at = st.locate(dbg) orelse return;
    if (at.file.where != .measured) return;
    var i = st.decs.items.len;
    const di = while (i > 0) {
        i -= 1;
        const d = st.decs.items[i];
        if (d.need == .phi and d.kind == .br and d.file == at.file and d.line == at.line and d.col == at.col and d.inl == at.inlined_at) break i;
    } else return;
    const d = st.decs.items[di];
    const rest = t[eq + " = phi ".len ..];
    if (!std.mem.startsWith(u8, rest, "i1 ")) {
        st.decs.items[di].need = .none; // a value and/or: no right operand decides
        return;
    }
    var ins = std.ArrayList([]const u8).init(st.alloc);
    var from = std.ArrayList([]const u8).init(st.alloc);
    var it = std.mem.splitSequence(u8, rest["i1 ".len..], "], ");
    while (it.next()) |piece| {
        const p = std.mem.trim(u8, piece, " ");
        if (p.len == 0 or p[0] != '[') break;
        const v = operand(std.mem.trim(u8, p[1..], " "));
        ins.append(v) catch oom();
        const after = std.mem.trim(u8, p[1..], " ");
        from.append(if (after.len > v.len + 2) std.mem.trim(u8, after[v.len + 2 ..], " ]") else "") catch oom();
    }
    const word = @tagName(d.class)[0 .. @tagName(d.class).len - 1];
    const k: []const u8 = if (d.class == .or_) "true" else "false";
    const ok = ins.items.len == 2 and ((std.mem.eql(u8, ins.items[0], k) and !isConst(ins.items[1])) or (std.mem.eql(u8, ins.items[1], k) and !isConst(ins.items[0])));
    if (!ok) return st.err("{s}: IR line {d}: the phi at this '{s}' is not that of a short-circuit one (two incoming values, one '{s}'): {s}", .{ st.whereOf(d), ln, word, k, t });
    // The constant decides only if it arrives from the target the left
    // operand's deciding value takes: `or` is true when its left operand is
    // (the branch's true target), `and` false when its left operand is (the
    // false target). From the other target the phi is of another expression
    // (`not a or b`), and the right operand derived from it would be wrong.
    // Only the block the branch itself jumps to is read: the constant
    // arriving straight from the branch's own block (no forwarding block) or
    // through a chain of them is refused, as no such IR has been seen.
    const blk = if (std.mem.eql(u8, ins.items[0], k)) from.items[0] else from.items[1];
    const want: usize = if (d.class == .or_) 0 else 1;
    const arm = [2][]const u8{ "true", "false" };
    if (!std.mem.eql(u8, blk, d.targets[want])) {
        if (std.mem.eql(u8, blk, d.targets[1 - want])) return st.err("{s}: IR line {d}: the '{s}' of the phi at this '{s}' arrives from {s}, the branch's {s} target, not its {s} target ({s}): the right operand cannot be derived: {s}", .{ st.whereOf(d), ln, k, word, blk, arm[1 - want], arm[want], d.targets[want], t });
        return st.err("{s}: IR line {d}: the '{s}' of the phi at this '{s}' arrives from {s}, which is not one of the branch's targets ({s}, {s}): the right operand cannot be derived: {s}", .{ st.whereOf(d), ln, k, word, blk, d.targets[0], d.targets[1], t });
    }
    st.decs.items[di].need = .observe;
    st.awaits.put(t[0..eq], .{ .dec = di, .negated = false }) catch oom();
}

/// The two targets of `br i1 %c, label %t, label %f, ...`: `%t`, `%f`
/// ("" when the text is not of that form, which no phi block matches).
fn brTargets(t: []const u8) [2][]const u8 {
    var out = [2][]const u8{ "", "" };
    var rest = t["br i1 ".len..];
    for (&out) |*o| {
        const at = std.mem.indexOf(u8, rest, ", label ") orelse return .{ "", "" };
        rest = rest[at + ", label ".len ..];
        o.* = operand(rest);
    }
    return out;
}

fn isConst(x: []const u8) bool {
    return std.mem.eql(u8, x, "true") or std.mem.eql(u8, x, "false");
}

/// The end of a function: every bool and/or has its right operand; branches
/// that are one are folded; ordinals assigned; the decisions recorded.
fn endFunction(st: *State) void {
    const ds = st.decs.items;
    for (ds) |d| {
        if (d.need == .none) continue;
        const word = @tagName(d.class)[0 .. @tagName(d.class).len - 1];
        if (d.need == .phi) {
            st.err("{s}: a short-circuit '{s}' (a br) whose result is not a phi at its location: its right operand cannot be counted", .{ st.whereOf(d), word });
        } else {
            st.err("{s}: the right operand of this '{s}' is not counted: its result is not tested by a branch or select in this function (it is returned, stored or passed on), so when the right operand decides cannot be told", .{ st.whereOf(d), word });
        }
    }
    // One decision tested twice (the same condition value and weights at the
    // same location): keep one, a br before a switch before a select.
    for (ds, 0..) |*a, i| {
        if (!a.keep or a.kind == .rhs or a.class == .and_ or a.class == .or_) continue;
        for (ds[i + 1 ..]) |*b| {
            if (!b.keep or b.kind == .rhs or b.class != a.class) continue;
            if (b.file != a.file or b.line != a.line or b.col != a.col or b.inl != a.inl or !std.mem.eql(u8, b.cond, a.cond)) continue;
            if ((a.prof == null) != (b.prof == null) or (a.prof != null and a.prof.? != b.prof.?)) continue;
            const rank = [_]u8{ 0, 3, 2, 1 }; // br, rhs, select, switch
            if (rank[@intFromEnum(b.kind)] < rank[@intFromEnum(a.kind)]) {
                a.keep = false;
                b.keep = true;
            } else b.keep = false;
            st.same += 1;
            if (!a.keep) break;
        }
    }
    // Ordinals per copy: (file, line, col, kind, inlined copy).
    var per = std.StringHashMap(std.ArrayList(usize)).init(st.alloc);
    var order = std.ArrayList([]const u8).init(st.alloc);
    for (ds, 0..) |d, i| {
        if (!d.keep or d.kind == .rhs) continue;
        const key = std.fmt.allocPrint(st.alloc, "{s}\x00{d}\x00{d}\x00{s}", .{ d.file.repo, d.line, d.col, @tagName(d.kind) }) catch oom();
        const copy = std.fmt.allocPrint(st.alloc, "{s}\x00{d}\x00{d}", .{ key, st.function, if (d.inl) |x| x + 1 else 0 }) catch oom();
        const slot = per.getOrPut(copy) catch oom();
        if (!slot.found_existing) {
            slot.value_ptr.* = std.ArrayList(usize).init(st.alloc);
            order.append(copy) catch oom();
            st.copies.put(copy, .{ .key = key, .where = std.fmt.allocPrint(st.alloc, "{s} ({s})", .{ st.whereOf(d), @tagName(d.kind) }) catch oom(), .n = 0, .fp = &.{} }) catch oom();
        }
        slot.value_ptr.append(i) catch oom();
    }
    for (order.items) |copy| {
        const idx = per.get(copy).?.items;
        var fp = st.alloc.alloc([]const u8, idx.len) catch oom();
        for (idx, 0..) |i, n| {
            ds[i].ordinal = n;
            ds[i].total = idx.len;
            fp[n] = ds[i].fp;
        }
        const c = st.copies.getPtr(copy).?;
        c.n = idx.len;
        c.fp = fp;
    }
    for (ds) |d| {
        if (!d.keep) continue;
        var r = Record{ .repo = d.file.repo, .line = d.line, .col = d.col, .kind = d.kind, .ordinal = d.ordinal, .total = d.total, .arms = d.arms, .weights = d.weights };
        if (d.parent) |p| {
            r.ordinal = ds[p].ordinal;
            r.total = ds[p].total;
        }
        st.records.append(r) catch oom();
    }
    st.decs.clearRetainingCapacity();
    st.defs.clearRetainingCapacity();
    st.awaits.clearRetainingCapacity();
}

fn scan(st: *State, ir: []const u8) void {
    var in_fn = false;
    var sw_cases: ?usize = null;
    var sw_cond: []const u8 = "";
    var it = std.mem.splitScalar(u8, ir, '\n');
    var ln: usize = 0;
    while (it.next()) |line| {
        ln += 1;
        if (std.mem.startsWith(u8, line, "define ")) {
            in_fn = true;
            st.function += 1;
            continue;
        }
        if (!in_fn) continue;
        if (std.mem.eql(u8, line, "}")) {
            in_fn = false;
            endFunction(st);
            continue;
        }
        if (!std.mem.startsWith(u8, line, "  ")) continue; // a label or a blank line
        const t = std.mem.trimLeft(u8, line, " ");
        if (sw_cases) |n| {
            if (std.mem.startsWith(u8, t, "]")) {
                sw_cases = null;
                _ = branch(st, .@"switch", n + 1, sw_cond, t, ln);
            } else if (std.mem.indexOf(u8, t, ", label ") != null) {
                sw_cases = n + 1;
            }
            continue;
        }
        const dbg = metaId(t, "!dbg !");
        if (dbg) |d| {
            if (st.locate(d)) |at| {
                if (at.file.where == .measured) at.file.exec.put(at.line, {}) catch oom();
            }
        }
        const eq = std.mem.indexOf(u8, t, " = ");
        if (eq) |e| {
            if (t[0] == '%') st.defs.put(t[0..e], dbg) catch oom();
        }
        const body = if (eq) |e| t[e + 3 ..] else t;
        if (std.mem.startsWith(u8, t, "br i1 ")) {
            const cond = operand(t["br i1 ".len..]);
            const r = branch(st, .br, 2, cond, t, ln);
            observe(st, cond, r);
            if (r.dec) |di| {
                const c = st.decs.items[di].class;
                if (c == .or_ or c == .and_) {
                    st.decs.items[di].need = .phi;
                    st.decs.items[di].targets = brTargets(t);
                }
            }
        } else if (std.mem.startsWith(u8, t, "switch ")) {
            sw_cases = 0;
            sw_cond = operand(t["switch ".len..]);
        } else if (std.mem.startsWith(u8, body, "indirectbr ") or std.mem.startsWith(u8, body, "callbr ") or std.mem.startsWith(u8, body, "invoke ")) {
            const word = body[0..std.mem.indexOfScalar(u8, body, ' ').?];
            const at = if (dbg) |d| st.locate(d) else null;
            if (at == null) {
                st.err("IR line {d}: an {s} with no !dbg location: no file can be named for it", .{ ln, word });
            } else if (at.?.file.where == .measured) {
                st.err("{s}:{d}:{d}: an {s} in a measured file: the classifier reads no such branch", .{ at.?.file.repo, at.?.line, at.?.col, word });
            }
        } else if (std.mem.startsWith(u8, body, "phi ")) {
            phi(st, t, ln);
        } else if (std.mem.startsWith(u8, body, "xor i1 ")) {
            const ops = body["xor i1 ".len..];
            const x = operand(ops);
            if (ops.len > x.len + 2 and std.mem.startsWith(u8, ops[x.len + 2 ..], "true")) {
                if (st.awaits.get(x)) |a| st.awaits.put(t[0..eq.?], .{ .dec = a.dec, .negated = !a.negated }) catch oom();
            }
        } else if (std.mem.startsWith(u8, body, "select ")) {
            var rest = body["select ".len..];
            var more = true;
            while (more) {
                more = false;
                for (fmf) |f| {
                    if (std.mem.startsWith(u8, rest, f)) {
                        rest = rest[f.len..];
                        more = true;
                    }
                }
            }
            if (!std.mem.startsWith(u8, rest, "i1 ")) continue; // a vector select: no branch
            const ops = rest["i1 ".len..];
            const cond = operand(ops);
            const r = branch(st, .select, 2, cond, t, ln);
            observe(st, cond, r);
            const di = r.dec orelse continue;
            const c = st.decs.items[di].class;
            if (c != .or_ and c != .and_) continue;
            if (ops.len < cond.len + 2) continue;
            const a = operand(ops[cond.len + 2 ..]);
            if (!std.mem.startsWith(u8, a, "i1 ")) continue; // a value and/or: no right operand decides
            const b = if (ops.len > cond.len + 2 + a.len + 2) operand(ops[cond.len + 2 + a.len + 2 ..]) else "";
            const or_form = std.mem.eql(u8, a, "i1 true") and std.mem.startsWith(u8, b, "i1 ") and !constant(b);
            const and_form = std.mem.eql(u8, b, "i1 false") and std.mem.startsWith(u8, a, "i1 ") and !constant(a);
            if ((c == .or_ and or_form) or (c == .and_ and and_form)) {
                st.decs.items[di].need = .observe;
                st.awaits.put(t[0..eq.?], .{ .dec = di, .negated = false }) catch oom();
            } else {
                st.err("{s}: IR line {d}: the select at this '{s}' is not that of one ('select i1 c, i1 true, i1 x' for or, 'select i1 c, i1 x, i1 false' for and): {s}", .{ st.whereOf(st.decs.items[di]), ln, @tagName(c)[0 .. @tagName(c).len - 1], t });
            }
        }
    }
}

// ---- output ----------------------------------------------------------------

fn pathLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Writes `SF:` and `end_of_record` for each path of `coded` (sorted) from
/// `p.*` on that sorts before `upto` (every one left when null), and steps
/// past `upto` itself: a measured file the IR holds code of, with no record.
fn writeNoRecord(w: anytype, coded: []const []const u8, p: *usize, upto: ?[]const u8) void {
    while (p.* < coded.len) {
        if (upto) |u| {
            switch (std.mem.order(u8, coded[p.*], u)) {
                .gt => return,
                .eq => {
                    p.* += 1;
                    return;
                },
                .lt => {},
            }
        }
        w.print("SF:{s}\nend_of_record\n", .{coded[p.*]}) catch oom();
        p.* += 1;
    }
}

/// The output: the records of `recs`, per file, and each measured file of
/// `coded` (the repository paths of the measured files the IR holds code
/// of) with no record named all the same, files sorted bytewise.
fn render(alloc: Alloc, recs: []Record, coded: [][]const u8) []const u8 {
    std.mem.sort(Record, recs, {}, recordLess);
    std.mem.sort([]const u8, coded, {}, pathLess);
    var p: usize = 0;
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();
    var i: usize = 0;
    var cur: ?[]const u8 = null;
    while (i < recs.len) {
        // Sum the copies of one (file, line, column, kind, ordinal).
        var j = i + 1;
        while (j < recs.len and !recordLess({}, recs[i], recs[j]) and !recordLess({}, recs[j], recs[i])) j += 1;
        const n = recs[i].arms;
        var ran = false;
        for (recs[i..j]) |r| {
            if (r.arms != n) fail("{s}:{d}:{d}: two instances of one {s} have {d} and {d} arms; nothing written", .{ r.repo, r.line, r.col, @tagName(r.kind), n, r.arms });
            if (r.weights != null) ran = true;
        }
        if (cur == null or !std.mem.eql(u8, cur.?, recs[i].repo)) {
            if (cur != null) w.writeAll("end_of_record\n") catch oom();
            writeNoRecord(w, coded, &p, recs[i].repo);
            cur = recs[i].repo;
            w.print("SF:{s}\n", .{recs[i].repo}) catch oom();
        }
        for (0..n) |arm| {
            w.print("BRDA:{d},{d}:{s}:{d}/{d},{d},", .{ recs[i].line, recs[i].col, @tagName(recs[i].kind), recs[i].ordinal, recs[i].total, arm }) catch oom();
            if (!ran) {
                w.writeAll("-\n") catch oom();
            } else {
                var sum: u64 = 0;
                for (recs[i..j]) |r| {
                    if (r.weights) |x| sum += if (arm < x.len) x[arm] else 0;
                }
                w.print("{d}\n", .{sum}) catch oom();
            }
        }
        i = j;
    }
    if (cur != null) w.writeAll("end_of_record\n") catch oom();
    writeNoRecord(w, coded, &p, null);
    return buf.items;
}

fn writeOut(path: []const u8, bytes: []const u8) !void {
    var af = try std.fs.cwd().atomicFile(path, .{});
    defer af.deinit();
    try af.file.writeAll(bytes);
    try af.finish();
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// ---- main ------------------------------------------------------------------

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch oom();

    var ir_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var map: ?[]const u8 = null;
    var gens = std.ArrayList([]const u8).init(alloc);
    var excludes = std.ArrayList([]const u8).init(alloc);
    var exclude_files = std.ArrayList([]const u8).init(alloc);
    var a: usize = 1;
    while (a < argv.len) : (a += 2) {
        const flag = argv[a];
        if (a + 1 >= argv.len) usageFail("{s} has no value", .{flag});
        const v: []const u8 = argv[a + 1];
        if (std.mem.eql(u8, flag, "--ir")) {
            if (ir_path != null) usageFail("--ir given twice", .{});
            ir_path = v;
        } else if (std.mem.eql(u8, flag, "--out")) {
            if (out_path != null) usageFail("--out given twice", .{});
            out_path = v;
        } else if (std.mem.eql(u8, flag, "--map")) {
            if (map != null) usageFail("--map given twice", .{});
            map = v;
        } else if (std.mem.eql(u8, flag, "--gen")) {
            if (v.len == 0 or v[0] == '/') usageFail("--gen '{s}' must be a relative path", .{v});
            gens.append(v) catch oom();
        } else if (std.mem.eql(u8, flag, "--exclude")) {
            if (v.len < 2 or v[v.len - 1] != '/') usageFail("--exclude '{s}' must end with '/'", .{v});
            excludes.append(v) catch oom();
        } else if (std.mem.eql(u8, flag, "--exclude-file")) {
            if (v.len == 0) usageFail("--exclude-file is empty", .{});
            exclude_files.append(v) catch oom();
        } else {
            usageFail("unknown flag '{s}'", .{flag});
        }
    }
    const in_file = ir_path orelse usageFail("--ir is required", .{});
    const out_file = out_path orelse usageFail("--out is required", .{});
    const m = map orelse usageFail("--map is required", .{});
    const eq = std.mem.indexOfScalar(u8, m, '=') orelse usageFail("--map '{s}' is not PREFIX=REPO", .{m});
    const opts = Opts{
        .prefix = m[0..eq],
        .hash_tail = hashTail(m[0..eq]),
        .repo = m[eq + 1 ..],
        .gens = gens.items,
        .excludes = excludes.items,
        .exclude_files = exclude_files.items,
    };
    if (opts.prefix.len < 2 or opts.prefix[opts.prefix.len - 1] != '/') usageFail("--map PREFIX '{s}' must end with '/'", .{opts.prefix});
    if (opts.repo.len > 0 and (opts.repo[0] == '/' or opts.repo[opts.repo.len - 1] != '/')) usageFail("--map REPO '{s}' must be empty or relative and end with '/'", .{opts.repo});
    // With no content hash in the [src] name, the library's sources under
    // another [src] could not be told, and `--exclude buck-out/` would drop
    // them unseen.
    if (opts.hash_tail == null) usageFail("the --map PREFIX '{s}' holds no '/<16 hex>/' segment: it is not a [src] of a library, and its sources under another [src] could not be told", .{opts.prefix});

    const ir = std.fs.cwd().readFileAlloc(alloc, in_file, max_ir) catch |err| fail("{s}: {s}", .{ in_file, @errorName(err) });
    const first = ir[0 .. std.mem.indexOfScalar(u8, ir, '\n') orelse ir.len];
    if (!std.mem.eql(u8, first, header)) fail("{s} does not start with '{s}': not the IR printed after pgo-instr-use; nothing written", .{ in_file, header });

    var st = State{
        .alloc = alloc,
        .opts = &opts,
        .meta = std.AutoHashMap(u32, Meta).init(alloc),
        .files = std.StringHashMap(*File).init(alloc),
        .nodebug = nodebugNames(alloc, &opts),
        .records = std.ArrayList(Record).init(alloc),
        .errors = std.ArrayList([]const u8).init(alloc),
        .unmapped = std.StringHashMap(void).init(alloc),
        .decs = std.ArrayList(Dec).init(alloc),
        .defs = std.StringHashMap(?u32).init(alloc),
        .awaits = std.StringHashMap(Await).init(alloc),
        .copies = std.StringHashMap(Copy).init(alloc),
    };
    // A nodebug operator, constructor or destructor lands on any token.
    var names = std.ArrayList([]const u8).init(alloc);
    var ni = st.nodebug.iterator();
    while (ni.next()) |e| {
        const n = e.key_ptr.*;
        if (n.len > 4 and std.mem.startsWith(u8, n, "__") and std.mem.endsWith(u8, n, "__"))
            names.append(std.fmt.allocPrint(alloc, "{s}: {s} is declared @always_inline(\"nodebug\"): its code carries the locations of the operators, calls and scope ends that run it, where its decisions cannot be told from the compiler's", .{ e.value_ptr.*, n }) catch oom()) catch oom();
    }
    std.mem.sort([]const u8, names.items, {}, lessStr);
    for (names.items) |n| st.err("{s}", .{n});

    // Metadata first: it follows the functions that use it.
    var lines = std.mem.splitScalar(u8, ir, '\n');
    while (lines.next()) |l| {
        if (l.len < 2 or l[0] != '!' or !std.ascii.isDigit(l[1])) continue;
        const sp = std.mem.indexOf(u8, l, " = ") orelse continue;
        const id = std.fmt.parseInt(u32, l[1..sp], 10) catch continue;
        st.meta.put(id, parseMeta(alloc, l[sp + 3 ..])) catch oom();
    }
    scan(&st, ir);

    names.clearRetainingCapacity();
    var ui = st.unmapped.keyIterator();
    while (ui.next()) |k| names.append(k.*) catch oom();
    std.mem.sort([]const u8, names.items, {}, lessStr);
    for (names.items) |n| st.err("unmapped file name '{s}': neither --map, --exclude nor --exclude-file covers it", .{n});

    // Every copy of a function must hold as many decisions of a kind at a
    // location as the others, with their conditions computed at the same
    // places (where both are known), or the n-th of one is not another's.
    const First = struct { n: usize, fp: [][]const u8 };
    var per_key = std.StringHashMap(First).init(alloc);
    var ci = st.copies.valueIterator();
    while (ci.next()) |c| {
        const slot = per_key.getOrPut(c.key) catch oom();
        if (!slot.found_existing) {
            slot.value_ptr.* = .{ .n = c.n, .fp = alloc.dupe([]const u8, c.fp) catch oom() };
        } else if (slot.value_ptr.n != c.n) {
            st.err("{s}: one copy of its function has {d} branch(es) of this kind here and another {d}: they cannot be matched to be summed", .{ c.where, @min(slot.value_ptr.n, c.n), @max(slot.value_ptr.n, c.n) });
            slot.value_ptr.n = c.n;
            slot.value_ptr.fp = alloc.dupe([]const u8, c.fp) catch oom();
        } else {
            for (slot.value_ptr.fp, c.fp, 0..) |*x, y, n| {
                if (x.len == 0) {
                    x.* = y;
                } else if (y.len > 0 and !std.mem.eql(u8, x.*, y)) {
                    st.err("{s}: two copies of its function hold different branches here: the condition of the one numbered {d} is computed at {s} in one and at {s} in another", .{ c.where, n, x.*, y });
                }
            }
        }
    }

    // A measured file with code on a decision line but no branch: the
    // branches were not parsed (or the location format moved).
    var fi = st.files.valueIterator();
    var measured_files: usize = 0;
    while (fi.next()) |fp| {
        const f = fp.*;
        if (f.where != .measured or f.exec.count() == 0) continue;
        measured_files += 1;
        if (f.branches > 0) continue;
        var li = f.exec.keyIterator();
        var at: u64 = 0;
        while (li.next()) |k| {
            if (k.* < 1 or k.* > f.lines.len) continue;
            if (decisionLine(f.lines[@intCast(k.* - 1)]) and (at == 0 or k.* < at)) at = k.*;
        }
        if (at != 0) st.err("{s}: zero branches parsed, yet the IR has code on its decision line {d}: the branches of this file were not read", .{ f.repo, at });
    }

    if (st.errors.items.len > 0) {
        for (st.errors.items, 0..) |e, i| {
            if (i == max_errors_shown) {
                std.debug.print("cov_branch_classify: ... and {d} more\n", .{st.errors.items.len - i});
                break;
            }
            std.debug.print("cov_branch_classify: {s}\n", .{e});
        }
        fail("{d} error(s) in {s}; nothing written", .{ st.errors.items.len, in_file });
    }

    // Every measured file the IR holds code of is named, a decision-free
    // one with no record, so covcheck can tell "measured, nothing to take"
    // from "not measured".
    var coded = std.ArrayList([]const u8).init(alloc);
    var cf = st.files.valueIterator();
    while (cf.next()) |fp| {
        if (fp.*.where == .measured and fp.*.exec.count() > 0) coded.append(fp.*.repo) catch oom();
    }
    const bytes = render(alloc, st.records.items, coded.items);
    writeOut(out_file, bytes) catch |err| fail("{s}: {s}; nothing written", .{ out_file, @errorName(err) });
    var decisions: usize = 0;
    var made: usize = 0;
    inline for (@typeInfo(Class).Enum.fields) |f| {
        const c: Class = @enumFromInt(f.value);
        if (c.decision()) decisions += st.counts[f.value] else if (c != .unknown) made += st.counts[f.value];
    }
    std.debug.print("cov_branch_classify: {d} measured file(s): {d} source decision(s) (if {d}, elif {d}, while {d}, and {d}, or {d}, for-range( {d}; {d} right operand(s) derived, {d} a second test of one decision), {d} compiler-made (+ {d}, call( {d}, // {d}, % {d}) not written; {d} branch(es) outside the measured sources\n", .{
        measured_files,                        decisions,                                  st.counts[@intFromEnum(Class.if_)],     st.counts[@intFromEnum(Class.elif)],
        st.counts[@intFromEnum(Class.while_)], st.counts[@intFromEnum(Class.and_)],        st.counts[@intFromEnum(Class.or_)],     st.counts[@intFromEnum(Class.for_range)],
        st.derived,                            st.same,                                    made,                                   st.counts[@intFromEnum(Class.plus)],
        st.counts[@intFromEnum(Class.call)],   st.counts[@intFromEnum(Class.floordiv)],    st.counts[@intFromEnum(Class.mod)],     st.outside,
    });
}
