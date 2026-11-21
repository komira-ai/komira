//! The cases of pypi.yml, the publish of the Python package, //:pypi_workflow_cases: a `zig_test`
//! run as a build action. The workflow's own bytes are the subject (the zig_test's `data`, under
//! KOMIRA_TEST_WORK/workflows/pypi.yml). `check` reads the text and says why it breaks the
//! contract, or null; the cases write each defect into the real text and want it refused with its
//! message. What the contract holds:
//!  - the triggers: `on:` is `workflow_dispatch:` alone (no schedule, cron, push or pull request
//!    outside a comment), with one required input, `flavour`, a choice of exactly `external` and
//!    `bundled` whose default is `bundled`; top-level `permissions` is `{}` exactly once, and the
//!    concurrency is the group `pypi` with no run cancelled;
//!  - the jobs are exactly build, testpypi, testpypi-smoke, pypi, pypi-smoke and result (the Linux
//!    wheel), then build-macos-arm64, testpypi-macos-arm64, testpypi-smoke-macos-arm64,
//!    pypi-macos-arm64, pypi-smoke-macos-arm64 and result-macos-arm64 (the macOS wheel, the bundled
//!    flavour only), each once, and each holds its exact `if:` (main only; build-macos-arm64 also only
//!    for the bundled flavour), runner, `needs:`, environment and permissions: the two smoke jobs of
//!    the macOS wheel run on macos-15 and every other job on ubuntu-24.04;
//!    `id-token: write` is held by build and build-macos-arm64 (for the farm only), testpypi, pypi,
//!    testpypi-macos-arm64 and pypi-macos-arm64 (for the upload only) and by no other job;
//!  - the farm: farm-connect is in build and build-macos-arm64 alone, with `farm-qos: batch`, buck2
//!    runs in those two jobs alone, and testpypi and pypi join no farm, check out nothing and run no
//!    buck2;
//!  - the Linux jobs' own contract is held here (the stamp, the artifacts, the state and the upload,
//!    the smoke steps, the result steps); what the macOS jobs hold beyond the job set is in
//!    release_macos_test.zig (//:release_macos_cases);
//!  - build has no upload step (no publish action, no legacy upload address, no twine); it builds the
//!    wheel and the install test of the input's flavour and the driver, each with the three stamp
//!    flags, writes the flavour and the version to the run's summary, and keeps exactly the dist and
//!    the smoke artifacts;
//!  - testpypi and pypi ask the state before the upload step, which runs for `absent` alone, with the
//!    pinned publish action and the dist directory; testpypi names the TestPyPI upload address, pypi
//!    none; neither skips an existing file or turns attestations off;
//!  - the smoke jobs verify, then install, each with 5 attempts 30 seconds apart, on the pinned
//!    setup-python with Python 3.13; setup-python is in the four smoke jobs alone;
//!  - every `uses:` that is not local names a commit: owner/repo@<40 lowercase hex>;
//!  - no line outside a comment holds a secret, a password, an API token, curl, wget, jq, twine,
//!    continue-on-error or pull_request_target, and no `run:` line holds a `${{ }}` expression;
//!  - result runs always on main, needs the five jobs, holds no permission, prints the notice for the
//!    `differs` state and fails the run in three steps with their exact conditions.

const std = @import("std");
const t = std.testing;

const JOBS = [_][]const u8{
    "build",
    "testpypi",
    "testpypi-smoke",
    "pypi",
    "pypi-smoke",
    "result",
    "build-macos-arm64",
    "testpypi-macos-arm64",
    "testpypi-smoke-macos-arm64",
    "pypi-macos-arm64",
    "pypi-smoke-macos-arm64",
    "result-macos-arm64",
};
const MAIN_ONLY = "    if: github.ref == 'refs/heads/main'";
/// The macOS wheel is the bundled flavour: its build runs for a bundled run alone.
const MACOS_BUILD_GATE = "    if: github.ref == 'refs/heads/main' && inputs.flavour == 'bundled'";

const JobSpec = struct {
    name: []const u8,
    /// The whole `runs-on:` line.
    runs_on: []const u8,
    gate: []const u8,
    needs: ?[]const u8,
    environment: ?[]const u8,
    /// The lines under `permissions:`; none means `permissions: {}`.
    perms: []const []const u8,
};

const BUILD_PERMS = [_][]const u8{ "      contents: read", "      id-token: write" };
const UPLOAD_PERMS = [_][]const u8{"      id-token: write"};
const SMOKE_PERMS = [_][]const u8{"      contents: read"};
const NO_PERMS = [_][]const u8{};
const empty: []const []const u8 = &.{};

const UBUNTU = "    runs-on: ubuntu-24.04";
const MACOS = "    runs-on: macos-15";
const SMOKE_GATE_MAIN = "    if: github.ref == 'refs/heads/main' && ";
const RESULT_GATE = "    if: always() && github.ref == 'refs/heads/main'";

const SPECS = [_]JobSpec{
    .{ .name = "build", .runs_on = UBUNTU, .gate = MAIN_ONLY, .needs = null, .environment = "    environment: build", .perms = &BUILD_PERMS },
    .{ .name = "testpypi", .runs_on = UBUNTU, .gate = MAIN_ONLY, .needs = "    needs: build", .environment = "    environment: testpypi", .perms = &UPLOAD_PERMS },
    .{ .name = "testpypi-smoke", .runs_on = UBUNTU, .gate = SMOKE_GATE_MAIN ++ "needs.testpypi.outputs.state != 'differs'", .needs = "    needs: [build, testpypi]", .environment = null, .perms = &SMOKE_PERMS },
    .{ .name = "pypi", .runs_on = UBUNTU, .gate = MAIN_ONLY, .needs = "    needs: [build, testpypi-smoke]", .environment = "    environment: pypi", .perms = &UPLOAD_PERMS },
    .{ .name = "pypi-smoke", .runs_on = UBUNTU, .gate = SMOKE_GATE_MAIN ++ "needs.pypi.outputs.state != 'differs'", .needs = "    needs: [build, pypi]", .environment = null, .perms = &SMOKE_PERMS },
    .{ .name = "result", .runs_on = UBUNTU, .gate = RESULT_GATE, .needs = "    needs: [build, testpypi, testpypi-smoke, pypi, pypi-smoke]", .environment = null, .perms = &NO_PERMS },
    // the macOS wheel: the build only asks the farm (an ubuntu runner), the smokes run on a hosted Mac
    .{ .name = "build-macos-arm64", .runs_on = UBUNTU, .gate = MACOS_BUILD_GATE, .needs = null, .environment = "    environment: build", .perms = &BUILD_PERMS },
    .{ .name = "testpypi-macos-arm64", .runs_on = UBUNTU, .gate = SMOKE_GATE_MAIN ++ "needs.build-macos-arm64.outputs.version != ''", .needs = "    needs: build-macos-arm64", .environment = "    environment: testpypi", .perms = &UPLOAD_PERMS },
    .{ .name = "testpypi-smoke-macos-arm64", .runs_on = MACOS, .gate = SMOKE_GATE_MAIN ++ "needs.testpypi-macos-arm64.outputs.state != 'differs'", .needs = "    needs: [build-macos-arm64, testpypi-macos-arm64]", .environment = null, .perms = &SMOKE_PERMS },
    .{ .name = "pypi-macos-arm64", .runs_on = UBUNTU, .gate = MAIN_ONLY, .needs = "    needs: [build-macos-arm64, testpypi-smoke-macos-arm64]", .environment = "    environment: pypi", .perms = &UPLOAD_PERMS },
    .{ .name = "pypi-smoke-macos-arm64", .runs_on = MACOS, .gate = SMOKE_GATE_MAIN ++ "needs.pypi-macos-arm64.outputs.state != 'differs'", .needs = "    needs: [build-macos-arm64, pypi-macos-arm64]", .environment = null, .perms = &SMOKE_PERMS },
    .{ .name = "result-macos-arm64", .runs_on = UBUNTU, .gate = RESULT_GATE, .needs = "    needs: [build-macos-arm64, testpypi-macos-arm64, testpypi-smoke-macos-arm64, pypi-macos-arm64, pypi-smoke-macos-arm64]", .environment = null, .perms = &NO_PERMS },
};

