//! cov_branch_ir: the IR side of cov_branch_classify (README.md,
//! "cov_branch_classify") below the branch walk: the metadata nodes, one
//! function's instructions indexed by the value each defines and by block,
//! and the instruction shapes the classes are told by: the code of a
//! String's lifetime, a raising call's error flag (and, in a `try:` body,
//! the flag of a raising callee inlined at the call), the reload of an `and`'s
//! left operand, and dominance over the printed predecessors. Imported by
//! cov_branch_classify.zig; no `main` of its own.

const std = @import("std");
const Alloc = std.mem.Allocator;
const source = @import("cov_branch_source.zig");
const oom = source.oom;

// ---- metadata --------------------------------------------------------------

pub const Meta = union(enum) {
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

pub fn parseMeta(alloc: Alloc, text: []const u8) Meta {
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

pub fn metaId(s: []const u8, key: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, s, key) orelse return null;
    const rest = s[at + key.len ..];
    var j: usize = 0;
    while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
    return std.fmt.parseInt(u32, rest[0..j], 10) catch null;
}

pub fn operand(s: []const u8) []const u8 {
    const e = std.mem.indexOf(u8, s, ", ") orelse s.len;
    return s[0..e];
}

/// An instruction's text without its metadata attachments (`, !dbg !7`).
pub fn core(s: []const u8) []const u8 {
    const e = std.mem.indexOf(u8, s, ", !") orelse s.len;
    return s[0..e];
}

fn after(s: []const u8, prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, s, prefix)) s[prefix.len..] else null;
}

// ---- one function ----------------------------------------------------------

/// One instruction line: its text (indentation off), the IR line number,
/// its block (an index into Fn.blocks).
pub const Inst = struct { text: []const u8, ln: usize, block: usize };

/// A block: its name as operands write it (`%12`; "" for an entry block
/// printed with no label), the predecessors LLVM prints (`; preds = ...`),
/// its instructions Fn.insts[first..end].
pub const Block = struct { name: []const u8, preds: []const []const u8, first: usize, end: usize };

/// What defines an SSA value: the text after ` = `, its `!dbg`, its block,
/// its index in Fn.insts.
pub const Def = struct { body: []const u8, dbg: ?u32, block: usize, at: usize };

