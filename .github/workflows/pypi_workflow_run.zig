//! A run of pypi.yml played from the workflow's own text, for each event (a push to main, the daily
//! schedule, a manual run), each answer an index gives (`absent`, `same`, `differs`) and the failure of a
//! job: which jobs run and which are skipped, which jobs upload to an index and which save the record of
//! a version, what the four verdict jobs (`result-...`) print, and whether the run ends green. Two more
//! plays read the top of the file: whether a push of a set of paths starts a run at all (`on.push`'s
//! `paths-ignore`), and which runs of a sequence of events start, wait or are replaced (`concurrency:`).
//! Part of //:pypi_workflow_cases (pypi_workflow_test.zig imports this file).
//!
//! The play holds the part of GitHub's rules the file uses and refuses anything else by name, so an
//! edit the play cannot read fails the cases instead of passing them:
//!  - the jobs run in file order (each job's `needs:` are above it);
//!  - a job whose `if:` has no `always()` runs only when every job it needs succeeded, else it is
//!    skipped; then its `if:` decides; a skipped job's outputs are empty;
//!  - an expression is a string literal, `github.ref` (a run of this file is on main), `github.event_name`,
//!    `needs.<job>.result` and `needs.<job>.outputs.<name>` of a job the reading job needs (the
//!    workflow takes no input, so `inputs.<name>` is refused like any other unknown name), `always()`, `!`, `==`, `!=`, `&&`,
//!    `||` and parentheses, with GitHub's values: `||` and `&&` give one of their operands, an empty
//!    string is false, and strings compare without regard to case;
//!  - a job that runs, other than the verdict jobs, ends as the case says (`success` unless the case
//!    says otherwise) with the outputs the case gives: the case is what the farm, the cache, the index and
//!    the smoke answered; in a job that succeeds, the step that uses the publish action uploads when its
//!    `if:` holds, `steps.state.outputs.state` there being the job's output `state`, and a step that uses
//!    `actions/cache/save` saves the record;
//!  - a verdict job is played step by step: a step runs when no step above it failed and its `if:`
//!    holds; its `env:` values are expressions; its `run:` is one `echo` of a workflow command
//!    (`::notice title=<title>::<text>` or `::error ...`), with `&& exit 1` when the step fails the
//!    job, and each `$NAME` of the text is the step's env value;
//!  - the run is green when no job failed;
//!  - a push starts a run unless every path it changes matches a `paths-ignore` pattern, where `**`
//!    matches any characters and `*` any but `/`;
//!  - a run joins the group its `concurrency.group` gives for its event; with `cancel-in-progress: false`
//!    a run starts when its group runs nothing, else it waits, and a newer run of the group replaces the
//!    one that waits (that one is cancelled, never started); with `true` it cancels the group's runs and
//!    starts.
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

/// The event of the run and how each job that runs ends.
const Case = struct {
    event: []const u8,
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
    /// the jobs whose publish step ran, in file order
    uploads: []const []const u8,
    /// the jobs whose record (actions/cache/save) was saved, in file order
    records: []const []const u8,

    fn resultOf(self: Played, name: []const u8) []const u8 {
        for (self.jobs) |d| if (std.mem.eql(u8, d.name, name)) return d.result;
        return "(no such job)";
    }

    fn green(self: Played) bool {
        for (self.jobs) |d| if (std.mem.eql(u8, d.result, "failure")) return false;
        return true;
    }
};


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
    /// `steps.state.outputs.state`, for the gate of an upload job's publish step
    step_state: ?[]const u8 = null,

    fn lookup(self: Scope, ar: std.mem.Allocator, name: []const u8) !Value {
        if (std.mem.eql(u8, name, "github.ref")) return .{ .str = "refs/heads/main" };
        if (std.mem.eql(u8, name, "github.event_name")) return .{ .str = self.case.event };
        if (self.step_state) |s| if (std.mem.eql(u8, name, "steps.state.outputs.state")) return .{ .str = s };
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
        if (a == .str and b == .str) return std.ascii.eqlIgnoreCase(a.str, b.str);
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
    return std.mem.startsWith(u8, name, "result-");
}

