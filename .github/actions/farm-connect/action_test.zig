//! The cases of the farm-connect action (action.yml, next to this file),
//! //:farm_connect_cases: a `zig_test` run as a build action.
//!
//! The action's own bytes are the subject. The test reads action.yml (the
//! zig_test's `data`, under KOMIRA_TEST_WORK), takes the `run:` script and the
//! `env:` of each step, and runs the two steps that need no network, the
//! input check and the buckconfig writer, in that order, with the busybox
//! `sh` (the launcher's PATH) and a HOME of the case's own. Each step gets
//! its `env:` with every `${{ inputs.<name> }}` replaced by the case's value,
//! or else the input's `default:`. The tailnet join and the port probe are
//! skipped: a case that passes the check is one the action would go on to
//! connect with.
//!
//! What the cases catch:
//!  - the buckconfig written is compared whole, so a key dropped, renamed,
//!    added or given the wrong value (`tls = false` written whatever `tls`
//!    says, `tls_ca_certs` or the macOS keys written when not asked for, or
//!    not written when asked for) fails a case;
//!  - each refusal (macOS set without hosts and the reverse, a macOS set equal
//!    to the linux one, `tls` neither true nor false, a CA file with TLS off,
//!    relative, holding `$`, missing or a directory, a line break or carriage
//!    return in a value) is a case that must exit 1 with its message and write
//!    no buckconfig, so a check deleted or weakened fails it;
//!  - the checks must come before the tailnet join (the step order is pinned),
//!    no `run:` script may hold a `${{ }}` expression (script injection: inputs
//!    arrive through `env:` only), and every input is used and every use is a
//!    declared input;
//!  - every step of every workflow (the zig_test's `data`, under
//!    KOMIRA_TEST_WORK/workflows) that uses the action passes exactly
//!    `tls: ${{ vars.FARM_TLS || 'false' }}` under its `with:`, so a caller
//!    that drops `tls` (and connects in plain text whatever FARM_TLS says),
//!    hard-codes it, or loses the `|| 'false'` (an unset variable is then the
//!    empty string, which the action refuses) fails; a mention of the action
//!    outside a step's `uses:` fails too, so a caller the reader cannot see is
//!    not skipped. The reader's own cases are workflow texts written here.

const std = @import("std");
const t = std.testing;

const Input = struct { name: []const u8, default: ?[]const u8 };
const EnvVar = struct { name: []const u8, input: ?[]const u8, literal: []const u8 };
const Step = struct { name: []const u8, env: []const EnvVar, run: ?[]const u8 };
const Action = struct { inputs: []const Input, steps: []const Step, runs: []const u8 };

const CHECK = "the farm variables are set";
const JOIN = "join the tailnet";
const PROBE = "refuse unless the farm answers";
const WRITE = "write the farm's machine buckconfig";

fn indentOf(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    return i;
}

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return v;
}

/// The input named by a whole `${{ inputs.<name> }}` value, or null.
fn inputRef(v: []const u8) ?[]const u8 {
    const pre = "${{ inputs.";
    const post = " }}";
    if (std.mem.startsWith(u8, v, pre) and std.mem.endsWith(u8, v, post)) return v[pre.len .. v.len - post.len];
    return null;
}

