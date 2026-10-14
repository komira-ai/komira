"""`script_test`: a command run as a build action, in a writable scratch copy of its sources.

The target exists only if the command exited 0, so building it is running
the test; a rule that takes `unit_tests` (`zig_exe`, `zig_module`) welds it
the way it welds a `zig_test`. The action needs no shell, interpreter or
coreutils of the worker: the shell and the file utilities are the pinned
busybox, and everything else the command runs is a declared tool.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:test_runtime.bzl", "RUNNER_ENV", "data_map")
load("@komira//tools/build/mojo:toolchain.bzl", "busybox_sh")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")

# What a path of an argument or an environment value is prefixed with, so
# that the script can make it absolute: the command runs in a scratch
# directory, and a path buck2 gives it is relative to the project root.
_ROOT = "@KOMIRA_ROOT@"

_SCRIPT = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
R="$PWD"
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
OUT="$1"; SRCS="$2"; TOOLS="$3"; ENVF="$4"; shift 4
case "$OUT" in /*) ;; *) OUT="$R/$OUT" ;; esac
TAB=$(printf '\\t')
RE=$(printf '%s/' "$R" | sed 's/[\\\\&|]/\\\\&/g')
# The root of the project in place of the marker the rule put before every
# artifact path of an argument or an environment value.
absolute() { printf '%s' "$1" | sed "s|@KOMIRA_ROOT@|$RE|g"; }

S="$T/work"
mkdir -p "$S" "$T/home" "$T/tmp" "$T/cache" "$T/zig-global" "$T/zig-local" "$T/tools"

# (The manifests end without a newline: a last line is read, with `read`'s
# failure, as long as it holds something.)
# The declared sources, each at its path from the cell root. A source is
# read-only in the input root: the copy is made writable, with its
# executable bits as they were.
while IFS="$TAB" read -r dest src || [ -n "$dest" ]; do
    case "$src" in /*) ;; *) src="$R/$src" ;; esac
    if [ -d "$src" ]; then
        mkdir -p "$S/$dest"
        cp -R "$src/." "$S/$dest/"
    else
        mkdir -p "$S/$(dirname "$dest")"
        cp "$src" "$S/$dest"
    fi
done < "$SRCS"
chmod -R u+w "$S"

# The declared tools. An executable file is on PATH under its name; a
# directory (an unpacked distribution) puts its bin/ there, or itself if it
# has none.
TOOLPATH="$T/tools"
while IFS="$TAB" read -r name path || [ -n "$name" ]; do
    case "$path" in /*) ;; *) path="$R/$path" ;; esac
    if [ -d "$path" ]; then
        if [ -d "$path/bin" ]; then TOOLPATH="$TOOLPATH:$path/bin"; else TOOLPATH="$TOOLPATH:$path"; fi
    else
        ln -s "$path" "$T/tools/$name"
    fi
done < "$TOOLS"
PATH="$TOOLPATH:$T/bin"

HOME="$T/home"; TMPDIR="$T/tmp"; XDG_CACHE_HOME="$T/cache"
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"
export PATH HOME TMPDIR XDG_CACHE_HOME ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR
while IFS="$TAB" read -r name value || [ -n "$name" ]; do
    value=$(absolute "$value")
    export "$name=$value"
done < "$ENVF"

# The command and its arguments, with their paths made absolute.
n=$#
while [ "$n" -gt 0 ]; do
    a=$(absolute "$1")
    shift
    set -- "$@" "$a"
    n=$((n - 1))
done

cd "$S"
rc=0
"$@" > "$T/out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "script_test: $1 exited with status $rc; the last 200 lines of its output:" >&2
    tail -n 200 "$T/out" >&2
    cd "$R"
    rm -rf "$T"
    exit 1
fi
cd "$R"
echo passed > "$OUT"
rm -rf "$T"
"""