fn play(ar: std.mem.Allocator, text: []const u8, case: Case) !Played {
    var done = std.ArrayList(Done).empty;
    var messages = std.ArrayList(Message).empty;
    var uploads = std.ArrayList([]const u8).empty;
    var records = std.ArrayList([]const u8).empty;
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
        if (!std.mem.eql(u8, end.result, "success")) continue;
        for (try stepsOf(ar, job)) |step| {
            if (reader.mentions(step, "uses: actions/cache/save@")) try records.append(ar, name);
            if (!reader.mentions(step, "uses: pypa/gh-action-pypi-publish@")) continue;
            const st = for (end.outputs) |o| {
                if (std.mem.eql(u8, o[0], "state")) break o[1];
            } else "";
            const step_scope = Scope{ .case = case, .needs = needs, .done = done.items, .step_state = st };
            const step_gate = for (step) |l| {
                if (std.mem.startsWith(u8, l, "        if: ")) break l["        if: ".len..];
            } else null;
            if (step_gate == null or truthy(try eval(ar, step_gate.?, step_scope))) try uploads.append(ar, name);
        }
    }
    // a case that says how a job ends where the job did not run, or names no job, is a wrong case
    for (case.ends) |e| {
        const d = for (done.items) |x| {
            if (std.mem.eql(u8, x.name, e.job)) break x;
        } else return unreadable("the case names a job pypi.yml does not have: {s}", .{e.job});
        if (std.mem.eql(u8, d.result, "skipped")) return unreadable("the case says how {s} ends, and it was skipped", .{e.job});
    }
    return .{ .jobs = try done.toOwnedSlice(ar), .messages = try messages.toOwnedSlice(ar), .uploads = try uploads.toOwnedSlice(ar), .records = try records.toOwnedSlice(ar) };
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

// ---- the push filter ------------------------------------------------------------------------------

/// Whether `path` matches the filter pattern `pat`: `**` any characters, `*` any but `/`, the rest
/// itself. A pattern with another special character is one the play cannot read.
fn globMatch(pat: []const u8, path: []const u8) error{Unreadable}!bool {
    if (pat.len == 0) return path.len == 0;
    if (std.mem.indexOfScalar(u8, "?[]!+", pat[0]) != null) return unreadable("the paths-ignore pattern character {c}", .{pat[0]});
    if (std.mem.startsWith(u8, pat, "**")) {
        for (0..path.len + 1) |i| if (try globMatch(pat[2..], path[i..])) return true;
        return false;
    }
    if (pat[0] == '*') {
        var i: usize = 0;
        while (true) : (i += 1) {
            if (try globMatch(pat[1..], path[i..])) return true;
            if (i == path.len or path[i] == '/') return false;
        }
    }
    return path.len > 0 and path[0] == pat[0] and try globMatch(pat[1..], path[1..]);
}

/// Whether a push to main that changes `paths` starts a run: `on.push` is for main, and a push whose
/// every path matches one of its `paths-ignore` patterns starts none.
fn pushStarts(ar: std.mem.Allocator, text: []const u8, paths: []const []const u8) !bool {
    var n: usize = 0;
    const on = (try reader.topLines(ar, text, "on:", &n)) orelse return unreadable("no on:", .{});
    const at = reader.lineAt(on, "  push:") orelse return false;
    if (at + 1 >= on.len or !std.mem.eql(u8, on[at + 1], "    branches: [main]")) return unreadable("a push trigger that is not `branches: [main]`", .{});
    var patterns = std.ArrayList([]const u8).empty;
    var i = at + 2;
    if (i < on.len and std.mem.eql(u8, on[i], "    paths-ignore:")) {
        i += 1;
        while (i < on.len and std.mem.startsWith(u8, on[i], "      - '") and std.mem.endsWith(u8, on[i], "'")) : (i += 1) {
            try patterns.append(ar, on[i]["      - '".len .. on[i].len - 1]);
        }
    }
    if (i < on.len and std.mem.startsWith(u8, on[i], "    ")) return unreadable("a push trigger line {s}", .{on[i]});
    for (paths) |p| {
        var ignored = false;
        for (patterns.items) |pat| {
            // every pattern is read, so one the play cannot read is refused whatever the path
            const matched = try globMatch(pat, p);
            ignored = ignored or matched;
        }
        if (!ignored) return true;
    }
    return false;
}

// ---- the concurrency ------------------------------------------------------------------------------

/// One event of a sequence: a run starting (`event` set), or the run `run` ending.
const Arrival = struct { run: []const u8, event: ?[]const u8 = null };

fn arrive(run: []const u8, event: []const u8) Arrival {
    return .{ .run = run, .event = event };
}

fn leave(run: []const u8) Arrival {
    return .{ .run = run };
}

const Queued = struct {
    /// the runs that started, in order
    started: []const []const u8,
    /// the runs cancelled, in order: a waiting run replaced, or a running one
    cancelled: []const []const u8,
};

