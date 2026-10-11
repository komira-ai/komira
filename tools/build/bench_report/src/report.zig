//! The bench report schema, `komira-bench-report-1`: what a report test
//! writes, checked key by key. A key the schema does not name is an error,
//! so a misspelt field is refused rather than dropped.
//!
//!   run_id, target   strings, written by the py_test runner
//!   schema           "komira-bench-report-1"
//!   host             cpus (affinity size, >= 1), cpu_model, cpu_max (cgroup cpu.max),
//!                    loadavg [3 numbers], nr_throttled_delta, throttled_usec_delta
//!   build            opt_levels {component: "0".."3"} (at least one), coverage (bool),
//!                    versions {name: version}
//!   rows             at least one row:
//!     variant, function   names: a-z 0-9 _ '
//!     threads             >= 1
//!     rows, batches, calls  >= 1, and calls == batches (a runtime call per batch, never per row)
//!     wall_ns             >= 1; cpu_user_ns, cpu_sys_ns, invol_ctx_switches >= 0
//!     memory              {pss | uss | rss_delta_per_thread | memory_report: bytes}, at
//!                         least one; memory_report is what the runtime's `memory_report`
//!                         entry returned (bytes it holds outside Arrow buffers)
//!     latency_ns          warmup_discarded >= 0, samples >= 30, min <= median <= p90 <= max
//!
//! Counts are JSON numbers that must be whole and at most 2^53.

const std = @import("std");
const C = @import("common.zig");
const J = @import("json.zig");
const Fail = C.Fail;
const Value = J.Value;

pub const schema = "komira-bench-report-1";

/// Language-neutral kinds only: what a runtime holds beyond the process
/// measures is its `memory_report`.
pub const memory_kinds = [_][]const u8{ "pss", "uss", "rss_delta_per_thread", "memory_report" };

pub const Pair = struct { k: []const u8, v: []const u8 };
pub const Mem = struct { k: []const u8, bytes: u64 };

pub const Host = struct {
    cpus: u64,
    cpu_model: []const u8,
    cpu_max: []const u8,
    loadavg: [3]f64,
    nr_throttled_delta: u64,
    throttled_usec_delta: u64,
};

pub const Build = struct {
    opt_levels: []const Pair,
    coverage: bool,
    versions: []const Pair,
};

pub const Latency = struct {
    warmup_discarded: u64,
    samples: u64,
    min: u64,
    median: u64,
    p90: u64,
    max: u64,
};

pub const Row = struct {
    variant: []const u8,
    function: []const u8,
    threads: u64,
    rows: u64,
    batches: u64,
    calls: u64,
    wall_ns: u64,
    cpu_user_ns: u64,
    cpu_sys_ns: u64,
    invol_ctx_switches: u64,
    memory: []const Mem,
    latency: Latency,
};

pub const Report = struct {
    run_id: []const u8,
    target: []const u8,
    host: Host,
    build: Build,
    rows: []const Row,
};

fn join(path: []const u8, key: []const u8) []const u8 {
    return if (path.len == 0) key else C.fmt("{s}.{s}", .{ path, key });
}

const Got = struct { v: Value, p: []const u8 };

/// One object, read key by key: every key must be taken.
const Obj = struct {
    path: []const u8,
    fields: []const J.Member,
    taken: std.ArrayList([]const u8),

    fn get(self: *Obj, key: []const u8) Fail!Got {
        C.push([]const u8, &self.taken, key);
        const p = join(self.path, key);
        for (self.fields) |m| {
            if (C.eql(m.k, key)) return .{ .v = m.v, .p = p };
        }
        return C.fail("{s}: missing", .{p});
    }

    fn str(self: *Obj, key: []const u8) Fail![]const u8 {
        const g = try self.get(key);
        return string(g.p, g.v);
    }

    fn cnt(self: *Obj, key: []const u8, min: u64) Fail!u64 {
        const g = try self.get(key);
        return count(g.p, g.v, min);
    }

    /// Fails on the first key that was not taken.
    fn done(self: *const Obj) Fail!void {
        for (self.fields) |m| {
            const taken = for (self.taken.items) |t| {
                if (C.eql(t, m.k)) break true;
            } else false;
            if (!taken) return C.fail("{s}: not a key of the schema", .{join(self.path, m.k)});
        }
    }
};

