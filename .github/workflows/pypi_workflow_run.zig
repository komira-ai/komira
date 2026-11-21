//! A run of pypi.yml played from the workflow's own text, for each answer an index gives (`absent`,
//! `same`, `differs`) and for the failure of a job: which jobs run and which are skipped, what the
//! two verdict jobs (`result`, `result-macos-arm64`) print, and whether the run ends green. Part of
//! //:pypi_workflow_cases (pypi_workflow_test.zig imports this file).
//!
//! The play holds the part of GitHub's rules the file uses and refuses anything else by name, so an
//! edit the play cannot read fails the cases instead of passing them:
//!  - the jobs run in file order (each job's `needs:` are above it);
//!  - a job whose `if:` has no `always()` runs only when every job it needs succeeded, else it is
//!    skipped; then its `if:` decides; a skipped job's outputs are empty;
//!  - an expression is a string literal, `github.ref` (a run of this file is on main), `github.event_name`,
//!    `inputs.<name>` (empty in a scheduled run, which has no inputs), `needs.<job>.result` and
//!    `needs.<job>.outputs.<name>` of a job the reading job needs, `always()`, `!`, `==`, `!=`, `&&`,
//!    `||` and parentheses, with GitHub's values: `||` and `&&` give one of their operands, and an
//!    empty string is false;
//!  - a job that runs, other than the two verdict jobs, ends as the case says (`success` unless the
//!    case says otherwise) with the outputs the case gives: the case is what the farm, the index and
//!    the smoke answered;
//!  - a verdict job is played step by step: a step runs when no step above it failed and its `if:`
//!    holds; its `env:` values are expressions; its `run:` is one `echo` of a workflow command
//!    (`::notice title=<title>::<text>` or `::error ...`), with `&& exit 1` when the step fails the
//!    job, and each `$NAME` of the text is the step's env value;
//!  - the run is green when no job failed.
//! `expanded` writes out each `${{ }}` of a job's lines the same way, with `steps.*` and `runner.*`
//! as `<steps...>` and `<runner...>`, so a case reads the target a run builds.

const std = @import("std");
const t = std.testing;
const reader = @import("pypi_workflow_text.zig");

/// How a job that runs ends, as the case says: the farm's, the index's or the smoke's answer.
const End = struct {
    job: []const u8,
    result: []const u8 = "success",
    outputs: []const [2][]const u8 = &.{},
};

/// The event of the run, its input (none in a scheduled run) and how each job that runs ends.
const Case = struct {
    event: []const u8 = "schedule",
    flavour: ?[]const u8 = null,
    ends: []const End = &.{},
};

const Done = struct {
    name: []const u8,
    result: []const u8,
    outputs: []const [2][]const u8,
};

const Message = struct {
    kind: []const u8,
    title: []const u8,
    text: []const u8,
};

const Played = struct {
    jobs: []const Done,
    messages: []const Message,

    fn resultOf(self: Played, name: []const u8) []const u8 {
        for (self.jobs) |d| if (std.mem.eql(u8, d.name, name)) return d.result;
        return "(no such job)";
    }

    fn green(self: Played) bool {
        for (self.jobs) |d| if (std.mem.eql(u8, d.result, "failure")) return false;
        return true;
    }
};

const VERDICT_JOBS = [_][]const u8{ "result", "result-macos-arm64" };

fn unreadable(comptime fmt: []const u8, args: anytype) error{Unreadable} {
    std.debug.print("the play cannot read pypi.yml: " ++ fmt ++ "\n", args);
    return error.Unreadable;
}

// ---- expressions --------------------------------------------------------------------------------

const Value = union(enum) {
    str: []const u8,
    boolean: bool,
};

fn truthy(v: Value) bool {
    return switch (v) {
        .str => |s| s.len > 0,
        .boolean => |b| b,
    };
}

