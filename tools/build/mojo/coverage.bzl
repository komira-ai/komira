"""Coverage builds of mojo_library: the switch, the debug link directory,
the kcov run of each test, and the gate.

`-c komira.coverage=true` (default false) gives every mojo_library on
linux-x86_64, per `test_srcs` entry:

- one more binary: the test compiled at -O0 with line tables, linked through
  a link directory that keeps the debug info and rewrites the action's
  directories out of it (`komira//tools/build/coverage/kcov`, README.md),
  `[coverage][bin][<test>]` (category `mojo_build_cov_test`);
- one run of it under kcov, through the release gate's runner, whose
  Cobertura report in repository paths is `[coverage][tests][<test>]`
  (category `mojo_cov_run`, `cov_run.sh` in the same directory);
- its branch coverage: the test as LLVM bitcode, that bitcode instrumented
  with profile counters and linked, the merged profile of its run through
  the release gate's runner, that profile applied to the bitcode, and the
  branch records of the library's sources, `[coverage][bc]`,
  `[coverage][pgo_bin]`, `[coverage][branch]`, `[coverage][branch_ir]` and
  `[coverage][branch_info]` (coverage_branch.bzl; categories
  `mojo_emit_cov_bc`, `mojo_cov_pgo_link`, `mojo_cov_branch_run`,
  `mojo_cov_branch_annotate`, `mojo_cov_branch_classify`), which the gate
  reads when `coverage_branch_gate` is set (a library of
  COVERAGE_BRANCH_GATE in policy.bzl, or a fixture of the tests cell that
  does not pass False), and nothing waits for otherwise.

and, per library (tests or none):

- the gate: `covcheck gate` over those reports (the kcov reports for lines,
  and with `coverage_branch_gate` the branch records, `--branch-lcov`, for
  branches) and the library's sources, in the mode of
  tools/build/coverage/policy.bzl, whose result.json and summary.md are
  `[coverage][gate]` (category `mojo_cov_gate`, cov_gate.sh of
  tools/build/coverage). A library of a test-only package (its package's
  directory in its cell is one of COVERAGE_INFO_ONLY_DIRS or under one)
  has the same gate, which reports its findings as information
  (`--info-package`), so it never fails on a finding (an input covcheck
  refuses still fails it).

What ships, the library's conda package (`<name>_conda`, its joins
`conda_join` and `conda_release_join`), then also waits for every coverage
run and the gate (and through the gate, when it reads them, for every branch
coverage action), through the library's MojoCoverageGateInfo: a test failing
at -O0, under kcov or (branch records read) instrumented for branch
coverage, a branch the classifier refuses, or a gate failing in enforce
mode, leaves the conda package unbuilt. The library's own package
(`mojo_gate_join`, what dependents compile against) does not wait for them:
a library whose coverage is red still builds, and so do its dependents. A
library with no test still has a gate (it has no report: NotMeasured), which
its conda package waits for. The libraries the gate's own tool depends on
(COVERAGE_NO_GATE, a ledger in policy.bzl) have no gate of their own: their
gate is the target `<name>_cov_gate`, which their conda package waits for
too. `[coverage]` is the binaries, the reports and the gate's outputs. Every
action of the library and its tests is what it is with the switch off.

The macro reads `[komira] coverage` from the buckconfig of the cell its
BUCK file is in: `-c` and a global buckconfig reach every cell, a cell's own
`.buckconfig` only that cell (tools/build/mojo/README.md, Coverage builds).

The switch is read here, in the macro, and only sets the `coverage_*`
attributes: a buckconfig value is not part of the configuration, so it moves
no output path and no action key, and with the switch off the attributes are
absent and analysis is what it was before they existed. With it on, no
release action of a library changes (its `mojo_gate_join` included, so its
dependents keep their keys); the actions that change are its conda
package's joins (`conda_join`, `conda_release_join`), whose inputs gain the
coverage markers (for a library of the ledger, the marker of its
`<name>_cov_gate` too), without changing their command or their bytes. On a
target platform other than linux-x86_64 the attributes are None (the
`select` below), so the library builds as with the switch off: coverage is
measured on linux-x86_64 only, never on another platform
(tools/build/platforms/limits.tsv, `coverage-linux-x86-64`).

Scope: a library's `test_srcs`, written or generated (a generated test is
named by its output path in the package, in its report and to the gate),
its README's examples and the standalone `mojo_test` targets it names in
`coverage_tests`; and a mojo_shared_lib's drivers (`gate_srcs`), which
measure the shared library's own sources (coverage_shared_lib, below; its
gate is in COVERAGE_SHARED_LIB_MODE and nothing waits for it).

- A README's examples (the program `[tests][readme]` runs) have a coverage
  binary and run like a test, `[coverage][bin][readme]` and
  `[coverage][tests][readme]` (coverage_readme): they test the library's
  public API, so they measure its lines. Whether the README holds an example
  is known only when the build reads it, so the coverage build compiles the
  program when it has one and otherwise a stub that runs nothing (category
  `mojo_cov_readme_source` chooses). The program is no repository file: its
  report names it under `buck-out/readme/`, which covcheck counts outside the
  repository.
- A `mojo_test` covers the libraries that name it in `coverage_tests`, none
  or several. The library cannot depend on its test (the test depends on the
  library), so such a library's gate is the target `<name>_cov_gate`, as for
  a library of the ledger: it runs each named test's coverage binary
  (`[coverage][bin]` of the mojo_test, coverage_test) under kcov against
  the library's sources (`<name>_cov_gate[tests][<test>]`), and gates over
  those reports with the library's own. A named test must depend on the
  library directly, and have a source main and no `args` (a generated
  welded test is run; a generated mojo_test main is refused, since its
  repository path, which the gate stages, names no file).

Line coverage only: neither has branch coverage actions, so a library whose
gate reads branch records reads those of its `test_srcs` alone (a file only
they reach is BranchUnmeasuredFile). Generated library sources are not
measured (nor staged for the gate): a library every source of which is
generated (a mojo_aws_client or mojo_gcp_client, whose hand-written sources
pass through its generator too) is NotMeasured in its gate.
"""

load("@komira//tools/build/coverage:policy.bzl", "COVERAGE_BRANCH_GATE", "COVERAGE_INFO_ONLY_DIRS", "COVERAGE_MODE", "COVERAGE_NO_GATE", "COVERAGE_SHARED_LIB_MODE", "COVERAGE_TARGET_BP")
load(":coverage_branch.bzl", "coverage_branch", "coverage_branch_sub_targets")
load(":providers.bzl", "MojoToolchainInfo")

