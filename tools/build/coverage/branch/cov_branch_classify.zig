//! cov_branch_classify: the branches of one test's annotated IR that fall in
//! the library's measured sources, each a source decision or a known
//! compiler-made branch, as lcov BRDA records in repository paths. README.md
//! ("cov_branch_classify") has the rules with their evidence; in brief:
//!
//! usage: cov_branch_classify --ir <test.ll> --out <file> --map <PREFIX>=<REPO>
//!            [--src <DIR>] --stdlib <PREFIX> [--gen <REL>]...
//!            [--exclude <PREFIX>]... [--exclude-file <NAME>]...
//!
//! <test.ll> is the module cov_branch_annotate.sh prints after LLVM's
//! `pgo-instr-use`: each `br i1`, `select i1` and `switch` that ran carries
//! `!prof !{!"branch_weights", ...}`, the counts of its arms.
//!
//! Files. A branch is attributed to its innermost `!dbg` location. A file
//! name is measured when it starts with --map's PREFIX (what the IR names
//! the library's sources by: `<lib>/` for a package compiled from the
//! parent of its [src]) and is not a --gen source; its repository path is
//! REPO followed by the rest, and it is read at --src (the library's [src],
//! `.../<16 hex>/src/<lib>/`; PREFIX when --src is not given) followed by
//! the rest. A --src with no such segment is bad usage. A name holding
//! `/<16 hex>/src/<lib>/` but not PREFIX (the library's sources under a
//! [src], this one or another) is refused; one equal to an --exclude-file
//! or under an --exclude prefix is not measured; any other name is refused.
//! Every `.mojo` file under --src is read for the functions it declares
//! `@always_inline("nodebug")`. --stdlib names where
//! the standard library's sources are (a String's last-reference test is
//! its code, inlined at the branch).
//!
//! Classes. First by shape: a br or select testing a String's flags word or
//! its last reference (a destructor or copy, `nodebug` code carrying the
//! location of the token that used the String) is compiler-made at any
//! token, at a decision's token only when the tested instruction is at the
//! branch's own location. Then by the token at the branch's line and column,
//! with the instruction kinds each takes: source decisions `if` (br, select,
//! switch), `elif` (br, select, switch), `while` (br), `and`/`or` (br,
//! select), the head of a `for` line's iterable (br: a call's `(`, an
//! attribute's last `.`, a name, a list literal's `[`); compiler-made `+`
//! (br), `//`, `//=` and `%` (select), a subscript's `[` (a br on a raising
//! call's error flag), and the `(` of a call off a `for` line (`name(` or
//! `name[...](`: br; select only on a raising call's error flag), unless the
//! callee is a measured `@always_inline("nodebug")` function, whose code
//! carries its callers' locations. In the body of a `try:` of its function,
//! a br at a call, a subscript or a `+` is a source decision of kind `try`
//! when it tests a raising call's error flag (arm 0: the call returned,
//! arm 1: it raised into the handler), and refused otherwise. Anything else
//! is refused.
//!
//! Records. `BRDA:<line>,<col>:<kind>:<n>/<N>,<arm>,<count>`: <kind> is `br`,
//! `select`, `switch`, `try` or `rhs` (the right operand of `and`/`or`); <N> is how
//! many decisions of that kind one copy of a function (an LLVM function, or
//! one inlined copy of it) holds at that location, <n> which one, in IR
//! order. Copies are summed arm by arm and must agree on <N> and on where
//! each one's condition is computed (or, for an `if`/`elif`/`while`, compute
//! it inside the same header). A branch on the same condition value
//! with the same weights at the same location as another (a loop's
//! two, an `if` both branched on and selected on) is that one. A count of an
//! instruction that never ran is `-`. A bool `and`/`or` is a decision at its
//! token (its left operand's branch or select: the right operand evaluated
//! or skipped); its right operand is counted too (`rhs`) when a source
//! decision tests the whole condition (cov_branch_andor.zig).
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
const headerSpan = source.headerSpan;
const inSpan = source.inSpan;
const ir_mod = @import("cov_branch_ir.zig");
const Meta = ir_mod.Meta;
const Fn = ir_mod.Fn;
const parseMeta = ir_mod.parseMeta;
const metaId = ir_mod.metaId;
const operand = ir_mod.operand;
const core = ir_mod.core;
const records = @import("cov_branch_records.zig");
const andor = @import("cov_branch_andor.zig");
const Record = records.Record;
const render = records.render;
const writeOut = records.writeOut;
const lessStr = records.lessStr;

