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
  (category `mojo_cov_run`, `cov_run.sh` in the same directory).

and, per library (tests or none):

- the gate: `covcheck gate` over those reports and the library's sources,
  in the mode of tools/build/coverage/policy.bzl, whose result.json and
  summary.md are `[coverage][gate]` (category `mojo_cov_gate`, cov_gate.sh
  of tools/build/coverage).

What ships, the library's conda package (`<name>_conda`, its joins
`conda_join` and `conda_release_join`), then also waits for every coverage
run and the gate, through the library's MojoCoverageGateInfo: a test failing
at -O0 or under kcov, or a gate failing in enforce mode, leaves the conda
package unbuilt. The library's own package (`mojo_gate_join`, what
dependents compile against) does not wait for them: a library whose
coverage is red still builds, and so do its dependents. A library with no
test still has a gate (it has no report: NotMeasured), which its conda
package waits for. The libraries the gate's own tool depends on
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
`select` below), so the library builds as with the switch off.

Scope: a library's `test_srcs`. A README's examples, `mojo_test`,
`mojo_shared_lib` drivers and generated test sources get no coverage binary,
and generated library sources are not measured (nor staged for the gate): a
library every source of which is generated (a mojo_aws_client or
mojo_gcp_client, whose hand-written sources pass through its generator too)
is NotMeasured in its gate.
"""

load("@komira//tools/build/coverage:policy.bzl", "COVERAGE_MODE", "COVERAGE_NO_GATE", "COVERAGE_TARGET_BP")
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

# What a library's coverage gate reads (coverage_gate): `package`, its
# repository directory as covcheck names it; `root`, its sources at their
# repository paths with a BUCK file at `package`; `tests`, a file naming
# the repository path of each test source it welds, one per line (each one
# covcheck's `--test-source`); `reports`, its tests' Cobertura reports. And
# `markers`: what its conda package (tools/build/package/conda.bzl) waits
# for, the marker of every coverage run and of its gate (none of a gate
# for a library of the ledger, whose `<name>_cov_gate` the conda package
# names itself). A library returns it whenever it has coverage builds.
MojoCoverageGateInfo = provider(fields = {
    "label": provider_field(typing.Any),
    "markers": provider_field(typing.Any),
    "package": provider_field(str),
    "reports": provider_field(typing.Any),
    "root": provider_field(typing.Any),
    "tests": provider_field(typing.Any),
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
    coverage is on. For a library of the ledger COVERAGE_NO_GATE, declares
    its gate `<name>_cov_gate` and returns that label (its conda package
    waits for it); otherwise returns None.

    A fixture in the `tests` cell may pass `coverage_debug` itself (a
    cov_link_dir), and with it `coverage_run` (a cov_run_dir; the one every
    library uses when not given) and `coverage_gate` (a cov_gate_dir) with
    `coverage_mode` (policy.bzl's when not given): its library then has
    coverage binaries and runs, and with `coverage_gate` the gate, whatever
    the switch says, through the directories it names, so a test can plant
    a defective tool or gate in enforce mode. Anywhere else passing any of
    them is refused.
    """
    name = kwargs.get("name", "mojo_library")
    link = kwargs.get("coverage_debug")
    run = kwargs.get("coverage_run")
    gate = kwargs.get("coverage_gate")
    mode = kwargs.get("coverage_mode")
    ledger = None
    if link != None or run != None or gate != None or mode != None:
        if get_cell_name() != "tests":
            fail("{}: `coverage_debug`, `coverage_run`, `coverage_gate` and `coverage_mode` are set by mojo_library from `[komira] coverage` and tools/build/coverage/policy.bzl; do not pass them".format(name))
        if link == None:
            fail("{}: `coverage_run` and `coverage_gate` need `coverage_debug`: a run measures the coverage binary, and the gate reads the runs".format(name))
        if mode != None and gate == None:
            fail("{}: `coverage_mode` needs `coverage_gate`".format(name))
        run = run or _COVERAGE_RUN
        mode = mode or COVERAGE_MODE
    elif coverage_on():
        link = _COVERAGE_LINK
        run = _COVERAGE_RUN
        mode = COVERAGE_MODE
        if "{}//{}:{}".format(get_cell_name(), package_name(), name) in COVERAGE_NO_GATE:
            ledger = name + "_cov_gate"
            _mojo_cov_gate(name = ledger, lib = ":" + name, mode = mode)
        else:
            gate = _COVERAGE_GATE
    else:
        return None
    kwargs["coverage_debug"] = _linux(link)
    kwargs["coverage_run"] = _linux(run)
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