/// The runs of `arrivals` under the workflow's `concurrency:` (the header says how).
fn queue(ar: std.mem.Allocator, text: []const u8, arrivals: []const Arrival) !Queued {
    var n: usize = 0;
    const conc = (try reader.topLines(ar, text, "concurrency:", &n)) orelse return unreadable("no concurrency:", .{});
    var group: ?[]const u8 = null;
    var cancel: ?bool = null;
    for (conc) |l| {
        if (std.mem.startsWith(u8, l, "  group: ")) {
            group = l["  group: ".len..];
        } else if (std.mem.eql(u8, l, "  cancel-in-progress: false")) {
            cancel = false;
        } else if (std.mem.eql(u8, l, "  cancel-in-progress: true")) {
            cancel = true;
        } else return unreadable("the concurrency line {s}", .{l});
    }
    const g = group orelse return unreadable("a concurrency without a group", .{});
    const cancels = cancel orelse return unreadable("a concurrency without cancel-in-progress", .{});
    const Slot = struct { name: []const u8, running: ?[]const u8 = null, waiting: ?[]const u8 = null };
    var slots = std.ArrayList(Slot).empty;
    var started = std.ArrayList([]const u8).empty;
    var cancelled = std.ArrayList([]const u8).empty;
    for (arrivals) |a| {
        if (a.event) |event| {
            const name = try expandLine(ar, g, .{ .case = .{ .event = event }, .needs = &.{}, .done = &.{} });
            const slot = for (slots.items) |*s| {
                if (std.mem.eql(u8, s.name, name)) break s;
            } else blk: {
                try slots.append(ar, .{ .name = name });
                break :blk &slots.items[slots.items.len - 1];
            };
            if (cancels) {
                if (slot.running) |r| try cancelled.append(ar, r);
                if (slot.waiting) |w| try cancelled.append(ar, w);
                slot.waiting = null;
                slot.running = a.run;
                try started.append(ar, a.run);
            } else if (slot.running == null) {
                slot.running = a.run;
                try started.append(ar, a.run);
            } else {
                if (slot.waiting) |w| try cancelled.append(ar, w);
                slot.waiting = a.run;
            }
            continue;
        }
        const slot = for (slots.items) |*s| {
            if (s.running) |r| if (std.mem.eql(u8, r, a.run)) break s;
        } else return unreadable("the case ends the run {s}, which is not running", .{a.run});
        slot.running = slot.waiting;
        slot.waiting = null;
        if (slot.running) |r| try started.append(ar, r);
    }
    return .{ .started = try started.toOwnedSlice(ar), .cancelled = try cancelled.toOwnedSlice(ar) };
}

// ---- the cases ----------------------------------------------------------------------------------

const V = "0.1.1513";
const NEWER = "0.1.1514";
const BUILT = End{ .job = "build", .outputs = &.{.{ "version", V }} };
/// the macOS build found its file on TestPyPI and built nothing
const MAC_NOTHING = End{ .job = "build-macos-arm64", .outputs = &.{.{ "version", "" }} };
const MAC_BUILT = End{ .job = "build-macos-arm64", .outputs = &.{.{ "version", V }} };
const PROMOTED = End{ .job = "promote", .outputs = &.{ .{ "version", V }, .{ "skipped", "" } } };
const PROMOTED_SKIPPING = End{ .job = "promote", .outputs = &.{ .{ "version", V }, .{ "skipped", NEWER } } };
const MAC_PROMOTED = End{ .job = "promote-macos-arm64", .outputs = &.{ .{ "version", V }, .{ "skipped", "" } } };

fn state(comptime job: []const u8, comptime s: []const u8) End {
    return .{ .job = job, .outputs = &.{.{ "state", s }} };
}

fn notice(comptime title: []const u8, comptime text: []const u8) Message {
    return .{ .kind = "notice", .title = title, .text = text };
}

fn linuxError(comptime text: []const u8) Message {
    return .{ .kind = "error", .title = "pypi", .text = text };
}

const ON_TESTPYPI = notice("pypi", "already on TestPyPI: komira " ++ V ++ " is on TestPyPI with the bytes built; nothing was uploaded, and the smoke passed");
const DIFFERS = notice("pypi", "bytes differ at the same version: a commit that changed only what the stamp ignores changed the wheel; a code commit raises the version");
const MAC_ON_TESTPYPI = notice("pypi-macos-arm64", "the macOS wheel of this version is on TestPyPI already: nothing was built on the Macs");
const NOT_PROMOTED = notice("pypi", "not promoted: komira " ++ NEWER ++ " on TestPyPI has no record that its TestPyPI smoke passed (the smoke failed, or its run had not ended); komira " ++ V ++ " is the newest version that passed");
const PUBLISHED = notice("pypi", "already published: komira " ++ V ++ " is on PyPI with the bytes TestPyPI served; nothing was uploaded, and the PyPI smoke passed");
const MAC_PUBLISHED = notice("pypi-macos-arm64", "already published: the macOS wheel of komira " ++ V ++ " is on PyPI with the bytes TestPyPI served; nothing was uploaded, and the PyPI smoke passed");
const STORAGE_PUSH = linuxError("an index holds over 80 percent of the size limit of komira (the summary of the job testpypi says which): prune old versions on TestPyPI or ask for a higher limit, docs/ci.md, Storage on the indexes");
const STORAGE_PROMOTE = linuxError("an index holds over 80 percent of the size limit of komira (the summary of the job promote says which): prune old versions on TestPyPI or ask for a higher limit, docs/ci.md, Storage on the indexes");

