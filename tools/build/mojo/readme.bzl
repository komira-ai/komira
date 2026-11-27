"""Which library of a BUCK file takes the package's README.md (mojo_library's `readme`), and the README gate.

A library takes its directory's README.md: the README's ```mojo examples run
as its welded `[tests][readme]` test and its conda package installs the file
(readme_gate below; tools/build/package/conda.bzl). A BUCK file that
declares one library needs to say nothing. One that declares several says
which of them the README is about, with the macro's `readme` keyword:

    readme omitted   the README.md of the directory if there is one (one
                     library: nothing to say)
    readme = True    the README.md of the directory, refused if there is none
    readme = False   no README: no `[tests][readme]`, none in the conda package

A README attached to a library that does not reach what it imports fails
that library's `[tests][readme]` compile, and a README attached to several
ships in each of their packages, so a package of several libraries gives
`readme = False` to every library its README is not about.

A library whose README is source-first lists its examples' files, which the
README shows through include markers (docs/design/documentation_tests.md):

    readme_examples = glob(["examples/*.mojo"])

Each file is compiled against the library and run as a welded test of its
own, and the README is held to the files byte for byte (the gate below).
`readme_examples` needs the README; `[]` is a source-first README that shows
no example. An example may carry `examples/<name>.expected_output.txt`: its
run's stdout must then be that file byte for byte. The macro adds every such
file of the package to `readme_examples` itself (with_expected_outputs), so
none is left out of the list by its glob.

This module loads providers.bzl, compile.bzl, test_runtime.bzl,
test_limit.bzl, opt_level.bzl, system_libs.bzl, the doc tree and rerun
modules: none of them loads defs.bzl, so defs.bzl can load it.
"""

load(":compile.bzl", "build_executable", "c_link", "dep_closure", "link_tail")
load(":opt_level.bzl", "TEST_OPT_LEVEL")
load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "MojoToolchainInfo", "ZigExeInfo")
load(":system_libs.bzl", "dep_system_libs", "run_args")
load(":test_limit.bzl", "HANG_LIMIT_ATTRS", "hang_limit_flags")
load(":test_runtime.bzl", "gate_mojo", "test_root")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/readme_examples:pages.bzl", "page", "pages_check_and_fill")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")

# The README examples tool, a Zig executable: no Mojo library, so any
# package, its own included, may hold a README.
_README_TOOL = "komira//tools/build/readme_examples:tool"

def readme_kwargs(kwargs):
    """Replaces the macro's `readme` keyword in `kwargs` by the rule's
    `readme` (the README.md source) and `readme_tool` attributes, or by
    neither when the library takes no README. `readme_examples` is passed
    through, and refused without a README."""
    name = kwargs.get("name", "mojo_library")
    if "readme_tool" in kwargs:
        fail("{}: `readme_tool` is set by mojo_library with the README; do not pass it".format(name))
    want = kwargs.pop("readme", None)
    if want != None and type(want) != "bool":
        fail("{}: `readme` takes True, False or nothing (the package's README.md, if any), not {}".format(name, repr(want)))
    listed = kwargs.get("readme_examples")
    if listed != None and type(listed) != "list":
        fail("{}: `readme_examples` is a list of the README's example files (glob([\"examples/*.mojo\"])), not {}".format(name, repr(listed)))
    if want == False:
        if listed != None:
            fail("{}: `readme_examples` lists the files a README shows, and `readme = False` takes no README".format(name))
        return
    found = glob(["README.md"])
    if not found:
        if want == True:
            fail("{}: `readme = True` and //{} holds no README.md".format(name, package_name()))
        if listed != None:
            fail("{}: `readme_examples` lists the files a README shows, and //{} holds no README.md".format(name, package_name()))
        return
    kwargs["readme"] = found[0]
    kwargs["readme_tool"] = _README_TOOL
    with_expected_outputs(kwargs)

def with_expected_outputs(kwargs):
    """Adds to a source-first library's `readme_examples` (in `kwargs`)
    every `examples/<name>.expected_output.txt` of the package it does not
    list: an expected output is held whenever it exists, whatever the glob
    the BUCK file wrote. A library with no `readme_examples` is left as it
    is. mojo_adopted_library calls it too (adopt.bzl)."""
    listed = kwargs.get("readme_examples")
    if listed == None:
        return
    kwargs["readme_examples"] = listed + [f for f in glob(["examples/*" + _EXPECTED]) if f not in listed]

