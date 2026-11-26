//! The contract of pypi.yml's text, the publish workflow of both wheels, line by line, part of
//! //:pypi_workflow_cases: `check` reads the workflow's text and says why it breaks the contract, or null.
//! pypi_workflow_test.zig writes each defect into the real text and wants it refused with its message;
//! pypi_workflow_run.zig plays runs of the file. The file-level rules (`checkFile`) and each job's own
//! (`checkJob`) are held for every job of the file; this file holds the rules of the file and of the ten
//! Linux jobs, and `check` then runs the contract of the nine macOS jobs, whose own lines are
//! pypi_macos_jobs_contract.zig's. What the contract of pypi.yml holds:
//!  - the triggers: `on:` is exactly a push to main whose `paths-ignore` is release.yml's list, one
//!    `schedule:` of one cron entry at a fixed minute and hour of every day, then `workflow_dispatch:` with
//!    no input (no pull request, and no other schedule or cron outside a comment); no line outside a
//!    comment reads a run input (`inputs.`); top-level `permissions` is `{}` exactly once; the concurrency
//!    is one group per half (`pypi-testpypi` for a push, `pypi-promote` otherwise) with no run cancelled;
//!  - the jobs are exactly the nineteen of ALL_JOBS, each once, in order (each half's Linux jobs, then
//!    its macOS jobs), each with its exact `if:` (main only, and the half: `github.event_name == 'push'` for the TestPyPI half,
//!    `!= 'push'` for the promotion), runner, `needs:`, environment and permissions; among the Linux
//!    jobs, `id-token: write` is held by the build job (the farm only) and the two upload jobs (the
//!    upload only) and by no other (the macOS chain's own build and upload jobs are the macOS contract's);
//!  - among the Linux jobs, farm-connect and buck2 are in the build job alone, at `farm-qos: batch`; the promotion builds
//!    nothing; `actions/cache/save` is in the record job alone, `actions/cache/restore` in the promote job
//!    alone;
//!  - the jobs' own lines: the build's stamp, wheel,
//!    install test, driver, list of Pythons, dist directory with its record, copied quickstart files,
//!    matrix and two artifacts; the user test (wheel_user_test_job.zig); the TestPyPI job's storage steps
//!    before its state and upload; the record job's download and cache key; the promote job's restore,
//!    storage, promote, matrix and artifacts, in that order; the PyPI job's state and upload on promote's
//!    artifacts; the smoke jobs' verify, set up Python and install with the record's quickstart files and
//!    no checkout; the upload step runs for `absent` alone, with the pinned action and its defaults;
//!  - every `uses:` that is not local names a commit: owner/repo@<40 lowercase hex>;
//!  - no line outside a comment holds a secret, a password, an API token, curl, wget, jq, twine,
//!    continue-on-error or pull_request_target, and no `run:` line holds a `${{ }}` expression;
//!  - the two verdict jobs print exactly their steps, the notice `already ...` last.

const std = @import("std");
const reader = @import("pypi_workflow_text.zig");
const user_test = @import("wheel_user_test_job.zig");
const macos = @import("pypi_macos_jobs_contract.zig");
const jobLines = reader.jobLines;
const jobNames = reader.jobNames;
const topLines = reader.topLines;
const has = reader.has;
const lineAt = reader.lineAt;
const mentions = reader.mentions;
const countMentions = reader.countMentions;
const countPrefix = reader.countPrefix;

