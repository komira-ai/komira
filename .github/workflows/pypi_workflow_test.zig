//! The cases of pypi.yml, the publish of the Python package's Linux wheel, //:pypi_workflow_cases: a
//! `zig_test` run as a build action (the macOS wheel's workflow, pypi-macos-arm64.yml, is
//! //:pypi_macos_workflow_cases). The workflow's own bytes are the subject (the zig_test's `data`, under
//! KOMIRA_TEST_WORK/workflows/pypi.yml, with release.yml beside it, whose push filter pypi.yml repeats).
//! pypi_workflow_contract.zig's `check` reads the text and says why it breaks the contract, or null (its
//! header says what the contract holds); each case here writes one defect into the real text and wants
//! it refused with its message. What a run of the file does, for each event and each answer of the
//! indexes, is played in pypi_workflow_run.zig.

const std = @import("std");
const t = std.testing;
const reader = @import("pypi_workflow_text.zig");
const c = @import("pypi_workflow_contract.zig");
const user_test = @import("wheel_user_test_job.zig");
const replaced = reader.replaced;
const inJob = reader.inJob;

const Texts = struct { pypi: []const u8, release: []const u8 };

fn texts(ar: std.mem.Allocator) !Texts {
    return .{ .pypi = try reader.readWorkflow(ar), .release = try reader.readRelease(ar) };
}

fn check(ar: std.mem.Allocator, text: []const u8, release: []const u8) !?[]const u8 {
    return c.check(ar, text, release);
}