fn isMacosJob(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "-macos-arm64");
}

// ---- the pinned actions and the shared lines ---------------------------------------------------
const CHECKOUT = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1";
const SETUP_PYTHON = "      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0";
const DOWNLOAD = "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1";
const UPLOAD = "      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1";
const PUBLISH = "        uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # v1.14.3";
const PACKAGES_DIR = "          packages-dir: dist";
const CHMOD = "        run: chmod +x \"$RUNNER_TEMP/pypi/smoke/pypi_smoke\"";
const STATE_ENABLED = "        if: steps.state.outputs.state == 'absent'";
const FARM_CONNECT = "      - uses: ./.github/actions/farm-connect";
const FARM_QOS = "          farm-qos: batch";
const FARM_TLS = "          tls: ${{ vars.FARM_TLS || 'false' }}";
const DOWNLOAD_NAMES = [_][]const u8{
    "          name: pypi-${{ needs.build.outputs.version }}-dist",
    "          path: dist",
    "          name: pypi-${{ needs.build.outputs.version }}-smoke",
    "          path: ${{ runner.temp }}/pypi/smoke",
};

// ---- the build job ------------------------------------------------------------------------------
const STAMP_FLAGS = "-c komira.package_stamp=${{ steps.stamp.outputs.build_number }} -c komira.package_commit=${{ steps.stamp.outputs.source_commit }} -c komira.package_timestamp_ms=${{ steps.stamp.outputs.timestamp_ms }}";
const BUILD_WHEEL = "          args: build " ++ STAMP_FLAGS ++ " //python:komira_wheel_${{ inputs.flavour }}[release] --out ${{ runner.temp }}/pypi/built/komira.whl";
const BUILD_INSTALL_TEST = "          args: build " ++ STAMP_FLAGS ++ " //python:wheel_install_test_${{ inputs.flavour }}";
const SUMMARY_STEP = "      - name: the flavour in the run's summary";
const SUMMARY_FLAVOUR = "          FLAVOUR: ${{ inputs.flavour }}";
const SUMMARY_VERSION = "          VERSION: ${{ steps.dist.outputs.version }}";
const SUMMARY_RUN = "        run: 'echo \"komira $VERSION, the $FLAVOUR flavour of the wheel (python/flavour.bzl)\" >> \"$GITHUB_STEP_SUMMARY\"'";
const BUILD_DRIVER = "          args: build " ++ STAMP_FLAGS ++ " //python/smoke:pypi_smoke --out ${{ runner.temp }}/pypi/smoke/pypi_smoke";
const BUILD_LINES = [_][]const u8{
    "      version: ${{ steps.dist.outputs.version }}",
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
    "        id: dist",
    "        run: '\"$RUNNER_TEMP/pypi/smoke/pypi_smoke\" dist --wheel \"$RUNNER_TEMP/pypi/built/komira.whl\" --out \"$RUNNER_TEMP/pypi/dist\" --github-output \"$GITHUB_OUTPUT\"'",
    "          name: pypi-${{ steps.dist.outputs.version }}-dist",
    "          path: ${{ runner.temp }}/pypi/dist",
    "          name: pypi-${{ steps.dist.outputs.version }}-smoke",
    "          path: ${{ runner.temp }}/pypi/smoke",
    SUMMARY_STEP,
    SUMMARY_FLAVOUR,
    SUMMARY_VERSION,
    SUMMARY_RUN,
};
const BUILD_UPLOAD_FORBIDDEN = [_][]const u8{ "pypa/gh-action-pypi-publish", "legacy/", "twine", "repository-url", "packages-dir" };

// ---- the index jobs -----------------------------------------------------------------------------
const Index = struct {
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
    return .{
        .name = idx,
        .state_step = "      - name: the wheel on " ++ title,
        .state_run = "        run: '\"$RUNNER_TEMP/pypi/smoke/pypi_smoke\" state --index " ++ idx ++ " --dist dist --github-output \"$GITHUB_OUTPUT\"'",
        .upload_step = "      - name: upload to " ++ title,
        .repository_url = repo,
        .verify_step = "      - name: " ++ title ++ " serves the wheel as built",
        .verify_run = "        run: '\"$RUNNER_TEMP/pypi/smoke/pypi_smoke\" verify --index " ++ idx ++ " --dist dist --attempts 5 --delay 30'",
        .install_step = "      - name: pip installs komira from " ++ title ++ " and the quickstart prints what it should",
        .install_run = "        run: '\"$RUNNER_TEMP/pypi/smoke/pypi_smoke\" install --index " ++ idx ++ " --dist dist --python \"$PYTHON\" --example python/examples/quickstart.py --expect python/examples/quickstart.expected --data python/examples/readings.parquet --abi-table src/so/abi/komira.tsv --work \"$RUNNER_TEMP/pypi/install\" --attempts 5 --delay 30'",
    };
}

const TESTPYPI = indexSpec("testpypi", "TestPyPI", "          repository-url: https://test.pypi.org/legacy/");
const PYPI = indexSpec("pypi", "PyPI", null);
const STATE_OUTPUT = "      state: ${{ steps.state.outputs.state }}";
const PYTHON_VERSION = "          python-version: '3.13'";
const PYTHON_ENV = "          PYTHON: ${{ steps.python.outputs.python-path }}";

// ---- the result job -----------------------------------------------------------------------------
const RESULT_BUILD_IF = "        if: needs.build.result != 'success' || needs.testpypi.result != 'success'";
const RESULT_UPLOAD_IF = "        if: needs.testpypi.outputs.state != 'differs' && (needs.testpypi-smoke.result != 'success' || needs.pypi.result != 'success')";
const RESULT_SMOKE_IF = "        if: needs.testpypi.outputs.state != 'differs' && needs.pypi.outputs.state != 'differs' && needs.pypi-smoke.result != 'success'";
const RESULT_DIFFERS_IF = "        if: needs.testpypi.outputs.state == 'differs' || needs.pypi.outputs.state == 'differs'";
const RESULT_NOTICE = "        run: 'echo \"::notice title=pypi::bytes differ at the same version: a commit that changed only documentation, which the stamp ignores; a code commit raises the version\"'";
const RESULT_LINES = [_][]const u8{
    "      - name: the build and the TestPyPI upload succeeded",
    RESULT_BUILD_IF,
    "          BUILD: ${{ needs.build.result }}",
    "          TESTPYPI: ${{ needs.testpypi.result }}",
    "        run: 'echo \"::error title=pypi::the build or the TestPyPI upload job did not succeed (build $BUILD, testpypi $TESTPYPI)\" && exit 1'",
    "      - name: the bytes differ at the same version",
    RESULT_DIFFERS_IF,
    RESULT_NOTICE,
    "      - name: the TestPyPI smoke and the PyPI upload succeeded",
    RESULT_UPLOAD_IF,
    "          TESTPYPI_SMOKE: ${{ needs.testpypi-smoke.result }}",
    "          PYPI: ${{ needs.pypi.result }}",
    "        run: 'echo \"::error title=pypi::the TestPyPI smoke or the PyPI upload job did not succeed (testpypi-smoke $TESTPYPI_SMOKE, pypi $PYPI)\" && exit 1'",
    "      - name: the PyPI smoke succeeded",
    RESULT_SMOKE_IF,
    "          PYPI_SMOKE: ${{ needs.pypi-smoke.result }}",
    "        run: 'echo \"::error title=pypi::the PyPI smoke job did not succeed (pypi-smoke $PYPI_SMOKE)\" && exit 1'",
};

