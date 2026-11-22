//! The cases of pypi-macos-arm64.yml, the publish of the Python package's macOS arm64 wheel,
//! //:pypi_macos_workflow_cases: a `zig_test` run as a build action. The workflow's own bytes are the
//! subject (the zig_test's `data`, under KOMIRA_TEST_WORK/workflows/, with pypi.yml, whose triggers it
//! repeats, and release.yml, whose push filter both repeat). pypi_macos_workflow_contract.zig's `check`
//! reads the text and says why it breaks the contract, or null (its header says what the contract holds);
//! each case here writes one defect into the real text and wants it refused with its message. What a run
//! of the file does, alone and beside pypi.yml's, is played in pypi_macos_workflow_run.zig. The macOS
//! build job's own steps (the present step, the gates of the Mac builds) are //:release_macos_cases'.

const std = @import("std");
const t = std.testing;
const reader = @import("pypi_workflow_text.zig");
const linux = @import("pypi_workflow_contract.zig");
const c = @import("pypi_macos_workflow_contract.zig");
const replaced = reader.replaced;
const inJob = reader.inJob;

const Texts = struct { macos: []const u8, pypi: []const u8, release: []const u8 };

fn texts(ar: std.mem.Allocator) !Texts {
    return .{ .macos = try reader.readMacosWorkflow(ar), .pypi = try reader.readWorkflow(ar), .release = try reader.readRelease(ar) };
}

fn expectRefused(ar: std.mem.Allocator, x: Texts, text: []const u8, want: []const u8) !void {
    const got = (try c.check(ar, text, x.pypi, x.release)) orelse {
        std.debug.print("accepted a workflow that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

fn expectHolds(ar: std.mem.Allocator, text: []const u8, pypi: []const u8, release: []const u8) !void {
    if (try c.check(ar, text, pypi, release)) |why| {
        std.debug.print("pypi-macos-arm64.yml: {s}\n", .{why});
        return error.Refused;
    }
}

test "pypi-macos-arm64.yml holds the contract of the macOS wheel's publish workflow" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    try expectHolds(ar, x.macos, x.pypi, x.release);
    // a comment may talk about what the file does not hold
    try expectHolds(ar, try replaced(ar, x.macos, "name: pypi-macos-arm64\n", "name: pypi-macos-arm64\n# no secrets, no twine, no schedule, no inputs.flavour: a comment says so\n"), x.pypi, x.release);
}

test "the triggers are pypi.yml's, line for line: each drift of either file is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.macos;
    const other = "on: is not pypi.yml's, line for line";
    // another daily time, in either file: one workflow's promotion would run without the other's
    try expectRefused(ar, x, try replaced(ar, text, "'17 5 * * *'", "'17 6 * * *'"), other);
    try t.expect((try c.check(ar, text, try replaced(ar, x.pypi, "'17 5 * * *'", "'5 17 * * *'"), x.release)) != null);
    // the two moved together hold
    try expectHolds(ar, try replaced(ar, text, "'17 5 * * *'", "'5 17 * * *'"), try replaced(ar, x.pypi, "'17 5 * * *'", "'5 17 * * *'"), x.release);
    // the push filter, the schedule, the manual run: what every publish workflow holds
    const on = "on: is not exactly a push to main";
    try expectRefused(ar, x, try replaced(ar, text, "      - '**.md'\n", ""), on);
    try expectRefused(ar, x, try replaced(ar, text, "  schedule:\n    - cron: '17 5 * * *'\n", ""), on);
    try expectRefused(ar, x, try replaced(ar, text, "  workflow_dispatch:\n", "  workflow_dispatch:\n    inputs:\n      index:\n        type: string\n"), on);
    try expectRefused(ar, x, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  pull_request:\n  workflow_dispatch:\n"), "a pull request trigger");
}

test "the concurrency is a group per half of its own, never pypi.yml's, and cancels nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.macos;
    const conc = "concurrency is not exactly one group per half of its own";
    try expectRefused(ar, x, try replaced(ar, text, c.GROUP ++ "\n", linux.GROUP ++ "\n"), conc);
    try expectRefused(ar, x, try replaced(ar, text, c.GROUP ++ "\n", "  group: pypi-macos-arm64\n"), conc);
    try expectRefused(ar, x, try replaced(ar, text, linux.NO_CANCEL ++ "\n", "  cancel-in-progress: true\n"), conc);
    try expectRefused(ar, x, try replaced(ar, text, "\npermissions: {}\n", "\npermissions:\n  contents: write\n"), "top-level permissions");
}

test "the job set is exactly the nine jobs of the macOS wheel, each once: a Linux job is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.macos;
    const jobs = "the jobs are not exactly the nine";
    try expectRefused(ar, x, try replaced(ar, text, "\n  result-pypi-macos-arm64:\n", "\n  build:\n    runs-on: ubuntu-24.04\n\n  result-pypi-macos-arm64:\n"), jobs);
    try expectRefused(ar, x, try replaced(ar, text, "\n  pypi-smoke-macos-arm64:\n", "\n  pypi-smoke-macos:\n"), jobs);
    try expectRefused(ar, x, try replaced(ar, text, "\n  result-testpypi-macos-arm64:\n", "\n  result-testpypi:\n"), jobs);
}