fn expectRefused(ar: std.mem.Allocator, x: Texts, text: []const u8, want: []const u8) !void {
    const got = (try check(ar, text, x.release)) orelse {
        std.debug.print("accepted a workflow that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

fn expectHolds(ar: std.mem.Allocator, text: []const u8, release: []const u8) !void {
    if (try check(ar, text, release)) |why| {
        std.debug.print("pypi.yml: {s}\n", .{why});
        return error.Refused;
    }
}

test "pypi.yml holds the contract of the publish workflow" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    try expectHolds(ar, x.pypi, x.release);
    // a comment may talk about what the file does not hold
    try expectHolds(ar, try replaced(ar, x.pypi, "name: pypi\n", "name: pypi\n# no secrets, no twine, no schedule, no inputs.flavour: a comment says so\n"), x.release);
}

test "a secret, a token or a download tool in any job is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", c.PACKAGES_DIR ++ "\n", c.PACKAGES_DIR ++ "\n          token: ${{ secrets.PYPI_API_TOKEN }}\n"), "contains \"secrets\"");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.PACKAGES_DIR ++ "\n", c.PACKAGES_DIR ++ "\n          password: x\n"), "contains \"password\"");
    try expectRefused(ar, x, try inJob(ar, text, "build", "      - name: Stop buck2\n", "      - name: fetch\n        run: curl -sS https://example.org\n      - name: Stop buck2\n"), "contains \"curl\"");
    try expectRefused(ar, x, try inJob(ar, text, "promote", "      - name: the driver is executable\n", "      - name: fetch\n        run: wget https://example.org\n      - name: the driver is executable\n"), "contains \"wget\"");
    try expectRefused(ar, x, try inJob(ar, text, "result-pypi", "    steps:\n", "    steps:\n      - run: echo x | jq .\n"), "contains \"jq \"");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", "      - name: the driver is executable\n", "      - run: twine upload dist/*\n      - name: the driver is executable\n"), "contains \"twine\"");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke", "    timeout-minutes: 30\n", "    timeout-minutes: 30\n    continue-on-error: true\n"), "contains \"continue-on-error\"");
    try expectRefused(ar, x, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  pull_request_target:\n  workflow_dispatch:\n"), "contains \"pull_request_target\"");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke", "        env:\n", "        env:\n          TOKEN: PYPI_TOKEN\n"), "contains \"pypi_token\"");
}

test "an expression inside a run line, one line or a block, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    try expectRefused(ar, x, try inJob(ar, x.pypi, "build", "        run: ./buck2 kill || true\n", "        run: ./buck2 kill ${{ github.sha }} || true\n"), "expression");
    try expectRefused(ar, x, try replaced(ar, x.pypi, "          ./buck2 audit config komira_re.linux_x86_64_properties", "          echo ${{ github.actor }}\n          ./buck2 audit config komira_re.linux_x86_64_properties"), "expression");
    try expectRefused(ar, x, try inJob(ar, x.pypi, "promote", c.PROMOTE_CHMOD, "        run: chmod +x \"${{ runner.temp }}/pypi/passed/pypi_smoke\""), "expression");
}

test "the triggers are a push to main of code, one daily schedule and a manual run: each other shape is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    const on = "on: is not exactly a push to main";
    // the push: missing, of another branch or of every branch, without the filter, with an entry less or more
    const push = "  push:\n    branches: [main]\n";
    try expectRefused(ar, x, try replaced(ar, text, push, ""), on);
    try expectRefused(ar, x, try replaced(ar, text, push, "  push:\n    branches: [release]\n"), on);
    try expectRefused(ar, x, try replaced(ar, text, "    branches: [main]\n    paths-ignore:\n", "    paths-ignore:\n"), on);
    try expectRefused(ar, x, try replaced(ar, text, "    paths-ignore:\n      - 'docs/**'\n      - '**.md'\n", ""), on);
    try expectRefused(ar, x, try replaced(ar, text, "      - 'docs/**'\n      - '**.md'\n  schedule:", "      - 'docs/**'\n  schedule:"), on);
    try expectRefused(ar, x, try replaced(ar, text, "      - '**.md'\n  schedule:", "      - '**.md'\n      - 'python/**'\n  schedule:"), on);
    // the filter follows release.yml's: a release.yml that ignores one more path wants pypi.yml to as well
    const grown = try replaced(ar, x.release, "      - '**.md'\n", "      - '**.md'\n      - '.github/**'\n");
    try t.expect((try check(ar, text, grown)) != null);
    try expectHolds(ar, try replaced(ar, text, "      - '**.md'\n  schedule:", "      - '**.md'\n      - '.github/**'\n  schedule:"), grown);
    // the schedule: missing, a second cron entry, a second schedule key
    const sched = "  schedule:\n    - cron: '17 5 * * *'\n";
    try expectRefused(ar, x, try replaced(ar, text, sched, ""), on);
    try expectRefused(ar, x, try replaced(ar, text, sched, sched ++ "    - cron: '17 17 * * *'\n"), on);
    try expectRefused(ar, x, try replaced(ar, text, sched, sched ++ sched), on);
    // a cron that is not one fixed time of every day
    for ([_][]const u8{ "*/30 * * * *", "0 */6 * * *", "17 5,17 * * *", "17 5 * * 1", "17 5 1 * *", "17 4-6 * * *", "60 5 * * *", "17 24 * * *", "17 5 * *", "17 5 * * * *", "* 5 * * *", "017 5 * * *" }) |cron| {
        try expectRefused(ar, x, try replaced(ar, text, "'17 5 * * *'", try std.fmt.allocPrint(ar, "'{s}'", .{cron})), on);
    }
    // any other fixed time of the day holds, the first and the last minute of it included
    for ([_][]const u8{ "0 0 * * *", "59 23 * * *", "5 17 * * *" }) |cron| {
        try expectHolds(ar, try replaced(ar, text, "'17 5 * * *'", try std.fmt.allocPrint(ar, "'{s}'", .{cron})), x.release);
    }
    // a cron named outside on:, a pull request, a call from another workflow, an input
    try expectRefused(ar, x, try inJob(ar, text, "result-pypi", "    steps:\n", "    steps:\n      - name: the cron\n        run: echo x\n"), "names a schedule or a cron");
    try expectRefused(ar, x, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  pull_request:\n  workflow_dispatch:\n"), "a pull request trigger");
    try expectRefused(ar, x, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  workflow_dispatch:\n  workflow_call:\n"), on);
    try expectRefused(ar, x, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  workflow_dispatch:\n    inputs: {}\n"), on);
}

test "the run takes no input: an input, or a read of one, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    try expectRefused(ar, x, try replaced(ar, text, "  workflow_dispatch:\n", "  workflow_dispatch:\n    inputs:\n      index:\n        type: string\n"), "then workflow_dispatch: with no input");
    const reads = "reads a run input";
    try expectRefused(ar, x, try replaced(ar, text, "//python:komira_wheel[release]", "//python:komira_wheel_${{ inputs.flavour }}[release]"), reads);
    try expectRefused(ar, x, try inJob(ar, text, "promote", c.PROMOTE_GATE ++ "\n", c.PROMOTE_GATE ++ " && inputs.promote\n"), reads);
}

test "the workflow permissions are empty and the concurrency is one group per half that cancels nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    try expectRefused(ar, x, try replaced(ar, text, "\npermissions: {}\n", "\npermissions:\n  contents: write\n"), "top-level permissions");
    try expectRefused(ar, x, try replaced(ar, text, "\npermissions: {}\n", "\n"), "top-level permissions");
    try expectRefused(ar, x, try replaced(ar, text, "\npermissions: {}\n", "\npermissions: {}\npermissions: {}\n"), "top-level permissions");
    const conc = "concurrency is not exactly one group per half";
    // the group missing, one group for both halves, a group per run, a run that is cancelled
    try expectRefused(ar, x, try replaced(ar, text, "concurrency:\n" ++ c.GROUP ++ "\n" ++ c.NO_CANCEL ++ "\n\n", ""), conc);
    try expectRefused(ar, x, try replaced(ar, text, c.GROUP ++ "\n", "  group: pypi\n"), conc);
    try expectRefused(ar, x, try replaced(ar, text, c.GROUP ++ "\n", "  group: pypi-${{ github.run_id }}\n"), conc);
    try expectRefused(ar, x, try replaced(ar, text, c.NO_CANCEL ++ "\n", "  cancel-in-progress: true\n"), conc);
}