// ---- the trigger ---------------------------------------------------------------------------------
/// The lines of `on:`: the manual run and its one input. The default is `bundled`, the flavour a scheduled
/// run publishes: flipping it is that one line here and in the workflow.
const ON_LINES = [_][]const u8{
    "  workflow_dispatch:",
    "    inputs:",
    "      flavour:",
    "        description: the wheel's flavour (python/flavour.bzl); a run publishes exactly one",
    "        type: choice",
    "        options:",
    "          - external",
    "          - bundled",
    "        default: bundled",
    "        required: true",
};

/// What no line outside a comment may contain, whatever the case.
const FORBIDDEN = [_][]const u8{ "secrets", "password", "api-token", "pypi_token", "curl", "wget", "jq ", "twine", "continue-on-error", "pull_request_target" };
/// What the triggers may not name outside a comment.
const TRIGGER_WORDS = [_][]const u8{ "schedule", "cron", "push:", "pull_request" };

// ---- the reader ---------------------------------------------------------------------------------

/// The lines of the job `name` of the `jobs:` map (a key at two spaces of
/// indent), without comment lines and blank lines, or null if there is no such
/// job. Counts the jobs of that name in `count`.
fn jobLines(ar: std.mem.Allocator, text: []const u8, name: []const u8, count: *usize) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    var found = false;
    var in_jobs = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "jobs:")) {
            in_jobs = true;
            continue;
        }
        if (!in_jobs) continue;
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = line.len - std.mem.trimLeft(u8, line, " ").len;
        if (indent == 2 and std.mem.endsWith(u8, trimmed, ":")) {
            inside = std.mem.eql(u8, trimmed[0 .. trimmed.len - 1], name);
            if (inside) {
                count.* += 1;
                found = true;
                out.clearRetainingCapacity();
            }
            continue;
        }
        if (inside) try out.append(ar, line);
    }
    if (!found) return null;
    return try out.toOwnedSlice(ar);
}

/// The names of the jobs of the `jobs:` map, in file order.
fn jobNames(ar: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var in_jobs = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "jobs:")) {
            in_jobs = true;
            continue;
        }
        if (!in_jobs) continue;
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = line.len - std.mem.trimLeft(u8, line, " ").len;
        if (indent == 2 and std.mem.endsWith(u8, trimmed, ":")) try out.append(ar, trimmed[0 .. trimmed.len - 1]);
    }
    return try out.toOwnedSlice(ar);
}

/// The lines of the top-level key `key` (a line at column 0, e.g. `on:`), up to the next
/// top-level line, without comment and blank lines.
fn topLines(ar: std.mem.Allocator, text: []const u8, key: []const u8, count: *usize) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    var found = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != ' ') {
            inside = std.mem.eql(u8, line, key);
            if (inside) {
                count.* += 1;
                found = true;
            }
            continue;
        }
        if (inside) try out.append(ar, line);
    }
    if (!found) return null;
    return try out.toOwnedSlice(ar);
}

fn has(lines: []const []const u8, exact: []const u8) bool {
    for (lines) |l| if (std.mem.eql(u8, l, exact)) return true;
    return false;
}

fn lineAt(lines: []const []const u8, exact: []const u8) ?usize {
    for (lines, 0..) |l, i| if (std.mem.eql(u8, l, exact)) return i;
    return null;
}

fn mentions(lines: []const []const u8, needle: []const u8) bool {
    return countMentions(lines, needle) > 0;
}