pub const JOBS = [_][]const u8{
    "build",
    "wheel-user-test",
    "testpypi",
    "testpypi-smoke",
    "testpypi-passed",
    "result-testpypi",
    "promote",
    "pypi",
    "pypi-smoke",
    "result-pypi",
};
/// The jobs of the macOS arm64 wheel's chain (pypi_macos_jobs_contract.zig holds each one's lines).
pub const MACOS_JOBS = [_][]const u8{
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
/// The jobs of the file, in order: the push half's Linux jobs, then its macOS ones, then the promotion's
/// Linux jobs, then its macOS ones.
pub const ALL_JOBS = JOBS[0..6].* ++ MACOS_JOBS[0..5].* ++ JOBS[6..].* ++ MACOS_JOBS[5..].*;

pub const PUSH_GATE = "    if: github.ref == 'refs/heads/main' && github.event_name == 'push'";
pub const PROMOTE_GATE = "    if: github.ref == 'refs/heads/main' && github.event_name != 'push'";
pub const RESULT_PUSH_GATE = "    if: always() && github.ref == 'refs/heads/main' && github.event_name == 'push'";
pub const RESULT_PROMOTE_GATE = "    if: always() && github.ref == 'refs/heads/main' && github.event_name != 'push'";

pub const JobSpec = struct {
    name: []const u8,
    /// The whole `runs-on:` line.
    runs_on: []const u8,
    gate: []const u8,
    needs: ?[]const u8,
    environment: ?[]const u8,
    /// The lines under `permissions:`; none means `permissions: {}`.
    perms: []const []const u8,
};

pub const BUILD_PERMS = [_][]const u8{ "      contents: read", "      id-token: write" };
pub const UPLOAD_PERMS = [_][]const u8{"      id-token: write"};
pub const NO_PERMS = [_][]const u8{};
const empty: []const []const u8 = &.{};

pub const UBUNTU = "    runs-on: ubuntu-24.04";
pub const MACOS = "    runs-on: macos-15";

const SPECS = [_]JobSpec{
    .{ .name = "build", .runs_on = UBUNTU, .gate = PUSH_GATE, .needs = null, .environment = "    environment: build", .perms = &BUILD_PERMS },
    .{ .name = "wheel-user-test", .runs_on = user_test.RUNS_ON, .gate = PUSH_GATE, .needs = "    needs: build", .environment = null, .perms = &NO_PERMS },
    .{ .name = "testpypi", .runs_on = UBUNTU, .gate = PUSH_GATE, .needs = "    needs: [build, wheel-user-test]", .environment = "    environment: testpypi", .perms = &UPLOAD_PERMS },
    .{ .name = "testpypi-smoke", .runs_on = UBUNTU, .gate = PUSH_GATE ++ " && needs.testpypi.outputs.state != 'differs'", .needs = "    needs: [build, testpypi]", .environment = null, .perms = &NO_PERMS },
    .{ .name = "testpypi-passed", .runs_on = UBUNTU, .gate = PUSH_GATE, .needs = "    needs: [build, testpypi-smoke]", .environment = null, .perms = &NO_PERMS },
    .{ .name = "result-testpypi", .runs_on = UBUNTU, .gate = RESULT_PUSH_GATE, .needs = "    needs: [build, wheel-user-test, testpypi, testpypi-smoke, testpypi-passed]", .environment = null, .perms = &NO_PERMS },
    .{ .name = "promote", .runs_on = UBUNTU, .gate = PROMOTE_GATE, .needs = null, .environment = null, .perms = &NO_PERMS },
    .{ .name = "pypi", .runs_on = UBUNTU, .gate = PROMOTE_GATE, .needs = "    needs: promote", .environment = "    environment: pypi", .perms = &UPLOAD_PERMS },
    .{ .name = "pypi-smoke", .runs_on = UBUNTU, .gate = PROMOTE_GATE ++ " && needs.pypi.outputs.state != 'differs'", .needs = "    needs: [promote, pypi]", .environment = null, .perms = &NO_PERMS },
    .{ .name = "result-pypi", .runs_on = UBUNTU, .gate = RESULT_PROMOTE_GATE, .needs = "    needs: [promote, pypi, pypi-smoke]", .environment = null, .perms = &NO_PERMS },
};

fn isOneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The jobs of either workflow that build, save a record and restore one (a workflow holds one of each).
const BUILD_JOBS = [_][]const u8{ "build", "build-macos-arm64" };
const PASSED_JOBS = [_][]const u8{ "testpypi-passed", "testpypi-passed-macos-arm64" };
const PROMOTE_JOBS = [_][]const u8{ "promote", "promote-macos-arm64" };

// ---- the pinned actions and the shared lines ---------------------------------------------------
pub const CHECKOUT = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1";
pub const SETUP_PYTHON = "      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0";
pub const DOWNLOAD = "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1";
pub const UPLOAD = "      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1";
pub const PUBLISH = "        uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # v1.14.3";
pub const CACHE_SAVE = "        uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0";
pub const CACHE_RESTORE = "        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0";
pub const PACKAGES_DIR = "          packages-dir: dist";
pub const CHMOD = "        run: chmod +x \"$RUNNER_TEMP/pypi/smoke/pypi_smoke\"";
pub const STATE_ENABLED = "        if: steps.state.outputs.state == 'absent'";
pub const FARM_CONNECT = "      - uses: ./.github/actions/farm-connect";
pub const FARM_QOS = "          farm-qos: batch";
pub const FARM_TLS = "          tls: ${{ vars.FARM_TLS || 'false' }}";

/// The four lines of the two downloads of a job after the build, or after the promote job.
fn downloadNames(comptime job: []const u8) [4][]const u8 {
    return .{
        "          name: pypi-${{ needs." ++ job ++ ".outputs.version }}-dist",
        "          path: dist",
        "          name: pypi-${{ needs." ++ job ++ ".outputs.version }}-smoke",
        "          path: ${{ runner.temp }}/pypi/smoke",
    };
}
pub const PUSH_DOWNLOADS = downloadNames("build");
pub const PROMOTE_DOWNLOADS = downloadNames("promote");

// ---- the triggers and the concurrency ------------------------------------------------------------
pub const PUSH_LINES = [_][]const u8{ "  push:", "    branches: [main]", "    paths-ignore:" };
pub const SCHEDULE = "  schedule:";
pub const CRON_PREFIX = "    - cron: '";
pub const DISPATCH = "  workflow_dispatch:";
pub const GROUP = "  group: pypi-${{ github.event_name == 'push' && 'testpypi' || 'promote' }}";
/// What a file-level check of one workflow needs: its concurrency group and its jobs, in order.
pub const FileSpec = struct {
    group: []const u8,
    /// the refusal of another concurrency
    group_why: []const u8,
    jobs: []const []const u8,
    /// the refusal of another job set
    jobs_why: []const u8,
};
pub const FILE = FileSpec{
    .group = GROUP,
    .group_why = "concurrency is not exactly one group per half (pypi-testpypi for a push, pypi-promote otherwise) with cancel-in-progress: false",
    .jobs = &ALL_JOBS,
    .jobs_why = "the jobs are not exactly the nineteen of the two halves of the two wheels, each once, in order (each half's Linux jobs, then its macOS jobs)",
};
pub const NO_CANCEL = "  cancel-in-progress: false";

/// What no line outside a comment may contain, whatever the case.
const FORBIDDEN = [_][]const u8{ "secrets", "password", "api-token", "pypi_token", "curl", "wget", "jq ", "twine", "continue-on-error", "pull_request_target" };
/// What the triggers may not name outside a comment.
const TRIGGER_WORDS = [_][]const u8{"pull_request"};

// ---- the build job ------------------------------------------------------------------------------
pub const STAMP_FLAGS = "-c komira.package_stamp=${{ steps.stamp.outputs.build_number }} -c komira.package_commit=${{ steps.stamp.outputs.source_commit }} -c komira.package_timestamp_ms=${{ steps.stamp.outputs.timestamp_ms }}";
pub const BUILD_WHEEL = "          args: build " ++ STAMP_FLAGS ++ " //python:komira_wheel[release] --out ${{ runner.temp }}/pypi/built/komira.whl";
pub const BUILD_INSTALL_TEST = "          args: build " ++ STAMP_FLAGS ++ " //python:wheel_install_test";
pub const BUILD_DRIVER = "          args: build " ++ STAMP_FLAGS ++ " //python/smoke:pypi_smoke --out ${{ runner.temp }}/pypi/smoke/pypi_smoke";
pub const BUILD_PYTHONS = "          args: build //python:supported_pythons[linux-x86_64] --out ${{ runner.temp }}/pypi/smoke/pythons.json";
pub const BUILD_DIST = "        run: '\"$RUNNER_TEMP/pypi/smoke/pypi_smoke\" dist --wheel \"$RUNNER_TEMP/pypi/built/komira.whl\" --out \"$RUNNER_TEMP/pypi/dist\" --record \"$RUNNER_TEMP/pypi/smoke/built.txt\" --github-output \"$GITHUB_OUTPUT\"'";
pub const BUILD_COPY = "        run: cp python/examples/quickstart.py python/examples/quickstart.expected python/examples/readings.parquet src/so/abi/komira.tsv \"$RUNNER_TEMP/pypi/smoke/\"";
pub const BUILD_MATRIX = "        run: '\"$RUNNER_TEMP/pypi/smoke/pypi_smoke\" matrix --pythons \"$RUNNER_TEMP/pypi/smoke/pythons.json\" --platform linux-x86_64 --github-output \"$GITHUB_OUTPUT\"'";
pub const BUILD_MATRIX_OUTPUT = "      matrix: ${{ steps.matrix.outputs.matrix }}";
const BUILD_LINES = [_][]const u8{
    "      version: ${{ steps.dist.outputs.version }}",
    BUILD_MATRIX_OUTPUT,
    "          ref: ${{ github.sha }}",
    "          fetch-depth: 0",
    FARM_CONNECT,
    FARM_QOS,
    FARM_TLS,
    "          args: build //release/ci:release_json --out ${{ runner.temp }}/pypi/release_json",
    "        id: stamp",
    "        run: '\"$RUNNER_TEMP/pypi/release_json\" stamp --revision \"$GITHUB_SHA\" --github-output \"$GITHUB_OUTPUT\"'",
    BUILD_WHEEL,
    BUILD_INSTALL_TEST,
    BUILD_DRIVER,
    BUILD_PYTHONS,
    "        id: dist",
    BUILD_DIST,
    BUILD_COPY,
    "        id: matrix",
    BUILD_MATRIX,
    "          name: pypi-${{ steps.dist.outputs.version }}-dist",
    "          path: ${{ runner.temp }}/pypi/dist",
    "          name: pypi-${{ steps.dist.outputs.version }}-smoke",
    "          path: ${{ runner.temp }}/pypi/smoke",
};
pub const USER_TEST = user_test.Spec{ .build_job = "build", .artifact = "pypi-${{ needs.build.outputs.version }}", .gate = PUSH_GATE };
const BUILD_UPLOAD_FORBIDDEN = [_][]const u8{ "pypa/gh-action-pypi-publish", "legacy/", "twine", "repository-url", "packages-dir" };

// ---- the storage steps ----------------------------------------------------------------------------
fn storageLines(comptime dir: []const u8) [6][]const u8 {
    return .{
        "      - name: the size of the project on TestPyPI",
        "        id: testpypi_storage",
        "        run: '\"$RUNNER_TEMP/pypi/" ++ dir ++ "/pypi_smoke\" storage --index testpypi --project komira --limit-gib 10 --over-percent 80 --summary \"$GITHUB_STEP_SUMMARY\" --github-output \"$GITHUB_OUTPUT\"'",
        "      - name: the size of the project on PyPI",
        "        id: pypi_storage",
        "        run: '\"$RUNNER_TEMP/pypi/" ++ dir ++ "/pypi_smoke\" storage --index pypi --project komira --limit-gib 10 --over-percent 80 --summary \"$GITHUB_STEP_SUMMARY\" --github-output \"$GITHUB_OUTPUT\"'",
    };
}
pub const TESTPYPI_STORAGE = storageLines("smoke");
pub const PROMOTE_STORAGE = storageLines("passed");
pub const STORAGE_OUTPUTS = [_][]const u8{
    "      testpypi_storage: ${{ steps.testpypi_storage.outputs.over }}",
    "      pypi_storage: ${{ steps.pypi_storage.outputs.over }}",
};

// ---- the index jobs -----------------------------------------------------------------------------
pub const Index = struct {
    name: []const u8,
    state_step: []const u8,
    state_run: []const u8,
    upload_step: []const u8,
    repository_url: ?[]const u8,
    verify_step: []const u8,
    verify_run: []const u8,
    install_step: []const u8,
    install_run: []const u8,
};

fn indexSpec(comptime idx: []const u8, comptime title: []const u8, comptime repo: ?[]const u8) Index {
    const smoke = "\"$RUNNER_TEMP/pypi/smoke/";
    return .{
        .name = idx,
        .state_step = "      - name: the wheel on " ++ title,
        .state_run = "        run: '\"$RUNNER_TEMP/pypi/smoke/pypi_smoke\" state --index " ++ idx ++ " --dist dist --github-output \"$GITHUB_OUTPUT\"'",
        .upload_step = "      - name: upload to " ++ title,
        .repository_url = repo,
        .verify_step = "      - name: " ++ title ++ " serves the wheel as built",
        .verify_run = "        run: '\"$RUNNER_TEMP/pypi/smoke/pypi_smoke\" verify --index " ++ idx ++ " --dist dist --attempts 5 --delay 30'",
        .install_step = "      - name: pip installs komira from " ++ title ++ " and the quickstart prints what it should",
        .install_run = "        run: '\"$RUNNER_TEMP/pypi/smoke/pypi_smoke\" install --index " ++ idx ++ " --dist dist --python \"$PYTHON\" --example " ++ smoke ++ "quickstart.py\" --expect " ++ smoke ++ "quickstart.expected\" --data " ++ smoke ++ "readings.parquet\" --abi-table " ++ smoke ++ "komira.tsv\" --work \"$RUNNER_TEMP/pypi/install\" --attempts 5 --delay 30'",
    };
}

pub const TESTPYPI = indexSpec("testpypi", "TestPyPI", "          repository-url: https://test.pypi.org/legacy/");
pub const PYPI = indexSpec("pypi", "PyPI", null);
pub const STATE_OUTPUT = "      state: ${{ steps.state.outputs.state }}";
pub const PYTHON_VERSION = "          python-version: ${{ matrix.python }}";
pub const PYTHON_ENV = "          PYTHON: ${{ steps.python.outputs.python-path }}";
/// One job per supported Python: the list the build job (or the promote job) made, every job run to the end.
fn smokeMatrix(comptime job: []const u8) [3][]const u8 {
    return .{ "    strategy:", "      fail-fast: false", "      matrix: ${{ fromJSON(needs." ++ job ++ ".outputs.matrix) }}" };
}
pub const PUSH_MATRIX = smokeMatrix("build");
pub const PROMOTE_MATRIX_LINES = smokeMatrix("promote");

// ---- the record job and the promote job ------------------------------------------------------------
pub const PASSED_LINES = [_][]const u8{
    DOWNLOAD,
    "          name: pypi-${{ needs.build.outputs.version }}-smoke",
    "          path: ${{ runner.temp }}/pypi/passed",
    "      - name: the record of the version that passed",
    CACHE_SAVE,
    "          path: ${{ runner.temp }}/pypi/passed",
    "          key: pypi-passed-linux-x86_64-${{ needs.build.outputs.version }}",
};
pub const RESTORE_STEP = "      - name: the newest record of a version whose TestPyPI smoke passed";
pub const RESTORE_KEY = "          key: pypi-passed-linux-x86_64-";
pub const RESTORE_KEYS = "          restore-keys: pypi-passed-linux-x86_64-";
pub const MISS_FAILS = "          fail-on-cache-miss: true";
pub const PROMOTE_CHMOD = "        run: chmod +x \"$RUNNER_TEMP/pypi/passed/pypi_smoke\"";
pub const PROMOTE_RUN = "        run: '\"$RUNNER_TEMP/pypi/passed/pypi_smoke\" promote --record \"$RUNNER_TEMP/pypi/passed/built.txt\" --out \"$RUNNER_TEMP/pypi/dist\" --github-output \"$GITHUB_OUTPUT\"'";
pub const PROMOTE_MATRIX = "        run: '\"$RUNNER_TEMP/pypi/passed/pypi_smoke\" matrix --pythons \"$RUNNER_TEMP/pypi/passed/pythons.json\" --platform linux-x86_64 --github-output \"$GITHUB_OUTPUT\"'";
pub const PROMOTE_LINES = [_][]const u8{
    "      version: ${{ steps.promote.outputs.version }}",
    "      skipped: ${{ steps.promote.outputs.skipped }}",
    "      matrix: ${{ steps.matrix.outputs.matrix }}",
    STORAGE_OUTPUTS[0],
    STORAGE_OUTPUTS[1],
    RESTORE_STEP,
    CACHE_RESTORE,
    "          path: ${{ runner.temp }}/pypi/passed",
    RESTORE_KEY,
    RESTORE_KEYS,
    MISS_FAILS,
    PROMOTE_CHMOD,
    "        id: promote",
    PROMOTE_RUN,
    "        id: matrix",
    PROMOTE_MATRIX,
    "          name: pypi-${{ steps.promote.outputs.version }}-dist",
    "          path: ${{ runner.temp }}/pypi/dist",
    "          name: pypi-${{ steps.promote.outputs.version }}-smoke",
    "          path: ${{ runner.temp }}/pypi/passed",
};

// ---- the verdict jobs ---------------------------------------------------------------------------
pub const TESTPYPI_SAME_STEP = "      - name: the version is on TestPyPI already";
pub const RESULT_TESTPYPI_LINES = [_][]const u8{
    "      - name: the build, the user test of the wheel and the TestPyPI upload succeeded",
    "        if: needs.build.result != 'success' || needs.wheel-user-test.result != 'success' || needs.testpypi.result != 'success'",
    "          BUILD: ${{ needs.build.result }}",
    "          USER_TEST: ${{ needs.wheel-user-test.result }}",
    "          TESTPYPI: ${{ needs.testpypi.result }}",
    "        run: 'echo \"::error title=pypi::the build, the user test of the wheel or the TestPyPI upload job did not succeed (build $BUILD, wheel-user-test $USER_TEST, testpypi $TESTPYPI)\" && exit 1'",
    "      - name: the bytes differ at the same version",
    "        if: needs.testpypi.outputs.state == 'differs'",
    "        run: 'echo \"::notice title=pypi::bytes differ at the same version: a commit that changed only what the stamp ignores changed the wheel; a code commit raises the version\"'",
    "      - name: the TestPyPI smoke and the record succeeded",
    "        if: needs.testpypi.outputs.state != 'differs' && (needs.testpypi-smoke.result != 'success' || needs.testpypi-passed.result != 'success')",
    "          TESTPYPI_SMOKE: ${{ needs.testpypi-smoke.result }}",
    "          PASSED: ${{ needs.testpypi-passed.result }}",
    "        run: 'echo \"::error title=pypi::the TestPyPI smoke or the record job did not succeed (testpypi-smoke $TESTPYPI_SMOKE, testpypi-passed $PASSED): this version is never promoted to PyPI\" && exit 1'",
    "      - name: the indexes are under 80 percent of their size limit",
    "        if: needs.testpypi.outputs.testpypi_storage == 'true' || needs.testpypi.outputs.pypi_storage == 'true'",
    "        run: 'echo \"::error title=pypi::an index holds over 80 percent of the size limit of komira (the summary of the job testpypi says which): prune old versions on TestPyPI or ask for a higher limit, docs/ci.md, Storage on the indexes\" && exit 1'",
    TESTPYPI_SAME_STEP,
    "        if: needs.testpypi.outputs.state == 'same'",
    "          VERSION: ${{ needs.build.outputs.version }}",
    "        run: 'echo \"::notice title=pypi::already on TestPyPI: komira $VERSION is on TestPyPI with the bytes built; nothing was uploaded, and the smoke passed\"'",
};
pub const PYPI_SAME_STEP = "      - name: the version is on PyPI already";
pub const RESULT_PYPI_LINES = [_][]const u8{
    "      - name: the newer versions on TestPyPI that were not promoted",
    "        if: needs.promote.outputs.skipped != ''",
    "          SKIPPED: ${{ needs.promote.outputs.skipped }}",
    "        run: 'echo \"::notice title=pypi::not promoted: komira $SKIPPED on TestPyPI has no record that its TestPyPI smoke passed (the smoke failed, or its run had not ended); komira $VERSION is the newest version that passed\"'",
    "      - name: the promotion found a version that passed and fetched it from TestPyPI",
    "        if: needs.promote.result != 'success'",
    "          PROMOTE: ${{ needs.promote.result }}",
    "        run: 'echo \"::error title=pypi::the promote job did not succeed (promote $PROMOTE): nothing was published to PyPI; its log says why\" && exit 1'",
    "      - name: the PyPI upload succeeded",
    "        if: needs.pypi.result != 'success'",
    "          PYPI: ${{ needs.pypi.result }}",
    "        run: 'echo \"::error title=pypi::the PyPI upload job did not succeed (pypi $PYPI)\" && exit 1'",
    "      - name: PyPI holds the version with the bytes TestPyPI served",
    "        if: needs.pypi.outputs.state == 'differs'",
    "        run: 'echo \"::error title=pypi::PyPI holds komira $VERSION with other bytes than TestPyPI serves: nothing was uploaded and PyPI was not smoked\" && exit 1'",
    "      - name: the PyPI smoke succeeded",
    "        if: needs.pypi-smoke.result != 'success'",
    "          PYPI_SMOKE: ${{ needs.pypi-smoke.result }}",
    "        run: 'echo \"::error title=pypi::the PyPI smoke job did not succeed (pypi-smoke $PYPI_SMOKE)\" && exit 1'",
    "      - name: the indexes are under 80 percent of their size limit",
    "        if: needs.promote.outputs.testpypi_storage == 'true' || needs.promote.outputs.pypi_storage == 'true'",
    "        run: 'echo \"::error title=pypi::an index holds over 80 percent of the size limit of komira (the summary of the job promote says which): prune old versions on TestPyPI or ask for a higher limit, docs/ci.md, Storage on the indexes\" && exit 1'",
    PYPI_SAME_STEP,
    "        if: needs.pypi.outputs.state == 'same'",
    "          VERSION: ${{ needs.promote.outputs.version }}",
    "        run: 'echo \"::notice title=pypi::already published: komira $VERSION is on PyPI with the bytes TestPyPI served; nothing was uploaded, and the PyPI smoke passed\"'",
};

// ---- the checks ---------------------------------------------------------------------------------

/// The lines under the job's `    permissions:` key (indented deeper than the key), or null if the
/// job has no such key.
fn permLines(ar: std.mem.Allocator, job: []const []const u8) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    var found = false;
    for (job) |l| {
        const indent = l.len - std.mem.trimLeft(u8, l, " ").len;
        if (std.mem.eql(u8, l, "    permissions:")) {
            inside = true;
            found = true;
            continue;
        }
        if (inside) {
            if (indent >= 6) try out.append(ar, l) else inside = false;
        }
    }
    if (!found) return null;
    return try out.toOwnedSlice(ar);
}