test "the job set is exactly the ten jobs of the Linux wheel, each once: a macOS job is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    const jobs = "the jobs are not exactly the ten";
    try expectRefused(ar, x, try replaced(ar, text, "\n  result-pypi:\n", "\n  extra:\n    runs-on: ubuntu-24.04\n\n  result-pypi:\n"), jobs);
    try expectRefused(ar, x, try replaced(ar, text, "\n  result-pypi:\n", "\n  pypi:\n    runs-on: ubuntu-24.04\n\n  result-pypi:\n"), jobs);
    try expectRefused(ar, x, try replaced(ar, text, "\n  testpypi-passed:\n", "\n  testpypi-record:\n"), jobs);
    try expectRefused(ar, x, try replaced(ar, text, "\n  promote:\n", "\n  pick:\n"), jobs);
    try expectRefused(ar, x, try replaced(ar, text, "\n  wheel-user-test:\n", "\n  wheel-test:\n"), jobs);
    // the macOS wheel's jobs are pypi-macos-arm64.yml's: one back in this file would put its verdict in this run
    try expectRefused(ar, x, try replaced(ar, text, "\n  result-pypi:\n", "\n  build-macos-arm64:\n    runs-on: ubuntu-24.04\n\n  result-pypi:\n"), jobs);
    try expectRefused(ar, x, try replaced(ar, text, "\n  result-testpypi:\n", "\n  result-testpypi-macos-arm64:\n"), jobs);
}

test "each job is in its half: a gate without the event, or with the other half's, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    const main_only = "    if: github.ref == 'refs/heads/main'\n";
    for ([_][]const u8{ "build", "testpypi", "testpypi-passed" }) |job| {
        try expectRefused(ar, x, try inJob(ar, text, job, c.PUSH_GATE ++ "\n", main_only), try std.fmt.allocPrint(ar, "{s}: its if:", .{job}));
        try expectRefused(ar, x, try inJob(ar, text, job, c.PUSH_GATE ++ "\n", c.PROMOTE_GATE ++ "\n"), try std.fmt.allocPrint(ar, "{s}: its if:", .{job}));
    }
    for ([_][]const u8{ "promote", "pypi" }) |job| {
        try expectRefused(ar, x, try inJob(ar, text, job, c.PROMOTE_GATE ++ "\n", main_only), try std.fmt.allocPrint(ar, "{s}: its if:", .{job}));
        try expectRefused(ar, x, try inJob(ar, text, job, c.PROMOTE_GATE ++ "\n", c.PUSH_GATE ++ "\n"), try std.fmt.allocPrint(ar, "{s}: its if:", .{job}));
    }
    try expectRefused(ar, x, try inJob(ar, text, "result-pypi", c.RESULT_PROMOTE_GATE ++ "\n", "    if: always() && github.ref == 'refs/heads/main'\n"), "result-pypi: its if:");
    try expectRefused(ar, x, try inJob(ar, text, "result-testpypi", c.RESULT_PUSH_GATE ++ "\n", "    if: always()\n"), "result-testpypi: its if:");
    try expectRefused(ar, x, try replaced(ar, text, "needs.testpypi.outputs.state != 'differs'\n", "needs.testpypi.result == 'success'\n"), "testpypi-smoke: its if:");
    try expectRefused(ar, x, try inJob(ar, text, "wheel-user-test", c.PUSH_GATE ++ "\n", "    if: always()\n"), "wheel-user-test: its if:");
}

test "each job's needs, environment and runner are exact" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    // the push order: the first upload waits for the user test, the record for every smoke job
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", "    needs: [build, wheel-user-test]\n", "    needs: build\n"), "testpypi: its needs:");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-passed", "    needs: [build, testpypi-smoke]\n", "    needs: [build, testpypi]\n"), "testpypi-passed: its needs:");
    try expectRefused(ar, x, try inJob(ar, text, "result-testpypi", "    needs: [build, wheel-user-test, testpypi, testpypi-smoke, testpypi-passed]\n", "    needs: [build, wheel-user-test, testpypi, testpypi-smoke]\n"), "result-testpypi: its needs:");
    // the promotion: PyPI waits for the promote job and needs no job of the push half
    try expectRefused(ar, x, try inJob(ar, text, "pypi", "    needs: promote\n", "    needs: [promote, testpypi-smoke]\n"), "pypi: its needs:");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke", "    needs: [promote, pypi]\n", "    needs: [promote]\n"), "pypi-smoke: its needs:");
    try expectRefused(ar, x, try inJob(ar, text, "promote", c.PROMOTE_GATE ++ "\n", c.PROMOTE_GATE ++ "\n    needs: build\n"), "promote: needs: where it needs nothing");
    try expectRefused(ar, x, try inJob(ar, text, "result-pypi", "    needs: [promote, pypi, pypi-smoke]\n", "    needs: [promote, pypi]\n"), "result-pypi: its needs:");
    // the environment: the one each index trusts, and none where a job has none
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", "    environment: testpypi\n", "    environment: build\n"), "testpypi: its environment");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", "    environment: pypi\n", ""), "pypi: its environment");
    try expectRefused(ar, x, try inJob(ar, text, "promote", "    timeout-minutes: 30\n", "    timeout-minutes: 30\n    environment: pypi\n"), "promote: an environment");
    try expectRefused(ar, x, try inJob(ar, text, "build", "    environment: build\n", "    environment: pypi\n"), "build: its environment");
    // hosted runners: every job but the user test on ubuntu-24.04
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.UBUNTU ++ "\n", "    runs-on: self-hosted\n"), "pypi: runs-on");
    try expectRefused(ar, x, try inJob(ar, text, "wheel-user-test", "    runs-on: ${{ matrix.runner }}\n", "    runs-on: self-hosted\n"), "wheel-user-test: runs-on");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke", c.UBUNTU ++ "\n", c.MACOS ++ "\n"), "testpypi-smoke: runs-on");
}