fn countMentions(lines: []const []const u8, needle: []const u8) usize {
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

// ---- the checks ---------------------------------------------------------------------------------

fn onLinesHold(lines: []const []const u8) bool {
    if (lines.len != ON_LINES.len) return false;
    for (ON_LINES, lines) |want, got| {
        if (!std.mem.eql(u8, want, got)) return false;
    }
    return true;
}

/// Null if the whole file passes its text-level rules, else the refusal: what no line may contain,
/// the triggers, the permissions and concurrency of the workflow, the job set and the pins.
fn checkFile(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var run_indent: ?usize = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = line.len - std.mem.trimLeft(u8, line, " ").len;
        for (FORBIDDEN) |w| {
            if (std.ascii.indexOfIgnoreCase(line, w) != null) return try std.fmt.allocPrint(ar, "a line outside a comment contains \"{s}\": {s}", .{ w, trimmed });
        }
        for (TRIGGER_WORDS) |w| {
            if (std.mem.indexOf(u8, line, w) != null) return try std.fmt.allocPrint(ar, "a line outside a comment names a schedule, a cron, a push or a pull request trigger (\"{s}\"): {s}", .{ w, trimmed });
        }
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
    if (on_n != 1 or !onLinesHold(on_lines)) return "on: is not exactly workflow_dispatch: with the input flavour, a required choice of external and bundled whose default is bundled";

    var perm_n: usize = 0;
    _ = try topLines(ar, text, "permissions: {}", &perm_n);
    var other_perm_n: usize = 0;
    _ = try topLines(ar, text, "permissions:", &other_perm_n);
    if (perm_n != 1 or other_perm_n != 0) return "top-level permissions is not exactly `permissions: {}` once";

    var conc_n: usize = 0;
    const conc = (try topLines(ar, text, "concurrency:", &conc_n)) orelse empty;
    if (conc_n != 1 or conc.len != 2 or !has(conc, "  group: pypi") or !has(conc, "  cancel-in-progress: false")) return "concurrency is not exactly the group pypi with cancel-in-progress: false";

    const names = try jobNames(ar, text);
    var same_jobs = names.len == JOBS.len;
    if (same_jobs) {
        for (names, 0..) |n, i| {
            if (!std.mem.eql(u8, n, JOBS[i])) same_jobs = false;
        }
    }
    if (!same_jobs) return "the jobs are not exactly the twelve of the Linux and the macOS wheel (build, testpypi, testpypi-smoke, pypi, pypi-smoke, result, and the same six with the suffix -macos-arm64), each once";

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

/// Null if the job holds what every job holds: its runner, gate, needs, environment and permissions.
fn checkJob(ar: std.mem.Allocator, job: []const []const u8, spec: JobSpec) !?[]const u8 {
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
    const is_build = std.mem.eql(u8, n, "build") or std.mem.eql(u8, n, "build-macos-arm64");
    if (mentions(job, "farm-connect") != is_build) return try std.fmt.allocPrint(ar, "{s}: farm-connect is used outside the two build jobs, or missing from them", .{n});
    if (!is_build and mentions(job, "buck2")) return try std.fmt.allocPrint(ar, "{s}: runs buck2: only the two build jobs build", .{n});
    if (std.mem.indexOf(u8, n, "-smoke") == null and mentions(job, "setup-python")) return try std.fmt.allocPrint(ar, "{s}: sets up Python: only the smoke jobs do", .{n});
    return null;
}

fn checkBuild(ar: std.mem.Allocator, job: []const []const u8) !?[]const u8 {
    for (BUILD_LINES) |l| {
        if (!has(job, l)) return try missingLine(ar, "build", "build, stamp, dist and artifacts", l);
    }
    for (BUILD_UPLOAD_FORBIDDEN) |w| {
        if (mentions(job, w)) return try std.fmt.allocPrint(ar, "build: has an upload step (it names \"{s}\"): only testpypi and pypi upload", .{w});
    }
    if (countMentions(job, "komira.package_stamp=") != 3) return "build: the wheel, the install test and the driver are not each built with the stamp flags";
    if (countMentions(job, "actions/upload-artifact@") != 2 or countPrefix(job, "          if-no-files-found: error") != 2 or countPrefix(job, "          retention-days: 14") != 2) return "build: it does not keep exactly the dist and the smoke artifacts, each failing when empty, for 14 days";
    if (countMentions(job, "build -c ") != 3) return "build: the buck2 steps that carry the stamp are not the wheel, the install test and the driver";
    return null;
}

fn checkUpload(ar: std.mem.Allocator, job: []const []const u8, ix: Index) !?[]const u8 {
    const n = ix.name;
    for (DOWNLOAD_NAMES) |l| {
        if (!has(job, l)) return try missingLine(ar, n, "the two downloads", l);
    }
    if (countMentions(job, "actions/download-artifact@") != 2) return try std.fmt.allocPrint(ar, "{s}: it does not download exactly the dist and the smoke artifacts", .{n});
    if (mentions(job, "actions/checkout")) return try std.fmt.allocPrint(ar, "{s}: checks out the repository: an upload job reads only the dist directory", .{n});
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
    return null;
}

fn checkSmoke(ar: std.mem.Allocator, job: []const []const u8, ix: Index, name: []const u8) !?[]const u8 {
    for (DOWNLOAD_NAMES) |l| {
        if (!has(job, l)) return try missingLine(ar, name, "the two downloads", l);
    }
    for ([_][]const u8{ CHECKOUT, "          persist-credentials: false", CHMOD, ix.verify_step, ix.verify_run, SETUP_PYTHON, "        id: python", PYTHON_VERSION, ix.install_step, PYTHON_ENV, ix.install_run }) |l| {
        if (!has(job, l)) return try missingLine(ar, name, "verify, set up Python and install", l);
    }
    if (countMentions(job, "setup-python") != 1) return try std.fmt.allocPrint(ar, "{s}: it does not set up Python exactly once", .{name});
    if (mentions(job, "gh-action-pypi-publish")) return try std.fmt.allocPrint(ar, "{s}: has an upload step", .{name});
    const verify_at = lineAt(job, ix.verify_run).?;
    const setup_at = lineAt(job, SETUP_PYTHON).?;
    const install_at = lineAt(job, ix.install_run).?;
    if (!(verify_at < setup_at and setup_at < install_at)) return try std.fmt.allocPrint(ar, "{s}: the steps are not verify, then set up Python, then install", .{name});
    return null;
}

fn checkResult(ar: std.mem.Allocator, job: []const []const u8) !?[]const u8 {
    for (RESULT_LINES) |l| {
        if (!has(job, l)) return try missingLine(ar, "result", "its steps", l);
    }
    if (countPrefix(job, "      - name:") != 4 or countPrefix(job, "        run:") != 4 or mentions(job, "uses:")) return "result: it is not exactly the four steps that print";
    return null;
}

/// Null if the workflow text holds the contract, else the refusal.
fn check(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (try checkFile(ar, text)) |why| return why;
    for (SPECS) |spec| {
        var n: usize = 0;
        const job = (try jobLines(ar, text, spec.name, &n)) orelse return try std.fmt.allocPrint(ar, "the job {s} is missing", .{spec.name});
        if (try checkJob(ar, job, spec)) |why| return why;
        // the macOS jobs hold their contract in release_macos_test.zig; here the job set and the
        // exact gate, runner, needs, environment and permissions of each
        const verdict = if (isMacosJob(spec.name))
            null
        else if (std.mem.eql(u8, spec.name, "build"))
            try checkBuild(ar, job)
        else if (std.mem.eql(u8, spec.name, "testpypi"))
            try checkUpload(ar, job, TESTPYPI)
        else if (std.mem.eql(u8, spec.name, "pypi"))
            try checkUpload(ar, job, PYPI)
        else if (std.mem.eql(u8, spec.name, "testpypi-smoke"))
            try checkSmoke(ar, job, TESTPYPI, spec.name)
        else if (std.mem.eql(u8, spec.name, "pypi-smoke"))
            try checkSmoke(ar, job, PYPI, spec.name)
        else
            try checkResult(ar, job);
        if (verdict) |why| return why;
    }
    return null;
}

// ---- the tests ----------------------------------------------------------------------------------

fn readWorkflow(ar: std.mem.Allocator) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(ar, &.{ work, "workflows", "pypi.yml" });
    return std.fs.cwd().readFileAlloc(ar, path, 1 << 20);
}

fn expectRefused(ar: std.mem.Allocator, text: []const u8, want: []const u8) !void {
    const got = (try check(ar, text)) orelse {
        std.debug.print("accepted a workflow that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

/// `text` with every `from` replaced by `to`; the anchor must be there.
fn replaced(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, from) == null) {
        std.debug.print("the case's anchor is not in pypi.yml: {s}\n", .{from});
        return error.NoAnchor;
    }
    return std.mem.replaceOwned(u8, ar, text, from, to);
}

/// `text` with the first `from` at or after the header of the job `job` replaced by `to`.
fn inJob(ar: std.mem.Allocator, text: []const u8, job: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const header = try std.fmt.allocPrint(ar, "\n  {s}:\n", .{job});
    const start = std.mem.indexOf(u8, text, header) orelse {
        std.debug.print("the case's job is not in pypi.yml: {s}\n", .{job});
        return error.NoAnchor;
    };
    const at = std.mem.indexOfPos(u8, text, start, from) orelse {
        std.debug.print("the case's anchor is not in job {s} of pypi.yml: {s}\n", .{ job, from });
        return error.NoAnchor;
    };
    return try std.mem.concat(ar, u8, &.{ text[0..at], to, text[at + from.len ..] });
}

fn realText(ar: std.mem.Allocator) ![]const u8 {
    return try readWorkflow(ar);
}

test "pypi.yml holds the contract of the publish workflow" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    if (try check(ar, text)) |why| {
        std.debug.print("pypi.yml: {s}\n", .{why});
        return error.Refused;
    }
    // a comment may talk about what the file does not hold
    try t.expect((try check(ar, try replaced(ar, text, "name: pypi\n", "name: pypi\n# no secrets, no twine, no schedule: a comment says so\n"))) == null);
}

test "a secret, a token or a download tool in any job is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    try expectRefused(ar, try inJob(ar, text, "testpypi", PACKAGES_DIR ++ "\n", PACKAGES_DIR ++ "\n          token: ${{ secrets.PYPI_API_TOKEN }}\n"), "contains \"secrets\"");
    try expectRefused(ar, try inJob(ar, text, "pypi", PACKAGES_DIR ++ "\n", PACKAGES_DIR ++ "\n          password: x\n"), "contains \"password\"");
    try expectRefused(ar, try inJob(ar, text, "build", "      - name: Stop buck2\n", "      - name: fetch\n        run: curl -sS https://example.org\n      - name: Stop buck2\n"), "contains \"curl\"");
    try expectRefused(ar, try inJob(ar, text, "build", "      - name: Stop buck2\n", "      - name: fetch\n        run: wget https://example.org\n      - name: Stop buck2\n"), "contains \"wget\"");
    try expectRefused(ar, try inJob(ar, text, "result", "    steps:\n", "    steps:\n      - run: echo x | jq .\n"), "contains \"jq \"");
    try expectRefused(ar, try inJob(ar, text, "pypi", "      - name: the driver is executable\n", "      - run: twine upload dist/*\n      - name: the driver is executable\n"), "contains \"twine\"");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", "    timeout-minutes: 30\n", "    timeout-minutes: 30\n    continue-on-error: true\n"), "contains \"continue-on-error\"");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  pull_request_target:\n  workflow_dispatch:\n"), "contains \"pull_request_target\"");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", "        env:\n", "        env:\n          TOKEN: PYPI_TOKEN\n"), "contains \"pypi_token\"");
}