test "each macOS job is in its half, with its needs, environment, runner and permissions" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.macos;
    const main_only = "    if: github.ref == 'refs/heads/main'\n";
    for ([_][]const u8{ "build-macos-arm64", "testpypi-passed-macos-arm64" }) |job| {
        try expectRefused(ar, x, try inJob(ar, text, job, linux.PUSH_GATE ++ "\n", main_only), try std.fmt.allocPrint(ar, "{s}: its if:", .{job}));
        try expectRefused(ar, x, try inJob(ar, text, job, linux.PUSH_GATE ++ "\n", linux.PROMOTE_GATE ++ "\n"), try std.fmt.allocPrint(ar, "{s}: its if:", .{job}));
    }
    for ([_][]const u8{ "promote-macos-arm64", "pypi-macos-arm64" }) |job| {
        try expectRefused(ar, x, try inJob(ar, text, job, linux.PROMOTE_GATE ++ "\n", main_only), try std.fmt.allocPrint(ar, "{s}: its if:", .{job}));
        try expectRefused(ar, x, try inJob(ar, text, job, linux.PROMOTE_GATE ++ "\n", linux.PUSH_GATE ++ "\n"), try std.fmt.allocPrint(ar, "{s}: its if:", .{job}));
    }
    try expectRefused(ar, x, try inJob(ar, text, "result-pypi-macos-arm64", linux.RESULT_PROMOTE_GATE ++ "\n", "    if: always()\n"), "result-pypi-macos-arm64: its if:");
    // the upload waits for a wheel that was built
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-macos-arm64", " && needs.build-macos-arm64.outputs.version != ''\n", "\n"), "testpypi-macos-arm64: its if:");
    // the record waits for every smoke job, the PyPI smoke for the upload
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-passed-macos-arm64", "    needs: [build-macos-arm64, testpypi-smoke-macos-arm64]\n", "    needs: [build-macos-arm64, testpypi-macos-arm64]\n"), "testpypi-passed-macos-arm64: its needs:");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke-macos-arm64", "    needs: [promote-macos-arm64, pypi-macos-arm64]\n", "    needs: promote-macos-arm64\n"), "pypi-smoke-macos-arm64: its needs:");
    // the environment each index trusts, and none on the promote job
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-macos-arm64", "    environment: testpypi\n", "    environment: build\n"), "testpypi-macos-arm64: its environment");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-macos-arm64", "    environment: pypi\n", ""), "pypi-macos-arm64: its environment");
    try expectRefused(ar, x, try inJob(ar, text, "promote-macos-arm64", "    timeout-minutes: 30\n", "    timeout-minutes: 30\n    environment: pypi\n"), "promote-macos-arm64: an environment");
    // hosted runners: the smokes on macos-15, the rest on ubuntu-24.04
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke-macos-arm64", linux.MACOS ++ "\n", "    runs-on: macos-latest\n"), "pypi-smoke-macos-arm64: runs-on");
    try expectRefused(ar, x, try inJob(ar, text, "promote-macos-arm64", linux.UBUNTU ++ "\n", linux.MACOS ++ "\n"), "promote-macos-arm64: runs-on");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-macos-arm64", linux.UBUNTU ++ "\n", "    runs-on: self-hosted\n"), "testpypi-macos-arm64: runs-on");
    // id-token: on the build and the two uploads alone
    for ([_][]const u8{ "testpypi-smoke-macos-arm64", "testpypi-passed-macos-arm64", "promote-macos-arm64", "pypi-smoke-macos-arm64", "result-pypi-macos-arm64" }) |job| {
        try expectRefused(ar, x, try inJob(ar, text, job, "    permissions: {}\n", "    permissions:\n      id-token: write\n"), try std.fmt.allocPrint(ar, "{s}: permissions", .{job}));
    }
    try expectRefused(ar, x, try inJob(ar, text, "pypi-macos-arm64", "      id-token: write\n", "      contents: read\n"), "pypi-macos-arm64: permissions");
    try expectRefused(ar, x, try inJob(ar, text, "build-macos-arm64", "      contents: read\n", "      contents: write\n"), "build-macos-arm64: permissions");
}