test "id-token is held by the build job and the two upload jobs alone, each holding exactly what it needs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    // a job with no permission that gains an identity or a read
    for ([_][]const u8{ "testpypi-smoke", "testpypi-passed", "promote", "pypi-smoke", "result-pypi" }) |job| {
        try expectRefused(ar, x, try inJob(ar, text, job, "    permissions: {}\n", "    permissions:\n      id-token: write\n"), try std.fmt.allocPrint(ar, "{s}: permissions", .{job}));
        try expectRefused(ar, x, try inJob(ar, text, job, "    permissions: {}\n", "    permissions:\n      contents: read\n"), try std.fmt.allocPrint(ar, "{s}: permissions", .{job}));
    }
    // an upload job without its identity, or with more than it needs
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", "      id-token: write\n", "      contents: read\n"), "testpypi: permissions");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", "      id-token: write\n", "      id-token: write\n      contents: write\n"), "pypi: permissions");
    // the build job loses a permission or gains one
    try expectRefused(ar, x, try inJob(ar, text, "build", "      contents: read\n", "      contents: write\n"), "build: permissions");
    try expectRefused(ar, x, try inJob(ar, text, "build", "      contents: read\n", "      contents: read\n      packages: write\n"), "build: permissions");
    // a job with no permissions key
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke", "    permissions: {}\n", ""), "pypi-smoke: permissions");
    // the build job holds id-token together with an upload step
    const publish_step = "      - uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # v1.14.3\n        with:\n          packages-dir: dist\n";
    try expectRefused(ar, x, try inJob(ar, text, "build", "      - name: Stop buck2\n", publish_step ++ "      - name: Stop buck2\n"), "build: has an upload step");
    // id-token named in a job that does not hold it
    try expectRefused(ar, x, try inJob(ar, text, "result-testpypi", "    steps:\n", "    steps:\n      - name: id-token\n        run: echo x\n"), "id-token");
}

test "the farm, buck2 and a checkout are in the build job alone; the promotion builds nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    try expectRefused(ar, x, try replaced(ar, text, c.FARM_QOS ++ "\n", ""), "build: build, stamp, dist, record and artifacts");
    try expectRefused(ar, x, try replaced(ar, text, c.FARM_TLS ++ "\n", ""), "build: build, stamp, dist, record and artifacts");
    try expectRefused(ar, x, try inJob(ar, text, "promote", "    steps:\n", "    steps:\n" ++ c.FARM_CONNECT ++ "\n"), "promote: farm-connect");
    try expectRefused(ar, x, try inJob(ar, text, "promote", "      - name: the driver is executable\n", "      - run: ./buck2 build //python/smoke:pypi_smoke\n      - name: the driver is executable\n"), "promote: runs buck2");
    try expectRefused(ar, x, try inJob(ar, text, "promote", "    steps:\n", "    steps:\n" ++ c.CHECKOUT ++ "\n"), "promote: checks out");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", "      - name: the driver is executable\n", c.FARM_CONNECT ++ "\n      - name: the driver is executable\n"), "testpypi: farm-connect");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", "    steps:\n", "    steps:\n" ++ c.CHECKOUT ++ "\n"), "pypi: checks out");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke", "    steps:\n", "    steps:\n" ++ c.CHECKOUT ++ "\n"), "testpypi-smoke: checks out");
}