/// The subset of YAML action.yml is written in: `inputs:` entries at indent
/// 2 with `default:` at 4, `runs:` > `steps:` items at indent 4 (`- `), their
/// keys at 6, `env:` entries at 8 and `run: |` scripts indented by 8.
fn parse(ar: std.mem.Allocator, text: []const u8) !Action {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(ar, l);
    const ls = lines.items;

    var inputs = std.ArrayList(Input).empty;
    var steps = std.ArrayList(Step).empty;
    var runs_at: ?usize = null;
    var section: enum { none, inputs, runs } = .none;
    var i: usize = 0;
    while (i < ls.len) : (i += 1) {
        const l = ls[i];
        if (l.len > 0 and l[0] != ' ' and l[0] != '#') {
            section = if (std.mem.eql(u8, l, "inputs:")) .inputs else if (std.mem.eql(u8, l, "runs:")) .runs else .none;
            if (section == .runs) runs_at = std.mem.indexOf(u8, text, "\nruns:\n").? + 1;
            continue;
        }
        switch (section) {
            .none => {},
            .inputs => {
                if (indentOf(l) == 2 and std.mem.endsWith(u8, l, ":")) {
                    try inputs.append(ar, .{ .name = l[2 .. l.len - 1], .default = null });
                } else if (indentOf(l) == 4 and std.mem.startsWith(u8, l[4..], "default: ")) {
                    inputs.items[inputs.items.len - 1].default = unquote(l[4 + "default: ".len ..]);
                }
            },
            .runs => {
                if (indentOf(l) == 4 and std.mem.startsWith(u8, l[4..], "- ")) {
                    try steps.append(ar, .{ .name = "", .env = &.{}, .run = null });
                    // A step's first key may sit on the `- ` line.
                    if (std.mem.startsWith(u8, l[6..], "name: ")) steps.items[steps.items.len - 1].name = l[6 + "name: ".len ..];
                    continue;
                }
                if (steps.items.len == 0) continue;
                const s = &steps.items[steps.items.len - 1];
                if (indentOf(l) != 6) continue;
                const key = l[6..];
                if (std.mem.startsWith(u8, key, "name: ")) {
                    s.name = key["name: ".len..];
                } else if (std.mem.eql(u8, key, "env:")) {
                    var env = std.ArrayList(EnvVar).empty;
                    while (i + 1 < ls.len and indentOf(ls[i + 1]) == 8 and ls[i + 1].len > 8) : (i += 1) {
                        const e = ls[i + 1][8..];
                        const colon = std.mem.indexOf(u8, e, ": ") orelse return error.BadEnvLine;
                        const value = e[colon + 2 ..];
                        try env.append(ar, .{ .name = e[0..colon], .input = inputRef(value), .literal = value });
                    }
                    s.env = env.items;
                } else if (std.mem.eql(u8, key, "run: |")) {
                    var body = std.ArrayList(u8).empty;
                    while (i + 1 < ls.len and (ls[i + 1].len == 0 or indentOf(ls[i + 1]) >= 8)) : (i += 1) {
                        const b = ls[i + 1];
                        if (b.len > 0) try body.appendSlice(ar, b[8..]);
                        try body.append(ar, '\n');
                    }
                    s.run = body.items;
                }
            },
        }
    }
    return .{ .inputs = inputs.items, .steps = steps.items, .runs = text[runs_at orelse return error.NoRuns ..] };
}

fn loadAction(ar: std.mem.Allocator) !Action {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(ar, &.{ work, "action.yml" });
    const text = try std.fs.cwd().readFileAlloc(ar, path, 1 << 20);
    return parse(ar, text);
}

fn step(action: Action, name: []const u8) !Step {
    for (action.steps) |s| if (std.mem.eql(u8, s.name, name)) return s;
    std.debug.print("action.yml has no step named '{s}'\n", .{name});
    return error.NoSuchStep;
}

const Value = struct { name: []const u8, value: []const u8 };

const Outcome = struct {
    /// The exit status of the first step that failed, or 0.
    code: u8,
    out: []const u8,
    /// $HOME/.buckconfig.d/farm.buckconfig, or null when none was written.
    buckconfig: ?[]const u8,
};

/// The required inputs of every case; a case's values replace or add to them.
const BASE = [_]Value{
    .{ .name = "ts-client-id", .value = "client-id" },
    .{ .name = "ts-audience", .value = "audience" },
    .{ .name = "farm-address", .value = "grpc://re.example.com:8980" },
    .{ .name = "farm-instance", .value = "main" },
    .{ .name = "farm-properties", .value = "OSFamily=Linux,pool=linux" },
};

fn valueOf(action: Action, values: []const Value, name: []const u8) ![]const u8 {
    var i = values.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, values[i].name, name)) return values[i].value;
    }
    for (BASE) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
    for (action.inputs) |in| if (std.mem.eql(u8, in.name, name)) return in.default orelse "";
    std.debug.print("a step reads input '{s}', which action.yml does not declare\n", .{name});
    return error.UndeclaredInput;
}