/// What `expanded` writes as `<name>`: what a build step reads that is not the case's to say.
const PLACEHOLDERS = [_][]const u8{ "steps.", "runner.", "vars.", "github.sha" };

/// What an expression of one job can read.
const Scope = struct {
    case: Case,
    /// the jobs the reading job needs
    needs: []const []const u8,
    done: []const Done,
    /// `steps.*` and `runner.*` read as their own names in `<>`, for `expanded`
    placeholders: bool = false,

    fn lookup(self: Scope, ar: std.mem.Allocator, name: []const u8) !Value {
        if (std.mem.eql(u8, name, "github.ref")) return .{ .str = "refs/heads/main" };
        if (std.mem.eql(u8, name, "github.event_name")) return .{ .str = self.case.event };
        if (std.mem.eql(u8, name, "inputs.flavour")) return .{ .str = self.case.flavour orelse "" };
        if (std.mem.startsWith(u8, name, "needs.")) {
            const rest = name["needs.".len..];
            const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return unreadable("{s}", .{name});
            const job = rest[0..dot];
            var needed = false;
            for (self.needs) |n| needed = needed or std.mem.eql(u8, n, job);
            if (!needed) return unreadable("{s} reads a job it does not need", .{name});
            const d = for (self.done) |x| {
                if (std.mem.eql(u8, x.name, job)) break x;
            } else return unreadable("{s} reads a job that has not run", .{name});
            const field = rest[dot + 1 ..];
            if (std.mem.eql(u8, field, "result")) return .{ .str = d.result };
            if (std.mem.startsWith(u8, field, "outputs.")) {
                for (d.outputs) |o| if (std.mem.eql(u8, o[0], field["outputs.".len..])) return .{ .str = o[1] };
                return .{ .str = "" };
            }
            return unreadable("{s}", .{name});
        }
        if (self.placeholders) {
            for (PLACEHOLDERS) |prefix| if (std.mem.startsWith(u8, name, prefix)) return .{ .str = try std.fmt.allocPrint(ar, "<{s}>", .{name}) };
        }
        return unreadable("the name {s}", .{name});
    }
};

const Parser = struct {
    ar: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    scope: Scope,

    fn skip(p: *Parser) void {
        while (p.pos < p.src.len and p.src[p.pos] == ' ') p.pos += 1;
    }

    fn eat(p: *Parser, tok: []const u8) bool {
        p.skip();
        if (!std.mem.startsWith(u8, p.src[p.pos..], tok)) return false;
        p.pos += tok.len;
        return true;
    }

    fn orExpr(p: *Parser) anyerror!Value {
        var l = try p.andExpr();
        while (p.eat("||")) {
            const r = try p.andExpr();
            if (!truthy(l)) l = r;
        }
        return l;
    }

    fn andExpr(p: *Parser) anyerror!Value {
        var l = try p.cmp();
        while (p.eat("&&")) {
            const r = try p.cmp();
            if (truthy(l)) l = r;
        }
        return l;
    }

    fn cmp(p: *Parser) anyerror!Value {
        const l = try p.unary();
        if (p.eat("==")) return .{ .boolean = try p.same(l, try p.unary()) };
        if (p.eat("!=")) {
            const eq = try p.same(l, try p.unary());
            return .{ .boolean = !eq };
        }
        return l;
    }

    fn same(p: *Parser, a: Value, b: Value) !bool {
        if (a == .str and b == .str) return std.mem.eql(u8, a.str, b.str);
        if (a == .boolean and b == .boolean) return a.boolean == b.boolean;
        return unreadable("a comparison of a string with a boolean in {s}", .{p.src});
    }

    fn unary(p: *Parser) anyerror!Value {
        if (p.eat("!")) return .{ .boolean = !truthy(try p.unary()) };
        return p.primary();
    }

    fn primary(p: *Parser) anyerror!Value {
        p.skip();
        if (p.eat("(")) {
            const v = try p.orExpr();
            if (!p.eat(")")) return unreadable("an open parenthesis in {s}", .{p.src});
            return v;
        }
        if (p.pos < p.src.len and p.src[p.pos] == '\'') {
            const end = std.mem.indexOfScalarPos(u8, p.src, p.pos + 1, '\'') orelse return unreadable("an open quote in {s}", .{p.src});
            defer p.pos = end + 1;
            return .{ .str = p.src[p.pos + 1 .. end] };
        }
        const start = p.pos;
        while (p.pos < p.src.len and (std.ascii.isAlphanumeric(p.src[p.pos]) or std.mem.indexOfScalar(u8, "._-", p.src[p.pos]) != null)) p.pos += 1;
        const name = p.src[start..p.pos];
        if (name.len == 0) return unreadable("no value at {d} of {s}", .{ start, p.src });
        if (p.eat("()")) {
            if (std.mem.eql(u8, name, "always")) return .{ .boolean = true };
            return unreadable("the function {s}() in {s}", .{ name, p.src });
        }
        return p.scope.lookup(p.ar, name);
    }
};