# The link directory of every coverage build (cov_link_dir, kcov/defs.bzl):
# one target, so the paths of zig's C runtime sources that the debug info
# names are the same for every library.
_COVERAGE_LINK = "komira//tools/build/coverage/kcov:cov_link"

# The directory every coverage run runs from (cov_run_dir, kcov/defs.bzl):
# cov_run.sh, kcov and cov_normalize.
_COVERAGE_RUN = "komira//tools/build/coverage/kcov:cov_run"

# The directory every coverage gate runs from (cov_gate_dir,
# tools/build/coverage/defs.bzl): cov_gate.sh, covcheck and the ratchet.
_COVERAGE_GATE = "komira//tools/build/coverage:cov_gate"

# The directory every branch coverage build links and runs from
# (cov_branch_dir, tools/build/coverage/branch/defs.bzl; coverage_branch.bzl).
_COVERAGE_BRANCH = "komira//tools/build/coverage/branch:cov_branch"

# What a library's coverage gate reads (coverage_gate): `package`, its
# repository directory as covcheck names it; `files`, {repository path:
# artifact} of its sources and its test sources, and a BUCK file at
# `package` (staged as the gate's root); `test_paths`, the repository path
# of each test source it welds (each covcheck's `--test-source`);
# `reports`, its tests' Cobertura reports (its README's included);
# `branch_infos`, its tests' branch records (coverage_branch.bzl's
# `cov/branch/<test>.info`, each covcheck's `--branch-lcov`) when the gate
# reads them (_branch_gated), else none. And `markers`: what its conda
# package (tools/build/package/conda.bzl) waits for, the marker of every
# coverage run and of its gate (none of a gate for a library whose gate is
# `<name>_cov_gate`, which the conda package names itself). `run` is what a
# coverage run of another target's binary against these sources needs
# (_cov_gate_impl): the run directory, [src], its repository directory, the
# generated sources and the import name. `external_gate`: its gate is the
# target `<name>_cov_gate` (a library of the ledger, or one naming
# `coverage_tests`), so a conda package of it that does not wait for that
# target is refused (tools/build/package/conda.bzl). A library returns it
# whenever it has coverage builds.
MojoCoverageGateInfo = provider(fields = {
    "branch_infos": provider_field(typing.Any),
    "external_gate": provider_field(bool),
    "files": provider_field(typing.Any),
    "label": provider_field(typing.Any),
    "markers": provider_field(typing.Any),
    "package": provider_field(str),
    "reports": provider_field(typing.Any),
    "run": provider_field(typing.Any),
    "test_paths": provider_field(typing.Any),
})

# What a mojo_test with a coverage build gives the `<name>_cov_gate` of each
# library naming it in `coverage_tests` (coverage_test): its coverage binary
# `bin` (None when `refusal` says why it cannot run under kcov), its main
# source `src` and that source's repository path `repo_path`, its data
# {dest: artifact} and runner environment arguments, its label and the
# labels of its direct `deps`.
MojoCoverageTestInfo = provider(fields = {
    "bin": provider_field(typing.Any),
    "data": provider_field(typing.Any),
    "deps": provider_field(typing.Any),
    "env_args": provider_field(typing.Any),
    "label": provider_field(typing.Any),
    "refusal": provider_field(typing.Any),
    "repo_path": provider_field(str),
    "src": provider_field(typing.Any),
})

COVERAGE_ATTRS = {
    # A cov_link_dir: set by the mojo_library macro when coverage is on (see
    # coverage_kwargs); None otherwise. A BUCK file in the komira cell may
    # not set it.
    "coverage_debug": attrs.option(attrs.exec_dep(), default = None),
    # A cov_run_dir, set together with coverage_debug; None otherwise.
    "coverage_run": attrs.option(attrs.exec_dep(), default = None),
    # A cov_gate_dir: this library's gate, which its conda package waits for.
    # Set with coverage on, except for a library of COVERAGE_NO_GATE; None
    # otherwise.
    "coverage_gate": attrs.option(attrs.exec_dep(), default = None),
    # The gate's mode, with coverage_gate: policy.bzl's COVERAGE_MODE (a
    # fixture of the tests cell may set another).
    "coverage_mode": attrs.option(attrs.enum(["census", "neutral", "enforce"]), default = None),
    # A cov_branch_dir, set together with coverage_debug: the branch
    # coverage builds and runs of coverage_branch.bzl. None otherwise.
    "coverage_branch": attrs.option(attrs.exec_dep(), default = None),
    # Whether the gate reads the tests' branch records (`--branch-lcov`),
    # so the conda package waits for every branch coverage action (through
    # the gate). Set by the macro with coverage: whether the library is in
    # COVERAGE_BRANCH_GATE (policy.bzl); for a fixture of the tests cell,
    # True unless it passes False. False otherwise.
    "coverage_branch_gate": attrs.bool(default = False),
    # The mojo_test targets this library names in `coverage_tests`, set by
    # the macro with coverage (their runs and the gate are the target
    # `<name>_cov_gate`, so the library has no coverage_gate); [] otherwise.
    "coverage_tests": attrs.list(attrs.string(), default = []),
}

# mojo_test's: a cov_link_dir, set by the mojo_test macro when coverage is on
# (coverage_test_kwargs); None otherwise.
COVERAGE_TEST_ATTRS = {
    "coverage_debug": attrs.option(attrs.exec_dep(), default = None),
}

def coverage_on():
    """Whether `[komira] coverage` is `true`. `false` or unset is off; any
    other value fails, naming it, so a typo never turns coverage off."""
    v = read_config("komira", "coverage", "false").strip()
    if v not in ("true", "false"):
        fail("[komira] coverage = {}: it must be `true` or `false` (default false); it turns on the coverage build of every mojo_library (tools/build/mojo/README.md, Coverage builds)".format(repr(v)))
    return v == "true"

def _linux(v):
    return select({
        "komira//tools/build/package:is_linux_x86_64": v,
        "DEFAULT": None,
    })