def coverage_run(ctx, tc, t, stem, cov_bin, src_dir, import_name, root, data, env_args):
    """Declares the `mojo_cov_run` action of test source `t`: its coverage
    binary `cov_bin` run under kcov by cov_run.sh, through the release gate's
    runner with the gate's environment (`env_args`) and data (`data`, staged
    as the gate stages it). `src_dir` is the library's [src] (it ends in
    `src/<import_name>`) and `root` the package directory it stages
    (_package_root). Returns (report, marker):
    `cov/tests/<stem>.xml`, the test's Cobertura report in repository paths,
    and `cov/tests/<stem>.passed`."""
    where = "{}: coverage run of {}".format(ctx.label.raw_target(), t.short_path)
    name = t.short_path
    for dest in data:
        if dest == name or dest.startswith(name + "/") or name.startswith(dest + "/"):
            fail("{}: the test's data destination {} collides with its source, which a coverage run stages at {}".format(where, repr(dest), repr(name)))
        if dest == "buck-out" or dest.startswith("buck-out/"):
            fail("{}: the data destination {} is under buck-out/, where a coverage run stages the library's sources".format(where, repr(dest)))
    share = ctx.actions.copied_dir("cov/tests/{}/share".format(stem), dict(data) | {name: t})
    pkg_dir = _pkg_dir(ctx.label)
    src_repo = _dir_prefix("/".join([d for d in [pkg_dir, root] if d]))
    gen = []
    for s in ctx.attrs.srcs:
        if not s.is_source:
            rel = s.short_path
            if root:
                rel = rel[len(root) + 1:]
            gen += ["--gen", rel]
    run = ctx.attrs.coverage_run[DefaultInfo].default_outputs[0]
    xml = ctx.actions.declare_output("cov/tests/{}.xml".format(stem))
    marker = ctx.actions.declare_output("cov/tests/{}.passed".format(stem))
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            run.project("cov_run.sh"),
            tc.busybox,
            tc.gate_runner,
            tc.compiler,
            "{}:{} [coverage]".format(ctx.label.raw_target(), t.short_path),
            cov_bin,
            share,
            src_dir,
            xml.as_output(),
            marker.as_output(),
            src_repo,
            name,
            _dir_prefix(pkg_dir) + name,
            import_name,
            gen,
            env_args,
            hidden = run,
        ),
        category = "mojo_cov_run",
        identifier = stem,
    )
    return xml, marker

def coverage_sub_targets(bins, runs, gate):
    """The `coverage` sub-target of a library: `bins` {stem: binary},
    `runs` {stem: (report, marker)} and `gate` (coverage_gate's, or None)."""
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
        sub_targets = g | {
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

def _gate_inputs(ctx, runs, markers):
    """The MojoCoverageGateInfo of this library: its non-generated sources
    and its test sources at their repository paths, a BUCK file at its
    package, the list of its test sources, its tests' reports (`runs`
    {stem: (report, marker)}) and `markers`."""
    where = "{}: coverage gate".format(ctx.label.raw_target())
    pkg = _pkg_dir(ctx.label)
    files = {}
    for s in ctx.attrs.srcs:
        if s.is_source:
            files[_dir_prefix(pkg) + s.short_path] = s
    # Every welded test is named to covcheck (`--test-source`), which sets
    # it aside wherever it is in the package: a test outside tests/
    # (`wire/tests/`, the package's top) is not the library's source.
    tests = []
    for t in ctx.attrs.test_srcs:
        if not t.is_source:
            continue
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
        label = ctx.label.raw_target(),
        markers = markers,
        package = pkg or "(root)",
        reports = [runs[k][0] for k in sorted(runs)],
        root = ctx.actions.copied_dir("cov/gate/root", files),
        tests = ctx.actions.write("cov/gate/tests.txt", "".join([t + "\n" for t in sorted(tests)])),
    )

def _gate_action(actions, bb, gate_dir, mode, info, prefix):
    """Declares the `mojo_cov_gate` action of `info` (MojoCoverageGateInfo):
    cov_gate.sh of `gate_dir` (a cov_gate_dir dependency) in `mode`, writing
    `<prefix>result.json`, `<prefix>summary.md` and `<prefix>gate.passed`."""
    d = gate_dir[DefaultInfo].default_outputs[0]
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
            info.root,
            info.tests,
            result.as_output(),
            summary.as_output(),
            marker.as_output(),
            info.reports,
            hidden = d,
        ),
        category = "mojo_cov_gate",
    )
    return struct(marker = marker, result = result, summary = summary)

