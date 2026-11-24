//! The contract of pypi-macos-arm64.yml's text, the macOS arm64 wheel's publish workflow, line by line,
//! part of //:pypi_macos_workflow_cases: `check` reads the workflow's text (with pypi.yml's and
//! release.yml's) and says why it breaks the contract, or null. pypi_macos_workflow_test.zig writes each
//! defect into the real text and wants it refused with its message; pypi_macos_workflow_run.zig plays runs
//! of the file and of the two workflows side by side. The rules every file of the two holds are
//! pypi_workflow_contract.zig's `checkFile` and `checkJob`; what this contract adds:
//!  - the triggers are pypi.yml's `on:`, line for line (so a push that starts one starts the other, and
//!    each daily run is at the same time), on top of the file rules both hold (release.yml's push filter,
//!    one daily cron, a manual run with no input, no pull request);
//!  - the concurrency is one group per half of its own, `pypi-macos-arm64-testpypi` for a push and
//!    `pypi-macos-arm64-promote` otherwise, never pypi.yml's, with no run cancelled;
//!  - the jobs are exactly the nine of JOBS (no Linux job), each once, in order, each with its exact `if:`,
//!    runner, `needs:`, environment and permissions; `id-token: write` is held by the build job (the farm
//!    only) and the two upload jobs (the upload only);
//!  - the jobs after the build: each one's outputs and steps exactly, in order (the build's present step
//!    and the gates of its Mac builds, and the chain's independence of the Linux one, are in
//!    release_macos_test.zig).

const std = @import("std");
const reader = @import("pypi_workflow_text.zig");
const linux = @import("pypi_workflow_contract.zig");
const JobSpec = linux.JobSpec;
const UBUNTU = linux.UBUNTU;
const MACOS = linux.MACOS;
const PUSH_GATE = linux.PUSH_GATE;
const PROMOTE_GATE = linux.PROMOTE_GATE;
const RESULT_PUSH_GATE = linux.RESULT_PUSH_GATE;
const RESULT_PROMOTE_GATE = linux.RESULT_PROMOTE_GATE;
const BUILD_PERMS = linux.BUILD_PERMS;
const UPLOAD_PERMS = linux.UPLOAD_PERMS;
const NO_PERMS = linux.NO_PERMS;

pub const JOBS = [_][]const u8{
    "build-macos-arm64",
    "testpypi-macos-arm64",
    "testpypi-smoke-macos-arm64",
    "testpypi-passed-macos-arm64",
    "result-testpypi-macos-arm64",
    "promote-macos-arm64",
    "pypi-macos-arm64",
    "pypi-smoke-macos-arm64",
    "result-pypi-macos-arm64",
};

pub const GROUP = "  group: pypi-macos-arm64-${{ github.event_name == 'push' && 'testpypi' || 'promote' }}";
pub const FILE = linux.FileSpec{
    .group = GROUP,
    .group_why = "concurrency is not exactly one group per half of its own (pypi-macos-arm64-testpypi for a push, pypi-macos-arm64-promote otherwise) with cancel-in-progress: false",
    .jobs = &JOBS,
    .jobs_why = "the jobs are not exactly the nine of the two halves of the macOS wheel, each once, in order",
};