const PUSH_JOBS = [_][]const u8{ "build", "wheel-user-test", "testpypi", "testpypi-smoke", "testpypi-passed", "result-testpypi", "build-macos-arm64", "testpypi-macos-arm64", "testpypi-smoke-macos-arm64", "testpypi-passed-macos-arm64", "result-testpypi-macos-arm64" };
const PROMOTE_JOBS = [_][]const u8{ "promote", "pypi", "pypi-smoke", "result-pypi", "promote-macos-arm64", "pypi-macos-arm64", "pypi-smoke-macos-arm64", "result-pypi-macos-arm64" };

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
    for (results) |r| std.debug.print("  wanted job {s}: {s}\n", .{ r[0], r[1] });
    for (p.messages) |m| std.debug.print("  printed {s} {s}: {s}\n", .{ m.kind, m.title, m.text });
    for (messages) |m| std.debug.print("  wanted  {s} {s}: {s}\n", .{ m.kind, m.title, m.text });
    return error.WrongRun;
}

fn expectList(what: []const u8, got: []const []const u8, want: []const []const u8) !void {
    var ok = got.len == want.len;
    if (ok) {
        for (want, got) |w, g| ok = ok and std.mem.eql(u8, w, g);
    }
    if (ok) return;
    for (got) |u| std.debug.print("  {s}: got {s}\n", .{ what, u });
    for (want) |u| std.debug.print("  {s}: wanted {s}\n", .{ what, u });
    return error.WrongList;
}

fn expectUploads(p: Played, want: []const []const u8) !void {
    return expectList("an upload in", p.uploads, want);
}

fn expectRecords(p: Played, want: []const []const u8) !void {
    return expectList("a record saved by", p.records, want);
}

/// Each of `names` with the result `result`, for expectPlayed.
fn all(ar: std.mem.Allocator, names: []const []const u8, result: []const u8) ![]const [2][]const u8 {
    var out = std.ArrayList([2][]const u8).empty;
    for (names) |n| try out.append(ar, .{ n, result });
    return out.toOwnedSlice(ar);
}

test "a push with a code change uploads to TestPyPI, smokes it and saves the record, and touches no PyPI job" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const ends = [_]End{ BUILT, state("testpypi", "absent"), MAC_BUILT, state("testpypi-macos-arm64", "absent") };
    const p = try play(ar, text, .{ .event = "push", .ends = &ends });
    try expectPlayed(p, true, try all(ar, &PUSH_JOBS, "success"), &.{});
    try expectPlayed(p, true, try all(ar, &PROMOTE_JOBS, "skipped"), &.{});
    try expectUploads(p, &.{ "testpypi", "testpypi-macos-arm64" });
    try expectRecords(p, &.{ "testpypi-passed", "testpypi-passed-macos-arm64" });
    // the half gates are what keep PyPI out of a push: without them the push would promote too
    const main_only = "    if: github.ref == 'refs/heads/main'\n";
    const promote_gate = "    if: github.ref == 'refs/heads/main' && github.event_name != 'push'\n";
    const open = try reader.inJob(ar, try reader.inJob(ar, text, "promote", promote_gate, main_only), "pypi", promote_gate, main_only);
    const both = ends ++ [_]End{ PROMOTED, state("pypi", "absent") };
    try expectUploads(try play(ar, open, .{ .event = "push", .ends = &both }), &.{ "testpypi", "pypi", "testpypi-macos-arm64" });
}

test "a push that changes no code starts no run, and one that changes only what the stamp ignores uploads nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // documentation alone, at any depth: no run; one path of code with it: a run
    try t.expect(!try pushStarts(ar, text, &.{ "docs/ci.md", "docs/design/python_package.md", "python/README.md", "AGENTS.md" }));
    try t.expect(try pushStarts(ar, text, &.{ "docs/ci.md", "src/engine/plan.mojo" }));
    try t.expect(try pushStarts(ar, text, &.{"python/examples/quickstart.expected"}));
    try t.expect(try pushStarts(ar, text, &.{".github/workflows/pypi.yml"}));
    // without the `**.md` entry a README edit would start a run
    try t.expect(try pushStarts(ar, try reader.replaced(ar, text, "      - '**.md'\n", ""), &.{"python/README.md"}));
    // a push the stamp ignores but the filter lets through (a workflow file): the same version, `same`
    // on TestPyPI, nothing uploaded, the smoke and the record again, green with the notice
    const p = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "same"), MAC_NOTHING } });
    try expectPlayed(p, true, &.{ .{ "testpypi-smoke", "success" }, .{ "testpypi-passed", "success" }, .{ "testpypi-macos-arm64", "skipped" } }, &.{ ON_TESTPYPI, MAC_ON_TESTPYPI });
    try expectUploads(p, &.{});
    try expectRecords(p, &.{"testpypi-passed"});
    // an upload gate that lets `same` through would send the bytes again
    const weak = try reader.inJob(ar, text, "testpypi", "        if: steps.state.outputs.state == 'absent'\n", "        if: steps.state.outputs.state != 'differs'\n");
    try expectUploads(try play(ar, weak, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "same"), MAC_NOTHING } }), &.{"testpypi"});
}

