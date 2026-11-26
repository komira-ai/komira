//! The job `wheel-user-test`, the user test of the wheel file, as pypi.yml's push run holds it before its first
//! upload (docs/ci.md, "The user test of the wheel file"); the job it needs, the artifacts' names and the gate are
//! the Spec's. `check` reads the job's lines (comment and blank lines dropped) and says why they break the
//! contract, or null. What the contract holds:
//!  - it needs exactly the job that built the wheel, takes its matrix from that job's output `matrix` with
//!    `fail-fast: false` (every Python finishes), and runs on the runner of the matrix entry;
//!  - it holds no permission, no environment and no identity, checks out nothing, joins no farm, runs no buck2,
//!    uploads to no index and never continues on an error;
//!  - its steps, in order: the dist and the smoke artifacts downloaded into the runner's temporary directory, the
//!    driver made executable, the pinned setup-python with the matrix entry's Python, then one step that runs
//!    `pypi_smoke install --index dist` on the dist directory with that interpreter and the quickstart, its
//!    expected output and the ABI table from the smoke artifact (no file of a checkout).
//! The build job's side (the copy of those files and the matrix step) is in pypi_workflow_contract.zig.

const std = @import("std");

/// What differs between the two workflows.
pub const Spec = struct {
    /// The job that built the wheel, e.g. `wheel` or `build`.
    build_job: []const u8,
    /// The artifacts are `<artifact>-dist` and `<artifact>-smoke`.
    artifact: []const u8,
    /// The job's whole `if:` line, or null for none.
    gate: ?[]const u8,
};

pub const JOB = "wheel-user-test";
pub const RUNS_ON = "    runs-on: ${{ matrix.runner }}";
pub const SETUP_PYTHON = "      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0";
pub const DOWNLOAD = "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1";
pub const PYTHON_VERSION = "          python-version: ${{ matrix.python }}";
pub const PYTHON_ENV = "          PYTHON: ${{ steps.python.outputs.python-path }}";
pub const CHMOD = "        run: chmod +x \"$RUNNER_TEMP/wheel/smoke/pypi_smoke\"";
pub const INSTALL_STEP = "      - name: pip installs the wheel file into an empty environment and the quickstart prints what it should";
pub const INSTALL_RUN = "        run: '\"$RUNNER_TEMP/wheel/smoke/pypi_smoke\" install --index dist --dist \"$RUNNER_TEMP/wheel/dist\" --python \"$PYTHON\" --example \"$RUNNER_TEMP/wheel/smoke/quickstart.py\" --expect \"$RUNNER_TEMP/wheel/smoke/quickstart.expected\" --abi-table \"$RUNNER_TEMP/wheel/smoke/komira.tsv\" --work \"$RUNNER_TEMP/wheel/install\"'";
pub const DIST_PATH = "          path: ${{ runner.temp }}/wheel/dist";
pub const SMOKE_PATH = "          path: ${{ runner.temp }}/wheel/smoke";

/// The words no line of the job may hold: a checkout, the farm, buck2, an upload or an index publisher, an
/// error that does not fail the job, an identity.
const FORBIDDEN = [_][]const u8{ "actions/checkout", "farm-connect", "buck2", "gh-action-pypi-publish", "twine", "continue-on-error", "id-token", "environment:", "secrets" };

fn has(lines: []const []const u8, exact: []const u8) bool {
    for (lines) |l| if (std.mem.eql(u8, l, exact)) return true;
    return false;
}

fn lineAt(lines: []const []const u8, exact: []const u8) ?usize {
    for (lines, 0..) |l, i| if (std.mem.eql(u8, l, exact)) return i;
    return null;
}

fn count(lines: []const []const u8, needle: []const u8) usize {
    var n: usize = 0;
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) n += 1;
    }
    return n;
}

fn countPrefix(lines: []const []const u8, prefix: []const u8) usize {
    var n: usize = 0;
    for (lines) |l| {
        if (std.mem.startsWith(u8, l, prefix)) n += 1;
    }
    return n;
}