def coverage_kwargs(kwargs):
    """Sets the coverage attributes in a mojo_library's `kwargs` when
    coverage is on. For a library of the ledger COVERAGE_NO_GATE, or one
    naming mojo_test targets in `coverage_tests` (popped from `kwargs`),
    declares its gate `<name>_cov_gate` and returns that label (its conda
    package waits for it); otherwise returns None. With coverage off,
    `coverage_tests` is dropped: it names what the coverage build runs.

    A fixture in the `tests` cell may pass `coverage_debug` itself (a
    cov_link_dir), and with it `coverage_run` (a cov_run_dir; the one every
    library uses when not given), `coverage_branch` (a cov_branch_dir;
    likewise) and `coverage_gate` (a cov_gate_dir) with
    `coverage_mode` (policy.bzl's when not given): its library then has
    coverage binaries and runs, and with `coverage_gate` the gate, whatever
    the switch says, through the directories it names, so a test can plant
    a defective tool or gate in enforce mode. Anywhere else passing any of
    them is refused.

    With coverage, `coverage_branch_gate` is whether the library is in
    COVERAGE_BRANCH_GATE (policy.bzl); a fixture of the tests cell reads
    its branch records unless it passes `coverage_branch_gate = False` (a
    gate on the side that does not read them), and anywhere else passing it
    is refused.
    """
    name = kwargs.get("name", "mojo_library")
    tests = kwargs.pop("coverage_tests", [])
    if type(tests) != type([]) or [t for t in tests if type(t) != type("")]:
        fail("{}: `coverage_tests` is a list of mojo_test labels".format(name))
    link = kwargs.get("coverage_debug")
    run = kwargs.get("coverage_run")
    gate = kwargs.get("coverage_gate")
    mode = kwargs.get("coverage_mode")
    branch = kwargs.get("coverage_branch")
    reads = kwargs.get("coverage_branch_gate")
    if reads != None and get_cell_name() != "tests":
        fail("{}: `coverage_branch_gate` is set by mojo_library from COVERAGE_BRANCH_GATE (tools/build/coverage/policy.bzl); do not pass it".format(name))
    ledger = None
    if link != None or run != None or gate != None or mode != None or branch != None:
        if get_cell_name() != "tests":
            fail("{}: `coverage_debug`, `coverage_run`, `coverage_gate` and `coverage_mode` are set by mojo_library from `[komira] coverage` and tools/build/coverage/policy.bzl, and so is `coverage_branch`; do not pass them".format(name))
        if link == None:
            fail("{}: `coverage_run`, `coverage_branch` and `coverage_gate` need `coverage_debug`: a run measures the coverage binary, and the gate reads the runs".format(name))
        if mode != None and gate == None:
            fail("{}: `coverage_mode` needs `coverage_gate`".format(name))
        run = run or _COVERAGE_RUN
        branch = branch or _COVERAGE_BRANCH
        mode = mode or COVERAGE_MODE
    elif coverage_on():
        link = _COVERAGE_LINK
        run = _COVERAGE_RUN
        branch = _COVERAGE_BRANCH
        mode = COVERAGE_MODE
        if "{}//{}:{}".format(get_cell_name(), package_name(), name) not in COVERAGE_NO_GATE:
            gate = _COVERAGE_GATE
        else:
            ledger = name + "_cov_gate"
    else:
        return None
    if tests and gate == None and ledger == None:
        fail("{}: `coverage_tests` needs `coverage_gate`: the runs of the tests it names are read by the gate alone".format(name))
    if tests or ledger:
        # The gate is a target of its own: the library cannot depend on the
        # tests it names (they depend on it), nor a library of the ledger
        # on the gate's tool (which depends on it).
        ledger = name + "_cov_gate"
        _mojo_cov_gate(name = ledger, lib = ":" + name, mode = mode, gate = gate or _COVERAGE_GATE, coverage_tests = tests)
        kwargs["coverage_tests"] = tests
        gate = None
    if get_cell_name() == "tests":
        kwargs["coverage_branch_gate"] = True if reads == None else reads
    else:
        kwargs["coverage_branch_gate"] = "{}//{}:{}".format(get_cell_name(), package_name(), name) in COVERAGE_BRANCH_GATE
    kwargs["coverage_debug"] = _linux(link)
    kwargs["coverage_run"] = _linux(run)
    kwargs["coverage_branch"] = _linux(branch)
    if gate != None:
        kwargs["coverage_gate"] = _linux(gate)
        kwargs["coverage_mode"] = mode
    return ":" + ledger if ledger else None

def coverage_link_dir(ctx):
    """The link directory of this library's coverage builds, what
    mojo_wrapper.sh takes as <zig_dir>, or None when coverage is off."""
    link = ctx.attrs.coverage_debug
    return link[DefaultInfo].default_outputs[0] if link != None else None

# The repository directory of a cell's root, for a cell whose root is not
# its repository's: the tests cell is komira's tools/build/tests
# (.buckconfig, [cells]). Every other cell's root is its repository's root:
# komira's, and that of a repository using komira as a cell, whose name komira
# does not know. A cell nested inside its repository must be listed here, or
# its reports name paths from the cell's root. A report names files by
# repository path, as covcheck reads them.
_CELL_REPO_DIR = {"tests": "tools/build/tests"}

def _dir_prefix(d):
    return d + "/" if d else ""

def _pkg_dir(label):
    """The repository directory of `label`'s package."""
    return "/".join([d for d in [_CELL_REPO_DIR.get(label.cell, ""), label.package] if d])

def coverage_sources(ctx, root):
    """Where the library's sources are measured: (src_repo, gen), the
    repository directory of its [src] (ending in `/`, or empty at the
    repository root) and the paths in [src] of its generated sources, which
    are not measured. `root` is the package directory [src] stages
    (_package_root)."""
    src_repo = _dir_prefix("/".join([d for d in [_pkg_dir(ctx.label), root] if d]))
    gen = []
    for s in ctx.attrs.srcs:
        if not s.is_source:
            rel = s.short_path
            if root:
                rel = rel[len(root) + 1:]
            gen.append(rel)
    return src_repo, gen

def coverage_branch_of(ctx, tc, t, stem, closure_tsets, mojo_cmd, link_tail, data, env_args, src_dir, root, defines):
    """The branch coverage actions of test source `t` (coverage_branch.bzl),
    as {stem: their outputs}, with `coverage_branch` set; {} otherwise. The
    arguments are coverage_branch's, but `root`, the package directory [src]
    stages (_package_root), from which its measured sources are found
    (coverage_sources)."""
    if not ctx.attrs.coverage_branch:
        return {}
    src_repo, gen = coverage_sources(ctx, root)
    return {stem: coverage_branch(ctx, tc, t, stem, closure_tsets, mojo_cmd, link_tail, data, env_args, src_dir, src_repo, gen, defines)}