test "a push whose wheel differs at the same version uploads nothing, smokes nothing, saves no record, and is green with the notice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const p = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "differs"), MAC_NOTHING } });
    try expectPlayed(p, true, &.{ .{ "testpypi-smoke", "skipped" }, .{ "testpypi-passed", "skipped" }, .{ "result-testpypi", "success" } }, &.{ DIFFERS, MAC_ON_TESTPYPI });
    try expectUploads(p, &.{});
    try expectRecords(p, &.{});
}

test "the daily run promotes the newest version that passed, naming the newer one that did not, and uploads it to PyPI alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const p = try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED_SKIPPING, state("pypi", "absent"), MAC_PROMOTED, state("pypi-macos-arm64", "absent") } });
    try expectPlayed(p, true, try all(ar, &PROMOTE_JOBS, "success"), &.{NOT_PROMOTED});
    try expectPlayed(p, true, try all(ar, &PUSH_JOBS, "skipped"), &.{NOT_PROMOTED});
    try expectUploads(p, &.{ "pypi", "pypi-macos-arm64" });
    try expectRecords(p, &.{});
    // with nothing skipped there is no notice at all
    const q = try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "absent"), MAC_PROMOTED, state("pypi-macos-arm64", "absent") } });
    try expectPlayed(q, true, &.{}, &.{});
}

test "a day whose newest version did not pass publishes nothing and says why; a version already on PyPI is not uploaded again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // the newest that passed is on PyPI already (`same`): no upload, the PyPI smoke runs, both notices
    inline for (.{ "schedule", "workflow_dispatch" }) |event| {
        const p = try play(ar, text, .{ .event = event, .ends = &.{ PROMOTED_SKIPPING, state("pypi", "same"), MAC_PROMOTED, state("pypi-macos-arm64", "same") } });
        try expectPlayed(p, true, &.{ .{ "pypi-smoke", "success" }, .{ "pypi-smoke-macos-arm64", "success" } }, &.{ NOT_PROMOTED, PUBLISHED, MAC_PUBLISHED });
        try expectUploads(p, &.{});
    }
    // an upload gate that lets `same` through would upload a version PyPI holds
    const weak = try reader.inJob(ar, text, "pypi", "        if: steps.state.outputs.state == 'absent'\n", "        if: steps.state.outputs.state != 'differs'\n");
    try expectUploads(try play(ar, weak, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "same"), MAC_PROMOTED, state("pypi-macos-arm64", "same") } }), &.{"pypi"});
    // the notice gated on the promote job alone would claim a version PyPI was not asked about
    const loose = try reader.replaced(ar, text, "        if: needs.pypi.outputs.state == 'same'\n", "        if: needs.promote.result == 'success'\n");
    try expectPlayed(try play(ar, loose, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "absent"), MAC_PROMOTED, state("pypi-macos-arm64", "absent") } }), true, &.{}, &.{PUBLISHED});
}

test "a promotion with no record, or one the promote job refused, publishes nothing and is red, naming the job" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const p = try play(ar, text, .{ .event = "schedule", .ends = &.{ .{ .job = "promote", .result = "failure" }, MAC_PROMOTED, state("pypi-macos-arm64", "same") } });
    try expectPlayed(p, false, &.{ .{ "pypi", "skipped" }, .{ "pypi-smoke", "skipped" }, .{ "result-pypi", "failure" }, .{ "result-pypi-macos-arm64", "success" } }, &.{ linuxError("the promote job did not succeed (promote failure): nothing was published to PyPI; its log says why"), MAC_PUBLISHED });
    try expectUploads(p, &.{});
    // the macOS promotion fails alone (no macOS wheel ever passed): the Linux one publishes and is green
    const q = try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "absent"), .{ .job = "promote-macos-arm64", .result = "failure" } } });
    try expectPlayed(q, false, &.{ .{ "result-pypi", "success" }, .{ "result-pypi-macos-arm64", "failure" } }, &.{.{ .kind = "error", .title = "pypi-macos-arm64", .text = "the macOS promote job did not succeed (promote-macos-arm64 failure): no macOS wheel was published to PyPI; its log says why" }});
    try expectUploads(q, &.{"pypi"});
}