fn missingLine(ar: std.mem.Allocator, job: []const u8, why: []const u8, line: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(ar, "{s}: {s}: the line `{s}` is missing", .{ job, why, line });
}

fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// Whether `n` is a plain decimal number (no `*`, list, range or step) of at most `max`.
fn cronField(n: []const u8, max: u8) bool {
    if (n.len == 0 or n.len > 2) return false;
    for (n) |c| if (c < '0' or c > '9') return false;
    return (std.fmt.parseInt(u8, n, 10) catch return false) <= max;
}

/// Whether `line` is the one cron entry of a run once a day at a fixed time: `'<minute> <hour> * * *'`.
pub fn dailyCron(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, CRON_PREFIX) or !std.mem.endsWith(u8, line, "'")) return false;
    var f = std.mem.splitScalar(u8, line[CRON_PREFIX.len .. line.len - 1], ' ');
    const minute = f.next() orelse return false;
    const hour = f.next() orelse return false;
    for (0..3) |_| if (!std.mem.eql(u8, f.next() orelse return false, "*")) return false;
    return f.next() == null and cronField(minute, 59) and cronField(hour, 23);
}

/// The `paths-ignore` entries of release.yml's push trigger, as lines of `on:`, in order.
pub fn releaseIgnores(ar: std.mem.Allocator, release_text: []const u8) ![]const []const u8 {
    var n: usize = 0;
    const lines = (try topLines(ar, release_text, "on:", &n)) orelse return &.{};
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    for (lines) |l| {
        if (std.mem.eql(u8, l, "    paths-ignore:")) {
            inside = true;
            continue;
        }
        if (inside and std.mem.startsWith(u8, l, "      - ")) {
            try out.append(ar, l);
        } else inside = false;
    }
    return out.toOwnedSlice(ar);
}