def _run_facts(ctx, src_dir, import_name, root):
    """What a coverage run of a binary against this library's sources needs
    (MojoCoverageGateInfo's `run`): the run directory, [src] (`src_dir`, it
    ends in `src/<import_name>`), its repository directory and the paths in
    it of its generated sources (coverage_sources over `root`, the package
    directory [src] stages), the import name and the package's directory."""
    src_repo, gen = coverage_sources(ctx, root)
    return struct(
        dir = ctx.attrs.coverage_run[DefaultInfo].default_outputs[0],
        gen = gen,
        import_name = import_name,
        pkg_dir = _pkg_dir(ctx.label),
        src_dir = src_dir,
        src_repo = src_repo,
    )

def _cov_run(actions, tc, facts, label, where, t, name, stem, cov_bin, test_repo, data, env_args, solib = None):
    """Declares the `mojo_cov_run` action of the coverage binary `cov_bin`
    of test source `t` (staged at `name`, the path its line tables name it
    by, with its `data`), run under kcov by cov_run.sh of `facts.dir`
    against the library sources of `facts` (_run_facts), through the
    release gate's runner with `env_args`, as `label`. `test_repo` is the
    path the report names `t` by; `solib` as coverage_run's. Returns
    (report, marker):
    `cov/tests/<stem>.xml`, the Cobertura report in repository paths, and
    `cov/tests/<stem>.passed`."""
    for dest in data:
        if dest == name or dest.startswith(name + "/") or name.startswith(dest + "/"):
            fail("{}: the test's data destination {} collides with its source, which a coverage run stages at {}".format(where, repr(dest), repr(name)))
        # cov_run.sh stages [src] at <import_name>/, where the line tables
        # name its sources; for a shared library's driver, which names none
        # of it, at its own path under buck-out/ (its sources are data).
        stage = "buck-out" if solib else facts.import_name
        if dest == stage or dest.startswith(stage + "/"):
            fail("{}: the data destination {} is under {}/, where a coverage run stages the library's sources".format(where, repr(dest), stage))
    share = actions.copied_dir("cov/tests/{}/share".format(stem), dict(data) | {name: t})
    gen = []
    for rel in facts.gen:
        gen += ["--gen", rel]
    xml = actions.declare_output("cov/tests/{}.xml".format(stem))
    marker = actions.declare_output("cov/tests/{}.passed".format(stem))
    actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            facts.dir.project("cov_run.sh"),
            tc.busybox,
            tc.gate_runner,
            tc.compiler,
            label,
            cov_bin,
            share,
            facts.src_dir,
            xml.as_output(),
            marker.as_output(),
            facts.src_repo,
            name,
            test_repo,
            facts.import_name,
            ["--solib", solib[0]] + [a for p in solib[1] for a in ("--solib-src", p)] if solib else [],
            gen,
            env_args,
            hidden = facts.dir,
        ),
        category = "mojo_cov_run",
        identifier = stem,
    )
    return xml, marker

def coverage_run(ctx, tc, t, stem, cov_bin, src_dir, import_name, root, data, env_args, solib = None):
    """Declares the `mojo_cov_run` action of test source `t`: its coverage
    binary `cov_bin` run under kcov by cov_run.sh, through the release gate's
    runner with the gate's environment (`env_args`) and data (`data`, staged
    as the gate stages it). `src_dir` is the library's [src] (it ends in
    `src/<import_name>`; the run stages it at `<import_name>/`, the directory
    the binary's line tables name its sources by) and `root` the package
    directory it stages (_package_root). `solib`, for a shared library's driver
    (coverage_shared_lib): (the library's file in `data`, which the driver
    loads, and its sources, also in `data` at their paths in the package,
    `main` first), cov_run.sh's `--solib` and `--solib-src`: kcov measures
    the libraries the driver loads, and the report must hold `main`.
    Returns (report, marker):
    `cov/tests/<stem>.xml`, the test's Cobertura report in repository paths,
    and `cov/tests/<stem>.passed`."""
    facts = _run_facts(ctx, src_dir, import_name, root)
    where = "{}: coverage run of {}".format(ctx.label.raw_target(), t.short_path)
    label = "{}:{} [coverage]".format(ctx.label.raw_target(), t.short_path)
    return _cov_run(ctx.actions, tc, facts, label, where, t, t.short_path, stem, cov_bin, _dir_prefix(facts.pkg_dir) + t.short_path, data, env_args, solib)

# The program a README with no example gives the coverage build: the
# README's own program is then a comment (readme_examples), which does not
# compile, and whether it is one is known only when the build reads it.
_README_STUB = "def main():\n    print(\"NO EXAMPLE: this README holds no example\")\n"

def coverage_readme(ctx, tc, build, readme, closure, link_tail, src_dir, import_name, root, env_args, bins, runs):
    """With coverage, the README's examples as a test (`readme`, the
    (marker, program, count) of defs.bzl's _readme_gate): the program, or
    _README_STUB when the README holds no example (a
    `mojo_cov_readme_source` action reads the count), built at -O0 with
    line tables against `closure` (the ungated package, as the README's
    gated run is) through `build` (defs.bzl's _build_executable, its link
    `link_tail` as the gated run's), and run under kcov with the library's
    `env_args`. Adds them to `bins` and `runs` as `readme`. Its report names
    the program `buck-out/readme/<package>/readme_<import>.mojo`: no
    repository file, which covcheck counts outside the repository, so only
    the library's lines it reached count."""
    program, count = readme[1], readme[2]
    src = ctx.actions.declare_output("cov/tests/readme/" + program.basename)
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            "-c",
            'if [ "$("$1" cat "$2")" = 0 ]; then printf "%s" "$4" >"$5"; else "$1" cp "$3" "$5"; fi',
            "cov_readme_source",
            tc.busybox,
            count,
            program,
            _README_STUB,
            src.as_output(),
        ),
        category = "mojo_cov_readme_source",
    )
    stem = program.basename[:-len(".mojo")]
    bins["readme"] = build(ctx, tc, "cov/tests/readme/" + stem, [src], src, [closure], "0", "mojo_build_cov_test", "readme", None, link_extra = link_tail, debug_link = coverage_link_dir(ctx))
    facts = _run_facts(ctx, src_dir, import_name, root)
    where = "{}: coverage run of README.md".format(ctx.label.raw_target())
    label = "{}:README.md [coverage]".format(ctx.label.raw_target())
    runs["readme"] = _cov_run(ctx.actions, tc, facts, label, where, src, src.short_path, "readme", bins["readme"], "buck-out/readme/" + _dir_prefix(facts.pkg_dir) + program.basename, {}, env_args)