fn eval(ar: std.mem.Allocator, src: []const u8, scope: Scope) !Value {
    var p = Parser{ .ar = ar, .src = src, .scope = scope };
    const v = try p.orExpr();
    p.skip();
    if (p.pos != src.len) return unreadable("{s} after {s}", .{ src[p.pos..], src[0..p.pos] });
    return v;
}

/// `line` with each `${{ <expression> }}` replaced by its value.
fn expandLine(ar: std.mem.Allocator, line: []const u8, scope: Scope) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, "${{")) |open| {
        const close = std.mem.indexOfPos(u8, line, open, "}}") orelse return unreadable("an open ${{{{ in {s}", .{line});
        try out.appendSlice(ar, line[from..open]);
        const v = try eval(ar, std.mem.trim(u8, line[open + 3 .. close], " "), scope);
        try out.appendSlice(ar, switch (v) {
            .str => |s| s,
            .boolean => |b| if (b) "true" else "false",
        });
        from = close + 2;
    }
    try out.appendSlice(ar, line[from..]);
    return out.toOwnedSlice(ar);
}

// ---- the play -----------------------------------------------------------------------------------

fn needsOf(ar: std.mem.Allocator, job: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (job) |l| {
        if (!std.mem.startsWith(u8, l, "    needs:")) continue;
        var tok = std.mem.tokenizeAny(u8, l["    needs:".len..], " ,[]");
        while (tok.next()) |n| try out.append(ar, n);
    }
    return out.toOwnedSlice(ar);
}

fn gateOf(job: []const []const u8) ?[]const u8 {
    for (job) |l| if (std.mem.startsWith(u8, l, "    if: ")) return l["    if: ".len..];
    return null;
}

/// The steps of a job, each from its `      - ` line up to the next.
fn stepsOf(ar: std.mem.Allocator, job: []const []const u8) ![]const []const []const u8 {
    var out = std.ArrayList([]const []const u8).empty;
    var start: ?usize = null;
    for (job, 0..) |l, i| {
        if (!std.mem.startsWith(u8, l, "      - ")) continue;
        if (start) |s| try out.append(ar, job[s..i]);
        start = i;
    }
    if (start) |s| try out.append(ar, job[s..]);
    return out.toOwnedSlice(ar);
}

/// The text of an echo with each `$NAME` of `env` written out.
fn substitute(ar: std.mem.Allocator, text: []const u8, env: []const [2][]const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '$') {
            try out.append(ar, text[i]);
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < text.len and (std.ascii.isUpper(text[j]) or std.ascii.isDigit(text[j]) or text[j] == '_')) j += 1;
        const name = text[i + 1 .. j];
        const value = for (env) |e| {
            if (std.mem.eql(u8, e[0], name)) break e[1];
        } else return unreadable("${s} is not in the step's env: {s}", .{ name, text });
        try out.appendSlice(ar, value);
        i = j;
    }
    return out.toOwnedSlice(ar);
}