test "build builds the wheel, the install test and the driver from one stamp, writes the record, and keeps exactly two artifacts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    const lines = "build: build, stamp, dist, record and artifacts";
    // a stamp flag missing from each of the three builds, the install test dropped
    try expectRefused(ar, x, try replaced(ar, text, c.BUILD_WHEEL, "          args: build -c komira.package_stamp=${{ steps.stamp.outputs.build_number }} //python:komira_wheel[release] --out ${{ runner.temp }}/pypi/built/komira.whl"), lines);
    try expectRefused(ar, x, try replaced(ar, text, c.BUILD_INSTALL_TEST, "          args: build //python:wheel_install_test"), lines);
    try expectRefused(ar, x, try replaced(ar, text, c.BUILD_DRIVER, "          args: build //python/smoke:pypi_smoke --out ${{ runner.temp }}/pypi/smoke/pypi_smoke"), lines);
    try expectRefused(ar, x, try replaced(ar, text, "      - name: the install test on the wheel\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ c.BUILD_INSTALL_TEST ++ "\n          assert-remote: ${{ steps.assert.outputs.path }}\n", ""), lines);
    // the stamp from another source, the version not published as an output
    try expectRefused(ar, x, try replaced(ar, text, "stamp --revision \"$GITHUB_SHA\"", "stamp --revision HEAD"), lines);
    try expectRefused(ar, x, try inJob(ar, text, "build", "      version: ${{ steps.dist.outputs.version }}\n", "      version: 0.1.0\n"), lines);
    // the record: the dist step without it, or writing it outside the smoke artifact
    try expectRefused(ar, x, try replaced(ar, text, " --record \"$RUNNER_TEMP/pypi/smoke/built.txt\"", ""), lines);
    try expectRefused(ar, x, try replaced(ar, text, "--record \"$RUNNER_TEMP/pypi/smoke/built.txt\"", "--record \"$RUNNER_TEMP/pypi/built.txt\""), lines);
    // the list of the supported Pythons for another platform, outside the smoke artifact, or read from elsewhere
    try expectRefused(ar, x, try replaced(ar, text, c.BUILD_PYTHONS, "          args: build //python:supported_pythons[macos-arm64] --out ${{ runner.temp }}/pypi/smoke/pythons.json"), lines);
    try expectRefused(ar, x, try replaced(ar, text, c.BUILD_PYTHONS, "          args: build //python:supported_pythons[linux-x86_64] --out ${{ runner.temp }}/pypi/pythons.json"), lines);
    try expectRefused(ar, x, try replaced(ar, text, c.BUILD_MATRIX, "        run: '\"$RUNNER_TEMP/pypi/smoke/pypi_smoke\" matrix --pythons python/pythons.json --platform linux-x86_64 --github-output \"$GITHUB_OUTPUT\"'"), lines);
    try expectRefused(ar, x, try inJob(ar, text, "build", c.BUILD_MATRIX_OUTPUT ++ "\n", ""), lines);
    // the quickstart files not beside the driver
    try expectRefused(ar, x, try replaced(ar, text, c.BUILD_COPY, "        run: cp python/examples/quickstart.py \"$RUNNER_TEMP/pypi/smoke/\""), lines);
    try expectRefused(ar, x, try replaced(ar, text, c.BUILD_COPY, "        run: cp python/examples/quickstart.py src/so/abi/komira.tsv \"$RUNNER_TEMP/pypi/smoke/\""), lines);
    try expectRefused(ar, x, try replaced(ar, text, c.BUILD_COPY, "        run: cp python/examples/quickstart.py python/examples/quickstart.expected \"$RUNNER_TEMP/pypi/smoke/\""), lines);
    // the data file the quickstart no longer reads: copied beside the driver, or passed with --data
    try expectRefused(ar, x, try replaced(ar, text, c.BUILD_COPY, "        run: cp python/examples/quickstart.py python/examples/quickstart.expected python/tests/fixtures/readings.parquet src/so/abi/komira.tsv \"$RUNNER_TEMP/pypi/smoke/\""), lines);
    // a third artifact, an artifact that may be empty, a shorter life, another name
    try expectRefused(ar, x, try inJob(ar, text, "build", "      - name: Stop buck2\n", c.UPLOAD ++ "\n        with:\n          name: extra\n          path: ${{ runner.temp }}/pypi\n          if-no-files-found: error\n          retention-days: 14\n      - name: Stop buck2\n"), "build: it does not keep exactly");
    try expectRefused(ar, x, try inJob(ar, text, "build", "          if-no-files-found: error\n", "          if-no-files-found: warn\n"), "build: it does not keep exactly");
    try expectRefused(ar, x, try inJob(ar, text, "build", "          name: pypi-${{ steps.dist.outputs.version }}-smoke\n", "          name: pypi-smoke\n"), lines);
}

test "wheel-user-test installs the built dist on the matrix's Python with no checkout" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    const want = "wheel-user-test: download, set up the matrix Python and install the dist directory";
    try expectRefused(ar, x, try inJob(ar, text, "wheel-user-test", "          name: pypi-${{ needs.build.outputs.version }}-dist\n", "          name: pypi-dist\n"), want);
    try expectRefused(ar, x, try inJob(ar, text, "wheel-user-test", "install --index dist", "install --index testpypi"), want);
    try expectRefused(ar, x, try inJob(ar, text, "wheel-user-test", user_test.PYTHON_VERSION, "          python-version: '3.13'"), want);
    try expectRefused(ar, x, try inJob(ar, text, "wheel-user-test", "      fail-fast: false\n", "      fail-fast: true\n"), "wheel-user-test: the matrix is not the build job's, with fail-fast off");
}