def coverage_test_kwargs(rule):
    """mojo_test's macro around `rule`: sets `coverage_debug` when coverage
    is on, its coverage binary, which the `<name>_cov_gate` of each library
    naming it in `coverage_tests` runs. A fixture of the tests cell may pass
    it (a cov_link_dir); anywhere else passing it is refused."""
    def macro(**kwargs):
        link = kwargs.get("coverage_debug")
        if link != None and get_cell_name() != "tests":
            fail("{}: `coverage_debug` is set by mojo_test from `[komira] coverage`; do not pass it".format(kwargs.get("name", "mojo_test")))
        if link == None and coverage_on():
            link = _COVERAGE_LINK
        if link != None:
            kwargs["coverage_debug"] = _linux(link)
        rule(**kwargs)
    return macro

def coverage_test(ctx, tc, build, main, closure, c_link, defines, data, env_args):
    """A mojo_test's coverage build, with `coverage_debug`: (sub_targets,
    providers), `[coverage][bin]` and MojoCoverageTestInfo; ({}, [])
    otherwise. The binary is the test's main (`main`, with its other `srcs`)
    built at -O0 with line tables against its `deps` (`closure`, `c_link`)
    with its `defines`, through `build` (defs.bzl's _build_executable). A
    test whose main is generated, or with `args` (a coverage run passes
    none), has no binary, and its MojoCoverageTestInfo says why."""
    link = coverage_link_dir(ctx)
    if link == None:
        return {}, []
    refusal = None
    if not main.is_source:
        refusal = "its main source {} is generated".format(main.short_path)
    elif ctx.attrs.args:
        refusal = "it has `args`, which a coverage run does not pass"
    exe = None
    sub = {}
    if refusal == None:
        srcs = ctx.attrs.srcs if main in ctx.attrs.srcs else ctx.attrs.srcs + [main]
        exe = build(ctx, tc, "cov/" + ctx.label.name, srcs, main, closure, "0", "mojo_build_cov_test", None, c_link, debug_link = link, defines = defines)
        sub = {"coverage": [DefaultInfo(default_output = exe, sub_targets = {"bin": [DefaultInfo(default_output = exe)]})]}
    return sub, [MojoCoverageTestInfo(
        bin = exe,
        data = data,
        deps = [str(d.label.raw_target()) for d in ctx.attrs.deps],
        env_args = env_args,
        label = str(ctx.label.raw_target()),
        refusal = refusal,
        repo_path = _dir_prefix(_pkg_dir(ctx.label)) + main.short_path,
        src = main,
    )]

def coverage_sub_targets(bins, runs, gate, branch):
    """The `coverage` sub-target of a library: `bins` {stem: binary},
    `runs` {stem: (report, marker)}, `gate` (coverage_gate's, or None) and
    `branch` {stem: coverage_branch's struct} (coverage_branch.bzl: `[bc]`,
    `[pgo_bin]`, `[branch]`, `[branch_ir]` and `[branch_info]`, which are
    not among `[coverage]`'s outputs)."""
    b = [bins[k] for k in sorted(bins)]
    x = [runs[k][0] for k in sorted(runs)]
    m = [runs[k][1] for k in sorted(runs)]
    g = {}
    if gate != None:
        x = x + [gate.result, gate.summary]
        m = m + [gate.marker]
        g = {"gate": [DefaultInfo(
            default_outputs = [gate.result, gate.summary],
            other_outputs = [gate.marker],
            sub_targets = {
                "result": [DefaultInfo(default_output = gate.result, other_outputs = [gate.marker])],
                "summary": [DefaultInfo(default_output = gate.summary, other_outputs = [gate.marker])],
            },
        )]}
    return {"coverage": [DefaultInfo(
        default_outputs = b + x,
        other_outputs = m,
        sub_targets = g | coverage_branch_sub_targets(branch) | {
            "bin": [DefaultInfo(
                default_outputs = b,
                sub_targets = {k: [DefaultInfo(default_output = v)] for k, v in bins.items()},
            )],
            "tests": [DefaultInfo(
                default_outputs = x,
                other_outputs = m,
                sub_targets = {k: [DefaultInfo(default_output = v[0], other_outputs = [v[1]])] for k, v in runs.items()},
            )],
        },
    )]}

def _branch_gated(ctx):
    """Whether this library's gate reads its tests' branch records: its
    `coverage_branch_gate` (coverage_kwargs sets it)."""
    return ctx.attrs.coverage_branch_gate

def _gate_inputs(ctx, runs, branch, markers, run, srcs = None, tests_srcs = None):
    """The MojoCoverageGateInfo of this library: its non-generated sources
    and its test sources at their repository paths, a BUCK file at its
    package, the list of its test sources, its tests' reports (`runs`
    {stem: (report, marker)}), when it reads them (_branch_gated) their
    branch records (`branch` {stem: coverage_branch's struct}), `markers`
    and `run` (_run_facts; None for a shared library, whose gate is its
    own). `srcs` and `tests_srcs` replace the library's `srcs` and
    `test_srcs` (a shared library's sources and drivers)."""
    where = "{}: coverage gate".format(ctx.label.raw_target())
    pkg = _pkg_dir(ctx.label)
    files = {}
    for s in ctx.attrs.srcs if srcs == None else srcs:
        if s.is_source:
            files[_dir_prefix(pkg) + s.short_path] = s
    # Every welded test is named to covcheck (`--test-source`), which sets
    # it aside wherever it is in the package: a test outside tests/
    # (`wire/tests/`, the package's top) is not the library's source. A
    # generated test is named by its output path in the package, as its
    # report names it (coverage_run).
    tests = []
    for t in ctx.attrs.test_srcs if tests_srcs == None else tests_srcs:
        if _dir_prefix(pkg) + t.short_path in files:
            fail("{}: the test {} has the path of a source of the library".format(where, t.short_path))
        files[_dir_prefix(pkg) + t.short_path] = t
        tests.append(_dir_prefix(pkg) + t.short_path)
    for path in files:
        if "\n" in path:
            fail("{}: the source path {} holds a newline".format(where, repr(path)))
    files[_dir_prefix(pkg) + "BUCK"] = ctx.actions.write(
        "cov/gate/BUCK",
        "# The package of {}, for covcheck's nearest-BUCK rule (a coverage gate's staged sources).\n".format(ctx.label.raw_target()),
    )
    return MojoCoverageGateInfo(
        branch_infos = [branch[k].info for k in sorted(branch)] if branch and _branch_gated(ctx) else [],
        external_gate = run != None and (bool(ctx.attrs.coverage_tests) or str(ctx.label.raw_target()) in COVERAGE_NO_GATE),
        files = files,
        label = ctx.label.raw_target(),
        markers = markers,
        package = pkg or "(root)",
        reports = [runs[k][0] for k in sorted(runs)],
        run = run,
        test_paths = sorted(tests),
    )