/// `on:` is the push of PUSH_LINES with release.yml's ignores, one daily cron, the manual run.
fn onLinesHold(lines: []const []const u8, ignores: []const []const u8) bool {
    const want_len = PUSH_LINES.len + ignores.len + 3;
    if (ignores.len == 0 or lines.len != want_len) return false;
    for (PUSH_LINES, lines[0..PUSH_LINES.len]) |want, got| if (!std.mem.eql(u8, want, got)) return false;
    for (ignores, lines[PUSH_LINES.len .. PUSH_LINES.len + ignores.len]) |want, got| if (!std.mem.eql(u8, want, got)) return false;
    const rest = lines[PUSH_LINES.len + ignores.len ..];
    return std.mem.eql(u8, rest[0], SCHEDULE) and dailyCron(rest[1]) and std.mem.eql(u8, rest[2], DISPATCH);
}

/// Null if the whole file passes its text-level rules, else the refusal: what no line may contain,
/// the triggers, the permissions and concurrency of the workflow, the job set and the pins.
pub fn checkFile(ar: std.mem.Allocator, text: []const u8, release_text: []const u8, spec: FileSpec) !?[]const u8 {
    var run_indent: ?usize = null;
    var schedule_n: usize = 0;
    var cron_n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = line.len - std.mem.trimLeft(u8, line, " ").len;
        for (FORBIDDEN) |w| {
            if (std.ascii.indexOfIgnoreCase(line, w) != null) return try std.fmt.allocPrint(ar, "a line outside a comment contains \"{s}\": {s}", .{ w, trimmed });
        }
        for (TRIGGER_WORDS) |w| {
            if (std.mem.indexOf(u8, line, w) != null) return try std.fmt.allocPrint(ar, "a line outside a comment names a pull request trigger (\"{s}\"): {s}", .{ w, trimmed });
        }
        if (std.mem.indexOf(u8, line, "schedule") != null) schedule_n += 1;
        if (std.mem.indexOf(u8, line, "cron") != null) cron_n += 1;
        if (std.mem.indexOf(u8, line, "inputs.") != null) return try std.fmt.allocPrint(ar, "a line outside a comment reads a run input (the workflow takes no input): {s}", .{trimmed});
        const in_block = if (run_indent) |ri| indent > ri else false;
        if (in_block) {
            if (std.mem.indexOf(u8, line, "${{") != null) return try std.fmt.allocPrint(ar, "a run: line holds a ${{{{ }}}} expression (pass it through env:): {s}", .{trimmed});
            continue;
        }
        run_indent = null;
        const key = if (std.mem.startsWith(u8, trimmed, "- ")) std.mem.trimLeft(u8, trimmed[2..], " ") else trimmed;
        if (std.mem.startsWith(u8, key, "run:")) {
            if (std.mem.indexOf(u8, line, "${{") != null) return try std.fmt.allocPrint(ar, "a run: line holds a ${{{{ }}}} expression (pass it through env:): {s}", .{trimmed});
            run_indent = if (std.mem.startsWith(u8, trimmed, "- ")) indent + 2 else indent;
        }
    }

    var on_n: usize = 0;
    const on_lines = (try topLines(ar, text, "on:", &on_n)) orelse empty;
    if (on_n != 1 or !onLinesHold(on_lines, try releaseIgnores(ar, release_text))) return "on: is not exactly a push to main with release.yml's paths-ignore, one schedule: of one cron entry at a fixed minute and hour of every day, then workflow_dispatch: with no input";
    if (schedule_n != 1 or cron_n != 1) return "a line outside a comment and outside the one cron entry of on: names a schedule or a cron";

    var perm_n: usize = 0;
    _ = try topLines(ar, text, "permissions: {}", &perm_n);
    var other_perm_n: usize = 0;
    _ = try topLines(ar, text, "permissions:", &other_perm_n);
    if (perm_n != 1 or other_perm_n != 0) return "top-level permissions is not exactly `permissions: {}` once";

    var conc_n: usize = 0;
    const conc = (try topLines(ar, text, "concurrency:", &conc_n)) orelse empty;
    if (conc_n != 1 or conc.len != 2 or !has(conc, spec.group) or !has(conc, NO_CANCEL)) return spec.group_why;

    const names = try jobNames(ar, text);
    var same_jobs = names.len == spec.jobs.len;
    if (same_jobs) {
        for (names, 0..) |n, i| {
            if (!std.mem.eql(u8, n, spec.jobs[i])) same_jobs = false;
        }
    }
    if (!same_jobs) return spec.jobs_why;

    var pit = std.mem.splitScalar(u8, text, '\n');
    while (pit.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const key = if (std.mem.startsWith(u8, trimmed, "- ")) std.mem.trimLeft(u8, trimmed[2..], " ") else trimmed;
        if (!std.mem.startsWith(u8, key, "uses:")) continue;
        const val = std.mem.trim(u8, key["uses:".len..], " ");
        if (std.mem.startsWith(u8, val, "./")) continue;
        const ref = if (std.mem.indexOfScalar(u8, val, ' ')) |sp| val[0..sp] else val;
        const at = std.mem.indexOfScalar(u8, ref, '@') orelse return try std.fmt.allocPrint(ar, "an action is not pinned to a 40-hex commit: {s}", .{trimmed});
        if (std.mem.indexOfScalar(u8, ref[0..at], '/') == null or !isHex40(ref[at + 1 ..])) return try std.fmt.allocPrint(ar, "an action is not pinned to a 40-hex commit (owner/repo@<sha>): {s}", .{trimmed});
    }
    return null;
}