test "an expression inside a run line, one line or a block, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    try expectRefused(ar, try replaced(ar, text, "        run: ./buck2 kill || true\n", "        run: ./buck2 kill ${{ github.sha }} || true\n"), "expression");
    try expectRefused(ar, try replaced(ar, text, "          ./buck2 audit config komira_re.linux_x86_64_properties", "          echo ${{ github.actor }}\n          ./buck2 audit config komira_re.linux_x86_64_properties"), "expression");
}

test "the triggers are a manual run alone: a schedule, a push or a pull request is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  schedule:\n    - cron: '17 3 * * *'\n  workflow_dispatch:\n"), "schedule, a cron, a push or a pull request");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  push:\n    branches: [main]\n  workflow_dispatch:\n"), "schedule, a cron, a push or a pull request");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  pull_request:\n  workflow_dispatch:\n"), "schedule, a cron, a push or a pull request");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  workflow_dispatch:\n  workflow_call:\n"), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  workflow_dispatch:\n    inputs: {}\n"), "on: is not exactly");
}

test "the flavour: a required choice of the two, bundled the default, and the build and summary follow it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    // bundled is the default: the other choice as the default is refused
    try t.expect((try check(ar, text)) == null);
    try expectRefused(ar, try replaced(ar, text, "        default: bundled\n", "        default: external\n"), "on: is not exactly");
    // the input missing, not a choice, not required, without a default, or with another default
    try expectRefused(ar, try replaced(ar, text, "  workflow_dispatch:\n    inputs:\n", "  workflow_dispatch:\n    unused:\n"), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "        type: choice\n", "        type: string\n"), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "        required: true\n", "        required: false\n"), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "        default: bundled\n", ""), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "        default: bundled\n", "        default: both\n"), "on: is not exactly");
    // an option added, dropped or renamed
    try expectRefused(ar, try replaced(ar, text, "          - bundled\n", "          - bundled\n          - both\n"), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "          - bundled\n", ""), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "          - external\n", "          - vendored\n"), "on: is not exactly");
    // a second input
    try expectRefused(ar, try replaced(ar, text, "        required: true\n", "        required: true\n      index:\n        type: string\n"), "on: is not exactly");
    // the wheel or its install test of a fixed flavour, or of none: not the input's
    try expectRefused(ar, try replaced(ar, text, "//python:komira_wheel_${{ inputs.flavour }}[release]", "//python:komira_wheel_bundled[release]"), "build: build, stamp, dist and artifacts");
    try expectRefused(ar, try replaced(ar, text, "//python:wheel_install_test_${{ inputs.flavour }}", "//python:wheel_install_test_external"), "build: build, stamp, dist and artifacts");
    try expectRefused(ar, try replaced(ar, text, "//python:komira_wheel_${{ inputs.flavour }}[release]", "//python:komira_wheel[release]"), "build: build, stamp, dist and artifacts");
    // the summary step dropped, or naming something else
    try expectRefused(ar, try replaced(ar, text, SUMMARY_STEP ++ "\n", "      - name: a summary\n"), "build: build, stamp, dist and artifacts");
    try expectRefused(ar, try replaced(ar, text, SUMMARY_FLAVOUR ++ "\n", "          FLAVOUR: external\n"), "build: build, stamp, dist and artifacts");
    try expectRefused(ar, try replaced(ar, text, SUMMARY_RUN ++ "\n", "        run: 'echo komira >> \"$GITHUB_STEP_SUMMARY\"'\n"), "build: build, stamp, dist and artifacts");
}

test "the workflow permissions are empty and the concurrency is one group that cancels nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    try expectRefused(ar, try replaced(ar, text, "\npermissions: {}\n", "\npermissions:\n  contents: write\n"), "top-level permissions");
    try expectRefused(ar, try replaced(ar, text, "\npermissions: {}\n", "\n"), "top-level permissions");
    try expectRefused(ar, try replaced(ar, text, "\npermissions: {}\n", "\npermissions: {}\npermissions: {}\n"), "top-level permissions");
    // the group is missing, another group, or a run that is cancelled
    try expectRefused(ar, try replaced(ar, text, "concurrency:\n  group: pypi\n  cancel-in-progress: false\n\n", ""), "concurrency");
    try expectRefused(ar, try replaced(ar, text, "  group: pypi\n", "  group: pypi-${{ github.run_id }}\n"), "concurrency");
    try expectRefused(ar, try replaced(ar, text, "  cancel-in-progress: false\n", "  cancel-in-progress: true\n"), "concurrency");
    try expectRefused(ar, try replaced(ar, text, "  group: pypi\n", ""), "concurrency");
}

test "the job set is exactly the twelve jobs, each once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    try expectRefused(ar, try replaced(ar, text, "\n  result:\n", "\n  extra:\n    runs-on: ubuntu-24.04\n\n  result:\n"), "the jobs are not exactly");
    try expectRefused(ar, try replaced(ar, text, "\n  result:\n", "\n  pypi:\n    runs-on: ubuntu-24.04\n\n  result:\n"), "the jobs are not exactly");
    try expectRefused(ar, try replaced(ar, text, "\n  pypi-smoke:\n", "\n  pypi-check:\n"), "the jobs are not exactly");
    try expectRefused(ar, try replaced(ar, text, "\n  testpypi-smoke:\n", "\n  smoke-first:\n"), "the jobs are not exactly");
    try expectRefused(ar, try replaced(ar, text, "\n  result-macos-arm64:\n", "\n  extra-macos-arm64:\n    runs-on: ubuntu-24.04\n\n  result-macos-arm64:\n"), "the jobs are not exactly");
    try expectRefused(ar, try replaced(ar, text, "\n  pypi-smoke-macos-arm64:\n", "\n  pypi-smoke-macos:\n"), "the jobs are not exactly");
    try expectRefused(ar, try replaced(ar, text, "\n  build-macos-arm64:\n", "\n  build-macos-arm64:\n    runs-on: ubuntu-24.04\n\n  build-macos-arm64:\n"), "the jobs are not exactly");
}