const SPECS = [_]JobSpec{
    // the build only asks the farm (an ubuntu runner), the smokes run on a hosted Mac
    .{ .name = "build-macos-arm64", .runs_on = UBUNTU, .gate = PUSH_GATE, .needs = null, .environment = "    environment: build", .perms = &BUILD_PERMS },
    .{ .name = "testpypi-macos-arm64", .runs_on = UBUNTU, .gate = PUSH_GATE ++ " && needs.build-macos-arm64.outputs.version != ''", .needs = "    needs: build-macos-arm64", .environment = "    environment: testpypi", .perms = &UPLOAD_PERMS },
    .{ .name = "testpypi-smoke-macos-arm64", .runs_on = MACOS, .gate = PUSH_GATE ++ " && needs.testpypi-macos-arm64.outputs.state != 'differs'", .needs = "    needs: [build-macos-arm64, testpypi-macos-arm64]", .environment = null, .perms = &NO_PERMS },
    .{ .name = "testpypi-passed-macos-arm64", .runs_on = UBUNTU, .gate = PUSH_GATE, .needs = "    needs: [build-macos-arm64, testpypi-smoke-macos-arm64]", .environment = null, .perms = &NO_PERMS },
    .{ .name = "result-testpypi-macos-arm64", .runs_on = UBUNTU, .gate = RESULT_PUSH_GATE, .needs = "    needs: [build-macos-arm64, testpypi-macos-arm64, testpypi-smoke-macos-arm64, testpypi-passed-macos-arm64]", .environment = null, .perms = &NO_PERMS },
    .{ .name = "promote-macos-arm64", .runs_on = UBUNTU, .gate = PROMOTE_GATE, .needs = null, .environment = null, .perms = &NO_PERMS },
    .{ .name = "pypi-macos-arm64", .runs_on = UBUNTU, .gate = PROMOTE_GATE, .needs = "    needs: promote-macos-arm64", .environment = "    environment: pypi", .perms = &UPLOAD_PERMS },
    .{ .name = "pypi-smoke-macos-arm64", .runs_on = MACOS, .gate = PROMOTE_GATE ++ " && needs.pypi-macos-arm64.outputs.state != 'differs'", .needs = "    needs: [promote-macos-arm64, pypi-macos-arm64]", .environment = null, .perms = &NO_PERMS },
    .{ .name = "result-pypi-macos-arm64", .runs_on = UBUNTU, .gate = RESULT_PROMOTE_GATE, .needs = "    needs: [promote-macos-arm64, pypi-macos-arm64, pypi-smoke-macos-arm64]", .environment = null, .perms = &NO_PERMS },
};