/// Null if the job holds what every job holds: its runner, gate, needs, environment and permissions,
/// and the tools only some jobs may name.
pub fn checkJob(ar: std.mem.Allocator, job: []const []const u8, spec: JobSpec) !?[]const u8 {
    const n = spec.name;
    if (!has(job, spec.runs_on) or countPrefix(job, "    runs-on:") != 1) return try std.fmt.allocPrint(ar, "{s}: runs-on is not exactly `{s}`", .{ n, std.mem.trim(u8, spec.runs_on, " ") });
    if (!has(job, spec.gate) or countPrefix(job, "    if:") != 1) return try std.fmt.allocPrint(ar, "{s}: its if: is not exactly `{s}`", .{ n, std.mem.trim(u8, spec.gate, " ") });
    if (spec.needs) |want| {
        if (!has(job, want) or countPrefix(job, "    needs:") != 1) return try std.fmt.allocPrint(ar, "{s}: its needs: is not exactly `{s}`", .{ n, std.mem.trim(u8, want, " ") });
    } else if (countPrefix(job, "    needs:") != 0) return try std.fmt.allocPrint(ar, "{s}: needs: where it needs nothing", .{n});
    if (spec.environment) |want| {
        if (!has(job, want) or countPrefix(job, "    environment:") != 1) return try std.fmt.allocPrint(ar, "{s}: its environment is not exactly `{s}`", .{ n, std.mem.trim(u8, want, " ") });
    } else if (countPrefix(job, "    environment:") != 0) return try std.fmt.allocPrint(ar, "{s}: an environment where it has none", .{n});
    if (countPrefix(job, "    permissions") != 1) return try std.fmt.allocPrint(ar, "{s}: permissions are not set exactly once", .{n});
    if (spec.perms.len == 0) {
        if (!has(job, "    permissions: {}")) return try std.fmt.allocPrint(ar, "{s}: permissions is not `{{}}`", .{n});
    } else {
        const got = (try permLines(ar, job)) orelse empty;
        var same = got.len == spec.perms.len;
        if (same) {
            for (spec.perms) |p| {
                if (!has(got, p)) same = false;
            }
        }
        if (!same) return try std.fmt.allocPrint(ar, "{s}: permissions are not exactly what the job needs", .{n});
    }
    const wants_id_token = spec.perms.len > 0 and has(spec.perms, "      id-token: write");
    if (mentions(job, "id-token") != wants_id_token) return try std.fmt.allocPrint(ar, "{s}: id-token is named where the job does not hold it", .{n});
    const is_build = isOneOf(n, &BUILD_JOBS);
    if (mentions(job, "farm-connect") != is_build) return try std.fmt.allocPrint(ar, "{s}: farm-connect is used outside the build job, or missing from it", .{n});
    if (!is_build and mentions(job, "buck2")) return try std.fmt.allocPrint(ar, "{s}: runs buck2: only the build job builds", .{n});
    if (!is_build and mentions(job, "actions/checkout")) return try std.fmt.allocPrint(ar, "{s}: checks out the repository: only the build job does", .{n});
    if (std.mem.indexOf(u8, n, "-smoke") == null and !std.mem.eql(u8, n, user_test.JOB) and mentions(job, "setup-python")) return try std.fmt.allocPrint(ar, "{s}: sets up Python: only the smoke jobs and the user test do", .{n});
    if (mentions(job, "actions/cache/save@") != isOneOf(n, &PASSED_JOBS)) return try std.fmt.allocPrint(ar, "{s}: saves to the cache where it may not, or the record job does not: only the record job saves a record", .{n});
    if (mentions(job, "actions/cache/restore@") != isOneOf(n, &PROMOTE_JOBS)) return try std.fmt.allocPrint(ar, "{s}: restores from the cache where it may not, or the promote job does not: only the promote job reads a record", .{n});
    if (mentions(job, "actions/cache@")) return try std.fmt.allocPrint(ar, "{s}: uses actions/cache, which saves at the end of any job: a record is saved by actions/cache/save alone", .{n});
    return null;
}