/// Runs the check, then the writer, as the runner would (bash -e there,
/// busybox sh -e here: the scripts are POSIX sh), in a HOME of its own.
fn runAction(ar: std.mem.Allocator, values: []const Value) !Outcome {
    const action = try loadAction(ar);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(ar, ".");
    var out = std.ArrayList(u8).empty;
    for ([_][]const u8{ CHECK, WRITE }) |name| {
        const s = try step(action, name);
        var env = std.process.EnvMap.init(ar);
        try env.put("PATH", try std.process.getEnvVarOwned(ar, "PATH"));
        try env.put("HOME", home);
        for (s.env) |e| try env.put(e.name, if (e.input) |in| try valueOf(action, values, in) else e.literal);
        const r = try std.process.Child.run(.{
            .allocator = ar,
            .argv = &.{ "sh", "-e", "-c", s.run.? },
            .env_map = &env,
        });
        try out.appendSlice(ar, r.stdout);
        try out.appendSlice(ar, r.stderr);
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        };
        if (code != 0) return .{ .code = code, .out = out.items, .buckconfig = readBuckconfig(ar, tmp.dir) };
    }
    return .{ .code = 0, .out = out.items, .buckconfig = readBuckconfig(ar, tmp.dir) };
}

fn readBuckconfig(ar: std.mem.Allocator, home: std.fs.Dir) ?[]const u8 {
    return home.readFileAlloc(ar, ".buckconfig.d/farm.buckconfig", 1 << 20) catch null;
}

fn expectWritten(values: []const Value, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try runAction(arena.allocator(), values);
    if (o.code != 0) std.debug.print("the action failed ({d}):\n{s}\n", .{ o.code, o.out });
    try t.expectEqual(@as(u8, 0), o.code);
    try t.expectEqualStrings(want, o.buckconfig orelse "<no buckconfig written>");
}

fn expectRefused(values: []const Value, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try runAction(arena.allocator(), values);
    if (o.code != 1 or std.mem.indexOf(u8, o.out, message) == null)
        std.debug.print("want exit 1 and '{s}'; got exit {d}:\n{s}\n", .{ message, o.code, o.out });
    try t.expectEqual(@as(u8, 1), o.code);
    try t.expect(std.mem.indexOf(u8, o.out, "::error title=farm-connect::") != null);
    try t.expect(std.mem.indexOf(u8, o.out, message) != null);
    try t.expect(o.buckconfig == null);
}

const LINUX_ONLY =
    \\[buck2_re_client]
    \\  engine_address = grpc://re.example.com:8980
    \\  action_cache_address = grpc://re.example.com:8980
    \\  cas_address = grpc://re.example.com:8980
    \\  instance_name = main
    \\  tls = false
    \\  execution_concurrency_limit = 256
    \\[komira_re]
    \\  linux_x86_64_properties = OSFamily=Linux,pool=linux
    \\
;

// ---- what the action writes ----------------------------------------------

test "the required inputs alone: the linux-only, plain-text buckconfig" {
    try expectWritten(&.{}, LINUX_ONLY);
}

test "macOS properties and hosts: both keys under [komira_re], after the linux set" {
    try expectWritten(&.{
        .{ .name = "darwin-properties", .value = "OSFamily=Darwin,label.pool=mac" },
        .{ .name = "darwin-macos-hosts", .value = "26.5-0123456789abcdef 27.0-fedcba9876543210" },
        .{ .name = "execution-concurrency-limit", .value = "64" },
    },
        \\[buck2_re_client]
        \\  engine_address = grpc://re.example.com:8980
        \\  action_cache_address = grpc://re.example.com:8980
        \\  cas_address = grpc://re.example.com:8980
        \\  instance_name = main
        \\  tls = false
        \\  execution_concurrency_limit = 64
        \\[komira_re]
        \\  linux_x86_64_properties = OSFamily=Linux,pool=linux
        \\  darwin_arm64_properties = OSFamily=Darwin,label.pool=mac
        \\  darwin_macos_hosts = 26.5-0123456789abcdef 27.0-fedcba9876543210
        \\
    );
}