test "the farm, buck2, a cache write and an upload stay in their own macOS jobs; no secret, token or unpinned action" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.macos;
    try expectRefused(ar, x, try inJob(ar, text, "promote-macos-arm64", "      - name: the driver is executable\n", "      - run: ./buck2 build //python:komira_wheel_macos_arm64\n      - name: the driver is executable\n"), "promote-macos-arm64: runs buck2");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-macos-arm64", "      - name: the driver is executable\n", linux.FARM_CONNECT ++ "\n      - name: the driver is executable\n"), "testpypi-macos-arm64: farm-connect");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke-macos-arm64", "    steps:\n", "    steps:\n" ++ linux.CHECKOUT ++ "\n"), "testpypi-smoke-macos-arm64: checks out");
    const save = "      - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: pypi-passed-macos-arm64-x\n";
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke-macos-arm64", "      - name: the driver is executable\n", save ++ "      - name: the driver is executable\n"), "testpypi-smoke-macos-arm64: saves to the cache where it may not");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-macos-arm64", "          packages-dir: dist\n", "          packages-dir: dist\n          password: x\n"), "contains \"password\"");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-macos-arm64", "          packages-dir: dist\n", "          packages-dir: dist\n          token: ${{ secrets.PYPI_API_TOKEN }}\n"), "contains \"secrets\"");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-macos-arm64", "      - name: the driver is executable\n", "      - run: twine upload dist/*\n      - name: the driver is executable\n"), "contains \"twine\"");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke-macos-arm64", linux.SETUP_PYTHON, "      - uses: actions/setup-python@v7"), "an action is not pinned");
    try expectRefused(ar, x, try inJob(ar, text, "promote-macos-arm64", "        run: chmod +x \"$RUNNER_TEMP/pypi-macos-arm64/passed/pypi_smoke\"", "        run: chmod +x \"${{ runner.temp }}/pypi-macos-arm64/passed/pypi_smoke\""), "expression");
    try expectRefused(ar, x, try inJob(ar, text, "result-pypi-macos-arm64", "        if: needs.promote-macos-arm64.result != 'success'\n", "        if: inputs.flavour == 'bundled' && needs.promote-macos-arm64.result != 'success'\n"), "reads a run input");
}

test "the macOS jobs after the build hold their outputs and steps exactly: each drift is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.macos;
    const exact = ": its outputs and steps are not exactly the contract's";
    // the promotion restores the Linux record, goes on without a record, or restores another directory
    try expectRefused(ar, x, try inJob(ar, text, "promote-macos-arm64", "          restore-keys: pypi-passed-macos-arm64-\n", "          restore-keys: pypi-passed-linux-x86_64-\n"), "promote-macos-arm64" ++ exact);
    try expectRefused(ar, x, try inJob(ar, text, "promote-macos-arm64", "          fail-on-cache-miss: true\n", ""), "promote-macos-arm64" ++ exact);
    try expectRefused(ar, x, try inJob(ar, text, "promote-macos-arm64", "          path: ${{ runner.temp }}/pypi-macos-arm64/passed\n          key:", "          path: ${{ runner.temp }}/pypi/passed\n          key:"), "promote-macos-arm64" ++ exact);
    // the record without its version, or saved before the smoke's verdict (a third step)
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-passed-macos-arm64", "          key: pypi-passed-macos-arm64-${{ needs.build-macos-arm64.outputs.version }}\n", "          key: pypi-passed-macos-arm64-\n"), "testpypi-passed-macos-arm64" ++ exact);
    // the uploads: TestPyPI's address dropped (the macOS wheel would go to PyPI), an upload for `same`
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-macos-arm64", "          repository-url: https://test.pypi.org/legacy/\n", ""), "testpypi-macos-arm64" ++ exact);
    try expectRefused(ar, x, try inJob(ar, text, "pypi-macos-arm64", linux.STATE_ENABLED ++ "\n", "        if: steps.state.outputs.state != 'differs'\n"), "pypi-macos-arm64" ++ exact);
    try expectRefused(ar, x, try inJob(ar, text, "pypi-macos-arm64", "      state: ${{ steps.state.outputs.state }}\n", ""), "pypi-macos-arm64" ++ exact);
    // the smokes: the Linux driver on the Mac, the quickstart of a checkout
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke-macos-arm64", "smoke/pypi_smoke_macos_arm64\" verify", "smoke/pypi_smoke\" verify"), "pypi-smoke-macos-arm64" ++ exact);
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke-macos-arm64", "--example \"$RUNNER_TEMP/pypi-macos-arm64/smoke/quickstart.py\"", "--example python/examples/quickstart.py"), "testpypi-smoke-macos-arm64" ++ exact);
    // the verdicts: an error that ends the run green, a step appended
    try expectRefused(ar, x, try inJob(ar, text, "result-pypi-macos-arm64", "(pypi-smoke-macos-arm64 $PYPI_SMOKE)\" && exit 1'", "(pypi-smoke-macos-arm64 $PYPI_SMOKE)\"'"), "result-pypi-macos-arm64" ++ exact);
    try expectRefused(ar, x, try inJob(ar, text, "result-testpypi-macos-arm64", "          PASSED: ${{ needs.testpypi-passed-macos-arm64.result }}\n", "          PASSED: ${{ needs.testpypi-passed-macos-arm64.result }}\n      - name: one more\n        run: echo done\n"), "result-testpypi-macos-arm64" ++ exact);
}

test {
    // the contract and the cases that play a run of the file, alone and beside pypi.yml
    _ = @import("pypi_macos_workflow_contract.zig");
    _ = @import("pypi_macos_workflow_run.zig");
}