/// Plays the steps of a verdict job; appends what it prints; its result.
fn playSteps(ar: std.mem.Allocator, job: []const []const u8, scope: Scope, messages: *std.ArrayList(Message)) ![]const u8 {
    for (try stepsOf(ar, job)) |step| {
        var gate: ?[]const u8 = null;
        var run: ?[]const u8 = null;
        var env = std.ArrayList([2][]const u8).empty;
        var in_env = false;
        for (step) |l| {
            if (std.mem.startsWith(u8, l, "      - name: ")) continue;
            if (std.mem.startsWith(u8, l, "        if: ")) {
                gate = l["        if: ".len..];
            } else if (std.mem.startsWith(u8, l, "        run: ")) {
                run = l["        run: ".len..];
            } else if (std.mem.eql(u8, l, "        env:")) {
                in_env = true;
                continue;
            } else if (in_env and std.mem.startsWith(u8, l, "          ")) {
                const kv = std.mem.trim(u8, l, " ");
                const colon = std.mem.indexOf(u8, kv, ": ") orelse return unreadable("the env line {s}", .{l});
                try env.append(ar, .{ kv[0..colon], try expandLine(ar, kv[colon + 2 ..], scope) });
                continue;
            } else return unreadable("a verdict step line that is not its name, if, env or run: {s}", .{l});
            in_env = false;
        }
        if (gate) |g| {
            if (std.mem.indexOf(u8, g, "()") != null) return unreadable("a status function in a verdict step: {s}", .{g});
            if (!truthy(try eval(ar, g, scope))) continue;
        }
        const r = run orelse return unreadable("a verdict step without run: {s}", .{step[0]});
        const echo = "'echo \"";
        const fails = std.mem.endsWith(u8, r, "\" && exit 1'");
        const tail: []const u8 = if (fails) "\" && exit 1'" else "\"'";
        if (!std.mem.startsWith(u8, r, echo) or !std.mem.endsWith(u8, r, tail)) return unreadable("a verdict run that is not one echo: {s}", .{r});
        const cmd = r[echo.len .. r.len - tail.len];
        const kind: []const u8 = if (std.mem.startsWith(u8, cmd, "::notice title=")) "notice" else if (std.mem.startsWith(u8, cmd, "::error title=")) "error" else return unreadable("a verdict echo that is not a notice or an error: {s}", .{cmd});
        const after = cmd[kind.len + "::".len + " title=".len ..];
        const sep = std.mem.indexOf(u8, after, "::") orelse return unreadable("a workflow command without its text: {s}", .{cmd});
        try messages.append(ar, .{ .kind = kind, .title = after[0..sep], .text = try substitute(ar, after[sep + 2 ..], env.items) });
        // a failed step stops the job: the steps below it have no status function
        if (fails) return "failure";
    }
    return "success";
}

fn isVerdict(name: []const u8) bool {
    for (VERDICT_JOBS) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}