/// Null if the lines of the job `wheel-user-test` hold the contract for `spec`, else the refusal.
pub fn check(ar: std.mem.Allocator, job: []const []const u8, spec: Spec) !?[]const u8 {
    const needs = try std.fmt.allocPrint(ar, "    needs: {s}", .{spec.build_job});
    if (!has(job, needs) or countPrefix(job, "    needs:") != 1) return try std.fmt.allocPrint(ar, JOB ++ ": its needs: is not exactly `needs: {s}` (the job that built the wheel)", .{spec.build_job});
    if (spec.gate) |g| {
        if (!has(job, g) or countPrefix(job, "    if:") != 1) return try std.fmt.allocPrint(ar, JOB ++ ": its if: is not exactly `{s}`", .{std.mem.trim(u8, g, " ")});
    } else if (countPrefix(job, "    if:") != 0) return JOB ++ ": it has an if: (it runs whenever the wheel was built)";
    if (!has(job, RUNS_ON) or countPrefix(job, "    runs-on:") != 1) return JOB ++ ": runs-on is not exactly the runner of the matrix entry";
    if (!has(job, "    permissions: {}") or countPrefix(job, "    permissions") != 1) return JOB ++ ": permissions is not exactly `{}`";
    for (FORBIDDEN) |w| {
        if (count(job, w) != 0) return try std.fmt.allocPrint(ar, JOB ++ ": a line names \"{s}\": the test checks out nothing, joins no farm, uploads nothing and holds no identity", .{w});
    }
    const matrix = try std.fmt.allocPrint(ar, "      matrix: ${{{{ fromJSON(needs.{s}.outputs.matrix) }}}}", .{spec.build_job});
    for ([_][]const u8{ "    strategy:", "      fail-fast: false", matrix }) |l| {
        if (!has(job, l)) return try std.fmt.allocPrint(ar, JOB ++ ": the matrix is not the build job's, with fail-fast off: the line `{s}` is missing", .{std.mem.trim(u8, l, " ")});
    }
    if (countPrefix(job, "    strategy:") != 1 or countPrefix(job, "      matrix:") != 1) return JOB ++ ": it has more than one strategy or matrix";

    const dist_name = try std.fmt.allocPrint(ar, "          name: {s}-dist", .{spec.artifact});
    const smoke_name = try std.fmt.allocPrint(ar, "          name: {s}-smoke", .{spec.artifact});
    for ([_][]const u8{ dist_name, DIST_PATH, smoke_name, SMOKE_PATH, CHMOD, SETUP_PYTHON, "        id: python", PYTHON_VERSION, INSTALL_STEP, PYTHON_ENV, INSTALL_RUN }) |l| {
        if (!has(job, l)) return try std.fmt.allocPrint(ar, JOB ++ ": download, set up the matrix Python and install the dist directory: the line `{s}` is missing", .{std.mem.trim(u8, l, " ")});
    }
    if (count(job, "actions/download-artifact@") != 2) return JOB ++ ": it does not download exactly the dist and the smoke artifacts";
    if (count(job, "setup-python") != 1) return JOB ++ ": it does not set up Python exactly once";
    if (countPrefix(job, "        run:") != 2) return JOB ++ ": it runs more than the chmod and the install";
    const dist_at = lineAt(job, DIST_PATH).?;
    const smoke_at = lineAt(job, SMOKE_PATH).?;
    const chmod_at = lineAt(job, CHMOD).?;
    const setup_at = lineAt(job, SETUP_PYTHON).?;
    const install_at = lineAt(job, INSTALL_RUN).?;
    if (!(dist_at < chmod_at and smoke_at < chmod_at and chmod_at < setup_at and setup_at < install_at)) return JOB ++ ": the steps are not the downloads, the chmod, set up Python, then install";
    return null;
}

// ---- the contract's own cases, on a job written here ---------------------------------------------

const SPEC = Spec{ .build_job = "wheel", .artifact = "wheel-${{ github.sha }}", .gate = null };

const GOOD =
    \\    needs: wheel
    \\    runs-on: ${{ matrix.runner }}
    \\    timeout-minutes: 20
    \\    permissions: {}
    \\    strategy:
    \\      fail-fast: false
    \\      matrix: ${{ fromJSON(needs.wheel.outputs.matrix) }}
    \\    steps:
    \\      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
    \\        with:
    \\          name: wheel-${{ github.sha }}-dist
    \\          path: ${{ runner.temp }}/wheel/dist
    \\      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
    \\        with:
    \\          name: wheel-${{ github.sha }}-smoke
    \\          path: ${{ runner.temp }}/wheel/smoke
    \\      - name: the driver is executable
    \\        run: chmod +x "$RUNNER_TEMP/wheel/smoke/pypi_smoke"
    \\      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0
    \\        id: python
    \\        with:
    \\          python-version: ${{ matrix.python }}
    \\      - name: pip installs the wheel file into an empty environment and the quickstart prints what it should
    \\        env:
    \\          PYTHON: ${{ steps.python.outputs.python-path }}
++ "\n" ++ INSTALL_RUN;

fn linesOf(ar: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(ar, l);
    return out.toOwnedSlice(ar);
}

