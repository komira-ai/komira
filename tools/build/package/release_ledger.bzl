"""The release ledger: every library is declared or listed with a reason.

`release/artifacts.textproto` declares the libraries a release publishes;
`release/unreleased.textproto` lists every other library under src/, each
with a reason from a closed set. `release_ledger_check` (release/BUCK) fails
the build when the two files and the libraries disagree:

  * a library in neither file, or in both;
  * a ledger row, or a declared artifact, for a directory that holds no
    library; a library listed or declared twice;
  * a row that is not `libraries { name: "<dir>" reason: <REASON> }` (with
    ` pr: <N>` before the `}` for PENDING_DECLARE, and only for it), or whose
    reason is not one of REASONS;
  * a row whose reason disagrees with what analysis knows of the library
    (release_ledger.sh says which reasons are computed and how).

What analysis knows comes from `library_census` (the root BUCK): one row per
library under src/ (not src/tests/), read from its MojoInfo: whether its
closure links native code (`c_link`, the refusal `_conda_facts` makes in
tools/build/mojo/defs.bzl), whether it has a README, and its `deps` (the
full closure). The census depends on every library but builds none of them:
its one file is written at analysis.

The check is standalone: nothing depends on it, so no library and no kci
target rebuilds when the ledger changes. It runs only after
`release_ledger_cases` (tools/build/package/BUCK), the same script over
fixtures whose verdict is known, has passed: a check that stops refusing
fails the build of the real one.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

# The closed set of reasons (docs/design/continuous_publish.md, "What blocks
# every package?"); the first three take precedence in this order.
REASONS = ["NATIVE", "DLOPEN", "NO_README", "UNDECLARED_DEP", "NO_CLOUD_CHECK", "TEST_SUPPORT", "PENDING_DECLARE"]

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _census_row(name, info):
    return "\t".join([
        name,
        "1" if info.c_link != None else "0",
        "1" if info.readme != None else "0",
        ",".join(info.direct) or "-",
    ])

def _library_census_impl(ctx):
    rows = []
    for name, lib in sorted(ctx.attrs.libraries.items()):
        info = lib[MojoInfo]
        if info.import_name != name:
            fail("library_census {}: //src/{} builds import name `{}`; a library's directory is its import name".format(ctx.label, name, info.import_name))
        rows.append(_census_row(name, info))
    if not rows:
        fail("library_census {}: no library under src/".format(ctx.label))
    out = ctx.actions.write("census.tsv", "\n".join(rows) + "\n")
    return [DefaultInfo(default_output = out)]

_library_census = rule(
    impl = _library_census_impl,
    doc = "One line per library (`libraries`: directory under src/ -> its mojo_library), written at analysis: `<dir>\\t<native 0|1>\\t<readme 0|1>\\t<deps, comma-separated, or ->`.",
    attrs = {
        "libraries": attrs.dict(attrs.string(), attrs.dep(providers = [MojoInfo])),
    },
)

def library_census(targets = {}, **kwargs):
    """The census of every library under src/, from the build graph; root BUCK only.

    A directory's library is the target named after it, or `targets[<dir>]`
    (a library whose target name is not its directory, as when a binary of
    the same package takes that name). A directory with neither fails
    analysis, as does a `targets` key that is not a directory under src/,
    and so does a library this target cannot see (`visibility`): a library
    is never left out of the census silently.
    """
    if package_name():
        fail("library_census {}: it lists the root package's subpackages, so it belongs in the cell's root BUCK".format(kwargs.get("name", "")))
    libs = {}
    for p in __internal__.sub_packages():
        if p.startswith("src/") and not p.startswith("src/tests/") and p.count("/") == 1:
            name = p[len("src/"):]
            libs[name] = "//{}:{}".format(p, targets.get(name, name))
    for name in targets:
        if name not in libs:
            fail("library_census {}: `targets` names {}, which is not a package under src/".format(kwargs.get("name", ""), name))
    _library_census(libraries = libs, **kwargs)

_ATTRS = {
    "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    "_script": attrs.source(default = "komira//tools/build/package:release_ledger.sh"),
}

def _script(ctx):
    # Copied under buck-out: a source's path in an action differs between a
    # standalone checkout and a repository that mounts komira as a cell, and
    # so would the action's digest.
    return ctx.actions.copy_file("release_ledger.sh", ctx.attrs._script)

def _check_impl(ctx):
    out = ctx.actions.declare_output("release_ledger.txt")
    bb = _out(ctx.attrs._busybox)
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            _script(ctx),
            bb,
            out.as_output(),
            ctx.attrs.census,
            ctx.attrs.artifacts,
            ctx.attrs.ledger,
            " ".join(REASONS),
            # The cases' verdicts: the check runs only once it has refused
            # every bad fixture (release_ledger_cases).
            hidden = [d[DefaultInfo].default_outputs for d in ctx.attrs.cases],
        ),
        category = "release_ledger",
    )
    return [DefaultInfo(default_output = out)]

_release_ledger_check = rule(
    impl = _check_impl,
    doc = "Every library of `census` (library_census) is declared in `artifacts` or listed in `ledger` with a reason, never both, and no row names a library that does not exist; release_ledger.sh says what else it refuses.",
    attrs = _ATTRS | {
        "artifacts": attrs.source(),
        "cases": attrs.list(attrs.dep(), default = ["komira//tools/build/package:release_ledger_cases"]),
        "census": attrs.source(),
        "ledger": attrs.source(),
    },
)

_CASE_SCRIPT = """
SCRIPT="$1"; EXPECT="$2"; REPORT="$3"; BB="$4"; shift 4
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.release_ledger_case" ;;
    /*) T="$BUCK_SCRATCH_PATH/release_ledger_case" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/release_ledger_case" ;;
esac
"$BB" rm -rf "$T"
"$BB" mkdir -p "$T"
rc=0
"$BB" sh "$SCRIPT" "$BB" "$T/out" "$@" 2> "$T/err" || rc=$?
if [ -z "$EXPECT" ]; then
    if [ "$rc" -ne 0 ] || ! "$BB" test -s "$T/out"; then
        echo "release_ledger_case: the check refused a ledger it must accept:" >&2
        "$BB" cat "$T/err" >&2
        exit 1
    fi
    "$BB" cp "$T/out" "$REPORT"
elif [ "$rc" -eq 0 ]; then
    echo "release_ledger_case: the check accepted a ledger it must refuse with: $EXPECT" >&2
    exit 1
elif ! "$BB" grep -qF -- "$EXPECT" "$T/err"; then
    echo "release_ledger_case: the check refused, but not with: $EXPECT" >&2
    "$BB" cat "$T/err" >&2
    exit 1
elif "$BB" test -e "$T/out"; then
    echo "release_ledger_case: the check refused but wrote its output" >&2
    exit 1
else
    { echo "refused"; "$BB" cat "$T/err"; } > "$REPORT"
fi
"$BB" rm -rf "$T"
"""

def _case_impl(ctx):
    census = ctx.actions.write("census.tsv", "".join([r + "\n" for r in ctx.attrs.census]))
    artifacts = ctx.actions.write("artifacts.textproto", "".join([
        "artifacts {{\n  name: \"{0}\"\n  targets: \"//src/{0}:{0}_conda\"\n}}\n".format(d)
        for d in ctx.attrs.declared
    ]))
    ledger = ctx.actions.write("unreleased.textproto", "".join([r + "\n" for r in ctx.attrs.ledger]))
    report = ctx.actions.declare_output(ctx.label.name + ".verdict.txt")
    bb = _out(ctx.attrs._busybox)
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", _CASE_SCRIPT, "sh", _script(ctx), ctx.attrs.expect, report.as_output(), bb, census, artifacts, ledger, " ".join(REASONS)),
        category = "release_ledger_case",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = report)]

_release_ledger_case = rule(
    impl = _case_impl,
    doc = "release_ledger.sh over a fixture (census rows, declared directories, ledger lines), with its verdict asserted: accepted when `expect` is empty, else refused with a message holding `expect`.",
    attrs = _ATTRS | {
        "census": attrs.list(attrs.string()),
        "declared": attrs.list(attrs.string(), default = []),
        "expect": attrs.string(default = ""),
        "ledger": attrs.list(attrs.string(), default = []),
    },
)

def release_ledger_check(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _release_ledger_check(**kwargs)

def release_ledger_case(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _release_ledger_case(**kwargs)

library_census = declares_docs(library_census)
release_ledger_check = declares_docs(release_ledger_check)
release_ledger_case = declares_docs(release_ledger_case)