test "tls true with no CA file: tls = true and no tls_ca_certs (the system's roots)" {
    try expectWritten(&.{.{ .name = "tls", .value = "true" }},
        \\[buck2_re_client]
        \\  engine_address = grpc://re.example.com:8980
        \\  action_cache_address = grpc://re.example.com:8980
        \\  cas_address = grpc://re.example.com:8980
        \\  instance_name = main
        \\  tls = true
        \\  execution_concurrency_limit = 256
        \\[komira_re]
        \\  linux_x86_64_properties = OSFamily=Linux,pool=linux
        \\
    );
}

test "tls false said outright is the default's buckconfig" {
    try expectWritten(&.{.{ .name = "tls", .value = "false" }}, LINUX_ONLY);
}

test "tls true with a CA file: tls_ca_certs names that path" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "ca.pem", .data = "not parsed by the action\n" });
    const ca = try tmp.dir.realpathAlloc(ar, "ca.pem");
    const want = try std.fmt.allocPrint(ar,
        \\[buck2_re_client]
        \\  engine_address = grpc://re.example.com:8980
        \\  action_cache_address = grpc://re.example.com:8980
        \\  cas_address = grpc://re.example.com:8980
        \\  instance_name = main
        \\  tls = true
        \\  tls_ca_certs = {s}
        \\  execution_concurrency_limit = 256
        \\[komira_re]
        \\  linux_x86_64_properties = OSFamily=Linux,pool=linux
        \\
    , .{ca});
    try expectWritten(&.{ .{ .name = "tls", .value = "true" }, .{ .name = "tls-ca-certs", .value = ca } }, want);
}

// ---- what the action refuses ---------------------------------------------

test "macOS properties without hosts are refused" {
    try expectRefused(&.{.{ .name = "darwin-properties", .value = "OSFamily=Darwin" }}, "darwin-properties is set but darwin-macos-hosts is empty");
}

test "macOS hosts without properties are refused" {
    try expectRefused(&.{.{ .name = "darwin-macos-hosts", .value = "26.5-0123456789abcdef" }}, "darwin-macos-hosts is set but darwin-properties is empty");
}

test "a macOS set equal to the linux set is refused" {
    try expectRefused(&.{
        .{ .name = "darwin-properties", .value = "OSFamily=Linux,pool=linux" },
        .{ .name = "darwin-macos-hosts", .value = "26.5-0123456789abcdef" },
    }, "darwin-properties equals farm-properties");
}

test "tls neither true nor false is refused, the empty string included" {
    try expectRefused(&.{.{ .name = "tls", .value = "yes" }}, "tls is 'yes', not true or false");
    try expectRefused(&.{.{ .name = "tls", .value = "" }}, "tls is '', not true or false");
    try expectRefused(&.{.{ .name = "tls", .value = "True" }}, "not true or false");
}

test "a CA file with tls false is refused" {
    try expectRefused(&.{.{ .name = "tls-ca-certs", .value = "/etc/hostname" }}, "tls-ca-certs is set but tls is false");
}

test "a relative CA path is refused" {
    try expectRefused(&.{ .{ .name = "tls", .value = "true" }, .{ .name = "tls-ca-certs", .value = "ca.pem" } }, "tls-ca-certs is not an absolute path");
}

test "a CA path holding $ is refused" {
    try expectRefused(&.{ .{ .name = "tls", .value = "true" }, .{ .name = "tls-ca-certs", .value = "/$HOME/ca.pem" } }, "tls-ca-certs holds a $");
}

test "a CA path that is missing, or a directory, is refused" {
    try expectRefused(&.{ .{ .name = "tls", .value = "true" }, .{ .name = "tls-ca-certs", .value = "/nonexistent/ca.pem" } }, "tls-ca-certs is not a readable file on this runner");
    try expectRefused(&.{ .{ .name = "tls", .value = "true" }, .{ .name = "tls-ca-certs", .value = "/" } }, "tls-ca-certs is not a readable file on this runner");
}