fn play(ar: std.mem.Allocator, text: []const u8, case: Case) !Played {
    if (std.mem.eql(u8, case.event, "schedule") and case.flavour != null) return unreadable("a case of a scheduled run gives an input", .{});
    var done = std.ArrayList(Done).empty;
    var messages = std.ArrayList(Message).empty;
    for (try reader.jobNames(ar, text)) |name| {
        var n: usize = 0;
        const job = (try reader.jobLines(ar, text, name, &n)).?;
        const needs = try needsOf(ar, job);
        const scope = Scope{ .case = case, .needs = needs, .done = done.items };
        const gate = gateOf(job) orelse return unreadable("the job {s} has no if:", .{name});
        var needs_succeeded = true;
        for (needs) |need| {
            const d = for (done.items) |x| {
                if (std.mem.eql(u8, x.name, need)) break x;
            } else return unreadable("{s} needs {s}, which is not above it", .{ name, need });
            needs_succeeded = needs_succeeded and std.mem.eql(u8, d.result, "success");
        }
        const runs = (needs_succeeded or std.mem.indexOf(u8, gate, "always()") != null) and truthy(try eval(ar, gate, scope));
        if (!runs) {
            try done.append(ar, .{ .name = name, .result = "skipped", .outputs = &.{} });
            continue;
        }
        if (isVerdict(name)) {
            try done.append(ar, .{ .name = name, .result = try playSteps(ar, job, scope, &messages), .outputs = &.{} });
            continue;
        }
        const end = for (case.ends) |e| {
            if (std.mem.eql(u8, e.job, name)) break e;
        } else End{ .job = name };
        try done.append(ar, .{ .name = name, .result = end.result, .outputs = end.outputs });
    }
    // a case that says how a job ends where the job did not run, or names no job, is a wrong case
    for (case.ends) |e| {
        const d = for (done.items) |x| {
            if (std.mem.eql(u8, x.name, e.job)) break x;
        } else return unreadable("the case names a job pypi.yml does not have: {s}", .{e.job});
        if (std.mem.eql(u8, d.result, "skipped")) return unreadable("the case says how {s} ends, and it was skipped", .{e.job});
    }
    return .{ .jobs = try done.toOwnedSlice(ar), .messages = try messages.toOwnedSlice(ar) };
}

/// The lines of the job `name`, each `${{ }}` written out for the case (a job that needs nothing).
fn expanded(ar: std.mem.Allocator, text: []const u8, case: Case, name: []const u8) ![]const []const u8 {
    var n: usize = 0;
    const job = (try reader.jobLines(ar, text, name, &n)).?;
    const scope = Scope{ .case = case, .needs = &.{}, .done = &.{}, .placeholders = true };
    var out = std.ArrayList([]const u8).empty;
    for (job) |l| try out.append(ar, try expandLine(ar, l, scope));
    return out.toOwnedSlice(ar);
}

// ---- the cases ----------------------------------------------------------------------------------

const V = "0.1.1513";
const BUILT = End{ .job = "build", .outputs = &.{.{ "version", V }} };
/// the macOS build found its file on both indexes and built nothing
const MAC_NOTHING = End{ .job = "build-macos-arm64", .outputs = &.{.{ "version", "" }} };
const MAC_BUILT = End{ .job = "build-macos-arm64", .outputs = &.{.{ "version", V }} };

fn state(comptime job: []const u8, comptime s: []const u8) End {
    return .{ .job = job, .outputs = &.{.{ "state", s }} };
}

const ALREADY = Message{ .kind = "notice", .title = "pypi", .text = "already published: komira " ++ V ++ " is on TestPyPI and PyPI with the bytes built; nothing was uploaded, and the smoke passed on both" };
const DIFFERS = Message{ .kind = "notice", .title = "pypi", .text = "bytes differ at the same version: a commit that changed only documentation, which the stamp ignores; a code commit raises the version" };
const MAC_ON_BOTH = Message{ .kind = "notice", .title = "pypi-macos-arm64", .text = "the macOS wheel of this version is on both indexes already: nothing was built on the Macs" };
const MAC_EXTERNAL = Message{ .kind = "notice", .title = "pypi-macos-arm64", .text = "the external flavour has no macOS wheel yet: no macOS job ran; the bundled flavour publishes it" };

fn linuxError(comptime text: []const u8) Message {
    return .{ .kind = "error", .title = "pypi", .text = text };
}

const LINUX = [_][]const u8{ "build", "testpypi", "testpypi-smoke", "pypi", "pypi-smoke", "result" };
const MACOS_AFTER_BUILD = [_][]const u8{ "testpypi-macos-arm64", "testpypi-smoke-macos-arm64", "pypi-macos-arm64", "pypi-smoke-macos-arm64" };