def _script_test_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    where = str(ctx.label.raw_target())
    if not ctx.attrs.cmd:
        fail("{}: cmd is empty".format(where))
    for name in ctx.attrs.env:
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
            fail("{}: env name {} is not a shell variable name".format(where, repr(name)))
        if name in RUNNER_ENV or name in ["XDG_CACHE_HOME", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR"]:
            fail("{}: env sets {}, which the action sets itself".format(where, name))
    for name in ctx.attrs.tools:
        if not regex_match("^[A-Za-z0-9_][A-Za-z0-9_.+-]*$", name):
            fail("{}: tool name {} is not a file name".format(where, repr(name)))

    out = ctx.actions.declare_output(ctx.label.name + ".passed")
    srcs = data_map(ctx, where, ctx.attrs.srcs)
    srcs_manifest, _ = ctx.actions.write(
        ctx.label.name + ".srcs",
        [cmd_args(dest, src, delimiter = "\t") for dest, src in sorted(srcs.items())],
        allow_args = True,
    )
    tools = {name: dep[DefaultInfo].default_outputs[0] for name, dep in ctx.attrs.tools.items()}
    tools_manifest, _ = ctx.actions.write(
        ctx.label.name + ".tools",
        [cmd_args(name, tool, delimiter = "\t") for name, tool in sorted(tools.items())],
        allow_args = True,
    )
    env_manifest, _ = ctx.actions.write(
        ctx.label.name + ".env",
        [cmd_args(name, value, delimiter = "\t", absolute_prefix = _ROOT) for name, value in sorted(ctx.attrs.env.items())],
        allow_args = True,
    )
    command = [cmd_args(a, absolute_prefix = _ROOT) for a in [ctx.attrs.cmd] + ctx.attrs.args]
    cmd = busybox_sh(bb, _SCRIPT, out.as_output(), srcs_manifest, tools_manifest, env_manifest, *command)
    ctx.actions.run(
        cmd_args(cmd, hidden = srcs.values() + tools.values() + ctx.attrs.env.values()),
        category = "script_test",
        env = rerun_env(ctx),
    )
    return [DefaultInfo(default_output = out), rerun_info(ctx)]

_script_test = rule(
    impl = _script_test_impl,
    doc = "Runs `cmd` with `args` as a build action, in a writable scratch copy of `srcs` (each at its path from the cell root, executable bits kept) that is its working directory, with `tools` on PATH and HOME, TMPDIR, XDG_CACHE_HOME and ZIG_GLOBAL_CACHE_DIR inside the scratch. Its output, `<name>.passed`, exists only if the command exited 0; otherwise the tail of its output is the failure.",
    attrs = {
        # The command's arguments. `$(location ...)` and `$(exe ...)` expand to
        # absolute paths.
        "args": attrs.list(attrs.arg(), default = []),
        # The shell and the file utilities of the action.
        "busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        # The command: a path of `srcs` (relative to the working directory, so
        # from the cell root) or the name of a tool on PATH. A script is run
        # by its own `#!` line: name its interpreter in `cmd` (`sh`, or a tool
        # such as `python3`) and the script in `args` when the worker image
        # has none.
        "cmd": attrs.string(),
        # name -> value, in the command's environment; `$(location ...)` and
        # `$(exe ...)` expand to absolute paths.
        "env": attrs.dict(attrs.string(), attrs.arg(), default = {}),
        # The files the command reads and writes, copied into its working
        # directory: a list of sources (files or directories, each at its path
        # from the cell root) or {destination: source}.
        "srcs": attrs.one_of(attrs.list(attrs.source(allow_directory = True)), attrs.dict(attrs.string(), attrs.source(allow_directory = True)), default = []),
        # name -> a tool the command runs (its default output): an executable
        # file is on PATH under `name`; a directory puts its `bin/`, or
        # itself, on PATH.
        "tools": attrs.dict(attrs.string(), attrs.exec_dep(), default = {}),
    } | RERUN_ATTRS,
)

def _script_test_macro(**kwargs):
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _script_test(**kwargs)

# The macro declares its package's doc_tree (tools/build/lint/doc_tree.bzl),
# so no BUCK file names one.
script_test = declares_docs(_script_test_macro)