test "each job's gate, needs, environment and runner are exact" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    // the gate: main only, no other condition, none missing
    try expectRefused(ar, try inJob(ar, text, "build", MAIN_ONLY ++ "\n", "\n"), "build: its if:");
    try expectRefused(ar, try inJob(ar, text, "testpypi", MAIN_ONLY ++ "\n", "    if: github.ref == 'refs/heads/main' || github.event_name == 'workflow_dispatch'\n"), "testpypi: its if:");
    try expectRefused(ar, try inJob(ar, text, "pypi", MAIN_ONLY ++ "\n", "    if: always()\n"), "pypi: its if:");
    try expectRefused(ar, try replaced(ar, text, "needs.testpypi.outputs.state != 'differs'\n", "needs.testpypi.result == 'success'\n"), "testpypi-smoke: its if:");
    try expectRefused(ar, try replaced(ar, text, "    if: github.ref == 'refs/heads/main' && needs.pypi.outputs.state != 'differs'\n", "    if: needs.pypi.outputs.state != 'differs'\n"), "pypi-smoke: its if:");
    try expectRefused(ar, try replaced(ar, text, "    if: always() && github.ref == 'refs/heads/main'\n", "    if: always()\n"), "result: its if:");
    // the order: pypi waits for the smoke on TestPyPI
    try expectRefused(ar, try replaced(ar, text, "    needs: [build, testpypi-smoke]\n", "    needs: [build, testpypi]\n"), "pypi: its needs:");
    try expectRefused(ar, try replaced(ar, text, "    needs: [build, pypi]\n", "    needs: [build, testpypi-smoke]\n"), "pypi-smoke: its needs:");
    try expectRefused(ar, try replaced(ar, text, "    needs: [build, testpypi, testpypi-smoke, pypi, pypi-smoke]\n", "    needs: [build, testpypi, testpypi-smoke, pypi]\n"), "result: its needs:");
    try expectRefused(ar, try inJob(ar, text, "build", "    runs-on: ubuntu-24.04\n", "    runs-on: ubuntu-24.04\n    needs: result\n"), "build: needs:");
    // the environment: the one each index trusts, and none where a job has none
    try expectRefused(ar, try replaced(ar, text, "    environment: testpypi\n", "    environment: build\n"), "testpypi: its environment");
    try expectRefused(ar, try replaced(ar, text, "    environment: pypi\n", ""), "pypi: its environment");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", "    timeout-minutes: 30\n", "    timeout-minutes: 30\n    environment: pypi\n"), "pypi-smoke: an environment");
    try expectRefused(ar, try inJob(ar, text, "build", "    environment: build\n", "    environment: pypi\n"), "build: its environment");
    // a hosted runner
    try expectRefused(ar, try inJob(ar, text, "pypi", "    runs-on: ubuntu-24.04\n", "    runs-on: self-hosted\n"), "pypi: runs-on");
    // the macOS jobs: the smokes on macos-15, every other job on ubuntu-24.04
    try expectRefused(ar, try inJob(ar, text, "testpypi-smoke-macos-arm64", "    runs-on: macos-15\n", "    runs-on: ubuntu-24.04\n"), "testpypi-smoke-macos-arm64: runs-on");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke-macos-arm64", "    runs-on: macos-15\n", "    runs-on: macos-latest\n"), "pypi-smoke-macos-arm64: runs-on");
    try expectRefused(ar, try inJob(ar, text, "build-macos-arm64", "    runs-on: ubuntu-24.04\n", "    runs-on: macos-15\n"), "build-macos-arm64: runs-on");
    try expectRefused(ar, try inJob(ar, text, "pypi-macos-arm64", "    runs-on: ubuntu-24.04\n", "    runs-on: macos-15\n"), "pypi-macos-arm64: runs-on");
    try expectRefused(ar, try inJob(ar, text, "result-macos-arm64", "    runs-on: ubuntu-24.04\n", "    runs-on: macos-15\n"), "result-macos-arm64: runs-on");
    // the macOS gates and needs
    try expectRefused(ar, try inJob(ar, text, "testpypi-macos-arm64", "    if: github.ref == 'refs/heads/main' && needs.build-macos-arm64.outputs.version != ''\n", MAIN_ONLY ++ "\n"), "testpypi-macos-arm64: its if:");
    try expectRefused(ar, try replaced(ar, text, "    if: github.ref == 'refs/heads/main' && needs.pypi-macos-arm64.outputs.state != 'differs'\n", "    if: needs.pypi-macos-arm64.outputs.state != 'differs'\n"), "pypi-smoke-macos-arm64: its if:");
    try expectRefused(ar, try replaced(ar, text, "    needs: [build-macos-arm64, testpypi-smoke-macos-arm64]\n", "    needs: [build-macos-arm64, testpypi-macos-arm64]\n"), "pypi-macos-arm64: its needs:");
    try expectRefused(ar, try replaced(ar, text, "    needs: [build-macos-arm64, testpypi-macos-arm64, testpypi-smoke-macos-arm64, pypi-macos-arm64, pypi-smoke-macos-arm64]\n", "    needs: [build-macos-arm64, testpypi-macos-arm64]\n"), "result-macos-arm64: its needs:");
    try expectRefused(ar, try inJob(ar, text, "pypi-macos-arm64", "    environment: pypi\n", "    environment: testpypi\n"), "pypi-macos-arm64: its environment");
}

test "id-token is held by build, testpypi and pypi alone, and each holds exactly what it needs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    // a smoke job that can exchange an identity
    try expectRefused(ar, try inJob(ar, text, "testpypi-smoke", "      contents: read\n", "      contents: read\n      id-token: write\n"), "testpypi-smoke: permissions");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", "      contents: read\n", "      contents: read\n      id-token: write\n"), "pypi-smoke: permissions");
    // the result job gains a permission
    try expectRefused(ar, try replaced(ar, text, "    timeout-minutes: 5\n    permissions: {}\n", "    timeout-minutes: 5\n    permissions:\n      id-token: write\n"), "result: permissions");
    // the macOS smoke jobs and the macOS result job hold no identity, the macOS build holds it for the farm
    try expectRefused(ar, try inJob(ar, text, "testpypi-smoke-macos-arm64", "      contents: read\n", "      contents: read\n      id-token: write\n"), "testpypi-smoke-macos-arm64: permissions");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke-macos-arm64", "      contents: read\n", "      contents: read\n      id-token: write\n"), "pypi-smoke-macos-arm64: permissions");
    try expectRefused(ar, try replaced(ar, text, "    needs: [build-macos-arm64, testpypi-macos-arm64, testpypi-smoke-macos-arm64, pypi-macos-arm64, pypi-smoke-macos-arm64]\n    if: always() && github.ref == 'refs/heads/main'\n    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n    permissions: {}\n", "    needs: [build-macos-arm64, testpypi-macos-arm64, testpypi-smoke-macos-arm64, pypi-macos-arm64, pypi-smoke-macos-arm64]\n    if: always() && github.ref == 'refs/heads/main'\n    runs-on: ubuntu-24.04\n    timeout-minutes: 5\n    permissions:\n      id-token: write\n"), "result-macos-arm64: permissions");
    try expectRefused(ar, try inJob(ar, text, "testpypi-macos-arm64", "      id-token: write\n", "      contents: read\n"), "testpypi-macos-arm64: permissions");
    try expectRefused(ar, try inJob(ar, text, "build-macos-arm64", "      id-token: write\n", "      contents: read\n"), "build-macos-arm64: permissions");
    // an upload job without its identity, or with more than it needs
    try expectRefused(ar, try inJob(ar, text, "testpypi", "      id-token: write\n", "      contents: read\n"), "testpypi: permissions");
    try expectRefused(ar, try inJob(ar, text, "pypi", "      id-token: write\n", "      id-token: write\n      contents: write\n"), "pypi: permissions");
    // the build job loses a permission or gains one
    try expectRefused(ar, try inJob(ar, text, "build", "      contents: read\n", "      contents: write\n"), "build: permissions");
    try expectRefused(ar, try inJob(ar, text, "build", "      contents: read\n", "      contents: read\n      packages: write\n"), "build: permissions");
    // a job with no permissions key
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", "    permissions:\n      contents: read\n", ""), "pypi-smoke: permissions");
    // the build job holds id-token together with an upload step
    const publish_step = "      - uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # v1.14.3\n        with:\n          packages-dir: dist\n";
    try expectRefused(ar, try inJob(ar, text, "build", "      - name: Stop buck2\n", publish_step ++ "      - name: Stop buck2\n"), "build: has an upload step");
    try expectRefused(ar, try inJob(ar, text, "build", "      - name: Stop buck2\n", "      - name: upload\n        run: echo legacy/\n      - name: Stop buck2\n"), "build: has an upload step");
    // id-token named on one more line than the three jobs hold
    try expectRefused(ar, try inJob(ar, text, "result", "    steps:\n", "    steps:\n      - name: id-token\n        run: echo x\n"), "id-token");
}

