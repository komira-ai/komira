//! cov_branch_andor: the `and`/`or` rules of cov_branch_classify (README.md,
//! "And, or"). A bool and/or is a decision of two arms at its token, its
//! left operand's br or select: the right operand evaluated or skipped.
//! When a source decision tests its result, the right operand's own
//! outcomes are counted too (`rhs`), derived from the left operand's counts
//! and the test's; when none does (the result is returned, stored or passed
//! on), or the test ran another number of times than the left operand (it
//! tests the value elsewhere, or only on some paths), the and/or's own two
//! arms are what is counted. The br of a short-circuit one is read as an
//! and/or only with its result phi (README.md); an `i1` phi at its token
//! that is neither a result, an error flag nor a forward of one value
//! refuses an and/or no test reads, as its result could not be told.
//! Imported by cov_branch_classify.zig, whose State and Dec it reads (the
//! root module); no `main` of its own.

const std = @import("std");
const root = @import("root");
const source = @import("cov_branch_source.zig");
const oom = source.oom;
const ir_mod = @import("cov_branch_ir.zig");
const operand = ir_mod.operand;
const core = ir_mod.core;
const State = root.State;

/// An SSA value whose outcomes give an and/or's right operand; for a
/// short-circuit one's phi, `rhs` is the value its right operand gives it.
pub const Await = struct { dec: usize, negated: bool, rhs: []const u8 = "" };

fn word(st: *State, di: usize) []const u8 {
    const c = @tagName(st.decs.items[di].class);
    return c[0 .. c.len - 1];
}

fn total(w: []const u64) u64 {
    var n: u64 = 0;
    for (w) |x| n += x;
    return n;
}

fn swapped(st: *State, w: ?[]const u64, negated: bool) ?[]const u64 {
    const x = w orelse return null;
    if (!negated or x.len != 2) return x;
    const sw = st.alloc.alloc(u64, 2) catch oom();
    sw[0] = x[1];
    sw[1] = x[0];
    return sw;
}

fn isConst(x: []const u8) bool {
    return std.mem.eql(u8, x, "true") or std.mem.eql(u8, x, "false");
}

fn constant(x: []const u8) bool {
    return std.mem.eql(u8, x, "i1 true") or std.mem.eql(u8, x, "i1 false");
}

/// Keeps `msg`, the first, as why a test of and/or `di`'s result gave no
/// right operand (it is not this result's test: it ran another number of
/// times).
fn unmatched(st: *State, di: usize, msg: []const u8) void {
    const d = &st.decs.items[di];
    if (d.unmatched.len == 0) d.unmatched = msg;
}

/// The right operand of and/or `di`: s = its own weights (the left operand:
/// true, false), b = the whole condition's (true, false). A select LLVM
/// gives no weights ran no time: with a whole of zero counts, never ran. A
/// test whose counts cannot be the whole's (it ran another number of times,
/// or one of the two ran and the other not) is not this result's test: the
/// and/or still awaits one, and is counted as its own two arms if none comes.
fn derive(st: *State, di: usize, b_or_null: ?[]const u64, rhs_val: []const u8) void {
    const p = st.decs.items[di];
    const where = st.whereOf(p);
    const w0 = word(st, di);
    var rhs = p;
    rhs.need = .none;
    rhs.kind = .rhs;
    rhs.parent = di;
    rhs.arms = 2;
    const b_ran = if (b_or_null) |b| total(b) > 0 else false;
    if (p.weights == null and !b_ran) {
        st.decs.items[di].need = .none;
        rhs.weights = null;
        st.decs.append(rhs) catch oom();
        st.derived += 1;
        return inner(st, rhs_val, null);
    }
    const s = p.weights orelse return unmatched(st, di, std.fmt.allocPrint(st.alloc, "{s}: the '{s}' never ran but the test of its result did", .{ where, w0 }) catch oom());
    const b = b_or_null orelse return unmatched(st, di, std.fmt.allocPrint(st.alloc, "{s}: the '{s}' ran but the test of its result never did", .{ where, w0 }) catch oom());
    if (s.len != 2 or b.len != 2) {
        // weightsOf has refused the run already.
        st.decs.items[di].need = .none;
        return;
    }
    if (s[0] + s[1] != b[0] + b[1]) return unmatched(st, di, std.fmt.allocPrint(st.alloc, "{s}: the left operand ran {d} times and the test of the result {d}: the right operand cannot be derived", .{ where, s[0] + s[1], b[0] + b[1] }) catch oom());
    var w = st.alloc.alloc(u64, 2) catch oom();
    if (p.class == .or_) {
        // true = left true + (left false, right true); false = both false.
        if (b[0] < s[0]) return unmatched(st, di, std.fmt.allocPrint(st.alloc, "{s}: 'or' is true {d} times but its left operand {d}", .{ where, b[0], s[0] }) catch oom());
        w[0] = b[0] - s[0];
        w[1] = b[1];
    } else {
        // true = both true; left true, right false = left true - true.
        if (s[0] < b[0]) return unmatched(st, di, std.fmt.allocPrint(st.alloc, "{s}: 'and' is true {d} times but its left operand {d}", .{ where, b[0], s[0] }) catch oom());
        w[0] = b[0];
        w[1] = s[0] - b[0];
    }
    st.decs.items[di].need = .none;
    rhs.weights = w;
    st.decs.append(rhs) catch oom();
    st.derived += 1;
    inner(st, rhs_val, w);
}