fn checkBuild(ar: std.mem.Allocator, job: []const []const u8) !?[]const u8 {
    for (BUILD_LINES) |l| {
        if (!has(job, l)) return try missingLine(ar, "build", "build, stamp, dist, record and artifacts", l);
    }
    for (BUILD_UPLOAD_FORBIDDEN) |w| {
        if (mentions(job, w)) return try std.fmt.allocPrint(ar, "build: has an upload step (it names \"{s}\"): only the upload jobs upload", .{w});
    }
    if (countMentions(job, "komira.package_stamp=") != 3 or countMentions(job, "build -c ") != 3) return "build: the wheel, the install test and the driver are not each built with the stamp flags, and nothing else is";
    if (countMentions(job, "actions/upload-artifact@") != 2 or countPrefix(job, "          if-no-files-found: error") != 2 or countPrefix(job, "          retention-days: 14") != 2) return "build: it does not keep exactly the dist and the smoke artifacts, each failing when empty, for 14 days";
    return null;
}

fn checkUpload(ar: std.mem.Allocator, job: []const []const u8, ix: Index, downloads: []const []const u8, storage: bool) !?[]const u8 {
    const n = ix.name;
    for (downloads) |l| {
        if (!has(job, l)) return try missingLine(ar, n, "the two downloads", l);
    }
    if (countMentions(job, "actions/download-artifact@") != 2) return try std.fmt.allocPrint(ar, "{s}: it does not download exactly the dist and the smoke artifacts", .{n});
    for ([_][]const u8{ CHMOD, "        id: state", ix.state_step, ix.state_run, STATE_OUTPUT, ix.upload_step, STATE_ENABLED, PUBLISH, PACKAGES_DIR }) |l| {
        if (!has(job, l)) return try missingLine(ar, n, "the state and the upload", l);
    }
    if (countMentions(job, "gh-action-pypi-publish") != 1) return try std.fmt.allocPrint(ar, "{s}: it does not hold exactly one upload step", .{n});
    const name_at = lineAt(job, ix.upload_step).?;
    const if_at = lineAt(job, STATE_ENABLED).?;
    const uses_at = lineAt(job, PUBLISH).?;
    if (if_at != name_at + 1 or uses_at != if_at + 1 or countPrefix(job, "        if:") != 1) return try std.fmt.allocPrint(ar, "{s}: the upload step is not the one step that runs only for the state absent", .{n});
    if (lineAt(job, ix.state_run).? > uses_at) return try std.fmt.allocPrint(ar, "{s}: the state is asked after the upload step", .{n});
    if (ix.repository_url) |want| {
        if (!has(job, want) or countMentions(job, "repository-url") != 1) return try std.fmt.allocPrint(ar, "{s}: the upload address is not exactly `{s}`", .{ n, std.mem.trim(u8, want, " ") });
    } else if (mentions(job, "repository-url")) return try std.fmt.allocPrint(ar, "{s}: names a repository-url (PyPI is the action's default)", .{n});
    for ([_][]const u8{ "skip-existing", "attestations" }) |w| {
        if (mentions(job, w)) return try std.fmt.allocPrint(ar, "{s}: sets {s}: the upload action keeps its defaults", .{ n, w });
    }
    if (storage) {
        for (TESTPYPI_STORAGE ++ STORAGE_OUTPUTS) |l| {
            if (!has(job, l)) return try missingLine(ar, n, "the size of the project on both indexes", l);
        }
        if (lineAt(job, TESTPYPI_STORAGE[5]).? > lineAt(job, ix.state_run).?) return try std.fmt.allocPrint(ar, "{s}: the size of the project is asked after the state: it is printed before the upload", .{n});
    } else if (mentions(job, " storage ")) return try std.fmt.allocPrint(ar, "{s}: asks the size of the project: the TestPyPI job and the promote job do", .{n});
    return null;
}