pub const Fn = struct {
    alloc: Alloc,
    insts: std.ArrayList(Inst),
    blocks: std.ArrayList(Block),
    by_name: std.StringHashMap(usize),
    defs: std.StringHashMap(Def),
    // Each `br i1` as `<cond> <!dbg> <!prof>` (0: none).
    brs: std.StringHashMap(void),

    pub fn init(alloc: Alloc) Fn {
        return .{ .alloc = alloc, .insts = std.ArrayList(Inst).init(alloc), .blocks = std.ArrayList(Block).init(alloc), .by_name = std.StringHashMap(usize).init(alloc), .defs = std.StringHashMap(Def).init(alloc), .brs = std.StringHashMap(void).init(alloc) };
    }

    /// Starts the function: its entry block, until a label says otherwise.
    pub fn begin(self: *Fn) void {
        self.insts.clearRetainingCapacity();
        self.blocks.clearRetainingCapacity();
        self.by_name.clearRetainingCapacity();
        self.defs.clearRetainingCapacity();
        self.brs.clearRetainingCapacity();
        self.blocks.append(.{ .name = "", .preds = &.{}, .first = 0, .end = 0 }) catch oom();
    }

    /// A line of the function that is not an instruction: a label starts a
    /// block (`12:  ; preds = %3, %9`); anything else is ignored.
    pub fn label(self: *Fn, line: []const u8) void {
        if (line.len == 0 or line[0] == ';') return;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return;
        const name = std.mem.concat(self.alloc, u8, &.{ "%", line[0..colon] }) catch oom();
        var preds = std.ArrayList([]const u8).init(self.alloc);
        if (std.mem.indexOf(u8, line, "; preds = ")) |p| {
            var it = std.mem.splitSequence(u8, line[p + "; preds = ".len ..], ", ");
            while (it.next()) |x| preds.append(std.mem.trim(u8, x, " ")) catch oom();
        }
        const last = &self.blocks.items[self.blocks.items.len - 1];
        if (last.name.len == 0 and last.first == self.insts.items.len and self.blocks.items.len == 1) {
            // The entry block is the labelled one: no unlabelled code before it.
            last.* = .{ .name = name, .preds = preds.items, .first = self.insts.items.len, .end = self.insts.items.len };
        } else {
            self.blocks.append(.{ .name = name, .preds = preds.items, .first = self.insts.items.len, .end = self.insts.items.len }) catch oom();
        }
        self.by_name.put(name, self.blocks.items.len - 1) catch oom();
    }

    pub fn inst(self: *Fn, text: []const u8, ln: usize) void {
        const b = self.blocks.items.len - 1;
        if (text.len > 0 and text[0] == '%') {
            if (std.mem.indexOf(u8, text, " = ")) |e| {
                self.defs.put(text[0..e], .{ .body = text[e + 3 ..], .dbg = metaId(text, "!dbg !"), .block = b, .at = self.insts.items.len }) catch oom();
            }
        }
        if (after(text, "br i1 ")) |r| {
            self.brs.put(brKey(self.alloc, operand(r), metaId(text, "!dbg !") orelse 0, metaId(text, "!prof !") orelse 0), {}) catch oom();
        }
        self.insts.append(.{ .text = text, .ln = ln, .block = b }) catch oom();
        self.blocks.items[b].end = self.insts.items.len;
    }

    fn body(self: *const Fn, v: []const u8) ?[]const u8 {
        const d = self.defs.get(v) orelse return null;
        return core(d.body);
    }

    fn dbgOf(self: *const Fn, v: []const u8) ?u32 {
        const d = self.defs.get(v) orelse return null;
        return d.dbg;
    }

    // ---- a String's lifetime (README.md, "String lifetime") ---------------

    /// A load of field 2 of a `{ ptr, i64, i64 }` (a String's capacity and
    /// flags word).
    fn flagsLoad(self: *const Fn, v: []const u8) bool {
        const r = after(self.body(v) orelse return false, "load i64, ptr ") orelse return false;
        const p = operand(r);
        if (r.len != p.len and !std.mem.startsWith(u8, r[p.len..], ", align ")) return false;
        var g = after(self.body(p) orelse return false, "getelementptr ") orelse return false;
        if (after(g, "inbounds ")) |x| g = x;
        const q = after(g, "{ ptr, i64, i64 }, ptr ") orelse return false;
        const base = operand(q);
        return std.mem.eql(u8, q[base.len..], ", i32 0, i32 2");
    }

    /// The flags word: such a load, or a web of `phi i64` (an inlined
    /// callee's String carried in values) whose leaves are such loads, i64
    /// constants and `undef`, one leaf at least such a load or the flags
    /// of a static String (1 << 61).
    fn flagsWord(self: *const Fn, v: []const u8) bool {
        var seen = std.StringHashMap(void).init(self.alloc);
        var evidence = false;
        return self.flagsLeaves(v, &seen, &evidence, 0) and evidence;
    }

    fn flagsLeaves(self: *const Fn, v: []const u8, seen: *std.StringHashMap(void), evidence: *bool, depth: usize) bool {
        if (seen.contains(v)) return true; // a cycle: no other leaf
        if (depth > 32) return false;
        seen.put(v, {}) catch oom();
        const b = self.body(v) orelse return false;
        const r = after(b, "phi i64 ") orelse {
            if (!self.flagsLoad(v)) return false;
            evidence.* = true;
            return true;
        };
        var it = std.mem.splitSequence(u8, r, "], ");
        while (it.next()) |piece| {
            const p = std.mem.trim(u8, piece, " ]");
            const in = after(p, "[ ") orelse return false;
            const x = operand(in);
            if (x.len > 0 and x[0] == '%') {
                if (!self.flagsLeaves(x, seen, evidence, depth + 1)) return false;
            } else if (std.mem.eql(u8, x, "2305843009213693952")) {
                evidence.* = true;
            } else if (!std.mem.eql(u8, x, "undef")) {
                _ = std.fmt.parseInt(i64, x, 10) catch return false;
            }
        }
        return true;
    }

    /// (a) `icmp ne i64 (and i64 W, M), 0`, M bit 62 (refcounted) or bit 63
    /// (inline), the `and` and the `icmp` at one `!dbg`, W the flags word.
    fn flagTest(self: *const Fn, v: []const u8) bool {
        const r = after(self.body(v) orelse return false, "icmp ne i64 ") orelse return false;
        const a = operand(r);
        if (!std.mem.eql(u8, r[a.len..], ", 0")) return false;
        const id = self.dbgOf(v) orelse return false;
        if ((self.dbgOf(a) orelse return false) != id) return false;
        const m = after(self.body(a) orelse return false, "and i64 ") orelse return false;
        const w = operand(m);
        const mask = m[w.len..];
        if (!std.mem.eql(u8, mask, ", 4611686018427387904") and !std.mem.eql(u8, mask, ", -9223372036854775808")) return false;
        return self.flagsWord(w);
    }

    /// (c)'s `atomicrmw sub ptr P, i64 1 ...` (directly, or the one incoming
    /// value of a `phi i64`), at a location `atOwn` accepts.
    fn lastRef(self: *const Fn, v: []const u8, ctx: anytype, br_dbg: u32) bool {
        var x = v;
        const b = self.body(x) orelse return false;
        if (after(b, "phi i64 [ ")) |r| {
            const y = operand(r);
            if (std.mem.indexOf(u8, r, "], ") != null) return false; // more than one incoming
            x = y;
        }
        const r = after(self.body(x) orelse return false, "atomicrmw sub ptr ") orelse return false;
        const p = operand(r);
        if (!std.mem.startsWith(u8, r[p.len..], ", i64 1 ")) return false;
        const d = self.dbgOf(x) orelse return false;
        return ctx.stdlibInlinedAt(d, br_dbg);
    }

    /// Whether the condition `cond` of a br or select at `br_dbg` is a
    /// String's destructor or copy: (a), (b) `xor i1 (a), true`, or (c)
    /// `icmp eq i64 (atomicrmw sub ..., i64 1), 1` whose atomicrmw is the
    /// standard library's, inlined at the branch. The tested instruction
    /// carries the branch's `!dbg`, except (a)'s at a token that is no
    /// decision (`strict` false).
    pub fn stringShape(self: *const Fn, cond: []const u8, br_dbg: u32, strict: bool, ctx: anytype) bool {
        const d = self.dbgOf(cond) orelse return false;
        const own = d == br_dbg;
        if (self.flagTest(cond)) return own or !strict;
        const b = self.body(cond) orelse return false;
        if (after(b, "xor i1 ")) |r| {
            const x = operand(r);
            return own and std.mem.eql(u8, r[x.len..], ", true") and self.flagTest(x);
        }
        if (after(b, "icmp eq i64 ")) |r| {
            const x = operand(r);
            return own and std.mem.eql(u8, r[x.len..], ", 1") and self.lastRef(x, ctx, br_dbg);
        }
        return false;
    }

    // ---- a raising call ----------------------------------------------------

    /// Whether `cond` is a raising call's error flag at `dbg`: the `i1` a
    /// `[tail] call i1 @...` returns (`direct`), or field 0 of the
    /// `{ i1, ... }` a call returns, the call at `dbg`.
    pub fn raisingFlag(self: *const Fn, cond: []const u8, dbg: u32, direct: bool) bool {
        const b = self.body(cond) orelse return false;
        if (isCall(b, "i1")) return direct and (self.dbgOf(cond) orelse return false) == dbg;
        const r = after(b, "extractvalue ") orelse return false;
        if (!std.mem.endsWith(u8, r, ", 0")) return false;
        const sp = std.mem.lastIndexOfScalar(u8, r[0 .. r.len - 3], ' ') orelse return false;
        const ty = r[0..sp];
        const c = r[sp + 1 .. r.len - 3];
        if (!std.mem.startsWith(u8, ty, "{ i1, ")) return false;
        const cb = self.body(c) orelse return false;
        return isCall(cb, ty) and (self.dbgOf(c) orelse return false) == dbg;
    }

    /// Whether `v` is field 0 of the `{ i1, ... }` a call returns, both at
    /// one location: a raising call's error flag (an and/or's raising right
    /// operand's, wherever the call is).
    pub fn ownFlag(self: *const Fn, v: []const u8) bool {
        const d = self.dbgOf(v) orelse return false;
        return self.raisingFlag(v, d, false);
    }

    /// Whether `cond`, tested by a br at `dbg`, is true exactly when a
    /// raising call at `dbg` raised (README.md, "try"): the call's own flag
    /// (raisingFlag), or a `phi i1` whose incoming values are `true`,
    /// `false`, such flags or phis, or code of a callee inlined at `dbg`
    /// (its location's inlinedAt chain holds `dbg`: the callee's test of
    /// its own `raise`), one at least such a value or a constant arriving
    /// from a block of that callee's code (its branch's location inlined at
    /// `dbg`: the callee's raise path and its return).
    pub fn errorFlag(self: *const Fn, cond: []const u8, dbg: u32, ctx: anytype) bool {
        return self.errorFlagAt(cond, dbg, ctx, 0);
    }

    fn errorFlagAt(self: *const Fn, v: []const u8, dbg: u32, ctx: anytype, depth: usize) bool {
        if (depth > 16) return false;
        if (self.raisingFlag(v, dbg, true)) return true;
        const r = after(self.body(v) orelse return false, "phi i1 ") orelse return false;
        var some = false;
        var value = false; // a non-constant incoming value
        // Constants-only: each constant from a callee block must say what
        // that block is, `true` from its raise path (a block calling the
        // raise hook), `false` from any other, or the arms would swap.
        var polarity = true;
        var raised = false;
        var it = std.mem.splitSequence(u8, r, "], ");
        while (it.next()) |piece| {
            const p = std.mem.trim(u8, piece, " ]");
            const in = after(p, "[ ") orelse return false;
            const x = operand(in);
            if (std.mem.eql(u8, x, "true") or std.mem.eql(u8, x, "false")) {
                const from = std.mem.trim(u8, in[@min(in.len, x.len + 2)..], " ");
                if (self.calleeBlock(from, dbg, ctx)) {
                    some = true;
                    const t = std.mem.eql(u8, x, "true");
                    const rb = self.raiseBlock(from);
                    if (t != rb) polarity = false;
                    if (t and rb) raised = true;
                }
                continue;
            }
            if (x.len == 0 or x[0] != '%') return false;
            some = true;
            value = true;
            if (self.errorFlagAt(x, dbg, ctx, depth + 1)) continue;
            const d = self.dbgOf(x) orelse return false;
            if (!ctx.inlinedAt(d, dbg)) return false;
        }
        if (!value) return some and polarity and raised;
        return some;
    }

    /// Whether block `b` calls the standard library's raise hook (Mojo's
    /// code for a `raise`: test 47's trial.mojo, komira_parquet's rle.mojo).
    fn raiseBlock(self: *const Fn, b: []const u8) bool {
        const bi = self.by_name.get(b) orelse return false;
        const blk = self.blocks.items[bi];
        for (self.insts.items[blk.first..blk.end]) |x| {
            if (std.mem.indexOf(u8, x.text, "@\"std::builtin::error::__mojo_debugger_raise_hook()\"(") != null) return true;
        }
        return false;
    }

    /// Whether block `b` ends in a branch whose location is inlined at `dbg`.
    fn calleeBlock(self: *const Fn, b: []const u8, dbg: u32, ctx: anytype) bool {
        const bi = self.by_name.get(b) orelse return false;
        const blk = self.blocks.items[bi];
        if (blk.end == blk.first) return false;
        const d = metaId(self.insts.items[blk.end - 1].text, "!dbg !") orelse return false;
        return ctx.inlinedAt(d, dbg);
    }

    /// Whether a `br i1` on `cond` at `dbg` with the `!prof` `prof` is in
    /// the function: a select on the value its call's error check tests.
    pub fn brOn(self: *const Fn, cond: []const u8, dbg: u32, prof: ?u32) bool {
        return self.brs.contains(brKey(self.alloc, cond, dbg, prof orelse 0));
    }

    // ---- blocks ------------------------------------------------------------

    /// Whether `own` (the block of a br) is the one predecessor of `t`.
    fn soleFrom(self: *const Fn, t: []const u8, own: []const u8) bool {
        const bi = self.by_name.get(t) orelse return false;
        const p = self.blocks.items[bi].preds;
        if (p.len != 1) return false;
        if (own.len == 0) return !self.by_name.contains(p[0]); // the unlabelled entry
        return std.mem.eql(u8, p[0], own);
    }

    /// Whether every path to block `b` passes through `t`, which only the
    /// block `own` jumps to: walking `b`'s predecessors back, never past
    /// `t`, reaches neither `own` nor a block with none (the entry).
    pub fn under(self: *const Fn, b: []const u8, t: []const u8, own: []const u8) bool {
        if (!self.soleFrom(t, own)) return false;
        var seen = std.StringHashMap(void).init(self.alloc);
        var todo = std.ArrayList([]const u8).init(self.alloc);
        todo.append(b) catch oom();
        seen.put(b, {}) catch oom();
        while (todo.popOrNull()) |x| {
            if (std.mem.eql(u8, x, t)) continue;
            if (std.mem.eql(u8, x, own)) return false;
            const bi = self.by_name.get(x) orelse return false;
            const preds = self.blocks.items[bi].preds;
            if (preds.len == 0) return false;
            for (preds) |p| {
                if (seen.contains(p)) continue;
                seen.put(p, {}) catch oom();
                todo.append(p) catch oom();
            }
        }
        return true;
    }

    /// Whether `v` reloads the `i1` the branch condition `left` loads
    /// (`load i1, ptr P` both), so that it equals the left operand: `left`
    /// is the last instruction before its branch, `v` the first of block
    /// `t` (the branch's target that only the branch reaches, `under`), but
    /// for lifetime markers and `nop` asm, and `t` ends in a `br label`.
    pub fn reload(self: *const Fn, v: []const u8, left: []const u8, t: []const u8) bool {
        const a = after(self.body(v) orelse return false, "load i1, ptr ") orelse return false;
        const b = after(self.body(left) orelse return false, "load i1, ptr ") orelse return false;
        if (!std.mem.eql(u8, operand(a), operand(b))) return false;
        const bi = self.by_name.get(t) orelse return false;
        const blk = self.blocks.items[bi];
        const dv = self.defs.get(v).?;
        if (dv.block != bi) return false;
        for (self.insts.items[blk.first..dv.at]) |x| {
            if (!marker(x.text)) return false;
        }
        if (!std.mem.startsWith(u8, self.insts.items[blk.end - 1].text, "br label ")) return false;
        const dl = self.defs.get(left).?;
        const ob = self.blocks.items[dl.block];
        const br = self.insts.items[ob.end - 1].text;
        if (!std.mem.startsWith(u8, br, "br i1 ") or !std.mem.eql(u8, operand(br["br i1 ".len..]), left)) return false;
        for (self.insts.items[dl.at + 1 .. ob.end - 1]) |x| {
            if (!marker(x.text)) return false;
        }
        return true;
    }
};

/// A lifetime marker or a `nop` asm: no write a reload could miss.
fn marker(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "call void @llvm.lifetime.") or std.mem.startsWith(u8, t, "call void asm sideeffect \"nop\", \"\"()");
}

fn brKey(alloc: Alloc, cond: []const u8, dbg: u32, prof: u32) []const u8 {
    return std.fmt.allocPrint(alloc, "{s} {d} {d}", .{ cond, dbg, prof }) catch oom();
}

/// Whether instruction text `b` is a call returning type `ty`.
fn isCall(b: []const u8, ty: []const u8) bool {
    const r = after(b, "tail call ") orelse after(b, "call ") orelse return false;
    return std.mem.startsWith(u8, r, ty) and std.mem.startsWith(u8, r[ty.len..], " @");
}