/// An and/or `p`'s right operand, `w` its outcomes, may itself be an
/// and/or no branch tests (`a and not (b and c)`): its whole condition's
/// outcomes are `w`, swapped through each `xor ..., true`.
fn inner(st: *State, rhs_val: []const u8, w: ?[]const u64) void {
    if (rhs_val.len == 0) return;
    const a = st.awaits.get(rhs_val) orelse return;
    if (st.decs.items[a.dec].need != .observe) return;
    derive(st, a.dec, swapped(st, w, a.negated), a.rhs);
}

/// A branch or select `seen` tested `cond`: the whole condition of an
/// and/or that awaits it, when it is a source decision's test (a call's
/// error check or a `try` decision is none).
pub fn observe(st: *State, cond: []const u8, seen: root.Seen) void {
    const a = st.awaits.get(cond) orelse return;
    if (st.decs.items[a.dec].need != .observe) return;
    if (seen.parsed and !seen.decision) return;
    const w = if (seen.parsed) seen.weights else st.weightsOf(seen.prof, 2, st.whereOf(st.decs.items[a.dec]));
    derive(st, a.dec, swapped(st, w, a.negated), a.rhs);
}

/// A br at an and/or's token, decision `di`: a short-circuit one, whose
/// result is a phi at the token joining its two targets.
pub fn brAt(st: *State, di: usize, t: []const u8) void {
    st.decs.items[di].need = .phi;
    st.decs.items[di].targets = brTargets(t);
}

/// `%x = xor i1 %v, true` of an awaited value: awaited, negated.
pub fn xorAt(st: *State, name: []const u8, ops: []const u8) void {
    const x = operand(ops);
    if (ops.len > x.len + 2 and std.mem.startsWith(u8, ops[x.len + 2 ..], "true")) {
        if (st.awaits.get(x)) |a| st.awaits.put(name, .{ .dec = a.dec, .negated = !a.negated, .rhs = a.rhs }) catch oom();
    }
}

/// A select at an and/or's token, decision `di` (`ops`: after `select i1 `,
/// `cond` its condition): `select i1 c, i1 true, i1 x` for or, `select i1
/// c, i1 x, i1 false` for and; its result awaits a test. Another form is
/// refused; a value and/or (not `i1`) has no right operand that decides.
pub fn selectAt(st: *State, di: usize, name: []const u8, ops: []const u8, cond: []const u8, t: []const u8, ln: usize) void {
    const c = st.decs.items[di].class;
    if (c != .or_ and c != .and_) return;
    if (ops.len < cond.len + 2) return;
    const a = operand(ops[cond.len + 2 ..]);
    if (!std.mem.startsWith(u8, a, "i1 ")) return; // a value and/or
    const b = if (ops.len > cond.len + 2 + a.len + 2) operand(ops[cond.len + 2 + a.len + 2 ..]) else "";
    const or_form = std.mem.eql(u8, a, "i1 true") and std.mem.startsWith(u8, b, "i1 ") and !constant(b);
    const and_form = std.mem.eql(u8, b, "i1 false") and std.mem.startsWith(u8, a, "i1 ") and !constant(a);
    if ((c == .or_ and or_form) or (c == .and_ and and_form)) {
        st.decs.items[di].need = .observe;
        st.awaits.put(name, .{ .dec = di, .negated = false }) catch oom();
    } else {
        st.err("{s}: IR line {d}: the select at this '{s}' is not that of one ('select i1 c, i1 true, i1 x' for or, 'select i1 c, i1 x, i1 false' for and): {s}", .{ st.whereOf(st.decs.items[di]), ln, word(st, di), t });
    }
}