fn expectPlayed(p: Played, green: bool, results: []const [2][]const u8, messages: []const Message) !void {
    var ok = p.green() == green and p.messages.len == messages.len;
    for (results) |r| ok = ok and std.mem.eql(u8, p.resultOf(r[0]), r[1]);
    if (ok) {
        for (messages, p.messages) |want, got| {
            ok = ok and std.mem.eql(u8, want.kind, got.kind) and std.mem.eql(u8, want.title, got.title) and std.mem.eql(u8, want.text, got.text);
        }
    }
    if (ok) return;
    std.debug.print("the run ended {s}, wanted {s}\n", .{ if (p.green()) "green" else "red", if (green) "green" else "red" });
    for (p.jobs) |d| std.debug.print("  job {s}: {s}\n", .{ d.name, d.result });
    for (p.messages) |m| std.debug.print("  printed {s} {s}: {s}\n", .{ m.kind, m.title, m.text });
    for (messages) |m| std.debug.print("  wanted  {s} {s}: {s}\n", .{ m.kind, m.title, m.text });
    return error.WrongRun;
}

/// Each of `names` with the result `result`, for expectPlayed.
fn all(ar: std.mem.Allocator, names: []const []const u8, result: []const u8) ![]const [2][]const u8 {
    var out = std.ArrayList([2][]const u8).empty;
    for (names) |n| try out.append(ar, .{ n, result });
    return out.toOwnedSlice(ar);
}

test "a scheduled run on an unchanged main: both indexes say same, nothing uploads, both smokes run, green with the notice already published" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const p = try play(ar, text, .{ .ends = &.{ BUILT, state("testpypi", "same"), state("pypi", "same"), MAC_NOTHING } });
    try expectPlayed(p, true, try all(ar, &LINUX, "success"), &.{ ALREADY, MAC_ON_BOTH });
    try expectPlayed(p, true, try all(ar, &MACOS_AFTER_BUILD, "skipped"), &.{ ALREADY, MAC_ON_BOTH });
    try t.expectEqualStrings("success", p.resultOf("result-macos-arm64"));
}

test "a scheduled run after a documentation-only commit: the bytes differ, nothing uploads, no smoke runs, green with the notice of differing bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // TestPyPI differs: no smoke, no PyPI job at all
    const p = try play(ar, text, .{ .ends = &.{ BUILT, state("testpypi", "differs"), MAC_NOTHING } });
    try expectPlayed(p, true, &.{ .{ "testpypi", "success" }, .{ "testpypi-smoke", "skipped" }, .{ "pypi", "skipped" }, .{ "pypi-smoke", "skipped" }, .{ "result", "success" } }, &.{ DIFFERS, MAC_ON_BOTH });
    // PyPI alone differs: its smoke is skipped, and the notice is the one of differing bytes, not already published
    const q = try play(ar, text, .{ .ends = &.{ BUILT, state("testpypi", "same"), state("pypi", "differs"), MAC_NOTHING } });
    try expectPlayed(q, true, &.{ .{ "testpypi-smoke", "success" }, .{ "pypi-smoke", "skipped" }, .{ "result", "success" } }, &.{ DIFFERS, MAC_ON_BOTH });
}

test "a scheduled run after a code commit: the file is absent on both, both chains upload and smoke, green with no notice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const p = try play(ar, text, .{ .ends = &.{ BUILT, state("testpypi", "absent"), state("pypi", "absent"), MAC_BUILT, state("testpypi-macos-arm64", "absent"), state("pypi-macos-arm64", "absent") } });
    try expectPlayed(p, true, try all(ar, &(LINUX ++ MACOS_AFTER_BUILD), "success"), &.{});
}