const usage =
    \\usage: cov_branch_classify --ir <test.ll> --out <file> --map <PREFIX>=<REPO>
    \\           [--src <DIR>] --stdlib <PREFIX> [--gen <REL>]...
    \\           [--exclude <PREFIX>]... [--exclude-file <NAME>]...
    \\
;

const header = "; *** IR Dump After PGOInstrumentationUse on [module] ***";
const max_ir = 1 << 31;
const max_errors_shown = 40;

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_branch_classify: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

// ---- branches --------------------------------------------------------------

/// What an `and`/`or` still needs before its function ends.
pub const Need = enum { none, phi, observe };

/// A position in a measured file; line 0: not known.
const Pos = struct { line: u64 = 0, col: u64 = 0 };

/// One measured decision of the function being read.
pub const Dec = struct {
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
    fp: Pos, // where its condition is computed in this copy (line 0: elsewhere)
    block: []const u8, // the block of its instruction
    need: Need = .none,
    // A short-circuit and/or's br: its true and false targets (`%4`).
    targets: [2][]const u8 = .{ "", "" },
    // Why no phi at its location was taken as its result (an error text),
    // a phi joining its targets in another shape (rank 2) before one that
    // does not join them (rank 1).
    note: []const u8 = "",
    note_rank: u8 = 0,
    // An `i1` phi at its token that is neither a result nor an error flag
    // (an error text): an and/or no test reads is refused for it.
    odd: []const u8 = "",
    // Why a test of its result gave no right operand (an error text): it
    // ran another number of times than the left operand.
    unmatched: []const u8 = "",
    parent: ?usize = null, // rhs: its and/or
    keep: bool = true,
    ordinal: usize = 0,
    total: usize = 0,
};

const Copy = struct { key: []const u8, where: []const u8, file: *File, line: u64, col: u64, n: usize, fp: []const Pos };

