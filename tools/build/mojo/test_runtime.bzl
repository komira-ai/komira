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
# gate_runner.sh starts the test with root/share as its current directory, so
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

# The prefix of every artifact path in a mojo_test's `args`: gate_runner.sh
# replaces it with the action's directory, because the test runs from its
# share/, where a path relative to the action's directory reaches nothing.
# gate_runner.sh's comment names this constant by its name before it moved
# here from defs.bzl (`_ACTION_DIR_TOKEN`); the runner stays byte for byte as
# it was until a change that may touch it corrects that.
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

def test_key(ctx, t):
    """The package-relative path of test source `t`: its test_data key."""
    p = t.short_path
    pkg = ctx.label.package
    if pkg and p.startswith(pkg + "/"):
        p = p[len(pkg) + 1:]
    return p

def admit_test_data(ctx):
    """{test_srcs key: {dest: artifact}} for mojo_library's `test_data`."""
    keys = [test_key(ctx, t) for t in ctx.attrs.test_srcs]
    where = "{}: test_data".format(ctx.label.raw_target())
    out = {}
    for entry, data in ctx.attrs.test_data.items():
        if entry not in keys:
            fail("{}[{}]: not a test_srcs entry (entries: {}). Data keyed to no test is staged for nothing.".format(where, repr(entry), ", ".join(keys)))
        out[entry] = data_map(ctx, "{}[{}]".format(where, repr(entry)), data)
    return out
