"""Mutation score builds of mojo_library: the switch and the `[mutation]`
sub-target (tools/build/coverage/README.md, "Mutation score").

`-c komira.mutation=true` (default false) gives every mojo_library on
linux-x86_64 a `[mutation]` sub-target, which nothing else depends on: only
building it by name runs anything.

1. `mutation_list` (`mutate list`, tools/build/coverage/mutate): the
   operator mutants of the library's hand-written sources (`srcs` that are
   sources; generated ones are compiled but not mutated), a deterministic
   sample of `[komira] mutation_sample` of them (default 30; 0 is all) with
   the seed `[komira] mutation_seed` (default `0`), as the list file
   `mut/list.tsv`, `[mutation][list]`.
2. A dynamic action reads the list and declares, per sampled mutant, under
   `mut/m/<file>/<line>_<col>_<operator>/`: the mutated file (`mutate apply`,
   `mutation_apply`); the library's sources with it in place, precompiled
   against the library's deps (`mutation_precompile`); per `test_srcs` entry
   the test built against that package exactly as its gated build (same
   optimization level, defines, test deps and link) (`mutation_build_test`)
   and run through the gate's runner with its data and environment under a
   memory cap, the library's `test_memory_cap_mib` or 4096 MiB
   (`mutation_run_test`). Each of those steps runs through mut_step.sh, which
   never fails the action and records `ok`, `fail <n>`, `timeout <s>` or
   `skipped`; `[komira] mutation_timeout_secs` (default 300) bounds each.
   Every input of a mutant's actions is the library's sources, its deps, its
   tests and the mutant's id, and every output path is named by the id, so a
   mutant's actions are the same actions whatever else was sampled, and the
   cache keeps them until a source changes.
3. `mutation_score` (`mutate score`): each mutant's verdict from its steps
   (killed, survived, timeout, error) and the report: covcheck's mutants file
   `mut/mutants.tsv` (paths from the repository root) and `mut/summary.md`,
   the outputs of `[mutation]`.

A README's examples are not run against a mutant: only `test_srcs` can kill.
The switch is read in the macro and sets the `mutation_*` attributes only;
with it off they are absent and analysis is what it was before they existed,
and with it on no other action of the library changes. The tool's own
package (`tools/build/coverage/mutate`) gets no attributes: its sub-target
would depend on itself.
"""

load(":coverage.bzl", "coverage_sources")
load(":defines.bzl", "capped_prefix")
load(":providers.bzl", "MojoPkgTSet")
load(":test_runtime.bzl", "test_root")

_MUTATION_DIR = "komira//tools/build/coverage/mutate:mut_dir"
_MUTATE_PACKAGE = "tools/build/coverage/mutate"
_DEFAULT_CAP_MIB = 4096

MUTATION_ATTRS = {
    # A mut_dir (tools/build/coverage/mutate/defs.bzl): set by the macro
    # when `[komira] mutation` is true; None otherwise.
    "mutation_dir": attrs.option(attrs.exec_dep(), default = None),
    "mutation_sample": attrs.int(default = 0),
    "mutation_seed": attrs.string(default = ""),
    "mutation_timeout_secs": attrs.int(default = 0),
}

def _config_count(key, default):
    v = read_config("komira", key, str(default)).strip()
    if not v.isdigit():
        fail("[komira] {} = {}: it must be a whole number (default {})".format(key, repr(v), default))
    return int(v)

def mutation_kwargs(kwargs):
    """Sets the mutation attributes in a mojo_library's `kwargs` when
    `[komira] mutation` is `true`; refuses them when a BUCK file passes one."""
    for a in MUTATION_ATTRS:
        if a in kwargs:
            fail("{}: `{}` is set by mojo_library from `[komira] mutation`; do not pass it".format(kwargs.get("name", "mojo_library"), a))
    v = read_config("komira", "mutation", "false").strip()
    if v not in ("true", "false"):
        fail("[komira] mutation = {}: it must be `true` or `false` (default false)".format(repr(v)))
    pkg = package_name()
    if v == "false" or pkg == _MUTATE_PACKAGE or pkg.startswith(_MUTATE_PACKAGE + "/"):
        return
    timeout = _config_count("mutation_timeout_secs", 300)
    if timeout < 1:
        fail("[komira] mutation_timeout_secs must be at least 1")
    kwargs["mutation_dir"] = select({
        "komira//tools/build/package:is_linux_x86_64": _MUTATION_DIR,
        "DEFAULT": None,
    })
    kwargs["mutation_sample"] = _config_count("mutation_sample", 30)
    kwargs["mutation_seed"] = read_config("komira", "mutation_seed", "0").strip()
    kwargs["mutation_timeout_secs"] = timeout

