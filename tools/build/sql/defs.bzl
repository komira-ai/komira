"""`duckdb_dist` and `sql_oracle`: SQL run by the pinned DuckDB CLI as a
build action, its declared result files test data for other targets
(README.md).

`duckdb_dist` names the pinned `duckdb` binary, the directory whose `lib/`
holds the C++ runtime it links beyond glibc, and the version the binary must
report. `komira//third_party/duckdb:duckdb` is the one komira uses.

`sql_oracle` runs that binary itself as the action's executable (no wrapper
script), with one fixed invocation:

    duckdb -no-init -batch -bail
        -cmd ".cd <work>"
        -cmd ".mode trash"
        -cmd "SET threads = 1; SET TimeZone = 'UTC'; ...; SET allowed_paths = [...]"
        -cmd "SELECT CASE WHEN version() <> 'v<version>' THEN error(...) END"
        -cmd ".safe_mode"
        -cmd ".mode duckbox"
        -f ../sql/0_<src> -f ../sql/1_<src> ...
        -cmd ".mode trash"
        -cmd "<one existence check per declared output>"
        :memory:

with `LD_LIBRARY_PATH` naming the dist's `native_libs`, `LC_ALL=C` and
`TZ=UTC`, and nothing else in its environment.

`<work>` is the action's working directory, the directory of its declared
outputs, where every input is copied first. The SQL names inputs and outputs
by their path there ('data.csv', 'golden/rows.tsv', 'rows.parquet').
`.safe_mode` sets `enable_external_access = false` and
`lock_configuration = true`: from then on the SQL can open no file but the
`allowed_paths` (its inputs and outputs, by name), can change no setting
(`threads`, `TimeZone`), and can run no dot command that reaches the system
(`.shell`, `.read`, `.output`, `.cd`). So a COPY to an undeclared file and a
read of a file that is not an input are DuckDB errors, `-bail` stops at the
first error with exit status 1, and an output the SQL did not write fails
the last check (and buck2's own check of the action's outputs).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

DuckdbInfo = provider(
    doc = "A pinned DuckDB CLI: the binary, the directory whose lib/ holds the libraries it links beyond glibc, and the version it reports (`version()`, without the leading v).",
    fields = {
        "binary": provider_field(Artifact),
        "native_libs": provider_field(Artifact),
        "version": provider_field(str),
    },
)

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _duckdb_dist_impl(ctx):
    return [
        DefaultInfo(default_output = _out(ctx.attrs.binary)),
        DuckdbInfo(binary = _out(ctx.attrs.binary), native_libs = _out(ctx.attrs.native_libs), version = ctx.attrs.version),
    ]

_duckdb_dist = rule(
    impl = _duckdb_dist_impl,
    doc = "A pinned DuckDB CLI binary with the directory of its C++ runtime (`native_libs`, whose lib/ every sql_oracle action names in LD_LIBRARY_PATH) and the version it must report; nothing is run here.",
    attrs = {
        "binary": attrs.dep(),
        "native_libs": attrs.dep(),
        "version": attrs.string(),
    },
)

# ---- sql_oracle ----------------------------------------------------------------

# An output's file name: a plain name, no directory, ending in a format the
# rule documents. A name is matched by DuckDB literally (allowed_paths) and
# also used as a glob pattern by the existence check, so no glob characters.
_NAME = "^[A-Za-z0-9_][A-Za-z0-9_.-]*$"
_OUTPUT_FORMATS = [".parquet", ".csv", ".tsv"]

def _where(ctx):
    return str(ctx.label.raw_target())

def _check_path(ctx, what, path):
    if path == "" or path.startswith("/") or path.endswith("/"):
        fail("{}: {} {} must be a relative file path".format(_where(ctx), what, repr(path)))
    for part in path.split("/"):
        if part in (".", "..") or not regex_match(_NAME, part):
            fail("{}: {} {} holds a segment that is not a plain name ({})".format(_where(ctx), what, repr(path), _NAME))

def _inputs(ctx):
    """{path in the work directory: artifact}."""
    if type(ctx.attrs.inputs) == type([]):
        staged = {}
        for a in ctx.attrs.inputs:
            if not a.is_source:
                fail("{}: inputs entry {} is built by {}; a list entry is staged at its path in the package, so name a build output in the dict form, {{path: target}}".format(_where(ctx), a.short_path, a.owner.raw_target() if a.owner != None else "an action of no rule"))
            # A source's short_path is relative to its package.
            if a.short_path in staged:
                fail("{}: inputs names {} twice".format(_where(ctx), repr(a.short_path)))
            staged[a.short_path] = a
    else:
        staged = dict(ctx.attrs.inputs)
    dirs = {}
    for p in staged:
        _check_path(ctx, "input", p)
        parts = p.split("/")
        for i in range(1, len(parts)):
            dirs["/".join(parts[:i])] = p
    for p in staged:
        if p in dirs:
            fail("{}: input {} is both a file and the directory of {}".format(_where(ctx), repr(p), repr(dirs[p])))
    return staged, dirs

def _sql_list(names):
    return "[" + ", ".join(["'{}'".format(n) for n in names]) + "]"

def _sql_oracle_impl(ctx):
    dist = ctx.attrs._duckdb[DuckdbInfo]
    srcs = ctx.attrs.srcs if type(ctx.attrs.srcs) == type([]) else [ctx.attrs.srcs]
    if not srcs:
        fail("{}: srcs is empty: name the .sql file(s) to run".format(_where(ctx)))
    for s in srcs:
        if not s.basename.endswith(".sql"):
            fail("{}: srcs entry {} is not a .sql file".format(_where(ctx), s.basename))
    if not ctx.attrs.outputs:
        fail("{}: outputs is empty: an oracle writes its answer to declared files (COPY ... TO)".format(_where(ctx)))
    staged, dirs = _inputs(ctx)
    seen = {}
    for o in ctx.attrs.outputs:
        if not regex_match(_NAME, o) or o in (".", ".."):
            fail("{}: output {} is not a plain file name ({}): outputs land in the working directory itself".format(_where(ctx), repr(o), _NAME))
        if not [f for f in _OUTPUT_FORMATS if o.endswith(f)]:
            fail("{}: output {} must end in one of {}".format(_where(ctx), repr(o), ", ".join(_OUTPUT_FORMATS)))
        if o in seen:
            fail("{}: outputs names {} twice".format(_where(ctx), repr(o)))
        if o in staged or o in dirs:
            fail("{}: output {} is also an input path".format(_where(ctx), repr(o)))
        seen[o] = True

    # Every file of the action under one prefix of this target: the outputs
    # and the copied inputs in work/, the SQL in sql/ beside it. A path that
    # is not content-based keeps work/ and sql/ siblings.
    outs = {o: ctx.actions.declare_output("work/" + o, has_content_based_path = False) for o in ctx.attrs.outputs}
    hidden = []
    for p in sorted(staged.keys()):
        dest = ctx.actions.declare_output("work/" + p, has_content_based_path = False)
        hidden.append(ctx.actions.copy_file(dest.as_output(), staged[p]))
    sql = []
    for i, s in enumerate(srcs):
        dest = ctx.actions.declare_output("sql/{}_{}".format(i, s.basename), has_content_based_path = False)
        hidden.append(ctx.actions.copy_file(dest.as_output(), s))
        sql.append("../sql/{}_{}".format(i, s.basename))

    first = outs[ctx.attrs.outputs[0]]
    allowed = sorted(staged.keys()) + sorted(ctx.attrs.outputs)
    settings = "; ".join([
        "SET threads = 1",
        "SET TimeZone = 'UTC'",
        "SET autoinstall_known_extensions = false",
        "SET autoload_known_extensions = false",
        "SET temp_directory = ''",
        "SET enable_progress_bar = false",
        "SET allowed_paths = " + _sql_list(allowed),
    ])
    version = "SELECT CASE WHEN version() <> 'v{v}' THEN error('sql_oracle: this duckdb is ' || version() || ', the pin says v{v}') END".format(v = dist.version)
    exists = "; ".join([
        "SELECT CASE WHEN (SELECT count(*) FROM glob('{o}')) = 0 THEN error('sql_oracle: the SQL wrote no {o}, a declared output') END".format(o = o)
        for o in ctx.attrs.outputs
    ])
    cmd = cmd_args(
        dist.binary,
        "-no-init",
        "-batch",
        "-bail",
        "-cmd",
        cmd_args(first.as_output(), parent = 1, format = ".cd {}"),
        # The rule's own statements print nothing (`trash`); the SQL's
        # results print as DuckDB's batch default (`duckbox`), which buck2
        # shows when the action fails.
        "-cmd",
        ".mode trash",
        "-cmd",
        settings,
        "-cmd",
        version,
        "-cmd",
        ".safe_mode",
        "-cmd",
        ".mode duckbox",
    )
    for f in sql:
        cmd.add("-f", f)
    cmd.add("-cmd", ".mode trash", "-cmd", exists, ":memory:")
    cmd.add(cmd_args(hidden = hidden + [o.as_output() for o in outs.values()]))
    ctx.actions.run(
        cmd,
        env = {
            "LC_ALL": "C",
            "LD_LIBRARY_PATH": cmd_args(dist.native_libs, format = "{}/lib"),
            "TZ": "UTC",
        },
        category = "sql_oracle",
    )
    return [DefaultInfo(
        default_outputs = [outs[o] for o in ctx.attrs.outputs],
        sub_targets = {o: [DefaultInfo(default_output = outs[o])] for o in ctx.attrs.outputs},
    )]

_sql_oracle = rule(
    impl = _sql_oracle_impl,
    doc = "Runs `srcs` (one .sql file or a list, in order) with the pinned DuckDB CLI as one build action, in-memory, threads=1, TimeZone 'UTC', from a working directory holding `inputs` (a list of sources, each at its path in the package, or {path: source}); the SQL writes every name in `outputs` there (`COPY ... TO '<name>'`), each a sub-target `[<name>]`. A file the SQL reads or writes that is neither an input nor an output, a missing output, a SQL error or a changed setting fails the action.",
    attrs = {
        "inputs": attrs.one_of(attrs.list(attrs.source()), attrs.dict(attrs.string(), attrs.source()), default = []),
        "outputs": attrs.list(attrs.string()),
        "srcs": attrs.one_of(attrs.source(), attrs.list(attrs.source())),
        "_duckdb": attrs.exec_dep(providers = [DuckdbInfo], default = "komira//third_party/duckdb:duckdb"),
    },
)

def _oracle_macro(**kwargs):
    # The pinned binary is linux-x86_64.
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _sql_oracle(**kwargs)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
duckdb_dist = declares_docs(_duckdb_dist)
sql_oracle = declares_docs(_oracle_macro)