test "each failure of the promotion after the promote job ends the run red, names it, and prints no notice already published" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const mac = [_]End{ MAC_PROMOTED, state("pypi-macos-arm64", "same") };
    // the upload job failed (an index error, or the upload refused)
    try expectPlayed(try play(ar, text, .{ .event = "schedule", .ends = &([_]End{ PROMOTED, .{ .job = "pypi", .result = "failure" } } ++ mac) }), false, &.{.{ "pypi-smoke", "skipped" }}, &.{ linuxError("the PyPI upload job did not succeed (pypi failure)"), MAC_PUBLISHED });
    // PyPI holds the version with other bytes: nothing uploaded, no smoke, red
    const d = try play(ar, text, .{ .event = "schedule", .ends = &([_]End{ PROMOTED, state("pypi", "differs") } ++ mac) });
    try expectPlayed(d, false, &.{.{ "pypi-smoke", "skipped" }}, &.{ linuxError("PyPI holds komira " ++ V ++ " with other bytes than TestPyPI serves: nothing was uploaded and PyPI was not smoked"), MAC_PUBLISHED });
    try expectUploads(d, &.{});
    // the PyPI smoke failed after an upload
    try expectPlayed(try play(ar, text, .{ .event = "schedule", .ends = &([_]End{ PROMOTED, state("pypi", "absent"), .{ .job = "pypi-smoke", .result = "failure" } } ++ mac) }), false, &.{}, &.{ linuxError("the PyPI smoke job did not succeed (pypi-smoke failure)"), MAC_PUBLISHED });
}

test "two pushes while a run is going leave one waiting run, the newer; a push never replaces a waiting promotion" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // three merges: the first runs, the second waits and is replaced by the third, which runs next
    const merges = [_]Arrival{ arrive("push-1", "push"), arrive("push-2", "push"), arrive("push-3", "push"), leave("push-1") };
    const q = try queue(ar, text, &merges);
    try expectList("started", q.started, &.{ "push-1", "push-3" });
    try expectList("cancelled", q.cancelled, &.{"push-2"});
    // a promotion starts while a push runs, and a push that lands while a manual run waits replaces nothing
    const mixed = [_]Arrival{ arrive("push-1", "push"), arrive("daily", "schedule"), arrive("manual", "workflow_dispatch"), arrive("push-2", "push"), leave("daily"), leave("push-1") };
    const m = try queue(ar, text, &mixed);
    try expectList("started", m.started, &.{ "push-1", "daily", "manual", "push-2" });
    try expectList("cancelled", m.cancelled, &.{});
    // one group for both halves: a push that lands while a manual run waits would replace it
    const waiting = [_]Arrival{ arrive("daily", "schedule"), arrive("manual", "workflow_dispatch"), arrive("push-1", "push") };
    try expectList("cancelled", (try queue(ar, text, &waiting)).cancelled, &.{});
    const one = try reader.replaced(ar, text, "  group: pypi-${{ github.event_name == 'push' && 'testpypi' || 'promote' }}\n", "  group: pypi\n");
    try expectList("cancelled", (try queue(ar, one, &waiting)).cancelled, &.{"manual"});
    // cancelling in progress: the second merge would cut the first one's upload short
    const cut = try reader.replaced(ar, text, "  cancel-in-progress: false\n", "  cancel-in-progress: true\n");
    try expectList("cancelled", (try queue(ar, cut, merges[0..3])).cancelled, &.{ "push-1", "push-2" });
}

test "each failure of the push chain ends the run red, names the job, saves no record and prints no notice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // the build fails: nothing after it runs
    try expectPlayed(try play(ar, text, .{ .event = "push", .ends = &.{ .{ .job = "build", .result = "failure" }, MAC_NOTHING } }), false, &.{ .{ "wheel-user-test", "skipped" }, .{ "testpypi", "skipped" }, .{ "result-testpypi", "failure" } }, &.{ linuxError("the build, the user test of the wheel or the TestPyPI upload job did not succeed (build failure, wheel-user-test skipped, testpypi skipped)"), MAC_ON_TESTPYPI });
    // the state of TestPyPI could not be asked: the job failed, no state
    try expectPlayed(try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, .{ .job = "testpypi", .result = "failure" }, MAC_NOTHING } }), false, &.{.{ "testpypi-smoke", "skipped" }}, &.{ linuxError("the build, the user test of the wheel or the TestPyPI upload job did not succeed (build success, wheel-user-test success, testpypi failure)"), MAC_ON_TESTPYPI });
    // the TestPyPI smoke fails on one Python: no record, so the version is never promoted
    const s = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "absent"), .{ .job = "testpypi-smoke", .result = "failure" }, MAC_NOTHING } });
    try expectPlayed(s, false, &.{.{ "testpypi-passed", "skipped" }}, &.{ linuxError("the TestPyPI smoke or the record job did not succeed (testpypi-smoke failure, testpypi-passed skipped): this version is never promoted to PyPI"), MAC_ON_TESTPYPI });
    try expectRecords(s, &.{});
    try expectUploads(s, &.{"testpypi"});
    // a record job that did not wait for the smoke would record a version that failed it
    const early = try reader.inJob(ar, text, "testpypi-passed", "    needs: [build, testpypi-smoke]\n", "    needs: [build, testpypi]\n");
    try expectRecords(try play(ar, early, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "absent"), .{ .job = "testpypi-smoke", .result = "failure" }, MAC_NOTHING } }), &.{"testpypi-passed"});
}