test "an upload job asks the state first and uploads for absent alone with the pinned action and its defaults" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", c.TESTPYPI.state_step ++ "\n        id: state\n" ++ c.TESTPYPI.state_run ++ "\n", ""), "testpypi: the state and the upload");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.STATE_OUTPUT ++ "\n", "      state: absent\n"), "pypi: the state and the upload");
    const state_block = c.PYPI.state_step ++ "\n        id: state\n" ++ c.PYPI.state_run ++ "\n";
    const upload_block = c.PYPI.upload_step ++ "\n" ++ c.STATE_ENABLED ++ "\n" ++ c.PUBLISH ++ "\n        with:\n" ++ c.PACKAGES_DIR ++ "\n";
    try expectRefused(ar, x, try replaced(ar, try inJob(ar, text, "pypi", state_block, ""), upload_block, upload_block ++ state_block), "pypi: the state is asked after the upload step");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", c.STATE_ENABLED ++ "\n", "        if: steps.state.outputs.state != 'differs'\n"), "testpypi: the state and the upload");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.STATE_ENABLED ++ "\n", ""), "pypi: the state and the upload");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.PACKAGES_DIR ++ "\n", c.PACKAGES_DIR ++ "\n      - name: a second upload\n        if: steps.state.outputs.state == 'same'\n" ++ c.PUBLISH ++ "\n"), "pypi: it does not hold exactly one upload step");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", c.PUBLISH, "        uses: pypa/gh-action-pypi-publish@release/v1"), "an action is not pinned");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", c.PACKAGES_DIR, "          packages-dir: dist/other"), "testpypi: the state and the upload");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", c.TESTPYPI.repository_url.?, "          repository-url: https://upload.pypi.org/legacy/"), "testpypi: the upload address");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.PACKAGES_DIR ++ "\n", c.PACKAGES_DIR ++ "\n          repository-url: https://test.pypi.org/legacy/\n"), "pypi: names a repository-url");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", c.PACKAGES_DIR ++ "\n", c.PACKAGES_DIR ++ "\n          skip-existing: true\n"), "testpypi: sets skip-existing");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.PACKAGES_DIR ++ "\n", c.PACKAGES_DIR ++ "\n          attestations: false\n"), "pypi: sets attestations");
    // PyPI uploads what the promote job fetched from TestPyPI, never the push build's artifact
    try expectRefused(ar, x, try inJob(ar, text, "pypi", "          name: pypi-${{ needs.promote.outputs.version }}-dist\n", "          name: pypi-${{ needs.build.outputs.version }}-dist\n"), "pypi: the two downloads");
}

test "the TestPyPI job prints the size of the project on both indexes before the state, at 80 percent of 10 GiB" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    const want = "testpypi: the size of the project on both indexes";
    const tp = c.TESTPYPI_STORAGE[0] ++ "\n" ++ c.TESTPYPI_STORAGE[1] ++ "\n" ++ c.TESTPYPI_STORAGE[2] ++ "\n";
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", tp, ""), want);
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", "--over-percent 80", "--over-percent 95"), want);
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", "--limit-gib 10", "--limit-gib 100"), want);
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", c.STORAGE_OUTPUTS[0] ++ "\n", ""), want);
    // after the state, an upload refused for its size would leave no numbers in the summary
    const state_block = c.TESTPYPI.state_step ++ "\n        id: state\n" ++ c.TESTPYPI.state_run ++ "\n";
    try expectRefused(ar, x, try replaced(ar, try inJob(ar, text, "testpypi", state_block, ""), tp, state_block ++ tp), "testpypi: the size of the project is asked after the state");
    // the PyPI job asks no size: the promote job did
    try expectRefused(ar, x, try inJob(ar, text, "pypi", "      - name: the wheel on PyPI\n", c.TESTPYPI_STORAGE[3] ++ "\n" ++ c.TESTPYPI_STORAGE[4] ++ "\n" ++ c.TESTPYPI_STORAGE[5] ++ "\n      - name: the wheel on PyPI\n"), "pypi: asks the size of the project");
}

test "a smoke job verifies, then sets up one supported Python, then installs with the record's quickstart, five attempts thirty seconds apart" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke", c.TESTPYPI.verify_step ++ "\n" ++ c.TESTPYPI.verify_run ++ "\n", ""), "testpypi-smoke: verify, set up Python and install");
    const verify_block = c.PYPI.verify_step ++ "\n" ++ c.PYPI.verify_run ++ "\n";
    try expectRefused(ar, x, try replaced(ar, try inJob(ar, text, "pypi-smoke", verify_block, ""), c.PYPI.install_run ++ "\n", c.PYPI.install_run ++ "\n" ++ verify_block), "pypi-smoke: the steps are not verify, then set up Python, then install");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke", "--attempts 5 --delay 30'", "--attempts 1 --delay 30'"), "testpypi-smoke: verify, set up Python and install");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke", "install --index pypi", "install --index testpypi"), "pypi-smoke: verify, set up Python and install");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke", "--python \"$PYTHON\"", "--python python3"), "testpypi-smoke: verify, set up Python and install");
    // the quickstart of a checkout, not the record's (a promotion runs the version's own files)
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke", "--example \"$RUNNER_TEMP/pypi/smoke/quickstart.py\"", "--example python/examples/quickstart.py"), "pypi-smoke: verify, set up Python and install");
    // the data flag the install command no longer has
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke", "--abi-table", "--data \"$RUNNER_TEMP/pypi/smoke/readings.parquet\" --abi-table"), "testpypi-smoke: verify, set up Python and install");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke", PYTHON_VERSION_LINE, "          python-version: '3.13'"), "testpypi-smoke: verify, set up Python and install");
    // one job per Python of the list of its half's first job: a list written here, the other half's, fail-fast
    const push_list = "      matrix: ${{ fromJSON(needs.build.outputs.matrix) }}\n";
    const promote_list = "      matrix: ${{ fromJSON(needs.promote.outputs.matrix) }}\n";
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke", push_list, "      matrix:\n        python: ['3.13.16']\n"), "testpypi-smoke: one job per supported Python");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke", promote_list, push_list), "pypi-smoke: one job per supported Python");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke", "      fail-fast: false\n", "      fail-fast: true\n"), "pypi-smoke: one job per supported Python");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke", push_list, push_list ++ "      matrix:\n        python: ['3.10.22']\n"), "testpypi-smoke: it is not one matrix of the supported Pythons, set up once");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke", c.SETUP_PYTHON, "      - uses: actions/setup-python@v7"), "an action is not pinned");
    try expectRefused(ar, x, try inJob(ar, text, "pypi-smoke", "      - name: the driver is executable\n", "      - uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # v1.14.3\n      - name: the driver is executable\n"), "pypi-smoke: has an upload step");
    // setup-python outside the smoke jobs and the user test
    const step = c.SETUP_PYTHON ++ "\n        with:\n          python-version: '3.13'\n";
    try expectRefused(ar, x, try inJob(ar, text, "promote", "      - name: the driver is executable\n", step ++ "      - name: the driver is executable\n"), "promote: sets up Python");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi", "      - name: the driver is executable\n", step ++ "      - name: the driver is executable\n"), "testpypi: sets up Python");
}
const PYTHON_VERSION_LINE = c.PYTHON_VERSION;