fn checkSmoke(ar: std.mem.Allocator, job: []const []const u8, ix: Index, name: []const u8, downloads: []const []const u8, matrix: []const []const u8) !?[]const u8 {
    for (downloads) |l| {
        if (!has(job, l)) return try missingLine(ar, name, "the two downloads", l);
    }
    for ([_][]const u8{ CHMOD, ix.verify_step, ix.verify_run, SETUP_PYTHON, "        id: python", PYTHON_VERSION, ix.install_step, PYTHON_ENV, ix.install_run }) |l| {
        if (!has(job, l)) return try missingLine(ar, name, "verify, set up Python and install", l);
    }
    if (countMentions(job, "setup-python") != 1) return try std.fmt.allocPrint(ar, "{s}: it does not set up Python exactly once", .{name});
    for (matrix) |l| {
        if (!has(job, l)) return try missingLine(ar, name, "one job per supported Python", l);
    }
    if (countPrefix(job, "    strategy:") != 1 or countPrefix(job, "      matrix:") != 1 or countMentions(job, "matrix.python") != 1) return try std.fmt.allocPrint(ar, "{s}: it is not one matrix of the supported Pythons, set up once", .{name});
    if (mentions(job, "gh-action-pypi-publish")) return try std.fmt.allocPrint(ar, "{s}: has an upload step", .{name});
    const verify_at = lineAt(job, ix.verify_run).?;
    const setup_at = lineAt(job, SETUP_PYTHON).?;
    const install_at = lineAt(job, ix.install_run).?;
    if (!(verify_at < setup_at and setup_at < install_at)) return try std.fmt.allocPrint(ar, "{s}: the steps are not verify, then set up Python, then install", .{name});
    return null;
}

fn checkPassed(ar: std.mem.Allocator, job: []const []const u8) !?[]const u8 {
    for (PASSED_LINES) |l| {
        if (!has(job, l)) return try missingLine(ar, "testpypi-passed", "the record saved under the version's key", l);
    }
    if (countMentions(job, "actions/download-artifact@") != 1 or countPrefix(job, "      - ") != 2) return "testpypi-passed: it is not exactly the download of the smoke artifact and the save of the record";
    // the directory saved is the directory the artifact was downloaded into
    if (countPrefix(job, "          path: ") != 2 or countMentions(job, "          path: ${{ runner.temp }}/pypi/passed") != 2) return "testpypi-passed: the record saved under the version's key: it saves another directory than the one it downloaded";
    return null;
}