def _checked_info_dirs(dirs):
    """COVERAGE_INFO_ONLY_DIRS (policy.bzl), each a directory relative to a
    cell's root: not empty, no leading or trailing `/`, no empty, `.` or
    `..` segment. Fails at load naming the entry otherwise: a malformed
    entry would match no package and hold the test-only packages it meant
    to the target, silently."""
    for d in dirs:
        if type(d) != "string" or d == "" or d.startswith("/") or d.endswith("/") or [s for s in d.split("/") if s in ("", ".", "..")]:
            fail("COVERAGE_INFO_ONLY_DIRS (tools/build/coverage/policy.bzl): {} is not a directory relative to a cell's root (no leading or trailing /, no empty, . or .. segment)".format(repr(d)))
    return dirs

_INFO_DIRS = _checked_info_dirs(COVERAGE_INFO_ONLY_DIRS)

def _info_only(label):
    """Whether `label`'s package is test-only: its directory, relative to its
    cell's root, is one of COVERAGE_INFO_ONLY_DIRS (policy.bzl) or under one,
    at a segment boundary (`src/tests` covers `src/tests/x`, not
    `src/testsuite`)."""
    for d in _INFO_DIRS:
        if label.package == d or label.package.startswith(d + "/"):
            return True
    return False

def _gate_action(actions, bb, gate_dir, mode, info, prefix):
    """Declares the `mojo_cov_gate` action of `info` (MojoCoverageGateInfo):
    cov_gate.sh of `gate_dir` (a cov_gate_dir dependency) in `mode` over
    `info.files` staged as `<prefix>root` and the list of its test sources
    `<prefix>tests.txt`, writing `<prefix>result.json`, `<prefix>summary.md`
    and `<prefix>gate.passed`. The branch records follow the reports after
    the argument `--branch-lcov` (none, and no such argument, for a library
    with no test). For a test-only package (_info_only), `--info-package`
    and its package come before the reports."""
    d = gate_dir[DefaultInfo].default_outputs[0]
    root = actions.copied_dir(prefix + "root", info.files)
    tests = actions.write(prefix + "tests.txt", "".join([t + "\n" for t in info.test_paths]))
    result = actions.declare_output(prefix + "result.json")
    summary = actions.declare_output(prefix + "summary.md")
    marker = actions.declare_output(prefix + "gate.passed")
    actions.run(
        cmd_args(
            bb,
            "sh",
            d.project("cov_gate.sh"),
            bb,
            "{} [coverage gate]".format(info.label),
            info.package,
            mode,
            str(COVERAGE_TARGET_BP),
            root,
            tests,
            result.as_output(),
            summary.as_output(),
            marker.as_output(),
            ["--info-package", info.package] if _info_only(info.label) else [],
            info.reports,
            ["--branch-lcov"] + info.branch_infos if info.branch_infos else [],
            hidden = d,
        ),
        category = "mojo_cov_gate",
    )
    return struct(marker = marker, result = result, summary = summary)

def _check_tools(ctx):
    """Outside the tests cell, the coverage attributes are what the macro
    sets (coverage_kwargs): komira's link, run and gate directories, and a
    gate unless the library is of the ledger COVERAGE_NO_GATE or names
    mojo_test targets in `coverage_tests` (its gate is then
    `<name>_cov_gate`). A BUCK file loading the rule itself cannot give a
    library a lenient gate (its own ratchet, a script that passes a
    failure) or runs with no gate, unless it names `coverage_tests`: the
    rule cannot see whether `<name>_cov_gate` exists (the macro always
    declares it with them), so its MojoCoverageGateInfo says
    `external_gate`, and a conda package of it that waits for no
    `<name>_cov_gate` is refused (tools/build/package/conda.bzl)."""
    if ctx.label.cell == "tests":
        return
    where = ctx.label.raw_target()
    for attr, want in (("coverage_debug", _COVERAGE_LINK), ("coverage_run", _COVERAGE_RUN), ("coverage_branch", _COVERAGE_BRANCH), ("coverage_gate", _COVERAGE_GATE)):
        d = getattr(ctx.attrs, attr)
        if d != None and str(d.label.raw_target()) != want:
            fail("{}: {} is {}, not {}: only a fixture of the tests cell may name another (tools/build/mojo/coverage.bzl)".format(where, attr, d.label.raw_target(), want))
    if ctx.attrs.coverage_gate == None and str(where) not in COVERAGE_NO_GATE and not ctx.attrs.coverage_tests:
        fail("{}: coverage builds with no coverage_gate: its conda package would wait for no coverage gate; only a library of the ledger COVERAGE_NO_GATE (tools/build/coverage/policy.bzl), one naming `coverage_tests` (whose gate is `<name>_cov_gate`) or a fixture of the tests cell may".format(where))
    if ctx.attrs.coverage_gate != None and ctx.attrs.coverage_tests:
        fail("{}: coverage_gate and coverage_tests: the gate of a library naming mojo_test targets is `<name>_cov_gate`, which reads their runs".format(where))
    if ctx.attrs.coverage_branch_gate != (str(where) in COVERAGE_BRANCH_GATE):
        fail("{}: coverage_branch_gate is {}, but the library is {}in COVERAGE_BRANCH_GATE (tools/build/coverage/policy.bzl); only a fixture of the tests cell may set it".format(where, ctx.attrs.coverage_branch_gate, "" if str(where) in COVERAGE_BRANCH_GATE else "not "))

def coverage_gate(ctx, tc, runs, branch, src_dir, import_name, root):
    """The coverage gate of a library with coverage builds (`runs` {stem:
    (report, marker)}, possibly empty, and `branch` {stem: coverage_branch's
    struct}, the same tests' branch records; `src_dir`, `import_name` and
    `root` as coverage_run's). Returns (gate, providers): the
    gate's outputs (a struct for coverage_sub_targets, or None without
    coverage_gate: a library of the ledger or naming `coverage_tests`, or a
    tests-cell fixture's runs alone) and [MojoCoverageGateInfo], whose
    `markers` (every run's, and the gate's, which reads the branch records
    when the library is gated on them) its conda package waits for. Nothing
    of the library waits for them: its package is the one it has with the
    switch off."""
    _check_tools(ctx)
    markers = [runs[k][1] for k in sorted(runs)]
    run = _run_facts(ctx, src_dir, import_name, root)
    gate_dir = ctx.attrs.coverage_gate
    if gate_dir == None:
        return None, [_gate_inputs(ctx, runs, branch, markers, run)]
    mode = ctx.attrs.coverage_mode
    if mode == None:
        fail("{}: coverage_gate needs coverage_mode".format(ctx.label.raw_target()))
    if mode != COVERAGE_MODE and ctx.label.cell != "tests":
        fail("{}: coverage_mode is {}, but the policy's is {} (tools/build/coverage/policy.bzl); only a fixture of the tests cell may set another".format(ctx.label.raw_target(), mode, COVERAGE_MODE))
    # The info returned is the gate's inputs, with the gate's own marker
    # added to `markers`.
    pre = _gate_inputs(ctx, runs, branch, markers, run)
    gate = _gate_action(ctx.actions, tc.busybox, gate_dir, mode, pre, "cov/gate/")
    return gate, [MojoCoverageGateInfo(
        branch_infos = pre.branch_infos,
        external_gate = pre.external_gate,
        files = pre.files,
        label = pre.label,
        markers = markers + [gate.marker],
        package = pre.package,
        reports = pre.reports,
        run = pre.run,
        test_paths = pre.test_paths,
    )]