test "a line break or carriage return in any value written is refused" {
    const msg = "an input holds a line break";
    const names = [_][]const u8{ "farm-address", "farm-instance", "farm-properties", "darwin-properties", "darwin-macos-hosts", "tls", "tls-ca-certs" };
    for (names) |name| {
        // The macOS pair is given whole, so only the line break can be refused.
        try expectRefused(&.{
            .{ .name = "darwin-properties", .value = "OSFamily=Darwin" },
            .{ .name = "darwin-macos-hosts", .value = "26.5-0123456789abcdef" },
            .{ .name = name, .value = "x\n[buck2_re_client]\n  tls = false" },
        }, msg);
        try expectRefused(&.{
            .{ .name = "darwin-properties", .value = "OSFamily=Darwin" },
            .{ .name = "darwin-macos-hosts", .value = "26.5-0123456789abcdef" },
            .{ .name = name, .value = "x\r" },
        }, msg);
    }
}

test "an empty required input is refused by name" {
    try expectRefused(&.{.{ .name = "farm-address", .value = "" }}, "these repository variables are empty: FARM_ADDRESS");
    try expectRefused(&.{.{ .name = "farm-properties", .value = "" }}, "FARM_LINUX_X86_64_PROPERTIES");
}

test "a concurrency limit that is not a number is refused" {
    try expectRefused(&.{.{ .name = "execution-concurrency-limit", .value = "64x" }}, "execution-concurrency-limit is not a number");
}

// ---- the shape of the action ---------------------------------------------

test "the steps run in this order: the check comes before the tailnet join" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const action = try loadAction(arena.allocator());
    const want = [_][]const u8{ CHECK, JOIN, PROBE, WRITE };
    try t.expectEqual(want.len, action.steps.len);
    for (want, action.steps) |w, s| try t.expectEqualStrings(w, s.name);
}

test "no run script holds a ${{ }} expression: inputs arrive through env only" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const action = try loadAction(arena.allocator());
    var scripts: usize = 0;
    for (action.steps) |s| {
        const r = s.run orelse continue;
        scripts += 1;
        if (std.mem.indexOf(u8, r, "${{") != null) std.debug.print("step '{s}' has an expression in its script\n", .{s.name});
        try t.expect(std.mem.indexOf(u8, r, "${{") == null);
    }
    try t.expectEqual(@as(usize, 3), scripts);
}

test "every input is used, and every use names a declared input" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const action = try loadAction(ar);
    try t.expectEqual(@as(usize, 10), action.inputs.len);
    for (action.inputs) |in| {
        const use = try std.fmt.allocPrint(ar, "${{{{ inputs.{s} }}}}", .{in.name});
        if (std.mem.indexOf(u8, action.runs, use) == null) std.debug.print("input '{s}' is never used\n", .{in.name});
        try t.expect(std.mem.indexOf(u8, action.runs, use) != null);
    }
    var rest = action.runs;
    var uses: usize = 0;
    while (std.mem.indexOf(u8, rest, "inputs.")) |at| {
        rest = rest[at + "inputs.".len ..];
        const end = std.mem.indexOfAny(u8, rest, " }\n") orelse rest.len;
        uses += 1;
        var declared = false;
        for (action.inputs) |in| declared = declared or std.mem.eql(u8, in.name, rest[0..end]);
        if (!declared) std.debug.print("inputs.{s} is not declared\n", .{rest[0..end]});
        try t.expect(declared);
    }
    try t.expect(uses >= action.inputs.len);
}

// ---- the workflows that call the action ----------------------------------

const ACTION_REF = "./.github/actions/farm-connect";
const TLS_VALUE = "${{ vars.FARM_TLS || 'false' }}";

const Caller = struct {
    /// 1-based line of the step's `uses:`.
    line: usize,
    /// The value of `tls:` under the step's `with:`, or null when it has none.
    tls: ?[]const u8,
};

const Callers = struct {
    callers: []const Caller,
    /// 1-based lines that name the action but are no step's `uses:` of it
    /// (comments excluded): a caller this reader cannot see.
    unread: []const usize,
};

fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, " \t\r");
}

fn isComment(l: []const u8) bool {
    const rest = l[indentOf(l)..];
    return rest.len > 0 and rest[0] == '#';
}

fn isBlank(l: []const u8) bool {
    return trimRight(l).len == 0;
}

/// Whether `l` names the farm-connect action: `actions/farm-connect` not
/// followed by a character of a longer name (`farm-connect-other`).
fn mentionsAction(l: []const u8) bool {
    const needle = "actions/farm-connect";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, l, from, needle)) |at| {
        const after = at + needle.len;
        if (after == l.len) return true;
        const c = l[after];
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return true;
        from = after;
    }
    return false;
}