def _check_tools(ctx):
    """Outside the tests cell, the coverage attributes are what the macro
    sets (coverage_kwargs): komira's link, run and gate directories, and a
    gate unless the library is of the ledger COVERAGE_NO_GATE. A BUCK file
    loading the rule itself cannot give a library a lenient gate (its own
    ratchet, a script that passes a failure) or runs with no gate."""
    if ctx.label.cell == "tests":
        return
    where = ctx.label.raw_target()
    for attr, want in (("coverage_debug", _COVERAGE_LINK), ("coverage_run", _COVERAGE_RUN), ("coverage_gate", _COVERAGE_GATE)):
        d = getattr(ctx.attrs, attr)
        if d != None and str(d.label.raw_target()) != want:
            fail("{}: {} is {}, not {}: only a fixture of the tests cell may name another (tools/build/mojo/coverage.bzl)".format(where, attr, d.label.raw_target(), want))
    if ctx.attrs.coverage_gate == None and str(where) not in COVERAGE_NO_GATE:
        fail("{}: coverage builds with no coverage_gate: its conda package would wait for no coverage gate; only a library of the ledger COVERAGE_NO_GATE (tools/build/coverage/policy.bzl) or a fixture of the tests cell may".format(where))

def coverage_gate(ctx, tc, runs):
    """The coverage gate of a library with coverage builds (`runs` {stem:
    (report, marker)}, possibly empty). Returns (gate, providers): the
    gate's outputs (a struct for coverage_sub_targets, or None without
    coverage_gate: a library of the ledger, or a tests-cell fixture's runs
    alone) and [MojoCoverageGateInfo], whose `markers` (every run's, and
    the gate's) its conda package waits for. Nothing of the library waits
    for them: its package is the one it has with the switch off."""
    _check_tools(ctx)
    markers = [runs[k][1] for k in sorted(runs)]
    gate_dir = ctx.attrs.coverage_gate
    if gate_dir == None:
        return None, [_gate_inputs(ctx, runs, markers)]
    mode = ctx.attrs.coverage_mode
    if mode == None:
        fail("{}: coverage_gate needs coverage_mode".format(ctx.label.raw_target()))
    if mode != COVERAGE_MODE and ctx.label.cell != "tests":
        fail("{}: coverage_mode is {}, but the policy's is {} (tools/build/coverage/policy.bzl); only a fixture of the tests cell may set another".format(ctx.label.raw_target(), mode, COVERAGE_MODE))
    # The info returned is the gate's inputs, with the gate's own marker
    # added to `markers`.
    pre = _gate_inputs(ctx, runs, markers)
    gate = _gate_action(ctx.actions, tc.busybox, gate_dir, mode, pre, "cov/gate/")
    return gate, [MojoCoverageGateInfo(
        label = pre.label,
        markers = markers + [gate.marker],
        package = pre.package,
        reports = pre.reports,
        root = pre.root,
        tests = pre.tests,
    )]

def _cov_gate_impl(ctx):
    if MojoCoverageGateInfo not in ctx.attrs.lib:
        # No coverage builds on this target platform (the select above).
        return [DefaultInfo()]
    if ctx.attrs.mode != COVERAGE_MODE:
        fail("{}: mode is {}, but the policy's is {}".format(ctx.label.raw_target(), ctx.attrs.mode, COVERAGE_MODE))
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    g = _gate_action(ctx.actions, tc.busybox, ctx.attrs.gate, ctx.attrs.mode, ctx.attrs.lib[MojoCoverageGateInfo], "")
    return [DefaultInfo(default_output = g.marker, other_outputs = [g.result, g.summary])]

# The gate of a library of the ledger COVERAGE_NO_GATE (policy.bzl), which
# cannot be an action of the library itself: the library would depend on
# the gate's tool, which depends on the library (a cycle of configured
# targets, whatever waits for the gate). The same action as a library's
# [coverage][gate], over the library's MojoCoverageGateInfo. Its default
# output is the marker, which the library's conda package waits for; the
# result and summary come with it.
_mojo_cov_gate = rule(
    impl = _cov_gate_impl,
    attrs = {
        "gate": attrs.exec_dep(default = _COVERAGE_GATE),
        "lib": attrs.dep(),
        "mode": attrs.string(),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