test "a wheel that failed its user test is not uploaded: TestPyPI is never asked, red, the job named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const failed = End{ .job = "wheel-user-test", .result = "failure" };
    const p = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, failed, MAC_NOTHING } });
    try expectPlayed(p, false, &.{ .{ "testpypi", "skipped" }, .{ "testpypi-smoke", "skipped" }, .{ "testpypi-passed", "skipped" }, .{ "result-testpypi", "failure" }, .{ "result-testpypi-macos-arm64", "success" } }, &.{ linuxError("the build, the user test of the wheel or the TestPyPI upload job did not succeed (build success, wheel-user-test failure, testpypi skipped)"), MAC_ON_TESTPYPI });
    try expectUploads(p, &.{});
    // an upload that did not wait for the user test would send the failed wheel to TestPyPI
    const unguarded = try reader.inJob(ar, text, "testpypi", "    needs: [build, wheel-user-test]\n", "    needs: build\n");
    try expectUploads(try play(ar, unguarded, .{ .event = "push", .ends = &.{ BUILT, failed, state("testpypi", "absent"), MAC_NOTHING } }), &.{"testpypi"});
}

test "an index over 80 percent of its size limit ends a push run and a promotion red, the uploads still made" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const full = End{ .job = "testpypi", .outputs = &.{ .{ "state", "absent" }, .{ "testpypi_storage", "true" }, .{ "pypi_storage", "false" } } };
    const p = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, full, MAC_NOTHING } });
    try expectPlayed(p, false, &.{.{ "result-testpypi", "failure" }}, &.{ STORAGE_PUSH, MAC_ON_TESTPYPI });
    try expectUploads(p, &.{"testpypi"});
    try expectRecords(p, &.{"testpypi-passed"});
    // PyPI over its limit, in the promotion
    const pfull = End{ .job = "promote", .outputs = &.{ .{ "version", V }, .{ "skipped", "" }, .{ "testpypi_storage", "false" }, .{ "pypi_storage", "true" } } };
    const q = try play(ar, text, .{ .event = "schedule", .ends = &.{ pfull, state("pypi", "absent"), MAC_PROMOTED, state("pypi-macos-arm64", "same") } });
    try expectPlayed(q, false, &.{.{ "result-pypi", "failure" }}, &.{ STORAGE_PROMOTE, MAC_PUBLISHED });
    try expectUploads(q, &.{"pypi"});
    // under the limit on both: green
    const ok = End{ .job = "testpypi", .outputs = &.{ .{ "state", "absent" }, .{ "testpypi_storage", "false" }, .{ "pypi_storage", "false" } } };
    try expectPlayed(try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, ok, MAC_NOTHING } }), true, &.{}, &.{MAC_ON_TESTPYPI});
}

test "the macOS chain is its own in both halves: a failed macOS build or smoke is red and leaves the Linux chain green" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const p = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "same"), .{ .job = "build-macos-arm64", .result = "failure" } } });
    try expectPlayed(p, false, &.{ .{ "result-testpypi", "success" }, .{ "result-testpypi-macos-arm64", "failure" } }, &.{ ON_TESTPYPI, .{ .kind = "error", .title = "pypi-macos-arm64", .text = "the macOS build job did not succeed (build-macos-arm64 failure)" } });
    const s = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "same"), MAC_BUILT, state("testpypi-macos-arm64", "absent"), .{ .job = "testpypi-smoke-macos-arm64", .result = "failure" } } });
    try expectPlayed(s, false, &.{ .{ "result-testpypi", "success" }, .{ "testpypi-passed-macos-arm64", "skipped" } }, &.{ ON_TESTPYPI, .{ .kind = "error", .title = "pypi-macos-arm64", .text = "the macOS TestPyPI smoke or the record job did not succeed (testpypi-smoke-macos-arm64 failure, testpypi-passed-macos-arm64 skipped): this macOS wheel is never promoted to PyPI" } });
    try expectUploads(s, &.{"testpypi-macos-arm64"});
    try expectRecords(s, &.{"testpypi-passed"});
}