fn checkPromote(ar: std.mem.Allocator, job: []const []const u8) !?[]const u8 {
    for (PROMOTE_LINES ++ PROMOTE_STORAGE) |l| {
        if (!has(job, l)) return try missingLine(ar, "promote", "restore the newest record, the size, promote, the matrix and the artifacts", l);
    }
    if (countMentions(job, "actions/upload-artifact@") != 2 or countPrefix(job, "          if-no-files-found: error") != 2 or countPrefix(job, "          retention-days: 14") != 2) return "promote: it does not keep exactly the dist and the smoke artifacts, each failing when empty, for 14 days";
    if (mentions(job, "gh-action-pypi-publish") or mentions(job, "actions/download-artifact@")) return "promote: uploads to an index or reads another job's artifact: it reads the record and TestPyPI alone";
    // the path restored is the record's directory (the artifacts' `path:` lines are the same text)
    const restore_at = lineAt(job, CACHE_RESTORE).?;
    if (restore_at + 2 >= job.len or !std.mem.eql(u8, job[restore_at + 2], "          path: ${{ runner.temp }}/pypi/passed")) return "promote: restore the newest record, the size, promote, the matrix and the artifacts: the restore's path is not the record's directory";
    const order = [_][]const u8{ CACHE_RESTORE, PROMOTE_CHMOD, PROMOTE_STORAGE[2], PROMOTE_STORAGE[5], PROMOTE_RUN, PROMOTE_MATRIX, UPLOAD };
    var last: usize = 0;
    for (order) |l| {
        const at = lineAt(job, l).?;
        if (at < last) return "promote: the steps are not restore, the size on both indexes, promote, the matrix, then the artifacts";
        last = at;
    }
    return null;
}

fn checkResult(ar: std.mem.Allocator, job: []const []const u8, name: []const u8, lines: []const []const u8, last_step: []const u8, steps: usize) !?[]const u8 {
    for (lines) |l| {
        if (!has(job, l)) return try missingLine(ar, name, "its steps", l);
    }
    if (countPrefix(job, "      - name:") != steps or countPrefix(job, "        run:") != steps or mentions(job, "uses:")) return try std.fmt.allocPrint(ar, "{s}: it is not exactly the {d} steps that print", .{ name, steps });
    // the notice of a run that uploaded nothing prints only when no step before it failed
    if (lineAt(job, last_step).? + 5 != job.len) return try std.fmt.allocPrint(ar, "{s}: the notice already ... is not its last step", .{name});
    return null;
}

/// The lines of the job's `outputs:` (when `with_outputs`) and `steps:`, as the macOS line lists hold them.
fn outputsAndSteps(ar: std.mem.Allocator, job: []const []const u8, with_outputs: bool) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const steps_at = lineAt(job, "    steps:") orelse return out.toOwnedSlice(ar);
    if (with_outputs) {
        if (lineAt(job, "    outputs:")) |o| {
            for (job[o + 1 .. steps_at]) |l| {
                if (!std.mem.startsWith(u8, l, "      ")) break;
                try out.append(ar, l);
            }
        }
    }
    try out.appendSlice(ar, job[steps_at + 1 ..]);
    return out.toOwnedSlice(ar);
}

/// Null if the job's outputs and steps are exactly `want`, in order; else the first line that differs.
pub fn checkExact(ar: std.mem.Allocator, job: []const []const u8, name: []const u8, want: []const []const u8, with_outputs: bool) !?[]const u8 {
    const got = try outputsAndSteps(ar, job, with_outputs);
    for (want, 0..) |w, i| {
        if (i >= got.len) return try std.fmt.allocPrint(ar, "{s}: its outputs and steps are not exactly the contract's: the line `{s}` is missing at the end", .{ name, std.mem.trim(u8, w, " ") });
        if (!std.mem.eql(u8, w, got[i])) return try std.fmt.allocPrint(ar, "{s}: its outputs and steps are not exactly the contract's: `{s}` where `{s}` is wanted", .{ name, std.mem.trim(u8, got[i], " "), std.mem.trim(u8, w, " ") });
    }
    if (got.len > want.len) return try std.fmt.allocPrint(ar, "{s}: its outputs and steps are not exactly the contract's: `{s}` after its last line", .{ name, std.mem.trim(u8, got[want.len], " ") });
    return null;
}

/// Null if the workflow text holds the contract, else the refusal. `release_text` is release.yml's,
/// whose push filter the push trigger repeats.
pub fn check(ar: std.mem.Allocator, text: []const u8, release_text: []const u8) !?[]const u8 {
    if (try checkLinuxJobs(ar, text, release_text)) |why| return why;
    return try macos.checkJobs(ar, text);
}

/// Null if the file rules and the ten Linux jobs hold the contract, else the refusal.
fn checkLinuxJobs(ar: std.mem.Allocator, text: []const u8, release_text: []const u8) !?[]const u8 {
    if (try checkFile(ar, text, release_text, FILE)) |why| return why;
    for (SPECS) |spec| {
        var n: usize = 0;
        const job = (try jobLines(ar, text, spec.name, &n)) orelse return try std.fmt.allocPrint(ar, "the job {s} is missing", .{spec.name});
        if (try checkJob(ar, job, spec)) |why| return why;
        const s = spec.name;
        const verdict = if (std.mem.eql(u8, s, "build"))
            try checkBuild(ar, job)
        else if (std.mem.eql(u8, s, user_test.JOB))
            try user_test.check(ar, job, USER_TEST)
        else if (std.mem.eql(u8, s, "testpypi"))
            try checkUpload(ar, job, TESTPYPI, &PUSH_DOWNLOADS, true)
        else if (std.mem.eql(u8, s, "testpypi-smoke"))
            try checkSmoke(ar, job, TESTPYPI, s, &PUSH_DOWNLOADS, &PUSH_MATRIX)
        else if (std.mem.eql(u8, s, "testpypi-passed"))
            try checkPassed(ar, job)
        else if (std.mem.eql(u8, s, "result-testpypi"))
            try checkResult(ar, job, s, &RESULT_TESTPYPI_LINES, TESTPYPI_SAME_STEP, 5)
        else if (std.mem.eql(u8, s, "promote"))
            try checkPromote(ar, job)
        else if (std.mem.eql(u8, s, "pypi"))
            try checkUpload(ar, job, PYPI, &PROMOTE_DOWNLOADS, false)
        else if (std.mem.eql(u8, s, "pypi-smoke"))
            try checkSmoke(ar, job, PYPI, s, &PROMOTE_DOWNLOADS, &PROMOTE_MATRIX_LINES)
        else
            try checkResult(ar, job, s, &RESULT_PYPI_LINES, PYPI_SAME_STEP, 7);
        if (verdict) |why| return why;
    }
    return null;
}