/// The incoming values of phi text `rest` (after `phi <ty> `) and the
/// blocks they arrive from.
fn incoming(rest: []const u8, ins: *std.ArrayList([]const u8), from: *std.ArrayList([]const u8)) bool {
    const ty_end = std.mem.indexOf(u8, rest, " [") orelse return false;
    var it = std.mem.splitSequence(u8, core(rest[ty_end + 1 ..]), "], ");
    while (it.next()) |piece| {
        const p = std.mem.trim(u8, piece, " ");
        if (p.len == 0 or p[0] != '[') break;
        const v = operand(std.mem.trim(u8, p[1..], " "));
        ins.append(v) catch oom();
        const after = std.mem.trim(u8, p[1..], " ");
        from.append(if (after.len > v.len + 2) std.mem.trim(u8, after[v.len + 2 ..], " ]") else "") catch oom();
    }
    return true;
}

/// Whether every incoming value is one (a forward of it, as LLVM's
/// one-predecessor phis are).
fn forward(ins: []const []const u8) bool {
    if (ins.len == 0) return false;
    for (ins[1..]) |v| {
        if (!std.mem.eql(u8, v, ins[0])) return false;
    }
    return true;
}

/// Each `phi i1` of the function, wherever it is: one forwarding one
/// awaited value is awaited too (its test is that value's); then a phi at
/// an and/or's token (phiAtToken).
pub fn phiAt(st: *State, t: []const u8, ln: usize) void {
    const eq = std.mem.indexOf(u8, t, " = phi ") orelse return;
    const rest = t[eq + " = phi ".len ..];
    var ins = std.ArrayList([]const u8).init(st.alloc);
    var from = std.ArrayList([]const u8).init(st.alloc);
    if (!incoming(rest, &ins, &from)) return;
    if (std.mem.startsWith(u8, rest, "i1 ") and forward(ins.items)) {
        if (st.awaits.get(ins.items[0])) |a| st.awaits.put(t[0..eq], a) catch oom();
    }
    phiAtToken(st, t, ln, eq, rest, ins.items, from.items);
}

/// Marks and/or `di` as holding, at its token, an `i1` phi that is neither
/// a result nor a raising right operand's error flag (`msg` says which):
/// if no test reads its result, which phi that is cannot be told.
fn odd(st: *State, di: usize, msg: []const u8) void {
    const d = &st.decs.items[di];
    if (d.odd.len == 0) d.odd = msg;
}