def _test_runs(ctx, tc, info):
    """The coverage run of each mojo_test of `tests` against the library of
    `info` (its MojoCoverageGateInfo): {name: (report, marker)}, and the
    gate's inputs with their reports, their sources (one in the library's
    package set aside as `--test-source`; one in another package staged
    with a BUCK file at that package, whose files the gate does not
    measure) added."""
    runs = {}
    files = dict(info.files)
    tests = list(info.test_paths)
    for dep in ctx.attrs.coverage_tests:
        where = "{}: coverage_tests of {}: {}".format(ctx.label.raw_target(), info.label, dep.label.raw_target())
        if MojoCoverageTestInfo not in dep:
            fail("{} is not a mojo_test with a coverage build".format(where))
        t = dep[MojoCoverageTestInfo]
        if t.refusal != None:
            fail("{} cannot run under kcov: {}".format(where, t.refusal))
        if str(info.label) not in t.deps:
            fail("{} does not name {} in its deps: a test covers a library it imports".format(where, info.label))
        name = dep.label.name
        if name in runs or name == "readme":
            fail("{}: two coverage tests are named {} (or one is named readme)".format(where, name))
        label = "{} [coverage of {}]".format(t.label, info.label)
        runs[name] = _cov_run(ctx.actions, tc, info.run, label, where, t.src, t.src.short_path, name, t.bin, t.repo_path, t.data, t.env_args)
        files[t.repo_path] = t.src
        tpkg = _pkg_dir(dep.label)
        if tpkg == info.run.pkg_dir:
            tests.append(t.repo_path)
        else:
            files[_dir_prefix(tpkg) + "BUCK"] = ctx.actions.write(
                "cov/tests/{}/BUCK".format(name),
                "# The package of {}, for covcheck's nearest-BUCK rule: its files are not {}'s.\n".format(t.label, info.label),
            )
    return runs, MojoCoverageGateInfo(
        branch_infos = info.branch_infos,
        external_gate = info.external_gate,
        files = files,
        label = info.label,
        markers = info.markers,
        package = info.package,
        reports = info.reports + [runs[k][0] for k in sorted(runs)],
        run = info.run,
        test_paths = sorted(tests),
    )

def _cov_gate_impl(ctx):
    if MojoCoverageGateInfo not in ctx.attrs.lib:
        # No coverage builds on this target platform (the select above).
        return [DefaultInfo()]
    if ctx.attrs.mode != COVERAGE_MODE and ctx.label.cell != "tests":
        fail("{}: mode is {}, but the policy's is {}".format(ctx.label.raw_target(), ctx.attrs.mode, COVERAGE_MODE))
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    runs, info = _test_runs(ctx, tc, ctx.attrs.lib[MojoCoverageGateInfo])
    g = _gate_action(ctx.actions, tc.busybox, ctx.attrs.gate, ctx.attrs.mode, info, "")
    reports = [runs[k][0] for k in sorted(runs)]
    markers = [runs[k][1] for k in sorted(runs)]
    return [DefaultInfo(
        default_outputs = [g.marker] + markers,
        other_outputs = [g.result, g.summary] + reports,
        sub_targets = {
            "gate": [DefaultInfo(
                default_outputs = [g.result, g.summary],
                other_outputs = [g.marker],
                sub_targets = {
                    "result": [DefaultInfo(default_output = g.result, other_outputs = [g.marker])],
                    "summary": [DefaultInfo(default_output = g.summary, other_outputs = [g.marker])],
                },
            )],
            "tests": [DefaultInfo(
                default_outputs = reports,
                other_outputs = markers,
                sub_targets = {k: [DefaultInfo(default_output = v[0], other_outputs = [v[1]])] for k, v in runs.items()},
            )],
        },
    )]