test "a run after one that stopped between the uploads: TestPyPI says same, PyPI absent, PyPI uploads, green without the notice already published" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const case = Case{ .ends = &.{ BUILT, state("testpypi", "same"), state("pypi", "absent"), MAC_NOTHING } };
    try expectPlayed(try play(ar, text, case), true, try all(ar, &LINUX, "success"), &.{MAC_ON_BOTH});
    // the notice gated on TestPyPI alone would claim a version PyPI did not have
    const one_index = try reader.replaced(ar, text, "        if: needs.testpypi.outputs.state == 'same' && needs.pypi.outputs.state == 'same'\n", "        if: needs.testpypi.outputs.state == 'same'\n");
    try expectPlayed(try play(ar, one_index, case), true, &.{}, &.{ ALREADY, MAC_ON_BOTH });
}

test "each failure of the Linux chain ends the run red, names the job, and prints no notice already published" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const same = state("testpypi", "same");
    const same_pypi = state("pypi", "same");
    // the PyPI smoke fails on an unchanged main
    try expectPlayed(try play(ar, text, .{ .ends = &.{ BUILT, same, same_pypi, .{ .job = "pypi-smoke", .result = "failure" }, MAC_NOTHING } }), false, &.{.{ "result", "failure" }}, &.{ linuxError("the PyPI smoke job did not succeed (pypi-smoke failure)"), MAC_ON_BOTH });
    // the TestPyPI smoke fails: PyPI is never asked
    try expectPlayed(try play(ar, text, .{ .ends = &.{ BUILT, same, .{ .job = "testpypi-smoke", .result = "failure" }, MAC_NOTHING } }), false, &.{ .{ "pypi", "skipped" }, .{ "pypi-smoke", "skipped" } }, &.{ linuxError("the TestPyPI smoke or the PyPI upload job did not succeed (testpypi-smoke failure, pypi skipped)"), MAC_ON_BOTH });
    // the build fails: nothing after it runs
    try expectPlayed(try play(ar, text, .{ .ends = &.{ .{ .job = "build", .result = "failure" }, MAC_NOTHING } }), false, &.{ .{ "testpypi", "skipped" }, .{ "result", "failure" } }, &.{ linuxError("the build or the TestPyPI upload job did not succeed (build failure, testpypi skipped)"), MAC_ON_BOTH });
    // the state of TestPyPI could not be asked (an index error): no state, the job failed
    try expectPlayed(try play(ar, text, .{ .ends = &.{ BUILT, .{ .job = "testpypi", .result = "failure" }, MAC_NOTHING } }), false, &.{ .{ "testpypi-smoke", "skipped" }, .{ "result", "failure" } }, &.{ linuxError("the build or the TestPyPI upload job did not succeed (build success, testpypi failure)"), MAC_ON_BOTH });
}

test "a failed macOS build ends the run red and leaves the Linux chain green with its notice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const p = try play(ar, text, .{ .ends = &.{ BUILT, state("testpypi", "same"), state("pypi", "same"), .{ .job = "build-macos-arm64", .result = "failure" } } });
    try expectPlayed(p, false, &.{ .{ "result", "success" }, .{ "result-macos-arm64", "failure" } }, &.{ ALREADY, .{ .kind = "error", .title = "pypi-macos-arm64", .text = "the macOS build job did not succeed (build-macos-arm64 failure)" } });
}