// ---- the jobs after the build: each job's outputs and steps, exactly and in order ----
// (comment and blank lines dropped; the build itself is held by release_macos_test.zig)
pub const MAC_TESTPYPI_LINES = [_][]const u8{
    "      state: ${{ steps.state.outputs.state }}",
    "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
    "        with:",
    "          name: pypi-${{ needs.build-macos-arm64.outputs.version }}-macos-arm64-dist",
    "          path: dist",
    "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
    "        with:",
    "          name: pypi-${{ needs.build-macos-arm64.outputs.version }}-macos-arm64-smoke",
    "          path: ${{ runner.temp }}/pypi-macos-arm64/smoke",
    "      - name: the driver is executable",
    "        run: chmod +x \"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke\"",
    "      - name: the macOS wheel on TestPyPI",
    "        id: state",
    "        run: '\"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke\" state --index testpypi --dist dist --github-output \"$GITHUB_OUTPUT\"'",
    "      - name: upload the macOS wheel to TestPyPI",
    "        if: steps.state.outputs.state == 'absent'",
    "        uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # v1.14.3",
    "        with:",
    "          repository-url: https://test.pypi.org/legacy/",
    "          packages-dir: dist",
};
pub const MAC_TESTPYPI_SMOKE_LINES = [_][]const u8{
    "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
    "        with:",
    "          name: pypi-${{ needs.build-macos-arm64.outputs.version }}-macos-arm64-dist",
    "          path: dist",
    "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
    "        with:",
    "          name: pypi-${{ needs.build-macos-arm64.outputs.version }}-macos-arm64-smoke",
    "          path: ${{ runner.temp }}/pypi-macos-arm64/smoke",
    "      - name: the driver is executable",
    "        run: chmod +x \"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke_macos_arm64\"",
    "      - name: TestPyPI serves the macOS wheel as built",
    "        run: '\"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke_macos_arm64\" verify --index testpypi --dist dist --attempts 5 --delay 30'",
    "      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0",
    "        id: python",
    "        with:",
    "          python-version: ${{ matrix.python }}",
    "      - name: pip installs komira from TestPyPI on macOS and the quickstart prints what it should",
    "        env:",
    "          PYTHON: ${{ steps.python.outputs.python-path }}",
    "        run: '\"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke_macos_arm64\" install --index testpypi --dist dist --python \"$PYTHON\" --example \"$RUNNER_TEMP/pypi-macos-arm64/smoke/quickstart.py\" --expect \"$RUNNER_TEMP/pypi-macos-arm64/smoke/quickstart.expected\" --abi-table \"$RUNNER_TEMP/pypi-macos-arm64/smoke/komira.tsv\" --work \"$RUNNER_TEMP/pypi-macos-arm64/install\" --attempts 5 --delay 30'",
};
pub const MAC_PASSED_LINES = [_][]const u8{
    "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
    "        with:",
    "          name: pypi-${{ needs.build-macos-arm64.outputs.version }}-macos-arm64-smoke",
    "          path: ${{ runner.temp }}/pypi-macos-arm64/passed",
    "      - name: the record of the version that passed",
    "        uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0",
    "        with:",
    "          path: ${{ runner.temp }}/pypi-macos-arm64/passed",
    "          key: pypi-passed-macos-arm64-${{ needs.build-macos-arm64.outputs.version }}",
};
pub const MAC_RESULT_TESTPYPI_LINES = [_][]const u8{
    "      - name: the macOS build succeeded",
    "        if: needs.build-macos-arm64.result != 'success'",
    "        env:",
    "          BUILD: ${{ needs.build-macos-arm64.result }}",
    "        run: 'echo \"::error title=pypi-macos-arm64::the macOS build job did not succeed (build-macos-arm64 $BUILD)\" && exit 1'",
    "      - name: the macOS wheel is on TestPyPI already",
    "        if: needs.build-macos-arm64.outputs.version == ''",
    "        run: 'echo \"::notice title=pypi-macos-arm64::the macOS wheel of this version is on TestPyPI already: nothing was built on the Macs\"'",
    "      - name: the TestPyPI upload of the macOS wheel succeeded",
    "        if: needs.build-macos-arm64.outputs.version != '' && needs.testpypi-macos-arm64.result != 'success'",
    "        env:",
    "          TESTPYPI: ${{ needs.testpypi-macos-arm64.result }}",
    "        run: 'echo \"::error title=pypi-macos-arm64::the macOS TestPyPI upload job did not succeed (testpypi-macos-arm64 $TESTPYPI)\" && exit 1'",
    "      - name: the bytes differ at the same version",
    "        if: needs.testpypi-macos-arm64.outputs.state == 'differs'",
    "        run: 'echo \"::notice title=pypi-macos-arm64::bytes differ at the same version: a commit that changed only what the stamp ignores changed the wheel; a code commit raises the version\"'",
    "      - name: the macOS TestPyPI smoke and the record succeeded",
    "        if: needs.build-macos-arm64.outputs.version != '' && needs.testpypi-macos-arm64.outputs.state != 'differs' && (needs.testpypi-smoke-macos-arm64.result != 'success' || needs.testpypi-passed-macos-arm64.result != 'success')",
    "        env:",
    "          TESTPYPI_SMOKE: ${{ needs.testpypi-smoke-macos-arm64.result }}",
    "          PASSED: ${{ needs.testpypi-passed-macos-arm64.result }}",
    "        run: 'echo \"::error title=pypi-macos-arm64::the macOS TestPyPI smoke or the record job did not succeed (testpypi-smoke-macos-arm64 $TESTPYPI_SMOKE, testpypi-passed-macos-arm64 $PASSED): this macOS wheel is never promoted to PyPI\" && exit 1'",
};
pub const MAC_PROMOTE_LINES = [_][]const u8{
    "      version: ${{ steps.promote.outputs.version }}",
    "      skipped: ${{ steps.promote.outputs.skipped }}",
    "      matrix: ${{ steps.matrix.outputs.matrix }}",
    "      - name: the newest record of a macOS wheel whose TestPyPI smoke passed",
    "        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0",
    "        with:",
    "          path: ${{ runner.temp }}/pypi-macos-arm64/passed",
    "          key: pypi-passed-macos-arm64-",
    "          restore-keys: pypi-passed-macos-arm64-",
    "          fail-on-cache-miss: true",
    "      - name: the driver is executable",
    "        run: chmod +x \"$RUNNER_TEMP/pypi-macos-arm64/passed/pypi_smoke\"",
    "      - name: the version to promote, downloaded from TestPyPI and held to the record",
    "        id: promote",
    "        run: '\"$RUNNER_TEMP/pypi-macos-arm64/passed/pypi_smoke\" promote --record \"$RUNNER_TEMP/pypi-macos-arm64/passed/built.txt\" --out \"$RUNNER_TEMP/pypi-macos-arm64/dist\" --github-output \"$GITHUB_OUTPUT\"'",
    "      - name: the Pythons of the macOS PyPI smoke",
    "        id: matrix",
    "        run: '\"$RUNNER_TEMP/pypi-macos-arm64/passed/pypi_smoke\" matrix --pythons \"$RUNNER_TEMP/pypi-macos-arm64/passed/pythons.json\" --platform macos-arm64 --github-output \"$GITHUB_OUTPUT\"'",
    "      - name: keep the dist directory",
    "        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1",
    "        with:",
    "          name: pypi-${{ steps.promote.outputs.version }}-macos-arm64-dist",
    "          path: ${{ runner.temp }}/pypi-macos-arm64/dist",
    "          if-no-files-found: error",
    "          retention-days: 14",
    "      - name: keep the drivers and the record",
    "        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1",
    "        with:",
    "          name: pypi-${{ steps.promote.outputs.version }}-macos-arm64-smoke",
    "          path: ${{ runner.temp }}/pypi-macos-arm64/passed",
    "          if-no-files-found: error",
    "          retention-days: 14",
};
pub const MAC_PYPI_LINES = [_][]const u8{
    "      state: ${{ steps.state.outputs.state }}",
    "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
    "        with:",
    "          name: pypi-${{ needs.promote-macos-arm64.outputs.version }}-macos-arm64-dist",
    "          path: dist",
    "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
    "        with:",
    "          name: pypi-${{ needs.promote-macos-arm64.outputs.version }}-macos-arm64-smoke",
    "          path: ${{ runner.temp }}/pypi-macos-arm64/smoke",
    "      - name: the driver is executable",
    "        run: chmod +x \"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke\"",
    "      - name: the macOS wheel on PyPI",
    "        id: state",
    "        run: '\"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke\" state --index pypi --dist dist --github-output \"$GITHUB_OUTPUT\"'",
    "      - name: upload the macOS wheel to PyPI",
    "        if: steps.state.outputs.state == 'absent'",
    "        uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # v1.14.3",
    "        with:",
    "          packages-dir: dist",
};
pub const MAC_PYPI_SMOKE_LINES = [_][]const u8{
    "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
    "        with:",
    "          name: pypi-${{ needs.promote-macos-arm64.outputs.version }}-macos-arm64-dist",
    "          path: dist",
    "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
    "        with:",
    "          name: pypi-${{ needs.promote-macos-arm64.outputs.version }}-macos-arm64-smoke",
    "          path: ${{ runner.temp }}/pypi-macos-arm64/smoke",
    "      - name: the driver is executable",
    "        run: chmod +x \"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke_macos_arm64\"",
    "      - name: PyPI serves the macOS wheel as built",
    "        run: '\"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke_macos_arm64\" verify --index pypi --dist dist --attempts 5 --delay 30'",
    "      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0",
    "        id: python",
    "        with:",
    "          python-version: ${{ matrix.python }}",
    "      - name: pip installs komira from PyPI on macOS and the quickstart prints what it should",
    "        env:",
    "          PYTHON: ${{ steps.python.outputs.python-path }}",
    "        run: '\"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke_macos_arm64\" install --index pypi --dist dist --python \"$PYTHON\" --example \"$RUNNER_TEMP/pypi-macos-arm64/smoke/quickstart.py\" --expect \"$RUNNER_TEMP/pypi-macos-arm64/smoke/quickstart.expected\" --abi-table \"$RUNNER_TEMP/pypi-macos-arm64/smoke/komira.tsv\" --work \"$RUNNER_TEMP/pypi-macos-arm64/install\" --attempts 5 --delay 30'",
};
pub const MAC_RESULT_PYPI_LINES = [_][]const u8{
    "      - name: the newer macOS wheels on TestPyPI that were not promoted",
    "        if: needs.promote-macos-arm64.outputs.skipped != ''",
    "        env:",
    "          SKIPPED: ${{ needs.promote-macos-arm64.outputs.skipped }}",
    "          VERSION: ${{ needs.promote-macos-arm64.outputs.version }}",
    "        run: 'echo \"::notice title=pypi-macos-arm64::not promoted: the macOS wheel of komira $SKIPPED on TestPyPI has no record that its TestPyPI smoke passed (the smoke failed, or its run had not ended); komira $VERSION is the newest version whose macOS wheel passed\"'",
    "      - name: the macOS promotion found a version that passed and fetched it from TestPyPI",
    "        if: needs.promote-macos-arm64.result != 'success'",
    "        env:",
    "          PROMOTE: ${{ needs.promote-macos-arm64.result }}",
    "        run: 'echo \"::error title=pypi-macos-arm64::the macOS promote job did not succeed (promote-macos-arm64 $PROMOTE): no macOS wheel was published to PyPI; its log says why\" && exit 1'",
    "      - name: the macOS PyPI upload succeeded",
    "        if: needs.pypi-macos-arm64.result != 'success'",
    "        env:",
    "          PYPI: ${{ needs.pypi-macos-arm64.result }}",
    "        run: 'echo \"::error title=pypi-macos-arm64::the macOS PyPI upload job did not succeed (pypi-macos-arm64 $PYPI)\" && exit 1'",
    "      - name: PyPI holds the macOS wheel with the bytes TestPyPI served",
    "        if: needs.pypi-macos-arm64.outputs.state == 'differs'",
    "        env:",
    "          VERSION: ${{ needs.promote-macos-arm64.outputs.version }}",
    "        run: 'echo \"::error title=pypi-macos-arm64::PyPI holds the macOS wheel of komira $VERSION with other bytes than TestPyPI serves: nothing was uploaded and PyPI was not smoked\" && exit 1'",
    "      - name: the macOS PyPI smoke succeeded",
    "        if: needs.pypi-smoke-macos-arm64.result != 'success'",
    "        env:",
    "          PYPI_SMOKE: ${{ needs.pypi-smoke-macos-arm64.result }}",
    "        run: 'echo \"::error title=pypi-macos-arm64::the macOS PyPI smoke job did not succeed (pypi-smoke-macos-arm64 $PYPI_SMOKE)\" && exit 1'",
    "      - name: the macOS wheel is on PyPI already",
    "        if: needs.pypi-macos-arm64.outputs.state == 'same'",
    "        env:",
    "          VERSION: ${{ needs.promote-macos-arm64.outputs.version }}",
    "        run: 'echo \"::notice title=pypi-macos-arm64::already published: the macOS wheel of komira $VERSION is on PyPI with the bytes TestPyPI served; nothing was uploaded, and the PyPI smoke passed\"'",
};