test "the record is saved by testpypi-passed alone, under the key of its platform and version" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    const want = "testpypi-passed: the record saved under the version's key";
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-passed", "          key: pypi-passed-linux-x86_64-${{ needs.build.outputs.version }}\n", "          key: pypi-passed-linux-x86_64\n"), want);
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-passed", "          key: pypi-passed-linux-x86_64-${{ needs.build.outputs.version }}\n", "          key: pypi-passed-macos-arm64-${{ needs.build.outputs.version }}\n"), want);
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-passed", "          path: ${{ runner.temp }}/pypi/passed\n      - name:", "          path: ${{ runner.temp }}/pypi/other\n      - name:"), want);
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-passed", "      - name: the record of the version that passed\n", c.DOWNLOAD ++ "\n        with:\n          name: pypi-${{ needs.build.outputs.version }}-dist\n          path: ${{ runner.temp }}/pypi/passed\n      - name: the record of the version that passed\n"), "testpypi-passed: it is not exactly the download of the smoke artifact and the save of the record");
    // a save anywhere else: in the smoke job a record would be written by the first Python to pass
    const save = "      - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: pypi-passed-linux-x86_64-x\n";
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-smoke", "      - name: the driver is executable\n", save ++ "      - name: the driver is executable\n"), "testpypi-smoke: saves to the cache where it may not");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-passed", c.CACHE_SAVE, "        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0"), "testpypi-passed: saves to the cache where it may not");
    try expectRefused(ar, x, try inJob(ar, text, "build", "      - name: Stop buck2\n", "      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n      - name: Stop buck2\n"), "build: uses actions/cache");
}

test "promote restores the newest record, prints the size, fetches the version, then its matrix and artifacts, failing on no record" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    const want = "promote: restore the newest record, the size, promote, the matrix and the artifacts";
    // a miss that would go on with no record, another prefix, an exact key of one version
    try expectRefused(ar, x, try inJob(ar, text, "promote", c.MISS_FAILS ++ "\n", ""), want);
    try expectRefused(ar, x, try inJob(ar, text, "promote", c.RESTORE_KEYS ++ "\n", "          restore-keys: pypi-passed-\n"), want);
    try expectRefused(ar, x, try inJob(ar, text, "promote", c.RESTORE_KEY ++ "\n", "          key: pypi-passed-linux-x86_64-0.1.1513\n"), want);
    // the promote step from another record, or writing elsewhere; the matrix of another list
    try expectRefused(ar, x, try inJob(ar, text, "promote", "--record \"$RUNNER_TEMP/pypi/passed/built.txt\"", "--record built.txt"), want);
    try expectRefused(ar, x, try inJob(ar, text, "promote", "--pythons \"$RUNNER_TEMP/pypi/passed/pythons.json\"", "--pythons python/pythons.json"), want);
    try expectRefused(ar, x, try inJob(ar, text, "promote", "      skipped: ${{ steps.promote.outputs.skipped }}\n", ""), want);
    // the size dropped from the promotion
    try expectRefused(ar, x, try inJob(ar, text, "promote", c.PROMOTE_STORAGE[3] ++ "\n" ++ c.PROMOTE_STORAGE[4] ++ "\n" ++ c.PROMOTE_STORAGE[5] ++ "\n", ""), want);
    // the matrix before the promote step: the order is held
    const promote_step = "      - name: the version to promote, downloaded from TestPyPI and held to the record\n        id: promote\n" ++ c.PROMOTE_RUN ++ "\n";
    const matrix_step = "      - name: the Pythons of the PyPI smoke\n        id: matrix\n" ++ c.PROMOTE_MATRIX ++ "\n";
    try expectRefused(ar, x, try replaced(ar, text, promote_step ++ "      # the Pythons that version's push run smoked, from its record\n" ++ matrix_step, matrix_step ++ promote_step), "promote: the steps are not restore");
    // a third artifact, or a read of another job's artifact
    try expectRefused(ar, x, try inJob(ar, text, "promote", "      - name: the driver is executable\n", c.DOWNLOAD ++ "\n        with:\n          name: pypi-dist\n          path: dist\n      - name: the driver is executable\n"), "promote: uploads to an index or reads another job's artifact");
    // a restore anywhere else
    try expectRefused(ar, x, try inJob(ar, text, "pypi", "      - name: the driver is executable\n", "      - name: restore\n" ++ c.CACHE_RESTORE ++ "\n      - name: the driver is executable\n"), "pypi: restores from the cache where it may not");
    try expectRefused(ar, x, try inJob(ar, text, "promote", c.CACHE_RESTORE, "        uses: actions/cache/restore@v6"), "an action is not pinned");
}