# ---- The gate -----------------------------------------------------------------
#
# A library whose package holds a README.md runs the README's ```mojo
# examples as one more welded test, `[tests][readme]`: the docs cannot rot.
# The macro passes the README (declaring is gating: a README is declared by
# existing; a library of a several-library package can refuse it with
# `readme = False`, readme_kwargs above) and the tool, //tools/build/readme_examples:tool, whose
# `generate` writes one program per example, `readme_<import name>_<line>.mojo`
# (and the runner of them all, which coverage builds), into a directory, and
# the README line of each example to `examples`. The convention (what an
# example is, its two modes, hidden lines, the refusals) is in that package
# and in README.md here.
#
# The inline model (no `readme_examples`): whether a README holds an example
# is in its bytes, which analysis cannot read, so a dynamic action reads
# `examples`: for each example it compiles that example's program alone
# against the UNGATED package and runs it through the gate (gate_mojo)
# exactly as a `test_srcs` entry, labelled `<target>:README.md:<line>`, and
# the marker joins their markers; with none it compiles and runs nothing, and
# the marker records that no example exists (never a PASS line). A refused
# README (an info string such as `mojo skip`, a stray hidden-lines comment,
# an include marker) fails `generate`, naming README.md:<line>.
# `[tests][readme][migrated]` is the README made source-first by the tool's
# `migrate` (its README.md and examples/), built only when asked for, and
# proven by `migrate --verify` in the same build.
#
# Source-first (`readme_examples` listed): the list is the glob, so analysis
# has the files and no dynamic action is needed. Each file is compiled
# against the UNGATED package and run through the gate as its own welded
# test, labelled `<target>:examples/<name>.mojo`, staged at its repository
# path so a failure names `<package>/examples/<name>.mojo:<line>`; the
# tool's `check` holds the README to the files (every listed file shown by
# exactly one include, every ```mojo fence an include, each fence its file
# byte for byte, the text-fence rule; include.zig, the `readme` row of the rule
# table a task page's `task` row shares), and the marker joins its line and
# every file's marker. An example with `examples/<name>.expected_output.txt`
# is run with the gate's `--stdout`, and the tool's `compare-output` holds that
# stdout to the file; its marker joins too. `[tests][readme][check]` is the
# freshness check alone and `[tests][readme][fill]` the patch that mends a
# stale README, which the author applies with `git apply`: the same two
# sub-targets, from the same implementation (pages.bzl), as a task tree's
# `:pages` has.
# `generate` still runs (it reads an included fence as a whole program) for
# `[generated]` and the coverage build.

# zig's os of each toolchain os (MojoToolchainInfo.os): a triple names it as
# its second dash-separated part (`x86_64-linux-musl`, `aarch64-macos.11.0`).
_ZIG_OS = {"darwin": "macos", "linux": "linux"}

# The sub-targets of `[tests][readme]` that are not an example's.
_RESERVED = ["check", "file", "fill", "generated", "migrated", "objects"]

# The suffix of a README example's expected output, beside its `.mojo`.
_EXPECTED = ".expected_output.txt"

def _tool_os_refusal(tool, os):
    """Why the exec_dep `tool` cannot run in an action of a toolchain whose
    os is `os`, or None. A zig_exe states its triple (ZigExeInfo); the
    `generate` action runs on the execution platform of the library, so a
    tool built for another operating system fails there (`exec format error`)
    after its inputs were sent. This refuses it at analysis instead. Only the
    os is compared: MojoToolchainInfo names no cpu as zig does."""
    info = tool.get(ZigExeInfo)
    if info == None:
        return None
    parts = info.target.split("-")
    want = _ZIG_OS.get(os)
    if len(parts) < 2 or want == None or parts[1].split(".")[0] != want:
        return ("the README tool {} is built for {} but runs on the {} execution platform; " +
                "an exec_dep must be built for the platform its action runs on").format(tool.label.raw_target(), info.target, os)
    return None

def _display(ctx, src):
    """`src` as a message names it: its path from the cell root."""
    return (ctx.label.package + "/" + src.short_path) if ctx.label.package else src.short_path

