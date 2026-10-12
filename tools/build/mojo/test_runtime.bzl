"""The test runtime contract of the Mojo rules (defs.bzl): the staged tree a
test runs from, and the data, environment and arguments it is given.
"""

# ---- the test runtime contract ------------------------------------------
#
# A test runs from a staged tree built for it alone:
#
#     root/bin/<test>        the test binary (a copy, so /proc/self/exe is here)
#     root/share/<dest>      each declared data file
#
# The gate (`gate mojo`, tools/build/run) starts the test with root/share as its current directory, so
# a relative path to a declared file opens and any other relative path names
# nothing. komira//tools/build/mojo/runtime_paths finds root/share from the
# executable, the same way a bundle finds its share/.

# Names the runner sets itself; a test may not override them through env.
RUNNER_ENV = ["PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "TMPDIR", "TEST_TMPDIR", "HOME", "PWD"]

def data_map(ctx, where, data):
    """{dest: artifact} for a `data` value: a list of sources (each staged at
    its path from the cell root) or a dict {dest: source}."""
    if type(data) == type([]):
        out = {}
        pkg = ctx.label.package
        for a in data:
            if not a.is_source:
                fail("{}: {} is a build output; a list entry is staged at its source path, so name a build output in the dict form, {{dest: source}}".format(where, a))
            # A source's short_path is relative to its package.
            out[pkg + "/" + a.short_path if pkg else a.short_path] = a
    else:
        out = dict(data)
    prefixes = {}
    for dest in out:
        if dest == "" or dest.startswith("/") or dest.endswith("/"):
            fail("{}: data destination {} must be a relative file path".format(where, repr(dest)))
        parts = dest.split("/")
        for part in parts:
            if part in ("", ".", ".."):
                fail("{}: data destination {} holds an empty, `.` or `..` segment".format(where, repr(dest)))
        for i in range(1, len(parts)):
            prefixes["/".join(parts[:i])] = dest
    for dest in out:
        if dest in prefixes:
            fail("{}: data destination {} is both a file and the directory of {}".format(where, repr(dest), repr(prefixes[dest])))
    return out

def env_args(where, env):
    """`--env NAME=VALUE` runner arguments, after refusing names the runner owns."""
    args = []
    for name in sorted(env.keys()):
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
            fail("{}: env name {} is not a shell variable name".format(where, repr(name)))
        if name in RUNNER_ENV:
            fail("{}: env sets {}, which the test runner sets itself (runner-owned: {})".format(where, name, ", ".join(RUNNER_ENV)))
        args += ["--env", "{}={}".format(name, env[name])]
    return args

# The prefix of every artifact path in a mojo_test's `args`: the gate
# replaces it with the action's directory, because the test runs from its
# share/, where a path relative to the action's directory reaches nothing
# (tools/build/run/mojo.zig, `action_dir_token`).
ACTION_DIR_TOKEN = "@KOMIRA_ACTION_DIR@"

def arg_args(args):
    """`--arg VALUE` runner arguments for a mojo_test's `args`, each artifact
    path (from `$(location ...)`, `$(exe_target ...)`) written under ACTION_DIR_TOKEN.
    The artifacts are on the command line, so they are inputs of the test."""
    out = []
    for a in args:
        out += ["--arg", cmd_args(a, absolute_prefix = ACTION_DIR_TOKEN + "/")]
    return out

def test_root(ctx, path, exe, data):
    """The staged tree of one test; returns (root, binary inside it)."""
    name = exe.basename
    files = {"bin/" + name: exe}
    for dest, a in data.items():
        files["share/" + dest] = a
    root = ctx.actions.copied_dir(path, files)
    return root, root.project("bin/" + name)

def gate_mojo(tc, label, test, marker, flags = [], tail = [], scripts = None):
    """The command that runs one gated test: `gate mojo` (tools/build/run,
    README.md) of `test` (the binary inside a test_root) as `label`, writing
    `PASS <label>` to `marker` when it passes. `flags` are its limits (the
    memory cap, cap_flags in defines.bzl; the time limit, deadline_flags in
    test_limit.bzl); `tail` its `--env` and `--arg` options, which come
    last.

    The darwin-arm64 toolchain has no gate (`tc.gate` is None): there the
    same run is the shell runner it keeps, `scripts` (struct(mem_cap,
    test_deadline), the rule's own copies) around `tc.gate_runner`, each
    command as it was before the gate."""
    if tc.gate == None:
        return _shell_runner(tc, label, test, marker, flags, tail, scripts)
    return cmd_args(
        tc.gate,
        "mojo",
        "--busybox",
        tc.busybox,
        "--runtime-lib",
        cmd_args(tc.compiler, format = "{}/lib"),
        "--label",
        label,
        "--test",
        test,
        "--marker",
        marker,
        flags,
        tail,
    )

def _flag(flags, name):
    for i in range(len(flags) - 1):
        if flags[i] == name:
            return flags[i + 1]
    return None

def _shell_runner(tc, label, test, marker, flags, tail, scripts):
    """darwin-arm64: gate_runner.sh, under test_deadline.sh and mem_cap.sh
    when `flags` ask for a limit (mem_cap.sh refuses a cap there: macOS has
    no /proc)."""
    if tc.gate_runner == None:
        fail("{}: the Mojo toolchain has neither a gate nor a gate_runner".format(label))
    prefix = []
    deadline = _flag(flags, "--deadline-s")
    cap = _flag(flags, "--mem-cap-mib")
    if (deadline != None or cap != None) and scripts == None:
        fail("{}: a limit on the darwin-arm64 toolchain needs the rule's mem_cap.sh and test_deadline.sh".format(label))
    if deadline != None:
        prefix += [tc.busybox, "sh", scripts.test_deadline, tc.busybox, deadline, _flag(flags, "--runner-timeout-s"), label, "--"]
    if cap != None:
        prefix += [tc.busybox, "sh", scripts.mem_cap, tc.busybox, cap, label, "--"]
    return cmd_args(prefix, tc.busybox, "sh", tc.gate_runner, tc.busybox, tc.compiler, label, test, marker, tail)