test "farm-connect is in build alone and build is at the batch class; the upload jobs touch no farm, checkout or buck2" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    try expectRefused(ar, try replaced(ar, text, FARM_QOS ++ "\n", ""), "build: build, stamp, dist and artifacts");
    try expectRefused(ar, try replaced(ar, text, FARM_QOS, "          farm-qos: ci"), "build: build, stamp, dist and artifacts");
    try expectRefused(ar, try replaced(ar, text, FARM_TLS ++ "\n", ""), "build: build, stamp, dist and artifacts");
    try expectRefused(ar, try inJob(ar, text, "testpypi", "      - name: the driver is executable\n", FARM_CONNECT ++ "\n      - name: the driver is executable\n"), "testpypi: farm-connect");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", "      - name: the driver is executable\n", FARM_CONNECT ++ "\n      - name: the driver is executable\n"), "pypi-smoke: farm-connect");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke-macos-arm64", "      - name: the driver is executable\n", FARM_CONNECT ++ "\n      - name: the driver is executable\n"), "pypi-smoke-macos-arm64: farm-connect");
    try expectRefused(ar, try inJob(ar, text, "testpypi-macos-arm64", "      - name: the driver is executable\n", "      - run: ./buck2 build //python:komira_wheel_macos_arm64\n      - name: the driver is executable\n"), "testpypi-macos-arm64: runs buck2");
    try expectRefused(ar, try inJob(ar, text, "result-macos-arm64", "    steps:\n", "    steps:\n" ++ FARM_CONNECT ++ "\n"), "result-macos-arm64: farm-connect");
    try expectRefused(ar, try inJob(ar, text, "pypi", "    steps:\n", "    steps:\n" ++ CHECKOUT ++ "\n"), "pypi: checks out");
    try expectRefused(ar, try inJob(ar, text, "testpypi", "      - name: the driver is executable\n", "      - run: ./buck2 build //python:komira_wheel\n      - name: the driver is executable\n"), "testpypi: runs buck2");
}

test "build builds the wheel, the install test and the driver from one stamp, and keeps exactly two artifacts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    // a stamp flag missing from each of the three builds
    try expectRefused(ar, try replaced(ar, text, BUILD_WHEEL, "          args: build -c komira.package_stamp=${{ steps.stamp.outputs.build_number }} //python:komira_wheel[release] --out ${{ runner.temp }}/pypi/built/komira.whl"), "build: build, stamp, dist and artifacts");
    try expectRefused(ar, try replaced(ar, text, BUILD_INSTALL_TEST, "          args: build //python:wheel_install_test"), "build: build, stamp, dist and artifacts");
    try expectRefused(ar, try replaced(ar, text, BUILD_DRIVER, "          args: build //python/smoke:pypi_smoke --out ${{ runner.temp }}/pypi/smoke/pypi_smoke"), "build: build, stamp, dist and artifacts");
    // the install test dropped
    try expectRefused(ar, try replaced(ar, text, "      - name: the install test on the wheel\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ BUILD_INSTALL_TEST ++ "\n          assert-remote: ${{ steps.assert.outputs.path }}\n", ""), "build: build, stamp, dist and artifacts");
    // the stamp from another source, the version not published as an output
    try expectRefused(ar, try replaced(ar, text, "stamp --revision \"$GITHUB_SHA\"", "stamp --revision HEAD"), "build: build, stamp, dist and artifacts");
    try expectRefused(ar, try replaced(ar, text, "      version: ${{ steps.dist.outputs.version }}\n", "      version: 0.1.0\n"), "build: build, stamp, dist and artifacts");
    // a third artifact, an artifact that may be empty, a shorter life
    try expectRefused(ar, try inJob(ar, text, "build", "      - name: Stop buck2\n", UPLOAD ++ "\n        with:\n          name: extra\n          path: ${{ runner.temp }}/pypi\n          if-no-files-found: error\n          retention-days: 14\n      - name: Stop buck2\n"), "build: it does not keep exactly");
    try expectRefused(ar, try inJob(ar, text, "build", "          if-no-files-found: error\n", "          if-no-files-found: warn\n"), "build: it does not keep exactly");
    try expectRefused(ar, try inJob(ar, text, "build", "          retention-days: 14\n", "          retention-days: 90\n"), "build: it does not keep exactly");
    // an artifact under another name
    try expectRefused(ar, try inJob(ar, text, "build", "          name: pypi-${{ steps.dist.outputs.version }}-smoke\n", "          name: pypi-smoke\n"), "build: build, stamp, dist and artifacts");
}

test "an upload job asks the state first, uploads for absent alone with the pinned action and its defaults" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    // the state step is missing, or its output is not published
    try expectRefused(ar, try inJob(ar, text, "testpypi", TESTPYPI.state_step ++ "\n        id: state\n" ++ TESTPYPI.state_run ++ "\n", ""), "testpypi: the state and the upload");
    try expectRefused(ar, try inJob(ar, text, "pypi", STATE_OUTPUT ++ "\n", "      state: absent\n"), "pypi: the state and the upload");
    // the state step after the upload step
    const state_block = PYPI.state_step ++ "\n        id: state\n" ++ PYPI.state_run ++ "\n";
    const upload_block = PYPI.upload_step ++ "\n" ++ STATE_ENABLED ++ "\n" ++ PUBLISH ++ "\n        with:\n" ++ PACKAGES_DIR ++ "\n";
    try expectRefused(ar, try replaced(ar, try inJob(ar, text, "pypi", state_block, ""), upload_block, upload_block ++ state_block), "pypi: the state is asked after the upload step");
    // the upload runs for another condition, or always
    try expectRefused(ar, try inJob(ar, text, "testpypi", STATE_ENABLED ++ "\n", "        if: steps.state.outputs.state != 'differs'\n"), "testpypi: the state and the upload");
    try expectRefused(ar, try inJob(ar, text, "pypi", STATE_ENABLED ++ "\n", ""), "pypi: the state and the upload");
    try expectRefused(ar, try inJob(ar, text, "pypi", PACKAGES_DIR ++ "\n", PACKAGES_DIR ++ "\n      - name: a second upload\n        if: steps.state.outputs.state == 'same'\n" ++ PUBLISH ++ "\n"), "pypi: it does not hold exactly one upload step");
    // the upload action is another one, or unpinned
    try expectRefused(ar, try inJob(ar, text, "testpypi", PUBLISH, "        uses: pypa/gh-action-pypi-publish@release/v1"), "an action is not pinned");
    // the upload sends another directory
    try expectRefused(ar, try inJob(ar, text, "testpypi", PACKAGES_DIR, "          packages-dir: dist/other"), "testpypi: the state and the upload");
    // the address: TestPyPI names its own, PyPI none
    try expectRefused(ar, try inJob(ar, text, "testpypi", TESTPYPI.repository_url.?, "          repository-url: https://upload.pypi.org/legacy/"), "testpypi: the upload address");
    try expectRefused(ar, try inJob(ar, text, "testpypi", TESTPYPI.repository_url.? ++ "\n", ""), "testpypi: the upload address");
    try expectRefused(ar, try inJob(ar, text, "pypi", PACKAGES_DIR ++ "\n", PACKAGES_DIR ++ "\n          repository-url: https://test.pypi.org/legacy/\n"), "pypi: names a repository-url");
    // the action's defaults: no skipping of an existing file, attestations on
    try expectRefused(ar, try inJob(ar, text, "testpypi", PACKAGES_DIR ++ "\n", PACKAGES_DIR ++ "\n          skip-existing: true\n"), "testpypi: sets skip-existing");
    try expectRefused(ar, try inJob(ar, text, "pypi", PACKAGES_DIR ++ "\n", PACKAGES_DIR ++ "\n          attestations: false\n"), "pypi: sets attestations");
    // an upload job that reads the repository
    try expectRefused(ar, try inJob(ar, text, "testpypi", "    steps:\n", "    steps:\n" ++ CHECKOUT ++ "\n"), "testpypi: checks out");
}