def readme_file_test(ctx, tc, tool, example, stem, closure, link_tail_args, env_args, rerun, hang_flags, opt_level, owner = False, expect = None, expected_output = None):
    """One README example file as a welded test: `example` (a source of the
    package) compiled against `closure` (a MojoPkgTSet) and run through the
    gate as `<target>:<its short path>`. The file is staged at its path from
    the cell root, so the compiler, and an assertion's location, name it so.
    With `expected_output` (its `examples/<name>.expected_output.txt`), the
    gate keeps the run's stdout (`--stdout`) and the tool's `compare-output`
    holds it to that file byte for byte, naming the file's first differing
    line. Returns (markers, object or None): the gate's marker, then the
    compare's when there is one. With `owner`, the program also as an
    object file (`[tests][readme][objects]`). With `expect`, the test must
    FAIL with `expect` in its output: its last marker is written only then
    (the tool's `expect-failure`; mojo_readme_example_failure below); with
    `expected_output` too, the run must pass and the compare fail."""
    prefix = (ctx.label.package + "/") if ctx.label.package else ""
    exe = build_executable(ctx, tc, "tests/readme/bin/" + stem, [example], example, [closure], opt_level, "mojo_build_test", "readme_" + stem, None, link_extra = link_tail_args, src_prefix = prefix)
    obj = None
    if owner:
        obj = build_executable(ctx, tc, "tests/readme/obj/" + stem + ".o", [example], example, [closure], opt_level, "mojo_readme_object", "readme_" + stem, None, emit_object = True, src_prefix = prefix)
    root, staged = test_root(ctx, "tests/readme/root/" + stem, exe, {})
    marker = ctx.actions.declare_output("tests/readme/{}.passed".format(stem))
    label = "{}:{}".format(ctx.label.raw_target(), example.short_path)
    printed = None
    flags = hang_flags
    if expected_output != None:
        printed = ctx.actions.declare_output("tests/readme/{}.stdout".format(stem))
        flags = hang_flags + ["--stdout", printed.as_output()]
    if expect == None or expected_output != None:
        cmd = gate_mojo(tc, label, staged, marker.as_output(), flags, env_args)
        category = "mojo_gated_test"
    else:
        # The gate writes its marker only for a run that passed; this one must
        # not pass, so its marker goes nowhere and the tool writes this one.
        cmd = cmd_args(tool, "expect-failure", "--text", expect, "--out", marker.as_output(), "--", gate_mojo(tc, label, staged, "/dev/null", flags, env_args))
        category = "mojo_readme_expect_failure"
    ctx.actions.run(
        cmd_args(cmd, hidden = root),
        env = salted(rerun),
        category = category,
        identifier = "readme_" + stem,
    )
    if expected_output == None:
        return [marker], obj
    compared = ctx.actions.declare_output("tests/readme/{}.output.passed".format(stem))
    compare = cmd_args(tool, "compare-output", "--expected", expected_output, "--display", prefix + expected_output.short_path, "--printed", printed)
    if expect == None:
        cmd = cmd_args(compare, "--out", compared.as_output())
        category = "mojo_readme_compare_output"
    else:
        cmd = cmd_args(tool, "expect-failure", "--text", expect, "--out", compared.as_output(), "--", compare, "--out", "/dev/null")
        category = "mojo_readme_expect_failure"
    ctx.actions.run(
        cmd_args(cmd, hidden = marker),
        env = salted(),
        category = category,
        identifier = "readme_" + stem + "_output",
    )
    return [marker, compared], obj