fn expectRefused(ar: std.mem.Allocator, from: []const u8, to: []const u8, want: []const u8) !void {
    if (std.mem.indexOf(u8, GOOD, from) == null) return error.NoAnchor;
    const text = try std.mem.replaceOwned(u8, ar, GOOD, from, to);
    const got = (try check(ar, try linesOf(ar, text), SPEC)) orelse {
        std.debug.print("accepted a job that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

test "the job written to the contract holds it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    if (try check(ar, try linesOf(ar, GOOD), SPEC)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "each defect of the user test job is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    // needs another job, or one more; a gate where there is none
    try expectRefused(ar, "    needs: wheel\n", "    needs: release\n", "its needs: is not exactly");
    try expectRefused(ar, "    needs: wheel\n", "    needs: [wheel, mopm-stage]\n", "its needs: is not exactly");
    try expectRefused(ar, "    needs: wheel\n", "    needs: wheel\n    if: github.event_name == 'push'\n", "it has an if:");
    // a fixed runner, a permission, an identity, an environment
    try expectRefused(ar, RUNS_ON, "    runs-on: ubuntu-24.04", "runs-on is not exactly");
    try expectRefused(ar, "    permissions: {}", "    permissions:\n      contents: read", "permissions is not exactly");
    try expectRefused(ar, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    environment: build\n", "names \"environment:\"");
    // a checkout, the farm, an upload, an error that does not fail the job
    try expectRefused(ar, "    steps:\n", "    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n", "names \"actions/checkout\"");
    try expectRefused(ar, "    steps:\n", "    steps:\n      - uses: ./.github/actions/farm-connect\n", "names \"farm-connect\"");
    try expectRefused(ar, "    steps:\n", "    steps:\n      - uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # v1.14.3\n", "names \"gh-action-pypi-publish\"");
    try expectRefused(ar, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    continue-on-error: true\n", "names \"continue-on-error\"");
    // the matrix: fail-fast on, another job's, a second one
    try expectRefused(ar, "      fail-fast: false\n", "", "fail-fast off");
    try expectRefused(ar, "fromJSON(needs.wheel.outputs.matrix)", "fromJSON('{\"include\":[{\"python\":\"3.13\"}]}')", "the matrix is not the build job's");
    // the downloads, the Python, the install line
    try expectRefused(ar, "          name: wheel-${{ github.sha }}-dist\n", "          name: wheel-dist\n", "the line `name: wheel-${{ github.sha }}-dist` is missing");
    try expectRefused(ar, PYTHON_VERSION, "          python-version: '3.13'", "the line `python-version: ${{ matrix.python }}` is missing");
    try expectRefused(ar, "--index dist", "--index testpypi", "install the dist directory");
    try expectRefused(ar, "--example \"$RUNNER_TEMP/wheel/smoke/quickstart.py\"", "--example python/examples/quickstart.py", "install the dist directory");
    try expectRefused(ar, "        id: python\n        with:\n          python-version: ${{ matrix.python }}\n", "        id: python\n        with:\n          python-version: ${{ matrix.python }}\n" ++ SETUP_PYTHON ++ "\n", "set up Python exactly once");
    // a third run step, and the install before the Python is set up
    try expectRefused(ar, "      - name: the driver is executable\n", "      - name: list\n        run: ls\n      - name: the driver is executable\n", "it runs more than the chmod and the install");
    // a second matrix, a third download
    try expectRefused(ar, "      fail-fast: false\n", "      fail-fast: false\n      matrix: ${{ fromJSON(needs.wheel.outputs.matrix) }}\n", "it has more than one strategy or matrix");
    try expectRefused(ar, "      - name: the driver is executable\n", DOWNLOAD ++ "\n        with:\n          name: wheel-${{ github.sha }}-extra\n          path: ${{ runner.temp }}/wheel/extra\n      - name: the driver is executable\n", "it does not download exactly the dist and the smoke artifacts");
    const install_block = INSTALL_STEP ++ "\n        env:\n" ++ PYTHON_ENV ++ "\n" ++ INSTALL_RUN;
    const setup_block = SETUP_PYTHON ++ "\n        id: python\n        with:\n" ++ PYTHON_VERSION ++ "\n";
    try expectRefused(ar, setup_block ++ install_block, install_block ++ "\n" ++ setup_block, "the steps are not the downloads, the chmod, set up Python, then install");
}

test "a gated spec wants its gate exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const gate = "    if: github.ref == 'refs/heads/main'";
    const gated = Spec{ .build_job = "wheel", .artifact = "wheel-${{ github.sha }}", .gate = gate };
    const with_gate = try std.mem.replaceOwned(u8, ar, GOOD, "    needs: wheel\n", "    needs: wheel\n" ++ gate ++ "\n");
    try std.testing.expect((try check(ar, try linesOf(ar, with_gate), gated)) == null);
    // no gate, another gate, the gate twice
    const want = "wheel-user-test: its if: is not exactly `if: github.ref == 'refs/heads/main'`";
    try std.testing.expectEqualStrings(want, (try check(ar, try linesOf(ar, GOOD), gated)).?);
    const other = try std.mem.replaceOwned(u8, ar, GOOD, "    needs: wheel\n", "    needs: wheel\n    if: always()\n");
    try std.testing.expectEqualStrings(want, (try check(ar, try linesOf(ar, other), gated)).?);
    const twice = try std.mem.replaceOwned(u8, ar, GOOD, "    needs: wheel\n", "    needs: wheel\n" ++ gate ++ "\n" ++ gate ++ "\n");
    try std.testing.expectEqualStrings(want, (try check(ar, try linesOf(ar, twice), gated)).?);
}
