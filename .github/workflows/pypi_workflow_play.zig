//! The play of the publish workflow (pypi.yml: the chain of the Linux wheel and the chain of the macOS
//! arm64 wheel), from the workflow's own text, for each event (a push to main, the daily schedule, a manual
//! run), each answer an index gives (`absent`, `same`, `differs`) and the failure of a job: which jobs run
//! and which are skipped, which jobs upload to an index and which save the record of a version, what the
//! verdict jobs (`result-...`) print, and whether the run ends green. Two more plays read the top of a
//! file: whether a push of a set of paths starts a run at all (`on.push`'s `paths-ignore`), and which runs
//! of a sequence of events, of one workflow or of several, start, wait or are replaced (`concurrency:`).
//! `chain` gives the run as one wheel's chain sees it (its jobs, the messages under its title, its uploads
//! and records), so a case can hold one chain to what it does whatever the other does. It holds no
//! case: pypi_workflow_run.zig plays the Linux chain and pypi_macos_jobs_run.zig the macOS chain and the
//! two side by side (both //:pypi_workflow_cases).
//!
//! The play holds the part of GitHub's rules the files use and refuses anything else by name, so an
//! edit the play cannot read fails the cases instead of passing them:
//!  - the jobs run in file order (each job's `needs:` are above it); a job needs only jobs of its own
//!    file, so a run of one workflow never reads another's jobs;
//!  - a job whose `if:` has no `always()` runs only when every job it needs succeeded, else it is
//!    skipped; then its `if:` decides; a skipped job's outputs are empty;
//!  - an expression is a string literal, `github.ref` (a run of these files is on main),
//!    `github.event_name`, `needs.<job>.result` and `needs.<job>.outputs.<name>` of a job the reading job
//!    needs (the workflows take no input, so `inputs.<name>` is refused like any other unknown name),
//!    `always()`, `!`, `==`, `!=`, `&&`, `||` and parentheses, with GitHub's values: `||` and `&&` give one
//!    of their operands, an empty string is false, and strings compare without regard to case;
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
//!  - a run joins the group its workflow's `concurrency.group` gives for its event, and a group's name
//!    is the repository's, whichever workflow names it; with `cancel-in-progress: false` a run starts
//!    when its group runs nothing, else it waits, and a newer run of the group replaces the one that
//!    waits (that one is cancelled, never started); with `true` it cancels the group's runs and starts.
//! `expanded` writes out each `${{ }}` of a job's lines the same way, with `steps.*` and `runner.*`
//! as `<steps...>` and `<runner...>`, so a case reads the target a run builds.

const std = @import("std");
const reader = @import("pypi_workflow_text.zig");

/// How a job that runs ends, as the case says: the farm's, the index's or the smoke's answer.
pub const End = struct {
    job: []const u8,
    result: []const u8 = "success",
    outputs: []const [2][]const u8 = &.{},
};

/// The event of the run and how each job that runs ends.
pub const Case = struct {
    event: []const u8,
    ends: []const End = &.{},
};

pub const Done = struct {
    name: []const u8,
    result: []const u8,
    outputs: []const [2][]const u8,
};

pub const Message = struct {
    kind: []const u8,
    title: []const u8,
    text: []const u8,
};

pub const Played = struct {
    jobs: []const Done,
    messages: []const Message,
    /// the jobs whose publish step ran, in file order
    uploads: []const []const u8,
    /// the jobs whose record (actions/cache/save) was saved, in file order
    records: []const []const u8,

    pub fn resultOf(self: Played, name: []const u8) []const u8 {
        for (self.jobs) |d| if (std.mem.eql(u8, d.name, name)) return d.result;
        return "(no such job)";
    }

    pub fn green(self: Played) bool {
        for (self.jobs) |d| if (std.mem.eql(u8, d.result, "failure")) return false;
        return true;
    }
};

/// The jobs of the macOS arm64 wheel's chain end in this; every other job is the Linux wheel's.
pub const MACOS_SUFFIX = "-macos-arm64";
/// The title of the macOS chain's verdict messages; the Linux chain's is `pypi`.
pub const MACOS_TITLE = "pypi-macos-arm64";

pub const Chain = enum { linux, macos };

fn ofChain(name: []const u8, which: Chain) bool {
    return std.mem.endsWith(u8, name, MACOS_SUFFIX) == (which == .macos);
}

/// The run `p` as the chain `which` sees it: its own jobs, the messages under its own title, and the
/// uploads and records of its own jobs, in order. The view's `green()` is that chain's verdict alone.
pub fn chain(ar: std.mem.Allocator, p: Played, which: Chain) !Played {
    var jobs = std.ArrayList(Done).empty;
    for (p.jobs) |d| if (ofChain(d.name, which)) try jobs.append(ar, d);
    var messages = std.ArrayList(Message).empty;
    for (p.messages) |m| if (std.mem.eql(u8, m.title, MACOS_TITLE) == (which == .macos)) try messages.append(ar, m);
    var uploads = std.ArrayList([]const u8).empty;
    for (p.uploads) |u| if (ofChain(u, which)) try uploads.append(ar, u);
    var records = std.ArrayList([]const u8).empty;
    for (p.records) |r| if (ofChain(r, which)) try records.append(ar, r);
    return .{ .jobs = try jobs.toOwnedSlice(ar), .messages = try messages.toOwnedSlice(ar), .uploads = try uploads.toOwnedSlice(ar), .records = try records.toOwnedSlice(ar) };
}