# The gate of a library that cannot have it as an action of its own: one of
# the ledger COVERAGE_NO_GATE (policy.bzl), which would depend on the gate's
# tool, which depends on the library, or one naming mojo_test targets in
# `coverage_tests`, which depend on it (a cycle of configured targets,
# whatever waits for the gate). The same action as a library's
# [coverage][gate], over the library's MojoCoverageGateInfo and the
# coverage runs of `tests` against its sources (`[tests][<test>]`). Its
# default outputs are the gate's marker and those runs' markers, which the
# library's conda package waits for; `[gate]` is the result and summary.
_mojo_cov_gate = rule(
    impl = _cov_gate_impl,
    attrs = {
        "gate": attrs.exec_dep(default = _COVERAGE_GATE),
        "lib": attrs.dep(),
        "mode": attrs.string(),
        "coverage_tests": attrs.list(attrs.dep(), default = []),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

# ---- mojo_shared_lib --------------------------------------------------------

# The coverage attributes of mojo_shared_lib: a library's, but those of
# branch coverage (a shared library's drivers have no branch coverage run).
COVERAGE_SHARED_LIB_ATTRS = {k: COVERAGE_ATTRS[k] for k in ("coverage_debug", "coverage_run", "coverage_gate", "coverage_mode")}

def _not_enforced(where, mode):
    if mode == "enforce":
        fail("{}: a mojo_shared_lib's coverage gate is reported, never enforced (COVERAGE_SHARED_LIB_MODE, tools/build/coverage/policy.bzl): mode `enforce` is refused".format(where))

def _coverage_shared_lib_kwargs(kwargs):
    """Sets the coverage attributes in a mojo_shared_lib's `kwargs` when
    coverage is on: komira's link, run and gate directories, and the mode
    COVERAGE_SHARED_LIB_MODE (policy.bzl). A fixture of the tests cell may
    pass `coverage_debug`, and with it `coverage_run`, `coverage_gate` and
    `coverage_mode`, as a library's may (coverage_kwargs); anywhere else
    passing them is refused. Mode `enforce` is refused in analysis
    (_check_shared_tools), for every shared library."""
    name = kwargs.get("name", "mojo_shared_lib")
    link = kwargs.get("coverage_debug")
    run = kwargs.get("coverage_run")
    gate = kwargs.get("coverage_gate")
    mode = kwargs.get("coverage_mode")
    if link != None or run != None or gate != None or mode != None:
        if get_cell_name() != "tests":
            fail("{}: `coverage_debug`, `coverage_run`, `coverage_gate` and `coverage_mode` are set by mojo_shared_lib from `[komira] coverage` and tools/build/coverage/policy.bzl; do not pass them".format(name))
        if link == None:
            fail("{}: `coverage_run` and `coverage_gate` need `coverage_debug`: a run measures the coverage build, and the gate reads the runs".format(name))
        if mode != None and gate == None:
            fail("{}: `coverage_mode` needs `coverage_gate`".format(name))
        run = run or _COVERAGE_RUN
        mode = mode or COVERAGE_SHARED_LIB_MODE
    elif coverage_on():
        link, run, gate, mode = _COVERAGE_LINK, _COVERAGE_RUN, _COVERAGE_GATE, COVERAGE_SHARED_LIB_MODE
    else:
        return
    kwargs["coverage_debug"] = _linux(link)
    kwargs["coverage_run"] = _linux(run)
    if gate != None:
        kwargs["coverage_gate"] = _linux(gate)
        kwargs["coverage_mode"] = mode

def coverage_shared_lib_macro(rule):
    """mojo_shared_lib: `rule`, its coverage attributes set by the switch
    (_coverage_shared_lib_kwargs)."""
    def macro(**kwargs):
        _coverage_shared_lib_kwargs(kwargs)
        rule(**kwargs)
    return macro

def _check_shared_tools(ctx):
    """A shared library's gate is never in enforce mode; outside the tests
    cell its coverage attributes are what the macro sets (komira's link, run
    and gate directories, COVERAGE_SHARED_LIB_MODE), so a BUCK file calling
    the rule itself cannot give it others."""
    where = ctx.label.raw_target()
    _not_enforced(where, ctx.attrs.coverage_mode)
    if ctx.label.cell == "tests":
        return
    for attr, want in (("coverage_debug", _COVERAGE_LINK), ("coverage_run", _COVERAGE_RUN), ("coverage_gate", _COVERAGE_GATE)):
        d = getattr(ctx.attrs, attr)
        if d == None or str(d.label.raw_target()) != want:
            fail("{}: {} is {}, not {}: only a fixture of the tests cell may name another (tools/build/mojo/coverage.bzl)".format(where, attr, d.label.raw_target() if d else None, want))
    if ctx.attrs.coverage_mode != COVERAGE_SHARED_LIB_MODE:
        fail("{}: coverage_mode is {}, but the policy's for a shared library is {} (COVERAGE_SHARED_LIB_MODE, tools/build/coverage/policy.bzl)".format(where, ctx.attrs.coverage_mode, COVERAGE_SHARED_LIB_MODE))

def coverage_shared_lib(ctx, tc, build, srcs, main, closure, c_link, link_extra, so_file):
    """The `coverage` sub-target of a mojo_shared_lib with coverage builds
    (`coverage_debug` set), as {"coverage": ...}; {} without. `build` is
    defs.bzl's _build_executable, and the rest what the release build of
    the library is given: its sources, `main`, the closure of its Mojo
    dependencies, its C libraries, its extra link arguments and its file
    name.

    - The library built again at -O0 with line tables through the coverage
      link directory (its sources named by their paths in the package, as
      a test's): `[coverage][bin][<file>]` (category
      `mojo_build_cov_shared_lib`).
    - Each driver of `gate_srcs`, written or generated, at -O0 with line
      tables: `[coverage][bin][<driver>]` (`mojo_build_cov_driver`), run
      under kcov through the release gate's runner with that build as its
      data, where the release gate stages the library, and the library's
      sources at their paths in the package, and kcov measuring the
      libraries the driver loads (cov_run.sh `--solib`):
      `[coverage][tests][<driver>]` (`mojo_cov_run`). The generated exports
      driver is not run: it only loads the library and looks its symbols up.
    - The gate, `covcheck gate` over those reports, the library's
      non-generated sources and each driver set aside (`--test-source`),
      in COVERAGE_SHARED_LIB_MODE: `[coverage][gate]` (`mojo_cov_gate`).

    A driver's report counts the library's own sources (`srcs` and `main`),
    none of its Mojo dependencies compiled into it: a library's gate reads
    its own tests' reports only, so its numbers do not depend on which
    shared library links it. Nothing waits for any of it: the published
    file and the release gate are what they are with coverage off."""
    link = coverage_link_dir(ctx)
    if link == None:
        return {}
    _check_shared_tools(ctx)
    # cov_run.sh's [src] (it names nothing the library's build names: that
    # names its sources by their paths in the package, given as data).
    out_name = so_file[:so_file.rfind(".")]
    src_dir = ctx.actions.copied_dir("cov/src/" + out_name, {s.short_path: s for s in srcs})
    so = build(ctx, tc, "cov/" + so_file, srcs, main, closure, "0", "mojo_build_cov_shared_lib", None, c_link, abi_lib = True, link_extra = link_extra, debug_link = link)
    data = {so_file: so} | {s.short_path: s for s in srcs}
    names = [s.short_path for s in [main] + sorted([s for s in srcs if s != main], key = lambda s: s.short_path) if s.is_source]
    bins, runs = {so_file: so}, {}
    for g in ctx.attrs.gate_srcs:
        stem = g.basename.removesuffix(".mojo")
        bins[stem] = build(ctx, tc, "cov/drivers/{}/{}".format(stem, stem), [g], g, [], "0", "mojo_build_cov_driver", stem, None, debug_link = link)
        runs[stem] = coverage_run(ctx, tc, g, stem, bins[stem], src_dir, out_name, "", data, [], solib = (so_file, names))
    gate = None
    if ctx.attrs.coverage_gate != None:
        info = _gate_inputs(ctx, runs, {}, [], None, srcs, ctx.attrs.gate_srcs)
        gate = _gate_action(ctx.actions, tc.busybox, ctx.attrs.coverage_gate, ctx.attrs.coverage_mode, info, "cov/gate/")
    return coverage_sub_targets(bins, runs, gate, {})