fn unquoteAny(v: []const u8) []const u8 {
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) return v[1 .. v.len - 1];
    return v;
}

/// The steps of a workflow that use the farm-connect action. A step is a
/// block-style sequence item (`- `); its `uses:` is on the `- ` line or a key
/// of the item; its `with:` is a key of the same item, a block mapping whose
/// entries are one indent deeper.
fn farmConnectCallers(ar: std.mem.Allocator, text: []const u8) !Callers {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(ar, l);
    const ls = lines.items;

    var callers = std.ArrayList(Caller).empty;
    var unread = std.ArrayList(usize).empty;
    for (ls, 0..) |l, i| {
        if (isComment(l) or !mentionsAction(l)) continue;
        const ind = indentOf(l);
        var rest = l[ind..];
        var dash = false;
        if (std.mem.startsWith(u8, rest, "- ")) {
            dash = true;
            rest = rest[2..];
        }
        const key_ind = if (dash) ind + 2 else ind;
        const value = if (std.mem.startsWith(u8, rest, "uses: ")) unquoteAny(trimRight(rest["uses: ".len..])) else "";
        if (!(std.mem.eql(u8, value, ACTION_REF) or std.mem.eql(u8, value, ACTION_REF ++ "/")) or key_ind < 2) {
            try unread.append(ar, i + 1);
            continue;
        }
        // The item's `- ` line: this line, or the nearest line above at the
        // item's indent that opens one.
        var start = i;
        if (!dash) {
            var found = false;
            var j = i;
            while (j > 0) {
                j -= 1;
                const p = ls[j];
                if (isBlank(p) or isComment(p)) continue;
                if (indentOf(p) == key_ind - 2 and std.mem.startsWith(u8, p[key_ind - 2 ..], "- ")) {
                    start = j;
                    found = true;
                    break;
                }
                if (indentOf(p) < key_ind) break;
            }
            if (!found) {
                try unread.append(ar, i + 1);
                continue;
            }
        }
        // The item ends at the next line indented no deeper than its `- `.
        var end = start + 1;
        while (end < ls.len and (isBlank(ls[end]) or isComment(ls[end]) or indentOf(ls[end]) >= key_ind)) end += 1;
        var tls: ?[]const u8 = null;
        var k = start;
        while (k < end) : (k += 1) {
            const kl = ls[k];
            // The `- ` line's key starts after the dash; any other key of
            // the item sits at the same indent.
            if (k != start and (indentOf(kl) != key_ind or isComment(kl))) continue;
            if (!std.mem.eql(u8, trimRight(kl[key_ind..]), "with:")) continue;
            var m = k + 1;
            var entry_ind: ?usize = null;
            while (m < end) : (m += 1) {
                const ml = ls[m];
                if (isBlank(ml) or isComment(ml)) continue;
                if (indentOf(ml) <= key_ind) break;
                if (entry_ind == null) entry_ind = indentOf(ml);
                if (indentOf(ml) != entry_ind.?) continue;
                const e = ml[entry_ind.?..];
                if (std.mem.startsWith(u8, e, "tls: ")) tls = trimRight(e["tls: ".len..]);
            }
        }
        try callers.append(ar, .{ .line = i + 1, .tls = tls });
    }
    return .{ .callers = callers.items, .unread = unread.items };
}

/// The callers of `text` that do not pass `tls: <TLS_VALUE>`, printed, and
/// the lines naming the action that are no caller; their total.
fn wrongCallers(ar: std.mem.Allocator, file: []const u8, text: []const u8) !struct { callers: usize, wrong: usize } {
    const cs = try farmConnectCallers(ar, text);
    var wrong: usize = 0;
    for (cs.callers) |c| {
        if (c.tls != null and std.mem.eql(u8, c.tls.?, TLS_VALUE)) continue;
        wrong += 1;
        std.debug.print("{s}:{d}: the farm-connect step passes tls: {s}; want tls: {s}\n", .{ file, c.line, c.tls orelse "<none>", TLS_VALUE });
    }
    for (cs.unread) |n| {
        wrong += 1;
        std.debug.print("{s}:{d}: names the farm-connect action outside a step's `uses:`\n", .{ file, n });
    }
    return .{ .callers = cs.callers.len, .wrong = wrong };
}