test "the flavour: a scheduled run builds the bundled wheel and runs the macOS chain; a manual run builds the flavour it was given" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const stamp = "-c komira.package_stamp=<steps.stamp.outputs.build_number> -c komira.package_commit=<steps.stamp.outputs.source_commit> -c komira.package_timestamp_ms=<steps.stamp.outputs.timestamp_ms>";
    inline for (.{ .{ "schedule", null, "bundled" }, .{ "workflow_dispatch", "bundled", "bundled" }, .{ "workflow_dispatch", "external", "external" } }) |c| {
        const lines = try expanded(ar, text, .{ .event = c[0], .flavour = c[1] }, "build");
        try t.expect(reader.has(lines, "          args: build " ++ stamp ++ " //python:komira_wheel_" ++ c[2] ++ "[release] --out <runner.temp>/pypi/built/komira.whl"));
        try t.expect(reader.has(lines, "          args: build " ++ stamp ++ " //python:wheel_install_test_" ++ c[2]));
        try t.expect(reader.has(lines, "          FLAVOUR: " ++ c[2]));
    }
    const ends = [_]End{ BUILT, state("testpypi", "same"), state("pypi", "same") };
    const ends_mac = [_]End{ BUILT, state("testpypi", "same"), state("pypi", "same"), MAC_NOTHING };
    // a scheduled run asks for the macOS wheel; an external run runs no macOS job and says why
    try expectPlayed(try play(ar, text, .{ .ends = &ends_mac }), true, &.{.{ "build-macos-arm64", "success" }}, &.{ ALREADY, MAC_ON_BOTH });
    try expectPlayed(try play(ar, text, .{ .event = "workflow_dispatch", .flavour = "external", .ends = &ends }), true, &.{.{ "build-macos-arm64", "skipped" }}, &.{ ALREADY, MAC_EXTERNAL });
    // without the fallback a scheduled run builds a target that does not exist, and skips the macOS build
    const bare = try reader.replaced(ar, text, "${{ inputs.flavour || 'bundled' }}[release]", "${{ inputs.flavour }}[release]");
    try t.expect(reader.has(try expanded(ar, bare, .{}, "build"), "          args: build " ++ stamp ++ " //python:komira_wheel_[release] --out <runner.temp>/pypi/built/komira.whl"));
    const bare_gate = try reader.replaced(ar, text, "&& (inputs.flavour || 'bundled') == 'bundled'\n", "&& inputs.flavour == 'bundled'\n");
    try expectPlayed(try play(ar, bare_gate, .{ .ends = &ends }), false, &.{.{ "build-macos-arm64", "skipped" }}, &.{ ALREADY, .{ .kind = "error", .title = "pypi-macos-arm64", .text = "the macOS build job did not succeed (build-macos-arm64 skipped)" } });
}

test "the play refuses a workflow or a case it cannot read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const ok = Case{ .ends = &.{ BUILT, state("testpypi", "same"), state("pypi", "same"), MAC_NOTHING } };
    // a context it does not know, a job it does not need, a status function in a verdict step
    try t.expectError(error.Unreadable, play(ar, try reader.inJob(ar, text, "result", "    if: always() && github.ref == 'refs/heads/main'\n", "    if: always() && vars.X == 'y'\n"), ok));
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "needs.testpypi.outputs.state != 'differs' && needs.pypi.outputs.state != 'differs' && needs.pypi-smoke.result", "needs.testpypi.outputs.state != 'differs' && needs.pypi.outputs.state != 'differs' && needs.build-macos-arm64.result"), ok));
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "        if: needs.build.result != 'success' || needs.testpypi.result != 'success'\n", "        if: failure()\n"), ok));
    // a verdict step that is not one echo, and an echo of a name the step's env does not hold
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "(pypi-smoke $PYPI_SMOKE)\" && exit 1'", "(pypi-smoke $PYPI_SMOKE)\"; exit 1'"), .{ .ends = &.{ BUILT, state("testpypi", "same"), state("pypi", "same"), .{ .job = "pypi-smoke", .result = "failure" }, MAC_NOTHING } }));
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "komira $VERSION is on", "komira $RELEASE is on"), ok));
    // a case for a scheduled run with an input, for a job the file lacks, or for a job that was skipped
    try t.expectError(error.Unreadable, play(ar, text, .{ .flavour = "bundled" }));
    try t.expectError(error.Unreadable, play(ar, text, .{ .ends = &.{.{ .job = "publish" }} }));
    try t.expectError(error.Unreadable, play(ar, text, .{ .ends = &.{ BUILT, state("testpypi", "differs"), state("pypi", "same") } }));
}