test "a smoke job verifies, then sets up Python 3.13, then installs, five attempts thirty seconds apart" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    // the verify dropped, or after the install
    try expectRefused(ar, try inJob(ar, text, "testpypi-smoke", TESTPYPI.verify_step ++ "\n" ++ TESTPYPI.verify_run ++ "\n", ""), "testpypi-smoke: verify, set up Python and install");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", PYPI.verify_step ++ "\n" ++ PYPI.verify_run ++ "\n", ""), "pypi-smoke: verify, set up Python and install");
    const verify_block = PYPI.verify_step ++ "\n" ++ PYPI.verify_run ++ "\n";
    try expectRefused(ar, try replaced(ar, try inJob(ar, text, "pypi-smoke", verify_block, ""), PYPI.install_run ++ "\n", PYPI.install_run ++ "\n" ++ verify_block), "pypi-smoke: the steps are not verify, then set up Python, then install");
    // fewer attempts, a shorter delay, another index
    try expectRefused(ar, try inJob(ar, text, "testpypi-smoke", "--attempts 5 --delay 30'", "--attempts 1 --delay 30'"), "testpypi-smoke: verify, set up Python and install");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", "--attempts 5 --delay 30'", "--attempts 5 --delay 0'"), "pypi-smoke: verify, set up Python and install");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", "install --index pypi", "install --index testpypi"), "pypi-smoke: verify, set up Python and install");
    // the install runs the example the checkout holds, with the interpreter setup-python made
    try expectRefused(ar, try inJob(ar, text, "testpypi-smoke", "--python \"$PYTHON\"", "--python python3"), "testpypi-smoke: verify, set up Python and install");
    try expectRefused(ar, try inJob(ar, text, "testpypi-smoke", "--expect python/examples/quickstart.expected ", ""), "testpypi-smoke: verify, set up Python and install");
    // Python 3.13 on the pinned action, once
    try expectRefused(ar, try inJob(ar, text, "testpypi-smoke", PYTHON_VERSION, "          python-version: '3.12'"), "testpypi-smoke: verify, set up Python and install");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", SETUP_PYTHON, "      - uses: actions/setup-python@v7"), "an action is not pinned");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", SETUP_PYTHON ++ "\n", SETUP_PYTHON ++ "\n        with:\n          python-version: '3.13'\n" ++ SETUP_PYTHON ++ "\n"), "pypi-smoke: it does not set up Python exactly once");
    // the smoke jobs read the repository's example and download what the build kept
    try expectRefused(ar, try inJob(ar, text, "testpypi-smoke", CHECKOUT ++ "\n        with:\n          ref: ${{ github.sha }}\n          persist-credentials: false\n", ""), "testpypi-smoke: verify, set up Python and install");
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", "          name: pypi-${{ needs.build.outputs.version }}-dist\n", "          name: pypi-dist\n"), "pypi-smoke: the two downloads");
    // a smoke job that uploads
    try expectRefused(ar, try inJob(ar, text, "pypi-smoke", "      - name: the driver is executable\n", "      - uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # v1.14.3\n      - name: the driver is executable\n"), "pypi-smoke: has an upload step");
}

test "setup-python outside the smoke jobs is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    const step = SETUP_PYTHON ++ "\n        with:\n          python-version: '3.13'\n";
    try expectRefused(ar, try inJob(ar, text, "build", "      - name: Stop buck2\n", step ++ "      - name: Stop buck2\n"), "build: sets up Python");
    try expectRefused(ar, try inJob(ar, text, "testpypi", "      - name: the driver is executable\n", step ++ "      - name: the driver is executable\n"), "testpypi: sets up Python");
    try expectRefused(ar, try inJob(ar, text, "pypi", "      - name: the driver is executable\n", step ++ "      - name: the driver is executable\n"), "pypi: sets up Python");
    try expectRefused(ar, try inJob(ar, text, "result", "    steps:\n", "    steps:\n" ++ step), "result: sets up Python");
    try expectRefused(ar, try inJob(ar, text, "build-macos-arm64", "      - name: Stop buck2\n", step ++ "      - name: Stop buck2\n"), "build-macos-arm64: sets up Python");
    try expectRefused(ar, try inJob(ar, text, "pypi-macos-arm64", "      - name: the driver is executable\n", step ++ "      - name: the driver is executable\n"), "pypi-macos-arm64: sets up Python");
}

test "an action that is not pinned to a 40-hex commit is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    try expectRefused(ar, try inJob(ar, text, "testpypi-smoke", CHECKOUT, "      - uses: actions/checkout@v7"), "an action is not pinned");
    try expectRefused(ar, try inJob(ar, text, "build", UPLOAD, "      - uses: actions/upload-artifact@main"), "an action is not pinned");
    try expectRefused(ar, try inJob(ar, text, "pypi", DOWNLOAD, "      - uses: actions/download-artifact"), "an action is not pinned");
    // a short hash, an upper-case hash, a hash with a non-hex letter
    try expectRefused(ar, try inJob(ar, text, "pypi", DOWNLOAD, "      - uses: actions/download-artifact@3e5f45b # v8.0.1"), "an action is not pinned");
    try expectRefused(ar, try inJob(ar, text, "pypi", DOWNLOAD, "      - uses: actions/download-artifact@3E5F45B2CFB9172054B4087A40E8E0B5A5461E7C # v8.0.1"), "an action is not pinned");
    try expectRefused(ar, try inJob(ar, text, "pypi", DOWNLOAD, "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7z # v8.0.1"), "an action is not pinned");
    // the upload action pinned to a branch
    try expectRefused(ar, try inJob(ar, text, "testpypi", PUBLISH, "        uses: pypa/gh-action-pypi-publish@release/v1"), "an action is not pinned");
    // a local action is fine
    try t.expect((try check(ar, text)) == null);
}

test "the result job fails the run in three steps and prints the notice for differing bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try realText(ar);
    try expectRefused(ar, try replaced(ar, text, RESULT_BUILD_IF, "        if: needs.build.result != 'success'"), "result: its steps");
    try expectRefused(ar, try replaced(ar, text, RESULT_UPLOAD_IF, "        if: needs.testpypi-smoke.result != 'success' || needs.pypi.result != 'success'"), "result: its steps");
    try expectRefused(ar, try replaced(ar, text, RESULT_SMOKE_IF, "        if: needs.pypi-smoke.result != 'success'"), "result: its steps");
    try expectRefused(ar, try replaced(ar, text, RESULT_DIFFERS_IF, "        if: needs.testpypi.outputs.state == 'differs'"), "result: its steps");
    try expectRefused(ar, try replaced(ar, text, RESULT_NOTICE, "        run: 'echo \"::notice title=pypi::bytes differ\"'"), "result: its steps");
    // a step that ends the run green instead of red
    try expectRefused(ar, try replaced(ar, text, " && exit 1'\n      - name: the bytes differ", "'\n      - name: the bytes differ"), "result: its steps");
    // a fifth step
    try expectRefused(ar, try replaced(ar, text, "          PYPI_SMOKE: ${{ needs.pypi-smoke.result }}\n", "          PYPI_SMOKE: ${{ needs.pypi-smoke.result }}\n      - name: one more\n        run: echo done\n"), "result: it is not exactly the four steps");
}
