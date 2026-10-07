"""Coverage builds of mojo_library: the switch, the debug link directory,
and the kcov run of each test.

`-c komira.coverage=true` (default false) gives every mojo_library on
linux-x86_64, per `test_srcs` entry:

- one more binary: the test compiled at -O0 with line tables, linked through
  a link directory that keeps the debug info and rewrites the action's
  directories out of it (`komira//tools/build/coverage/kcov`, README.md),
  `[coverage][bin][<test>]` (category `mojo_build_cov_test`);
- one run of it under kcov, through the release gate's runner, whose
  Cobertura report in repository paths is `[coverage][tests][<test>]`
  (category `mojo_cov_run`, `cov_run.sh` in the same directory).

`[coverage]` is all of them. Nothing else depends on them yet: the package
and its tests are what they are with the switch off, action for action.

The macro reads `[komira] coverage` from the buckconfig of the cell its
BUCK file is in: `-c` and a global buckconfig reach every cell, a cell's own
`.buckconfig` only that cell (tools/build/mojo/README.md, Coverage builds).

The switch is read here, in the macro, and only sets the `coverage_debug`
and `coverage_run` attributes: a buckconfig value is not part of the
configuration, so it moves no output path and no action key, and with the
switch off the attributes are absent and analysis is what it was before they
existed. On a target platform other than linux-x86_64 they are None (the
`select` below), so the library builds as with the switch off.

Scope: a library's `test_srcs`. A README's examples, `mojo_test`,
`mojo_shared_lib` drivers and generated test sources get no coverage binary,
and generated library sources are not measured.
"""

# The link directory of every coverage build (cov_link_dir, kcov/defs.bzl):
# one target, so the paths of zig's C runtime sources that the debug info
# names are the same for every library.
_COVERAGE_LINK = "komira//tools/build/coverage/kcov:cov_link"

# The directory every coverage run runs from (cov_run_dir, kcov/defs.bzl):
# cov_run.sh, kcov and cov_normalize.
_COVERAGE_RUN = "komira//tools/build/coverage/kcov:cov_run"

COVERAGE_ATTRS = {
    # A cov_link_dir: set by the mojo_library macro when coverage is on (see
    # coverage_kwargs); None otherwise. A BUCK file in the komira cell may
    # not set it.
    "coverage_debug": attrs.option(attrs.exec_dep(), default = None),
    # A cov_run_dir, set together with coverage_debug; None otherwise.
    "coverage_run": attrs.option(attrs.exec_dep(), default = None),
}

def coverage_on():
    """Whether `[komira] coverage` is `true`. `false` or unset is off; any
    other value fails, naming it, so a typo never turns coverage off."""
    v = read_config("komira", "coverage", "false").strip()
    if v not in ("true", "false"):
        fail("[komira] coverage = {}: it must be `true` or `false` (default false); it turns on the coverage build of every mojo_library (tools/build/mojo/README.md, Coverage builds)".format(repr(v)))
    return v == "true"

def coverage_kwargs(kwargs):
    """Sets `coverage_debug` and `coverage_run` in a mojo_library's `kwargs`
    when coverage is on.

    A fixture in the `tests` cell may pass `coverage_debug` itself (a
    cov_link_dir), and with it `coverage_run` (a cov_run_dir; the one every
    library uses when not given): its library then has coverage binaries and
    runs whatever the switch says, through the directories it names, so a
    test can plant a defective tool. Anywhere else passing either is refused.
    """
    name = kwargs.get("name", "mojo_library")
    link = kwargs.get("coverage_debug")
    run = kwargs.get("coverage_run")
    if link != None or run != None:
        if get_cell_name() != "tests":
            fail("{}: `coverage_debug` and `coverage_run` are set by mojo_library from `[komira] coverage`; do not pass them".format(name))
        if link == None:
            fail("{}: `coverage_run` needs `coverage_debug`: a run measures the coverage binary".format(name))
        run = run or _COVERAGE_RUN
    elif coverage_on():
        link = _COVERAGE_LINK
        run = _COVERAGE_RUN
    else:
        return
    kwargs["coverage_debug"] = select({
        "komira//tools/build/package:is_linux_x86_64": link,
        "DEFAULT": None,
    })
    kwargs["coverage_run"] = select({
        "komira//tools/build/package:is_linux_x86_64": run,
        "DEFAULT": None,
    })

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
    pkg_dir = "/".join([d for d in [_CELL_REPO_DIR.get(ctx.label.cell, ""), ctx.label.package] if d])
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

def coverage_sub_targets(bins, runs):
    """The `coverage` sub-target of a library: `bins` {stem: binary} and
    `runs` {stem: (report, marker)}."""
    b = [bins[k] for k in sorted(bins)]
    x = [runs[k][0] for k in sorted(runs)]
    m = [runs[k][1] for k in sorted(runs)]
    return {"coverage": [DefaultInfo(
        default_outputs = b + x,
        other_outputs = m,
        sub_targets = {
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