/// A phi at the token of an and/or `br` of this copy: a result of it when
/// it joins one value arriving under the br's true target and one under its
/// false target (`under`: every path from the branch to the incoming block
/// passes through that target). A non-`i1` one is a value and/or's (no
/// right operand decides). An `i1` one is a candidate when the value that
/// decides (`true` for or, `false` for and) arrives under the target the
/// left operand takes for it (true for or, false for and), as that constant
/// or as a reload of the left operand (README.md, "And, or"); the first
/// candidate a source decision tests is the result. A raising right
/// operand's error flag (`false` under that target, field 0 of the `{ i1,
/// ... }` the right operand's call returns under the other) is no result.
/// Any other `i1` phi there (but a forward of one value) is odd: a phi
/// that is no candidate is refused when none is, or when no test reads a
/// candidate.
fn phiAtToken(st: *State, t: []const u8, ln: usize, eq: usize, rest: []const u8, ins: []const []const u8, from: []const []const u8) void {
    const dbg = ir_mod.metaId(t, "!dbg !") orelse return;
    const at = st.locate(dbg) orelse return;
    if (at.file.where != .measured) return;
    var i = st.decs.items.len;
    const di = while (i > 0) {
        i -= 1;
        const d = st.decs.items[i];
        if ((d.need == .phi or d.need == .observe) and d.kind == .br and d.targets[0].len > 0 and d.file == at.file and d.line == at.line and d.col == at.col and d.inl == at.inlined_at) break i;
    } else return;
    const d = st.decs.items[di];
    const w0 = word(st, di);
    const want: usize = if (d.class == .or_) 0 else 1;
    const arm = [2][]const u8{ "true", "false" };
    const tt = d.targets[want];
    const ot = d.targets[1 - want];
    const is_i1 = std.mem.startsWith(u8, rest, "i1 ");
    var ti: ?usize = null;
    if (ins.len == 2) {
        for (0..2) |x| {
            if (st.fun.under(from[x], tt, d.block) and st.fun.under(from[1 - x], ot, d.block)) ti = x;
        }
    }
    const k = ti orelse {
        const msg = std.fmt.allocPrint(st.alloc, "{s}: a short-circuit '{s}' (a br) whose result is not a phi at its location: its right operand cannot be counted (IR line {d}: the phi at this '{s}' does not join one value arriving under the branch's {s} target {s} and one under its {s} target {s}: {s})", .{ st.whereOf(d), w0, ln, w0, arm[want], tt, arm[1 - want], ot, t }) catch oom();
        noteOn(st, di, 1, msg);
        if (is_i1 and !forward(ins)) odd(st, di, msg);
        return;
    };
    if (!is_i1) {
        if (d.need == .phi) st.decs.items[di].need = .none; // a value and/or: no right operand decides
        return;
    }
    const kc: []const u8 = if (d.class == .or_) "true" else "false";
    const v = ins[k];
    const other = ins[1 - k];
    const deciding = std.mem.eql(u8, v, kc) or st.fun.reload(v, d.cond, from[k]);
    if (!deciding or isConst(other)) {
        // A raising right operand's error flag beside the result: false
        // when the right operand is skipped, the call's flag when it runs.
        if (std.mem.eql(u8, v, "false") and st.fun.ownFlag(other)) return;
        // The constant arriving under the other target is the phi of
        // another expression (`not a or b`): the right operand derived
        // from it would be wrong.
        const msg = if (std.mem.eql(u8, other, kc) and !isConst(v))
            std.fmt.allocPrint(st.alloc, "{s}: IR line {d}: the '{s}' of the phi at this '{s}' arrives from {s}, the branch's {s} target, not its {s} target ({s}): the right operand cannot be derived: {s}", .{ st.whereOf(d), ln, kc, w0, from[1 - k], arm[1 - want], arm[want], tt, t }) catch oom()
        else
            std.fmt.allocPrint(st.alloc, "{s}: IR line {d}: the phi at this '{s}' is not that of a short-circuit one (the value arriving under the branch's {s} target {s} is '{s}', not '{s}' or a reload of the left operand; the other is not a constant): {s}", .{ st.whereOf(d), ln, w0, arm[want], tt, v, kc, t }) catch oom();
        noteOn(st, di, 2, msg);
        odd(st, di, msg);
        return;
    }
    st.decs.items[di].need = .observe;
    st.awaits.put(t[0..eq], .{ .dec = di, .negated = false, .rhs = other }) catch oom();
}

/// Keeps `msg` as why and/or `di` has no result phi, unless one of a higher
/// rank (or an earlier one of its rank) is kept.
fn noteOn(st: *State, di: usize, rank: u8, msg: []const u8) void {
    const d = &st.decs.items[di];
    if (d.need != .phi or rank <= d.note_rank) return;
    d.note = msg;
    d.note_rank = rank;
}

/// The two targets of `br i1 %c, label %t, label %f, ...`: `%t`, `%f`
/// ("" when the text is not of that form, which no phi block matches).
fn brTargets(t: []const u8) [2][]const u8 {
    var out = [2][]const u8{ "", "" };
    var r = t["br i1 ".len..];
    for (&out) |*o| {
        const at = std.mem.indexOf(u8, r, ", label ") orelse return .{ "", "" };
        r = r[at + ", label ".len ..];
        o.* = operand(r);
    }
    return out;
}

/// The end of a function: an and/or with no result phi is refused; one
/// whose result no test read (or whose tests ran another number of times)
/// is its own two arms, unless a phi at its token is odd.
pub fn finish(st: *State) void {
    for (st.decs.items, 0..) |d, di| {
        if (d.need == .none) continue;
        const w0 = word(st, di);
        if (d.need == .phi) {
            if (d.note.len > 0) {
                st.err("{s}", .{d.note});
            } else {
                st.err("{s}: a short-circuit '{s}' (a br) whose result is not a phi at its location: its right operand cannot be counted", .{ st.whereOf(d), w0 });
            }
        } else if (d.odd.len > 0) {
            const why: []const u8 = if (d.unmatched.len > 0) d.unmatched else "no test in this function reads its result";
            st.err("{s}: the right operand of this '{s}' is not counted ({s}), and a phi at its location is neither its result nor an error flag, so the '{s}' cannot be told from it: {s}", .{ st.whereOf(d), w0, why, w0, d.odd });
        } else {
            st.escaped += 1;
        }
    }
}