fn obj(path: []const u8, v: Value) Fail!Obj {
    return switch (v) {
        .obj => |fields| Obj{ .path = path, .fields = fields, .taken = C.list([]const u8) },
        else => C.fail("{s}: is {s}, not an object", .{ if (path.len == 0) "report" else path, v.kind() }),
    };
}

fn string(path: []const u8, v: Value) Fail![]const u8 {
    switch (v) {
        .str => |s| {
            if (s.len == 0) return C.fail("{s}: is empty", .{path});
            return s;
        },
        else => return C.fail("{s}: is {s}, not a string", .{ path, v.kind() }),
    }
}

fn number(path: []const u8, v: Value) Fail!f64 {
    return switch (v) {
        .num => |n| n,
        else => C.fail("{s}: is {s}, not a number", .{ path, v.kind() }),
    };
}

const max_count: f64 = 9007199254740992.0; // 2^53

fn count(path: []const u8, v: Value, min: u64) Fail!u64 {
    const n = try number(path, v);
    if (n != @floor(n) or n < 0 or n > max_count) {
        return C.fail("{s}: {d} is not a whole number from 0 to 2^53", .{ path, n });
    }
    const u: u64 = @intFromFloat(n);
    if (u < min) return C.fail("{s}: {d} is below {d}", .{ path, u, min });
    return u;
}

fn name(path: []const u8, v: Value) Fail![]const u8 {
    const s = try string(path, v);
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '\'';
        if (!ok) return C.fail("{s}: '{s}' is not a name (a-z 0-9 _ ')", .{ path, s });
    }
    return s;
}

/// An object of string values, in the order written.
fn stringMap(path: []const u8, v: Value, allow_empty: bool) Fail![]const Pair {
    const o = try obj(path, v);
    if (o.fields.len == 0 and !allow_empty) return C.fail("{s}: is empty", .{path});
    var out = C.list(Pair);
    for (o.fields) |m| C.push(Pair, &out, .{ .k = m.k, .v = try string(join(path, m.k), m.v) });
    return out.items;
}

fn host(path: []const u8, v: Value) Fail!Host {
    var o = try obj(path, v);
    const cpus = try o.cnt("cpus", 1);
    const cpu_model = try o.str("cpu_model");
    const cpu_max = try o.str("cpu_max");
    const l = try o.get("loadavg");
    var loadavg: [3]f64 = undefined;
    const three = switch (l.v) {
        .arr => |items| if (items.len == 3) items else null,
        else => null,
    } orelse return C.fail("{s}: is not an array of three numbers", .{l.p});
    for (three, 0..) |x, i| {
        const p = C.fmt("{s}[{d}]", .{ l.p, i });
        loadavg[i] = try number(p, x);
        if (loadavg[i] < 0) return C.fail("{s}: {d} is negative", .{ p, loadavg[i] });
    }
    const nr = try o.cnt("nr_throttled_delta", 0);
    const usec = try o.cnt("throttled_usec_delta", 0);
    try o.done();
    return .{ .cpus = cpus, .cpu_model = cpu_model, .cpu_max = cpu_max, .loadavg = loadavg, .nr_throttled_delta = nr, .throttled_usec_delta = usec };
}

fn build(path: []const u8, v: Value) Fail!Build {
    var o = try obj(path, v);
    const og = try o.get("opt_levels");
    const opt_levels = try stringMap(og.p, og.v, false);
    for (opt_levels) |kv| {
        const ok = kv.v.len == 1 and kv.v[0] >= '0' and kv.v[0] <= '3';
        if (!ok) return C.fail("{s}: '{s}' is not one of 0, 1, 2, 3", .{ join(og.p, kv.k), kv.v });
    }
    const cg = try o.get("coverage");
    const coverage = switch (cg.v) {
        .boolean => |b| b,
        else => return C.fail("{s}: is {s}, not a boolean", .{ cg.p, cg.v.kind() }),
    };
    const vg = try o.get("versions");
    const versions = try stringMap(vg.p, vg.v, true);
    try o.done();
    return .{ .opt_levels = opt_levels, .coverage = coverage, .versions = versions };
}