def _stem(src):
    b = src.basename
    return b[:-len(".mojo")] if b.endswith(".mojo") else b

def mutation_sub_targets(ctx, tc, mojo_cmd, src_dir, root, deps, extra_closure, link_tail, test_data, env_args, defines, cap, mem_cap):
    """{"mutation": ...} with the switch on, else {}. The arguments are what
    the library's gated tests are built from (defs.bzl, _library_impl):
    `src_dir` its staged sources ([src]), `root` the package directory they
    are staged from, `deps` its deps' closure (MojoPkgTSet children),
    `extra_closure` the test_deps packages after the library's, `link_tail`
    the tests' C link tail, `test_data` {test key: {dest: artifact}},
    `env_args` and `defines` the tests' runner and compile arguments, `cap`
    the tests' memory cap (None for none) and `mem_cap` mem_cap.sh."""
    d = ctx.attrs.mutation_dir
    if d == None:
        return {}
    step, mdir = d[DefaultInfo].default_outputs
    import_name = ctx.attrs.import_name or ctx.label.name
    files = {}
    mutable = []
    for s in ctx.attrs.srcs:
        rel = s.short_path
        if root:
            rel = rel[len(root) + 1:]
        files[rel] = s
        if s.is_source and rel.endswith(".mojo"):
            mutable.append(rel)
    src_repo, _gen = coverage_sources(ctx, root)
    lst = ctx.actions.declare_output("mut/list.tsv")
    ctx.actions.run(
        cmd_args(
            mdir.project("mutate/mutate"),
            "list",
            "--src-dir",
            src_dir,
            [["--file", f] for f in sorted(mutable)],
            "--sample",
            str(ctx.attrs.mutation_sample),
            "--seed",
            ctx.attrs.mutation_seed,
            "--out",
            lst.as_output(),
            hidden = mdir,
        ),
        category = "mutation_list",
    )
    pkg = ctx.label.package
    tests = []
    for t in ctx.attrs.test_srcs:
        stem = _stem(t)
        key = t.short_path
        if pkg and key.startswith(pkg + "/"):
            key = key[len(pkg) + 1:]
        tests.append(struct(
            stem = stem,
            staged = ctx.actions.copied_dir("mut/tests/{}.src".format(stem), {t.short_path: t}),
            entry = t.short_path,
            data = test_data.get(key, {}),
            label = "{}:{} [mutation]".format(ctx.label.raw_target(), t.short_path),
        ))
    tsv = ctx.actions.declare_output("mut/mutants.tsv")
    md = ctx.actions.declare_output("mut/summary.md")
    ctx.actions.dynamic_output_new(_mutants(
        list_value = lst,
        list_file = lst,
        tsv = tsv.as_output(),
        md = md.as_output(),
        ctx_values = struct(
            label = str(ctx.label.raw_target()),
            tc = tc,
            mojo_cmd = mojo_cmd,
            mdir = mdir,
            step = step,
            files = files,
            deps = deps,
            extra = extra_closure,
            link_tail = link_tail,
            tests = tests,
            defines = defines,
            opt_level = ctx.attrs.test_optimization_level,
            cap = cap or _DEFAULT_CAP_MIB,
            mem_cap = mem_cap,
            env_args = env_args,
            limit = str(ctx.attrs.mutation_timeout_secs),
            src_repo = src_repo,
            import_name = import_name,
        ),
    ))
    return {"mutation": [DefaultInfo(default_outputs = [tsv, md], sub_targets = {"list": [DefaultInfo(default_output = lst)]})]}

def _step(v, status, after, command):
    # One mutant step through mut_step.sh (never fails; records the outcome).
    return cmd_args(
        v.tc.busybox,
        "sh",
        v.step,
        v.tc.busybox,
        status.as_output(),
        v.limit,
        [["--after", a] for a in after],
        "--",
        command,
    )