def _source_first(ctx, tc, import_name, closure, link_tail_args, env_args, rerun, owner, hang, display):
    """The gate of a source-first README: (marker, objects directory, the
    sub-targets of its examples, the check and fill outputs)."""
    readme = ctx.attrs.readme
    tool = ctx.attrs.readme_tool[RunInfo]
    readme_dir = readme.short_path.rpartition("/")[0]

    def rel_of(f):
        rel = f.short_path
        if readme_dir:
            if not rel.startswith(readme_dir + "/"):
                fail("{}: readme_examples lists {}, which is not beside {}".format(ctx.label, f.short_path, readme.short_path))
            rel = rel[len(readme_dir) + 1:]
        return rel

    # The expected outputs first, by the name of the example they are of.
    expected = {}
    for f in ctx.attrs.readme_examples:
        rel = rel_of(f)
        if rel.endswith(_EXPECTED):
            if not regex_match("^examples/[a-z][a-z0-9_]*\\.expected_output\\.txt$", rel):
                fail("{}: readme_examples lists {}: an expected output is examples/<name>.expected_output.txt beside the README, <name> its example's".format(ctx.label, f.short_path))
            expected[rel[len("examples/"):-len(_EXPECTED)]] = f
    markers = []
    built = {}
    subs = {}
    files = []
    for f in ctx.attrs.readme_examples:
        rel = rel_of(f)
        if rel.endswith(_EXPECTED):
            files.append((rel, f))
            continue
        if not regex_match("^examples/[a-z][a-z0-9_]*\\.mojo$", rel):
            fail("{}: readme_examples lists {}: a README's example is examples/<name>.mojo beside the README, <name> lower-case letters, digits and underscores".format(ctx.label, f.short_path))
        stem = rel[len("examples/"):-len(".mojo")]
        if stem in _RESERVED:
            fail("{}: readme_examples lists {}: `{}` names a sub-target of [tests][readme]; rename the file".format(ctx.label, f.short_path, stem))
        if stem in subs:
            fail("{}: readme_examples lists {} twice".format(ctx.label, f.short_path))
        ms, obj = readme_file_test(ctx, tc, tool, f, stem, closure, link_tail_args, env_args, rerun, hang, ctx.attrs.test_optimization_level, owner = owner, expected_output = expected.get(stem))
        markers.extend(ms)
        subs[stem] = [DefaultInfo(default_output = ms[-1], other_outputs = ms[:-1])]
        if obj != None:
            built["readme_{}_{}.o".format(import_name, stem)] = obj
        files.append((rel, f))
    for stem in expected:
        if stem not in subs:
            fail("{}: readme_examples lists examples/{}{}, and no examples/{}.mojo whose output it is".format(ctx.label, stem, _EXPECTED, stem))

    # The same check and fill as a task page's (pages.bzl): a stem starts with
    # a letter, so `_fresh` names no example's marker.
    out = pages_check_and_fill(
        ctx,
        tool,
        "readme",
        [page(readme, display, files)],
        "tests/readme/_fresh.passed",
        "tests/readme/fill.patch",
        env = salted(),
        category = "mojo_readme",
    )
    marker = ctx.actions.declare_output("tests/readme.passed")
    ctx.actions.run(
        cmd_args(tc.act, "cat", marker.as_output(), [out.check] + markers),
        env = salted(),
        category = "mojo_readme_join",
    )
    objects = ctx.actions.copied_dir("tests/readme/objects", built)
    return marker, objects, subs, out

def readme_gate(ctx, tc, import_name, ungated_tset, link_args, env_args, ships, readme_test, owner = False, rerun = {}):
    """The README gate, or None without a README: a struct of `marker` (the
    `[tests][readme]` marker), `generated` (the directory `generate` wrote),
    `objects` and `sub_targets` (those of `[tests][readme]`). With `owner`
    (the library lists a C library among its `deps`: native_facts.bzl
    `c_direct`), the objects directory holds each example's program as an
    object file, `readme_<import name>_<line or name>.o`, whose undefined
    symbols are the C it calls: `[tests][readme][objects]`, which the
    library's own shared library reads for its README check
    (tools/build/native/shared.bzl, `readme_calls`). It is empty for any
    other library and with no example.
    `ships`: the library's conda package installs the README, so a
    relative link in it is refused.
    `link_args`: the link arguments of the library's C closure (defs.bzl's
    _link_tail); `readme_test`: defs.bzl's dynamic action that builds and
    runs each example of an inline README; `rerun`: the environment each
    example's run adds (rerun.bzl's rerun_env). A source-first README (the
    library lists `readme_examples`) runs its files instead (see above)."""
    readme = ctx.attrs.readme
    listed = ctx.attrs.readme_examples
    if readme == None:
        if ctx.attrs.readme_tool != None:
            fail("{}: readme_tool is set and readme is not".format(ctx.label))
        if listed != None:
            fail("{}: readme_examples is set and readme is not".format(ctx.label))
        return None
    if ctx.attrs.readme_tool == None:
        fail("{}: readme is set and readme_tool is not; the mojo_library macro sets both".format(ctx.label))
    refusal = _tool_os_refusal(ctx.attrs.readme_tool, tc.os)
    if refusal:
        fail("{}: {}".format(ctx.label, refusal))
    display = _display(ctx, readme)
    tool = ctx.attrs.readme_tool[RunInfo]
    src = ctx.actions.declare_output("tests/readme/src", dir = True)
    examples = ctx.actions.declare_output("tests/readme/examples")
    ctx.actions.run(
        cmd_args(
            tool,
            "generate",
            "--readme",
            readme,
            "--display",
            display,
            "--package",
            import_name,
            "--links",
            "refuse" if ships else "allow",
            "--includes",
            "refuse" if listed == None else "allow",
            "--out-dir",
            src.as_output(),
            "--examples",
            examples.as_output(),
        ),
        env = salted(),
        category = "mojo_readme_generate",
    )
    hang = hang_limit_flags(str(ctx.label.raw_target()), ctx.attrs.test_hang_limit_s)
    subs = {
        "file": [DefaultInfo(default_output = readme)],
        "generated": [DefaultInfo(default_output = src)],
    }
    if listed != None:
        marker, objects, examples_subs, out = _source_first(ctx, tc, import_name, ungated_tset, link_args, env_args, rerun, owner, hang, display)
        subs.update(examples_subs)
        subs["check"] = [DefaultInfo(default_output = out.check)]
        subs["fill"] = [DefaultInfo(default_output = out.fill)]
    else:
        marker = ctx.actions.declare_output("tests/readme.passed")
        objects = ctx.actions.declare_output("tests/readme/objects", dir = True)
        ctx.actions.dynamic_output_new(readme_test(
            label = ctx.label,
            gate_label = "{}:{}".format(ctx.label.raw_target(), readme.short_path),
            examples = examples,
            package = import_name,
            src = src,
            marker = marker.as_output(),
            objects = objects.as_output(),
            owner = owner,
            tc = tc,
            closure = ungated_tset,
            opt_level = ctx.attrs.test_optimization_level,
            link_tail = link_args,
            env_args = env_args,
            rerun = rerun,
            hang_flags = hang,
        ))
        migrated = ctx.actions.declare_output("tests/readme/migrated", dir = True)
        ctx.actions.run(
            cmd_args(tool, "migrate", "--readme", readme, "--display", display, "--out-dir", migrated.as_output()),
            env = salted(),
            category = "mojo_readme_migrate",
        )
        verified = ctx.actions.declare_output("tests/readme/migrated.verified")
        ctx.actions.run(
            cmd_args(tool, "migrate", "--verify", "--readme", readme, "--display", display, "--migrated", migrated, "--out", verified.as_output()),
            env = salted(),
            category = "mojo_readme_migrate_verify",
        )
        subs["migrated"] = [DefaultInfo(default_output = migrated, other_outputs = [verified])]
    subs["objects"] = [DefaultInfo(default_output = objects)]
    return struct(marker = marker, generated = src, objects = objects, sub_targets = subs)