test "a push builds the one wheel from the stamp; a read of an input is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const stamp = "-c komira.package_stamp=<steps.stamp.outputs.build_number> -c komira.package_commit=<steps.stamp.outputs.source_commit> -c komira.package_timestamp_ms=<steps.stamp.outputs.timestamp_ms>";
    const lines = try expanded(ar, text, .{ .event = "push" }, "build");
    try t.expect(reader.has(lines, "          args: build " ++ stamp ++ " //python:komira_wheel[release] --out <runner.temp>/pypi/built/komira.whl"));
    try t.expect(reader.has(lines, "          args: build " ++ stamp ++ " //python:wheel_install_test"));
    const ends = [_]End{ BUILT, state("testpypi", "absent"), MAC_NOTHING };
    try t.expectError(error.Unreadable, expanded(ar, try reader.replaced(ar, text, "//python:komira_wheel[release]", "//python:komira_wheel_${{ inputs.flavour || 'bundled' }}[release]"), .{ .event = "push" }, "build"));
    try t.expectError(error.Unreadable, play(ar, try reader.inJob(ar, text, "build-macos-arm64", "    if: github.ref == 'refs/heads/main' && github.event_name == 'push'\n", "    if: github.ref == 'refs/heads/main' && (inputs.flavour || 'bundled') == 'bundled'\n"), .{ .event = "push", .ends = &ends }));
}

test "the plays refuse a workflow or a case they cannot read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const ok = Case{ .event = "push", .ends = &.{ BUILT, state("testpypi", "same"), MAC_NOTHING } };
    // a context it does not know, a job it does not need, a status function in a verdict step
    try t.expectError(error.Unreadable, play(ar, try reader.inJob(ar, text, "result-testpypi", "    if: always() && github.ref == 'refs/heads/main' && github.event_name == 'push'\n", "    if: always() && vars.X == 'y'\n"), ok));
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "        if: needs.testpypi.outputs.state == 'differs'\n", "        if: needs.build-macos-arm64.outputs.version == 'differs'\n"), ok));
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "        if: needs.build.result != 'success' || needs.wheel-user-test.result != 'success' || needs.testpypi.result != 'success'\n", "        if: failure()\n"), ok));
    // a verdict step that is not one echo, and an echo of a name the step's env does not hold
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "(pypi-smoke $PYPI_SMOKE)\" && exit 1'", "(pypi-smoke $PYPI_SMOKE)\"; exit 1'"), .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "absent"), .{ .job = "pypi-smoke", .result = "failure" }, MAC_PROMOTED } }));
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "komira $VERSION is on TestPyPI with", "komira $RELEASE is on TestPyPI with"), ok));
    // a case for a job the file lacks, or for a job that was skipped (a PyPI job in a push run)
    try t.expectError(error.Unreadable, play(ar, text, .{ .event = "push", .ends = &.{.{ .job = "publish" }} }));
    try t.expectError(error.Unreadable, play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "absent"), state("pypi", "absent") } }));
    // a push filter pattern the play does not know, a concurrency line it does not know, a run ended twice
    try t.expectError(error.Unreadable, pushStarts(ar, try reader.replaced(ar, text, "      - '**.md'\n", "      - '!docs/keep.md'\n"), &.{"docs/x.md"}));
    try t.expectError(error.Unreadable, queue(ar, try reader.replaced(ar, text, "  cancel-in-progress: false\n", "  cancel-in-progress: ${{ false }}\n"), &.{arrive("a", "push")}));
    try t.expectError(error.Unreadable, queue(ar, text, &.{ arrive("a", "push"), leave("a"), leave("a") }));
}

test "the macOS promotion names its skipped versions, refuses other bytes on PyPI, and prints already published only when nothing failed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const mac_skipping = End{ .job = "promote-macos-arm64", .outputs = &.{ .{ "version", V }, .{ "skipped", NEWER } } };
    const skipped = notice("pypi-macos-arm64", "not promoted: the macOS wheel of komira " ++ NEWER ++ " on TestPyPI has no record that its TestPyPI smoke passed (the smoke failed, or its run had not ended); komira " ++ V ++ " is the newest version whose macOS wheel passed");
    const p = try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "same"), mac_skipping, state("pypi-macos-arm64", "absent") } });
    try expectPlayed(p, true, &.{.{ "result-pypi-macos-arm64", "success" }}, &.{ PUBLISHED, skipped });
    try expectUploads(p, &.{"pypi-macos-arm64"});
    const d = try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "same"), MAC_PROMOTED, state("pypi-macos-arm64", "differs") } });
    try expectPlayed(d, false, &.{ .{ "pypi-smoke-macos-arm64", "skipped" }, .{ "result-pypi", "success" } }, &.{ PUBLISHED, .{ .kind = "error", .title = "pypi-macos-arm64", .text = "PyPI holds the macOS wheel of komira " ++ V ++ " with other bytes than TestPyPI serves: nothing was uploaded and PyPI was not smoked" } });
    try expectUploads(d, &.{});
    const s = try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "same"), MAC_PROMOTED, state("pypi-macos-arm64", "same"), .{ .job = "pypi-smoke-macos-arm64", .result = "failure" } } });
    try expectPlayed(s, false, &.{}, &.{ PUBLISHED, .{ .kind = "error", .title = "pypi-macos-arm64", .text = "the macOS PyPI smoke job did not succeed (pypi-smoke-macos-arm64 failure)" } });
}