test "an action that is not pinned to a 40-hex commit is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    try expectRefused(ar, x, try inJob(ar, text, "build", c.CHECKOUT, "      - uses: actions/checkout@v7"), "an action is not pinned");
    try expectRefused(ar, x, try inJob(ar, text, "build", c.UPLOAD, "      - uses: actions/upload-artifact@main"), "an action is not pinned");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.DOWNLOAD, "      - uses: actions/download-artifact"), "an action is not pinned");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.DOWNLOAD, "      - uses: actions/download-artifact@3e5f45b # v8.0.1"), "an action is not pinned");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.DOWNLOAD, "      - uses: actions/download-artifact@3E5F45B2CFB9172054B4087A40E8E0B5A5461E7C # v8.0.1"), "an action is not pinned");
    try expectRefused(ar, x, try inJob(ar, text, "pypi", c.DOWNLOAD, "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7z # v8.0.1"), "an action is not pinned");
    try expectRefused(ar, x, try inJob(ar, text, "testpypi-passed", c.CACHE_SAVE, "        uses: actions/cache/save@main"), "an action is not pinned");
}

test "each verdict job prints exactly its steps, the notice already ... last" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const x = try texts(ar);
    const text = x.pypi;
    // the push run: a condition loosened, an error that ends the run green, a sixth step
    try expectRefused(ar, x, try replaced(ar, text, c.RESULT_TESTPYPI_LINES[1], "        if: needs.build.result != 'success'"), "result-testpypi: its steps");
    try expectRefused(ar, x, try replaced(ar, text, c.RESULT_TESTPYPI_LINES[10], "        if: needs.testpypi-smoke.result != 'success'"), "result-testpypi: its steps");
    try expectRefused(ar, x, try replaced(ar, text, " && exit 1'\n      - name: the bytes differ at the same version\n        if: needs.testpypi.outputs.state == 'differs'", "'\n      - name: the bytes differ at the same version\n        if: needs.testpypi.outputs.state == 'differs'"), "result-testpypi: its steps");
    try expectRefused(ar, x, try inJob(ar, text, "result-testpypi", "          PASSED: ${{ needs.testpypi-passed.result }}\n", "          PASSED: ${{ needs.testpypi-passed.result }}\n      - name: one more\n        run: echo done\n"), "result-testpypi: it is not exactly the 5 steps");
    // the storage error for one index alone
    try expectRefused(ar, x, try replaced(ar, text, c.RESULT_TESTPYPI_LINES[15], "        if: needs.testpypi.outputs.testpypi_storage == 'true'"), "result-testpypi: its steps");
    // the promotion: the skipped versions not named, the differs on PyPI a notice, the storage dropped
    try expectRefused(ar, x, try replaced(ar, text, c.RESULT_PYPI_LINES[3], "        run: 'echo \"::notice title=pypi::not promoted\"'"), "result-pypi: its steps");
    try expectRefused(ar, x, try replaced(ar, text, "PyPI was not smoked\" && exit 1'", "PyPI was not smoked\"'"), "result-pypi: its steps");
    try expectRefused(ar, x, try replaced(ar, text, c.RESULT_PYPI_LINES[20], "        if: needs.promote.outputs.pypi_storage == 'true'"), "result-pypi: its steps");
    // the notice already published before a failing step
    const same_step = c.PYPI_SAME_STEP ++ "\n" ++ c.RESULT_PYPI_LINES[23] ++ "\n        env:\n" ++ c.RESULT_PYPI_LINES[24] ++ "\n" ++ c.RESULT_PYPI_LINES[25] ++ "\n";
    try expectRefused(ar, x, try replaced(ar, try replaced(ar, text, same_step, ""), "      - name: the PyPI smoke succeeded\n", same_step ++ "      - name: the PyPI smoke succeeded\n"), "result-pypi: the notice already ... is not its last step");
}

test {
    // the contract, the cases that play a run of the file, and the contract of the user test job
    _ = @import("pypi_workflow_contract.zig");
    _ = @import("pypi_workflow_run.zig");
    _ = @import("wheel_user_test_job.zig");
}