# ---- A README example that must fail ----------------------------------------------

def _example_failure_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    refusal = _tool_os_refusal(ctx.attrs._tool, tc.os)
    if refusal:
        fail("{}: {}".format(ctx.label, refusal))
    for d in ctx.attrs.deps:
        if MojoInfo not in d:
            fail("{}: dep {} provides no MojoInfo (a mojo_library or an adopted library)".format(ctx.label, d.label))
    if ctx.attrs.expect == "":
        fail("{}: `expect` is empty, which every output holds".format(ctx.label))
    where = str(ctx.label.raw_target())
    closure = ctx.actions.tset(MojoPkgTSet, children = dep_closure(ctx))
    if not ctx.attrs.example.basename.endswith(".mojo"):
        fail("{}: `example` {} is not a .mojo file".format(ctx.label, ctx.attrs.example.short_path))
    stem = ctx.attrs.example.basename[:-len(".mojo")]
    markers, _ = readme_file_test(
        ctx,
        tc,
        ctx.attrs._tool[RunInfo],
        ctx.attrs.example,
        stem,
        closure,
        link_tail(c_link(ctx)),
        run_args([], dep_system_libs(ctx.attrs.deps)),
        rerun_env(ctx),
        hang_limit_flags(where, ctx.attrs.test_hang_limit_s),
        TEST_OPT_LEVEL,
        expect = ctx.attrs.expect,
        expected_output = ctx.attrs.expected_output,
    )
    return [DefaultInfo(default_output = markers[-1], other_outputs = markers[:-1]), rerun_info(ctx)]

_example_failure = rule(
    impl = _example_failure_impl,
    doc = "A README example that must fail: `example` compiled against `deps` and run as a README example's welded test is (tools/build/mojo/readme.bzl, readme_file_test); the target builds only when the run fails with `expect` in its output (the README tool's `expect-failure`), so a broken example is shown to go red naming its file and line. With `expected_output`, the run must pass and its stdout's compare with that file must fail with `expect`, so a changed output is shown to go red naming the expected file's line.",
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "example": attrs.source(),
        "expect": attrs.string(),
        "expected_output": attrs.option(attrs.source(), default = None),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
        "_tool": attrs.exec_dep(default = _README_TOOL, providers = [RunInfo]),
    } | HANG_LIMIT_ATTRS | RERUN_ATTRS,
)

mojo_readme_example_failure = declares_docs(_example_failure)