fn unreadable(comptime fmt: []const u8, args: anytype) error{Unreadable} {
    std.debug.print("the play cannot read the workflow: " ++ fmt ++ "\n", args);
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

pub fn play(ar: std.mem.Allocator, text: []const u8, case: Case) !Played {
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
        } else return unreadable("the case names a job the workflow does not have: {s}", .{e.job});
        if (std.mem.eql(u8, d.result, "skipped")) return unreadable("the case says how {s} ends, and it was skipped", .{e.job});
    }
    return .{ .jobs = try done.toOwnedSlice(ar), .messages = try messages.toOwnedSlice(ar), .uploads = try uploads.toOwnedSlice(ar), .records = try records.toOwnedSlice(ar) };
}

/// The lines of the job `name`, each `${{ }}` written out for the case (a job that needs nothing).
pub fn expanded(ar: std.mem.Allocator, text: []const u8, case: Case, name: []const u8) ![]const []const u8 {
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
pub fn pushStarts(ar: std.mem.Allocator, text: []const u8, paths: []const []const u8) !bool {
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
pub const Arrival = struct {
    run: []const u8,
    event: ?[]const u8 = null,
    /// which of the texts given to `queueOf` the run is of
    file: usize = 0,
};

pub fn arrive(run: []const u8, event: []const u8) Arrival {
    return .{ .run = run, .event = event };
}

pub fn leave(run: []const u8) Arrival {
    return .{ .run = run };
}

pub const Queued = struct {
    /// the runs that started, in order
    started: []const []const u8,
    /// the runs cancelled, in order: a waiting run replaced, or a running one
    cancelled: []const []const u8,
};

/// The group and the cancelling of one workflow's `concurrency:`.
const Concurrency = struct { group: []const u8, cancels: bool };

fn concurrencyOf(ar: std.mem.Allocator, text: []const u8) !Concurrency {
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
    return .{
        .group = group orelse return unreadable("a concurrency without a group", .{}),
        .cancels = cancel orelse return unreadable("a concurrency without cancel-in-progress", .{}),
    };
}

/// The runs of `arrivals` of one workflow under its `concurrency:` (the header says how).
pub fn queue(ar: std.mem.Allocator, text: []const u8, arrivals: []const Arrival) !Queued {
    return queueOf(ar, &.{text}, arrivals);
}

/// The runs of `arrivals`, each a run of the workflow `texts[arrival.file]` under that workflow's
/// `concurrency:`. A group is the repository's: runs of two workflows whose groups have the same name
/// wait on and replace each other as the runs of one workflow do.
pub fn queueOf(ar: std.mem.Allocator, texts: []const []const u8, arrivals: []const Arrival) !Queued {
    var concs = std.ArrayList(Concurrency).empty;
    for (texts) |text| try concs.append(ar, try concurrencyOf(ar, text));
    const Slot = struct { name: []const u8, running: ?[]const u8 = null, waiting: ?[]const u8 = null };
    var slots = std.ArrayList(Slot).empty;
    var started = std.ArrayList([]const u8).empty;
    var cancelled = std.ArrayList([]const u8).empty;
    for (arrivals) |a| {
        if (a.event) |event| {
            if (a.file >= concs.items.len) return unreadable("the case's run {s} is of workflow {d}, and there are {d}", .{ a.run, a.file, concs.items.len });
            const conc = concs.items[a.file];
            const name = try expandLine(ar, conc.group, .{ .case = .{ .event = event }, .needs = &.{}, .done = &.{} });
            const slot = for (slots.items) |*s| {
                if (std.mem.eql(u8, s.name, name)) break s;
            } else blk: {
                try slots.append(ar, .{ .name = name });
                break :blk &slots.items[slots.items.len - 1];
            };
            if (conc.cancels) {
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

// ---- what the cases share ---------------------------------------------------------------------------

/// A job that ends with the output `state` (an upload job's answer from its index).
pub fn state(comptime job: []const u8, comptime s: []const u8) End {
    return .{ .job = job, .outputs = &.{.{ "state", s }} };
}

pub fn notice(comptime title: []const u8, comptime text: []const u8) Message {
    return .{ .kind = "notice", .title = title, .text = text };
}

pub fn failure(comptime title: []const u8, comptime text: []const u8) Message {
    return .{ .kind = "error", .title = title, .text = text };
}

/// Fails unless the run ended `green` (or red), each job of `results` with its result, and printed
/// exactly `messages`, in order.
pub fn expectPlayed(p: Played, green: bool, results: []const [2][]const u8, messages: []const Message) !void {
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

pub fn expectList(what: []const u8, got: []const []const u8, want: []const []const u8) !void {
    var ok = got.len == want.len;
    if (ok) {
        for (want, got) |w, g| ok = ok and std.mem.eql(u8, w, g);
    }
    if (ok) return;
    for (got) |u| std.debug.print("  {s}: got {s}\n", .{ what, u });
    for (want) |u| std.debug.print("  {s}: wanted {s}\n", .{ what, u });
    return error.WrongList;
}

pub fn expectUploads(p: Played, want: []const []const u8) !void {
    return expectList("an upload in", p.uploads, want);
}

pub fn expectRecords(p: Played, want: []const []const u8) !void {
    return expectList("a record saved by", p.records, want);
}

/// Each of `names` with the result `result`, for expectPlayed.
pub fn all(ar: std.mem.Allocator, names: []const []const u8, result: []const u8) ![]const [2][]const u8 {
    var out = std.ArrayList([2][]const u8).empty;
    for (names) |n| try out.append(ar, .{ n, result });
    return out.toOwnedSlice(ar);
}