fn latency(path: []const u8, v: Value) Fail!Latency {
    var o = try obj(path, v);
    const l = Latency{
        .warmup_discarded = try o.cnt("warmup_discarded", 0),
        .samples = try o.cnt("samples", 30),
        .min = try o.cnt("min", 0),
        .median = try o.cnt("median", 0),
        .p90 = try o.cnt("p90", 0),
        .max = try o.cnt("max", 0),
    };
    try o.done();
    if (!(l.min <= l.median and l.median <= l.p90 and l.p90 <= l.max)) {
        return C.fail("{s}: min {d} <= median {d} <= p90 {d} <= max {d} does not hold", .{ path, l.min, l.median, l.p90, l.max });
    }
    return l;
}

fn memory(path: []const u8, v: Value) Fail![]const Mem {
    const m = try obj(path, v);
    if (m.fields.len == 0) return C.fail("{s}: is empty", .{path});
    var out = C.list(Mem);
    for (m.fields) |f| {
        const p = join(path, f.k);
        const known = for (memory_kinds) |k| {
            if (C.eql(k, f.k)) break true;
        } else false;
        if (!known) return C.fail("{s}: not a memory kind ({s})", .{ p, C.join(&memory_kinds, ", ") });
        C.push(Mem, &out, .{ .k = f.k, .bytes = try count(p, f.v, 0) });
    }
    return out.items;
}

fn row(path: []const u8, v: Value) Fail!Row {
    var o = try obj(path, v);
    const vg = try o.get("variant");
    const variant = try name(vg.p, vg.v);
    const fg = try o.get("function");
    const function = try name(fg.p, fg.v);
    const threads = try o.cnt("threads", 1);
    const rows = try o.cnt("rows", 1);
    const batches = try o.cnt("batches", 1);
    const calls = try o.cnt("calls", 1);
    const wall_ns = try o.cnt("wall_ns", 1);
    const cpu_user_ns = try o.cnt("cpu_user_ns", 0);
    const cpu_sys_ns = try o.cnt("cpu_sys_ns", 0);
    const invol = try o.cnt("invol_ctx_switches", 0);
    const mg = try o.get("memory");
    const mem = try memory(mg.p, mg.v);
    const lg = try o.get("latency_ns");
    const lat = try latency(lg.p, lg.v);
    try o.done();
    if (calls != batches) {
        return C.fail("{s}: {d} runtime calls for {d} batches; a runtime is called once per batch", .{ path, calls, batches });
    }
    return .{
        .variant = variant,
        .function = function,
        .threads = threads,
        .rows = rows,
        .batches = batches,
        .calls = calls,
        .wall_ns = wall_ns,
        .cpu_user_ns = cpu_user_ns,
        .cpu_sys_ns = cpu_sys_ns,
        .invol_ctx_switches = invol,
        .memory = mem,
        .latency = lat,
    };
}

/// Checks one parsed report against the schema.
pub fn check(v: Value) Fail!Report {
    var o = try obj("", v);
    const run_id = try o.str("run_id");
    const target = try o.str("target");
    const sg = try o.get("schema");
    const is_schema = switch (sg.v) {
        .str => |s| C.eql(s, schema),
        else => false,
    };
    if (!is_schema) return C.fail("{s}: is not \"{s}\"", .{ sg.p, schema });
    const hg = try o.get("host");
    const h = try host(hg.p, hg.v);
    const bg = try o.get("build");
    const b = try build(bg.p, bg.v);
    const rg = try o.get("rows");
    var rows = C.list(Row);
    switch (rg.v) {
        .arr => |items| {
            if (items.len == 0) return C.fail("{s}: is empty", .{rg.p});
            for (items, 0..) |r, i| C.push(Row, &rows, try row(C.fmt("{s}[{d}]", .{ rg.p, i }), r));
        },
        else => return C.fail("{s}: is {s}, not an array", .{ rg.p, rg.v.kind() }),
    }
    try o.done();
    return .{ .run_id = run_id, .target = target, .host = h, .build = b, .rows = rows.items };
}