fn expectCallers(text: []const u8, want: []const Caller, want_unread: []const usize) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try farmConnectCallers(arena.allocator(), text);
    try t.expectEqual(want.len, got.callers.len);
    for (want, got.callers) |w, g| {
        try t.expectEqual(w.line, g.line);
        if (w.tls) |wt| try t.expectEqualStrings(wt, g.tls orelse "<none>") else try t.expect(g.tls == null);
    }
    try t.expectEqualSlices(usize, want_unread, got.unread);
}

test "reader: a caller on its `- uses:` line, and one whose `uses:` follows its name" {
    try expectCallers(
        \\jobs:
        \\  a:
        \\    steps:
        \\      - uses: ./.github/actions/farm-connect
        \\        with:
        \\          farm-address: ${{ vars.FARM_ADDRESS }}
        \\          tls: ${{ vars.FARM_TLS || 'false' }}
        \\      - name: connect
        \\        if: always()
        \\        # a comment between keys
        \\        uses: "./.github/actions/farm-connect/"
        \\        with:
        \\
        \\          tls: ${{ vars.FARM_TLS || 'false' }}   
        \\      - run: true
        \\
    , &.{ .{ .line = 4, .tls = TLS_VALUE }, .{ .line = 11, .tls = TLS_VALUE } }, &.{});
}

test "reader: a caller without tls, and one whose tls is a value of its own" {
    try expectCallers(
        \\    steps:
        \\      - uses: ./.github/actions/farm-connect
        \\        with:
        \\          farm-address: ${{ vars.FARM_ADDRESS }}
        \\      - uses: ./.github/actions/farm-connect
        \\        with:
        \\          tls: ${{ vars.FARM_TLS }}
        \\      - uses: ./.github/actions/farm-connect
        \\
    , &.{ .{ .line = 2, .tls = null }, .{ .line = 5, .tls = "${{ vars.FARM_TLS }}" }, .{ .line = 8, .tls = null } }, &.{});
}

test "reader: tls of the next step, or nested deeper, or outside with:, is not the caller's" {
    try expectCallers(
        \\    steps:
        \\      - uses: ./.github/actions/farm-connect
        \\        with:
        \\          farm-address: ${{ vars.FARM_ADDRESS }}
        \\          other:
        \\            tls: ${{ vars.FARM_TLS || 'false' }}
        \\        env:
        \\          tls: ${{ vars.FARM_TLS || 'false' }}
        \\      - uses: ./.github/actions/other
        \\        with:
        \\          tls: ${{ vars.FARM_TLS || 'false' }}
        \\
    , &.{.{ .line = 2, .tls = null }}, &.{});
}

test "reader: a mention that is no step's uses: is reported, a comment or another action is not" {
    try expectCallers(
        \\# uses: ./.github/actions/farm-connect
        \\    steps:
        \\      - uses: ./.github/actions/farm-connect-other
        \\      - run: echo ./.github/actions/farm-connect
        \\      - uses: ./.github/actions/farm-connect@v1
        \\
    , &.{}, &.{ 4, 5 });
}

test "every workflow step that uses the action passes tls from FARM_TLS" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    var dir = try std.fs.cwd().openDir(try std.fs.path.join(ar, &.{ work, "workflows" }), .{ .iterate = true });
    defer dir.close();
    var files: usize = 0;
    var callers: usize = 0;
    var wrong: usize = 0;
    var di = dir.iterate();
    while (try di.next()) |e| {
        if (!std.mem.endsWith(u8, e.name, ".yml")) continue;
        files += 1;
        const text = try dir.readFileAlloc(ar, e.name, 1 << 20);
        const r = try wrongCallers(ar, e.name, text);
        callers += r.callers;
        wrong += r.wrong;
    }
    // The staged workflows are read, and the action has callers: a staging
    // or reader fault would otherwise pass with nothing checked.
    try t.expect(files > 0);
    try t.expect(callers > 0);
    try t.expectEqual(@as(usize, 0), wrong);
}