pub const State = struct {
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
    escaped: usize = 0, // and/or results no test reads: the and/or's two arms
    same: usize = 0,
    function: usize = 0,
    // The function being read: its instructions, its decisions, and the
    // values whose outcomes an and/or awaits.
    fun: Fn,
    decs: std.ArrayList(Dec),
    awaits: std.StringHashMap(andor.Await),
    // Every copy of a function's decisions at one location and kind.
    copies: std.StringHashMap(Copy),

    pub fn err(self: *State, comptime fmt: []const u8, args: anytype) void {
        self.errors.append(std.fmt.allocPrint(self.alloc, fmt, args) catch oom()) catch oom();
    }

    fn fileOf(self: *State, name: []const u8) *File {
        const slot = self.files.getOrPut(name) catch oom();
        if (!slot.found_existing) {
            const f = self.alloc.create(File) catch oom();
            f.* = placeFile(self.alloc, self.opts, name);
            slot.value_ptr.* = f;
            if (f.where == .unmapped) self.unmapped.put(name, {}) catch oom();
            if (f.where == .other_src) self.err("'{s}' is the library's source under a [src], not under --map's PREFIX ('{s}', read at '{s}'): the IR was compiled from other sources than the ones measured", .{ name, self.opts.prefix, self.opts.src });
        }
        return slot.value_ptr.*;
    }

    const At = struct { file: *File, line: u64, col: u64, inlined_at: ?u32 };

    /// The file name and location of metadata id `loc` (a DILocation).
    fn where(self: *State, loc: u32) ?struct { name: []const u8, line: u64, col: u64, inlined_at: ?u32 } {
        const m = self.meta.get(loc) orelse return null;
        if (m != .location) return null;
        const s = self.meta.get(m.location.scope) orelse return null;
        if (s != .scope) return null;
        const fid = s.scope.file orelse return null;
        const f = self.meta.get(fid) orelse return null;
        if (f != .file) return null;
        return .{ .name = f.file.name, .line = m.location.line, .col = m.location.col, .inlined_at = m.location.inlined_at };
    }

    /// The file and location of metadata id `loc` (a DILocation), or null.
    pub fn locate(self: *State, loc: u32) ?At {
        const w = self.where(loc) orelse return null;
        return .{ .file = self.fileOf(w.name), .line = w.line, .col = w.col, .inlined_at = w.inlined_at };
    }

    /// Whether location `loc` is inlined at `at`, directly or through
    /// another inlined call.
    pub fn inlinedAt(self: *State, loc: u32, at: u32) bool {
        var l = loc;
        for (0..32) |_| {
            const m = self.meta.get(l) orelse return false;
            if (m != .location) return false;
            const i = m.location.inlined_at orelse return false;
            if (i == at) return true;
            l = i;
        }
        return false;
    }

    /// Whether `loc` is in the standard library (--stdlib), inlined at `at`.
    pub fn stdlibInlinedAt(self: *State, loc: u32, at: u32) bool {
        const w = self.where(loc) orelse return false;
        const i = w.inlined_at orelse return false;
        return i == at and std.mem.startsWith(u8, w.name, self.opts.stdlib);
    }

    pub fn weightsOf(self: *State, prof: ?u32, arms: usize, what: []const u8) ?[]const u64 {
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

    pub fn whereOf(self: *State, d: Dec) []const u8 {
        return std.fmt.allocPrint(self.alloc, "{s}:{d}:{d}", .{ d.file.repo, d.line, d.col }) catch oom();
    }
};

const fmf = [_][]const u8{ "nnan ", "ninf ", "nsz ", "arcp ", "contract ", "afn ", "reassoc ", "fast " };

/// What one branch instruction is: a measured decision (`dec`, an index into
/// st.decs), or not; its weights when it is in a measured file (`parsed`),
/// else its `!prof`, read only when an and/or awaits its outcomes.
/// `decision`: a measured branch of a source decision's class (an and/or's
/// result is counted only from such a test, never from a call's error check).
pub const Seen = struct { dec: ?usize = null, weights: ?[]const u64 = null, prof: ?u32 = null, parsed: bool = true, decision: bool = false };

/// One branch instruction: `kind` with `arms` arms on condition `cond`, its
/// `!dbg` and `!prof` on `text`, in block `blk`.
fn branch(st: *State, kind: Kind, arms: usize, cond: []const u8, text: []const u8, ln: usize, blk: []const u8) Seen {
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
    const in_file = at.line >= 1 and at.line <= at.file.lines.len;
    const src: []const u8 = if (in_file) at.file.lines[@intCast(at.line - 1)] else "";
    const code = std.mem.trim(u8, src, " ");
    const c = if (in_file) classify(st.alloc, at.file.lines, @intCast(at.line - 1), at.col) else classify(st.alloc, &.{""}, 0, at.col);
    const w = st.weightsOf(prof, arms, where);
    // A token that cannot be read (a call's name behind a triple-quoted
    // string) is refused before any rule, a String's shapes included: the
    // call may be of a nodebug function.
    if (c.refusal.len > 0) {
        st.counts[@intFromEnum(Class.unknown)] += 1;
        st.err("{s}: a {s} at '{s}': {s}: {s}", .{ where, @tagName(kind), c.token, c.refusal, code });
        return .{ .weights = w };
    }
    // A call of a measured nodebug function: its own code carries the
    // call's location, whatever its shape.
    if (c.class == .call) {
        if (st.nodebug.get(c.callee)) |decl| {
            st.counts[@intFromEnum(Class.unknown)] += 1;
            st.err("{s}: a {s} at '{s}' may be a decision of {s}, which {s} declares @always_inline(\"nodebug\"): its code carries the call's location, so its decisions cannot be told from the compiler's here: {s}", .{ where, @tagName(kind), c.token, c.callee, decl, code });
            return .{ .weights = w };
        }
    }
    // A String's destructor or copy, at any token (README.md, "String
    // lifetime"); at a decision's token only when the tested instruction is
    // at the branch's own location, so a decision on such a test stays one.
    if (kind != .@"switch" and st.fun.stringShape(cond, dbg, c.class.decision(), st)) {
        st.counts[@intFromEnum(Class.string)] += 1;
        return .{ .weights = w };
    }
    // In a `try:` body of its function, a br at a call, a subscript or a `+`
    // is a raising call's error check, and a decision: whether the call
    // raised into the handler. Any other br there is refused: whether its
    // error reaches the handler is not known.
    const in_try = if (kind == .br and (c.class == .call or c.class == .subscript or c.class == .plus)) source.inTry(st.alloc, at.file, at.line) else false;
    if (in_try == null) {
        st.counts[@intFromEnum(Class.unknown)] += 1;
        if (!at.file.unbalanced_told) {
            at.file.unbalanced_told = true;
            st.err("{s}: the brackets of the file do not balance ({s}): which lines are continuations, and so whether a call is in a try body, cannot be read", .{ at.file.repo, at.file.unbalanced });
        }
        return .{ .weights = w };
    }
    if (in_try.?) {
        if (st.fun.errorFlag(cond, dbg, st)) return tryDecision(st, at, w, cond, prof, blk);
        st.counts[@intFromEnum(Class.unknown)] += 1;
        st.err("{s}: a br at '{s}' in a try body that is not a raising call's error flag (the i1, or field 0 of the {{ i1, ... }}, a call at this location returns, or a phi of such flags, constants and the code of a callee inlined here): whether it is the call's error check is not known: {s}", .{ where, c.token, code });
        return .{ .weights = w };
    }
    st.counts[@intFromEnum(c.class)] += 1;
    if (c.class == .unknown) {
        st.err("{s}: a {s} at '{s}' is neither a source decision nor a known compiler-made branch: {s}", .{ where, @tagName(kind), c.token, code });
        return .{ .weights = w };
    }
    if (!c.class.takes(kind)) {
        st.err("{s}: a {s} at '{s}': no {s} has been seen at this token, so what it is is not known: {s}", .{ where, @tagName(kind), c.token, @tagName(kind), code });
        return .{ .weights = w };
    }
    // A subscript's branch is a raising `__getitem__`'s error flag; a select
    // at a call keeps the old value when the call raised.
    if (c.class == .subscript and !st.fun.raisingFlag(cond, dbg, true)) {
        st.err("{s}: a br at '[' that is not on a raising call's error flag (the i1, or field 0 of the {{ i1, ... }}, a call at this location returns): what it is is not known: {s}", .{ where, code });
        return .{ .weights = w };
    }
    if (c.class == .call and kind == .select and !st.fun.raisingFlag(cond, dbg, false) and !st.fun.brOn(cond, dbg, prof)) {
        st.err("{s}: a select at '{s}' that is not on a raising call's error flag (field 0 of the {{ i1, ... }} a call at this location returns, or a value a br at this location with the same weights tests): what it is is not known: {s}", .{ where, c.token, code });
        return .{ .weights = w };
    }
    if (!c.class.decision()) return .{ .weights = w };
    st.decs.append(.{ .file = at.file, .line = at.line, .col = at.col, .inl = at.inlined_at, .kind = kind, .class = c.class, .arms = arms, .weights = w, .cond = cond, .prof = prof, .fp = condPos(st, cond, at), .block = blk }) catch oom();
    return .{ .dec = st.decs.items.len - 1, .weights = w, .decision = true };
}

/// Where condition `cond` of a branch at `at` is computed, when in the same
/// copy of the function and file (line 0: elsewhere).
fn condPos(st: *State, cond: []const u8, at: State.At) Pos {
    const dd = st.fun.defs.get(cond) orelse return .{};
    const d = dd.dbg orelse return .{};
    const ca = st.locate(d) orelse return .{};
    if (ca.inlined_at == at.inlined_at and ca.file == at.file) return .{ .line = ca.line, .col = ca.col };
    return .{};
}

/// A `try:` body's raising call (README.md, "try"): its br is a decision
/// whose arm 0 is the call returning (LLVM's false, the second weight) and
/// arm 1 the call raising into the handler (true, the first).
fn tryDecision(st: *State, at: State.At, w: ?[]const u64, cond: []const u8, prof: ?u32, blk: []const u8) Seen {
    st.counts[@intFromEnum(Class.try_)] += 1;
    var arms: ?[]const u64 = w;
    if (w) |x| {
        if (x.len == 2) {
            const sw = st.alloc.alloc(u64, 2) catch oom();
            sw[0] = x[1];
            sw[1] = x[0];
            arms = sw;
        }
    }
    st.decs.append(.{ .file = at.file, .line = at.line, .col = at.col, .inl = at.inlined_at, .kind = .@"try", .class = .try_, .arms = 2, .weights = arms, .cond = cond, .prof = prof, .fp = condPos(st, cond, at), .block = blk }) catch oom();
    // No source decision's test: an and/or's result is never counted from it.
    return .{ .dec = st.decs.items.len - 1, .weights = w, .decision = false };
}

/// The end of a function: every bool and/or is read (andor.finish);
/// branches that are one are folded; ordinals assigned; the decisions
/// recorded.
fn endFunction(st: *State) void {
    andor.finish(st);
    const ds = st.decs.items;
    // One decision tested twice (the same condition value and weights at the
    // same location): keep one, a br before a switch before a select.
    for (ds, 0..) |*a, i| {
        if (!a.keep or a.kind == .rhs or a.class == .and_ or a.class == .or_) continue;
        for (ds[i + 1 ..]) |*b| {
            if (!b.keep or b.kind == .rhs or b.class != a.class) continue;
            if (b.file != a.file or b.line != a.line or b.col != a.col or b.inl != a.inl or !std.mem.eql(u8, b.cond, a.cond)) continue;
            if ((a.prof == null) != (b.prof == null) or (a.prof != null and a.prof.? != b.prof.?)) continue;
            const rank = [_]u8{ 0, 3, 2, 1, 0 }; // br, rhs, select, switch, try
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
            st.copies.put(copy, .{ .key = key, .where = std.fmt.allocPrint(st.alloc, "{s} ({s})", .{ st.whereOf(d), @tagName(d.kind) }) catch oom(), .file = d.file, .line = d.line, .col = d.col, .n = 0, .fp = &.{} }) catch oom();
        }
        slot.value_ptr.append(i) catch oom();
    }
    for (order.items) |copy| {
        const idx = per.get(copy).?.items;
        var fp = st.alloc.alloc(Pos, idx.len) catch oom();
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
    st.awaits.clearRetainingCapacity();
}

/// One function, its lines read into st.fun: its branches and phis, in
/// order.
fn walk(st: *State) void {
    var sw_cases: ?usize = null;
    var sw_cond: []const u8 = "";
    for (st.fun.insts.items) |li| {
        const t = li.text;
        const ln = li.ln;
        const blk = st.fun.blocks.items[li.block].name;
        if (sw_cases) |n| {
            if (std.mem.startsWith(u8, t, "]")) {
                sw_cases = null;
                _ = branch(st, .@"switch", n + 1, sw_cond, t, ln, blk);
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
        const body = if (eq) |e| t[e + 3 ..] else t;
        if (std.mem.startsWith(u8, t, "br i1 ")) {
            const cond = operand(t["br i1 ".len..]);
            const r = branch(st, .br, 2, cond, t, ln, blk);
            andor.observe(st, cond, r);
            if (r.dec) |di| {
                const c = st.decs.items[di].class;
                if (c == .or_ or c == .and_) andor.brAt(st, di, t);
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
            andor.phiAt(st, t, ln);
        } else if (std.mem.startsWith(u8, body, "xor i1 ")) {
            andor.xorAt(st, t[0..eq.?], body["xor i1 ".len..]);
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
            const r = branch(st, .select, 2, cond, t, ln, blk);
            andor.observe(st, cond, r);
            const di = r.dec orelse continue;
            andor.selectAt(st, di, t[0..eq.?], ops, cond, t, ln);
        }
    }
}

/// Each function of the module: its lines indexed (st.fun), then walked.
fn scan(st: *State, ir: []const u8) void {
    var in_fn = false;
    var it = std.mem.splitScalar(u8, ir, '\n');
    var ln: usize = 0;
    while (it.next()) |line| {
        ln += 1;
        if (std.mem.startsWith(u8, line, "define ")) {
            in_fn = true;
            st.function += 1;
            st.fun.begin();
            continue;
        }
        if (!in_fn) continue;
        if (std.mem.eql(u8, line, "}")) {
            in_fn = false;
            walk(st);
            endFunction(st);
            continue;
        }
        if (std.mem.startsWith(u8, line, "  ")) {
            st.fun.inst(std.mem.trimLeft(u8, line, " "), ln);
        } else {
            st.fun.label(line);
        }
    }
}

// ---- main ------------------------------------------------------------------

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch oom();

    var ir_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var map: ?[]const u8 = null;
    var src_dir: ?[]const u8 = null;
    var stdlib: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, flag, "--src")) {
            if (src_dir != null) usageFail("--src given twice", .{});
            if (v.len < 2 or v[v.len - 1] != '/') usageFail("--src '{s}' must end with '/'", .{v});
            src_dir = v;
        } else if (std.mem.eql(u8, flag, "--stdlib")) {
            if (stdlib != null) usageFail("--stdlib given twice", .{});
            if (v.len < 2 or v[v.len - 1] != '/') usageFail("--stdlib '{s}' must end with '/'", .{v});
            stdlib = v;
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
    const std_prefix = stdlib orelse usageFail("--stdlib is required", .{});
    const eq = std.mem.indexOfScalar(u8, m, '=') orelse usageFail("--map '{s}' is not PREFIX=REPO", .{m});
    const src = src_dir orelse m[0..eq];
    const opts = Opts{
        .prefix = m[0..eq],
        .src = src,
        .hash_tail = hashTail(src),
        .repo = m[eq + 1 ..],
        .gens = gens.items,
        .excludes = excludes.items,
        .exclude_files = exclude_files.items,
        .stdlib = std_prefix,
    };
    if (opts.prefix.len < 2 or opts.prefix[opts.prefix.len - 1] != '/') usageFail("--map PREFIX '{s}' must end with '/'", .{opts.prefix});
    if (opts.repo.len > 0 and (opts.repo[0] == '/' or opts.repo[opts.repo.len - 1] != '/')) usageFail("--map REPO '{s}' must be empty or relative and end with '/'", .{opts.repo});
    // With no content hash in the [src] name, the library's sources named by
    // a [src] could not be told, and an exclusion would drop them unseen.
    if (opts.hash_tail == null) usageFail("the [src] '{s}' (--src, or --map's PREFIX without it) holds no '/<16 hex>/' segment: it is not a [src] of a library, and its sources named by a [src] could not be told", .{opts.src});

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
        .fun = Fn.init(alloc),
        .decs = std.ArrayList(Dec).init(alloc),
        .awaits = std.StringHashMap(andor.Await).init(alloc),
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
    // places (where both are known; for an `if`, `elif` or `while`, inside
    // its header: a copy may have folded part of the condition away), or
    // the n-th of one is not another's.
    const First = struct { n: usize, fp: []Pos };
    var per_key = std.StringHashMap(First).init(alloc);
    var ci = st.copies.valueIterator();
    while (ci.next()) |c| {
        const slot = per_key.getOrPut(c.key) catch oom();
        if (!slot.found_existing) {
            slot.value_ptr.* = .{ .n = c.n, .fp = alloc.dupe(Pos, c.fp) catch oom() };
        } else if (slot.value_ptr.n != c.n) {
            st.err("{s}: one copy of its function has {d} branch(es) of this kind here and another {d}: they cannot be matched to be summed", .{ c.where, @min(slot.value_ptr.n, c.n), @max(slot.value_ptr.n, c.n) });
            slot.value_ptr.n = c.n;
            slot.value_ptr.fp = alloc.dupe(Pos, c.fp) catch oom();
        } else {
            const span = headerSpan(c.file.lines, c.line, c.col);
            for (slot.value_ptr.fp, c.fp, 0..) |*x, y, n| {
                if (x.line == 0) {
                    x.* = y;
                } else if (y.line > 0 and (x.line != y.line or x.col != y.col)) {
                    if (span) |h| {
                        if (inSpan(h, x.line, x.col) and inSpan(h, y.line, y.col)) continue;
                    }
                    st.err("{s}: two copies of its function hold different branches here: the condition of the one numbered {d} is computed at {d}:{d} in one and at {d}:{d} in another", .{ c.where, n, x.line, x.col, y.line, y.col });
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
    const cn = st.counts;
    std.debug.print("cov_branch_classify: {d} measured file(s): {d} source decision(s) (if {d}, elif {d}, while {d}, and {d}, or {d}, for-in {d}, try {d}; {d} right operand(s) derived, {d} and/or result(s) no test reads, {d} a second test of one decision), {d} compiler-made (String lifetime {d}, + {d}, call( {d}, [ {d}, // {d}, % {d}) not written; {d} branch(es) outside the measured sources\n", .{
        measured_files,                      decisions,                              cn[@intFromEnum(Class.if_)],       cn[@intFromEnum(Class.elif)],
        cn[@intFromEnum(Class.while_)],       cn[@intFromEnum(Class.and_)],            cn[@intFromEnum(Class.or_)],       cn[@intFromEnum(Class.for_in)],
        cn[@intFromEnum(Class.try_)],
        st.derived,                          st.escaped,                             st.same,                                made,                             cn[@intFromEnum(Class.string)],
        cn[@intFromEnum(Class.plus)],         cn[@intFromEnum(Class.call)],            cn[@intFromEnum(Class.subscript)], cn[@intFromEnum(Class.floordiv)],
        cn[@intFromEnum(Class.mod)],          st.outside,
    });
}
