//! The cases of the macOS arm64 wheel's nine jobs of pypi.yml, the publish of the Python package's two
//! wheels, part of //:pypi_workflow_cases: a `zig_test` run as a build action. pypi.yml's own bytes are
//! the subject (the zig_test's `data`, under KOMIRA_TEST_WORK/workflows/, with release.yml, whose push
//! filter it repeats). pypi_workflow_contract.zig's `check` reads the text, runs the contract of the
//! file and the ten Linux jobs, then pypi_macos_jobs_contract.zig's of the nine macOS jobs, and says why
//! it breaks the contract, or null; each case here writes one defect of the macOS jobs into the real text
//! and wants it refused with its message. What a run of the file does for the macOS chain is played in
//! pypi_macos_jobs_run.zig. The macOS build job's own steps (the present step, the gates of the Mac
//! builds) are //:release_macos_cases'.

const std = @import("std");
const t = std.testing;
const reader = @import("pypi_workflow_text.zig");
const linux = @import("pypi_workflow_contract.zig");
const replaced = reader.replaced;
const inJob = reader.inJob;

const Texts = struct { pypi: []const u8, release: []const u8 };

fn texts(ar: std.mem.Allocator) !Texts {
    return .{ .pypi = try reader.readWorkflow(ar), .release = try reader.readRelease(ar) };
}

fn expectRefused(ar: std.mem.Allocator, x: Texts, text: []const u8, want: []const u8) !void {
    const got = (try linux.check(ar, text, x.release)) orelse {
        std.debug.print("accepted a workflow that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

test "pypi.yml holds the contract of the macOS wheel's jobs, with the Linux jobs'" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    if (try linux.check(ar, x.pypi, x.release)) |why| {
        std.debug.print("pypi.yml: {s}\n", .{why});
        return error.Refused;
    }
    // a comment may talk about what the file does not hold
    const commented = try replaced(ar, x.pypi, "\njobs:\n", "\n# no secrets, no twine, no inputs.flavour: a comment says so\njobs:\n");
    if (try linux.check(ar, commented, x.release)) |why| {
        std.debug.print("pypi.yml with a comment: {s}\n", .{why});
        return error.Refused;
    }
}

test "the macOS jobs are in pypi.yml in the order of the nineteen: removed, renamed, duplicated or moved is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    const jobs = linux.FILE.jobs_why;
    try expectRefused(ar, x, try replaced(ar, text, "\n  pypi-smoke-macos-arm64:\n", "\n  pypi-smoke-macos:\n"), jobs);
    try expectRefused(ar, x, try replaced(ar, text, "\n  result-testpypi-macos-arm64:\n", "\n  result-testpypi-mac:\n"), jobs);
    // a macOS job removed from its place: its header line gone makes its lines another job's
    try expectRefused(ar, x, try replaced(ar, text, "\n  build-macos-arm64:\n", "\n"), jobs);
    // a macOS job twice
    try expectRefused(ar, x, try replaced(ar, text, "\n  result-pypi-macos-arm64:\n", "\n  result-pypi-macos-arm64:\n    runs-on: ubuntu-24.04\n\n  result-pypi-macos-arm64:\n"), jobs);
    // a macOS job of the TestPyPI half in the promotion half's place, and the other way
    try expectRefused(ar, x, try replaced(ar, text, "\n  promote-macos-arm64:\n", "\n  testpypi-passed-macos-arm64:\n    runs-on: ubuntu-24.04\n\n  promote-macos-arm64:\n"), jobs);
    try expectRefused(ar, x, try replaced(ar, text, "\n  promote:\n", "\n  promote-macos-arm64:\n    runs-on: ubuntu-24.04\n\n  promote:\n"), jobs);
    // a job of neither wheel
    try expectRefused(ar, x, try replaced(ar, text, "\n  result-pypi-macos-arm64:\n", "\n  extra:\n    runs-on: ubuntu-24.04\n\n  result-pypi-macos-arm64:\n"), jobs);
}

test "each macOS job is in its half, with its needs, environment, runner and permissions" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
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
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke-macos-arm64", "    needs: [build-macos-arm64, testpypi-macos-arm64]\n", "    needs: build-macos-arm64\n"), "testpypi-smoke-macos-arm64: its needs:");
    // a verdict that does not need the record, or the PyPI smoke, would end green without it
    try expectRefused(ar, x, try inJob(ar, text, "result-testpypi-macos-arm64", "    needs: [build-macos-arm64, testpypi-macos-arm64, testpypi-smoke-macos-arm64, testpypi-passed-macos-arm64]\n", "    needs: [build-macos-arm64, testpypi-macos-arm64, testpypi-smoke-macos-arm64]\n"), "result-testpypi-macos-arm64: its needs:");
    try expectRefused(ar, x, try inJob(ar, text, "result-pypi-macos-arm64", "    needs: [promote-macos-arm64, pypi-macos-arm64, pypi-smoke-macos-arm64]\n", "    needs: [promote-macos-arm64, pypi-macos-arm64]\n"), "result-pypi-macos-arm64: its needs:");
    // the environment each index trusts, and none on the promote job
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-macos-arm64", "    environment: testpypi\n", "    environment: build\n"), "testpypi-macos-arm64: its environment");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-macos-arm64", "    environment: pypi\n", ""), "pypi-macos-arm64: its environment");
    // the environments the indexes' trusted publisher for pypi.yml names: another name is refused
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-macos-arm64", "    environment: testpypi\n", "    environment: testpypi-macos\n"), "testpypi-macos-arm64: its environment");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-macos-arm64", "    environment: pypi\n", "    environment: pypi-macos-arm64\n"), "pypi-macos-arm64: its environment");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-macos-arm64", "    environment: pypi\n", "    environment: testpypi\n"), "pypi-macos-arm64: its environment");
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
    const text = x.pypi;
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
    const text = x.pypi;
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
    // the verdicts: an error that ends the run green, a step inserted
    try expectRefused(ar, x, try inJob(ar, text, "result-pypi-macos-arm64", "(pypi-smoke-macos-arm64 $PYPI_SMOKE)\" && exit 1'", "(pypi-smoke-macos-arm64 $PYPI_SMOKE)\"'"), "result-pypi-macos-arm64" ++ exact);
    try expectRefused(ar, x, try inJob(ar, text, "result-testpypi-macos-arm64", "          PASSED: ${{ needs.testpypi-passed-macos-arm64.result }}\n", "          PASSED: ${{ needs.testpypi-passed-macos-arm64.result }}\n      - name: one more\n        run: echo done\n"), "result-testpypi-macos-arm64" ++ exact);
}

test {
    // the contract and the cases that play a run of the file
    _ = @import("pypi_macos_jobs_contract.zig");
    _ = @import("pypi_macos_jobs_run.zig");
}