def _mutants_impl(actions, list_value, list_file, tsv, md, ctx_values):
    v = ctx_values
    tc = v.tc
    shim = struct(actions = actions)
    score = []
    for line in list_value.read_string().splitlines():
        if line.startswith("#") or not line:
            continue
        f = line.split("\t")
        if len(f) != 6:
            fail("{}: mutation list row {} does not have 6 fields".format(v.label, repr(line)))
        mid, path, op = f[0], f[1], f[4]
        if path not in v.files:
            fail("{}: mutant {} names {}, not a source of the library".format(v.label, mid, path))
        base = "mut/m/{}/{}_{}_{}".format(path, f[2], f[3], op)
        mutated = actions.declare_output(base + "/file/" + path)
        actions.run(
            cmd_args(v.mdir.project("mutate/mutate"), "apply", "--src", v.files[path], "--path", path, "--id", mid, "--out", mutated.as_output(), hidden = v.mdir),
            category = "mutation_apply",
            identifier = mid,
        )
        # The directory's name is the package's import name, as [src]'s is.
        src = actions.copied_dir(base + "/src/" + v.import_name, v.files | {path: mutated})
        mojoc = actions.declare_output(base + "/pkg/" + v.import_name + ".mojoc")
        pre = actions.declare_output(base + "/precompile.status")
        dep_closure = actions.tset(MojoPkgTSet, children = v.deps)
        actions.run(
            _step(v, pre, [], v.mojo_cmd(tc, ["precompile", dep_closure.project_as_args("include"), src, "-o", mojoc.as_output()])),
            category = "mutation_precompile",
            identifier = mid,
        )
        closure = actions.tset(MojoPkgTSet, children = [actions.tset(MojoPkgTSet, value = mojoc, children = v.deps)] + v.extra)
        score += ["--mutant", mid, "--precompile", pre]
        for t in v.tests:
            exe = actions.declare_output("{}/tests/{}/{}".format(base, t.stem, t.stem))
            built = actions.declare_output("{}/tests/{}.build.status".format(base, t.stem))
            actions.run(
                _step(v, built, [pre], v.mojo_cmd(tc, [
                    "build",
                    "--optimization-level",
                    v.opt_level,
                    "--target-cpu",
                    tc.target_cpu,
                    v.defines,
                    closure.project_as_args("include"),
                    t.staged.project(t.entry),
                    "-o",
                    exe.as_output(),
                ], source_root = t.staged, link_tail = v.link_tail)),
                category = "mutation_build_test",
                identifier = "{} {}".format(mid, t.stem),
            )
            root_dir, binary = test_root(shim, "{}/tests/{}/root".format(base, t.stem), exe, t.data)
            ran = actions.declare_output("{}/tests/{}.run.status".format(base, t.stem))
            actions.run(
                _step(v, ran, [built], cmd_args(
                    capped_prefix(tc, v.mem_cap, t.label, v.cap),
                    tc.busybox,
                    "sh",
                    tc.gate_runner,
                    tc.busybox,
                    tc.compiler,
                    t.label,
                    binary,
                    # gate_runner's PASS marker: not an output, the status is.
                    "mutant.passed",
                    v.env_args,
                    hidden = root_dir,
                )),
                category = "mutation_run_test",
                identifier = "{} {}".format(mid, t.stem),
            )
            score += ["--test", t.stem, "--build", built, "--run", ran]
    actions.run(
        cmd_args(
            v.mdir.project("mutate/mutate"),
            "score",
            "--list",
            list_file,
            "--label",
            v.label,
            "--src-repo",
            v.src_repo,
            "--out-tsv",
            tsv,
            "--out-md",
            md,
            score,
            hidden = v.mdir,
        ),
        category = "mutation_score",
    )
    return []

_mutants = dynamic_actions(
    impl = _mutants_impl,
    attrs = {
        "ctx_values": dynattrs.value(typing.Any),
        "list_file": dynattrs.value(Artifact),
        "list_value": dynattrs.artifact_value(),
        "md": dynattrs.output(),
        "tsv": dynattrs.output(),
    },
)