const MacExact = struct { name: []const u8, lines: []const []const u8, with_outputs: bool };
const MAC_EXACT = [_]MacExact{
    .{ .name = "testpypi-macos-arm64", .lines = &MAC_TESTPYPI_LINES, .with_outputs = true },
    .{ .name = "testpypi-smoke-macos-arm64", .lines = &MAC_TESTPYPI_SMOKE_LINES, .with_outputs = false },
    .{ .name = "testpypi-passed-macos-arm64", .lines = &MAC_PASSED_LINES, .with_outputs = false },
    .{ .name = "result-testpypi-macos-arm64", .lines = &MAC_RESULT_TESTPYPI_LINES, .with_outputs = false },
    .{ .name = "promote-macos-arm64", .lines = &MAC_PROMOTE_LINES, .with_outputs = true },
    .{ .name = "pypi-macos-arm64", .lines = &MAC_PYPI_LINES, .with_outputs = true },
    .{ .name = "pypi-smoke-macos-arm64", .lines = &MAC_PYPI_SMOKE_LINES, .with_outputs = false },
    .{ .name = "result-pypi-macos-arm64", .lines = &MAC_RESULT_PYPI_LINES, .with_outputs = false },
};

/// Null if pypi-macos-arm64.yml's text holds the contract, else the refusal. `pypi_text` is pypi.yml's,
/// whose triggers it repeats, and `release_text` release.yml's, whose push filter both repeat.
pub fn check(ar: std.mem.Allocator, text: []const u8, pypi_text: []const u8, release_text: []const u8) !?[]const u8 {
    if (try linux.checkFile(ar, text, release_text, FILE)) |why| return why;
    var n: usize = 0;
    var pn: usize = 0;
    const on = (try reader.topLines(ar, text, "on:", &n)).?;
    const pypi_on = (try reader.topLines(ar, pypi_text, "on:", &pn)) orelse return "pypi.yml has no on:";
    var same_on = on.len == pypi_on.len;
    if (same_on) {
        for (on, pypi_on) |a, b| same_on = same_on and std.mem.eql(u8, a, b);
    }
    if (!same_on) return "on: is not pypi.yml's, line for line: a push or a day would start one workflow and not the other";
    for (SPECS) |spec| {
        var jn: usize = 0;
        const job = (try reader.jobLines(ar, text, spec.name, &jn)) orelse return try std.fmt.allocPrint(ar, "the job {s} is missing", .{spec.name});
        if (try linux.checkJob(ar, job, spec)) |why| return why;
        for (MAC_EXACT) |m| {
            if (!std.mem.eql(u8, m.name, spec.name)) continue;
            if (try linux.checkExact(ar, job, m.name, m.lines, m.with_outputs)) |why| return why;
        }
    }
    return null;
}
