"""Committed generated sources: the one way a generated library is built.

`mojo_aws_client`, `mojo_gcp_client`, `mojo_proto_library` and
`mojo_db_proto_library` (tools/build/cloud/{aws,gcp}.bzl, tools/build/mojo/proto.bzl)
generate Mojo from a model or from `.proto` files. A library `<name>` of one of them
is built from the directory `generated/<name>/` of its package, committed to the
repository, and from nothing else:

    <name>_gen      the generator's output for the current inputs (nothing is
                    compiled from it)
    <name>_fresh    regenerates, compares with `generated/<name>/` file by file
                    and byte by byte, and fails with the command that regenerates
    <name>          a `mojo_library` over `generated/<name>/`, whose first gate
                    is `<name>_fresh`: no `.mojoc` exists, and no test of the
                    library runs, while the committed files are not what the
                    generator writes now

So a model, a `.proto`, a generator change or a hand edit that is not followed by
a regeneration is a red build, whose message is the command. The command is
`./buck2 run komira//tools/build/gen:regen -- <library target>` (regen.zig): it
builds `<name>_gen` and makes `generated/<name>/` equal to it, removing a file the
generator no longer writes. `<name>_fresh` is the only reader of `<name>_gen`.

The libraries that have no committed directory yet are listed in
transition.bzl, and are built from the generator as before until they leave the
list: that is a transition, not a second way. See "Transition" in README.md.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load(":transition.bzl", "UNMIGRATED")

# The directory of a package that holds `<name>/`, the committed sources of
# the library `<name>`. regen.zig reads the directory from `<name>_fresh`'s
# `committed_dir`, never from this name.
GENERATED_DIR = "generated"

# The command that regenerates a library, before its target. The same text is
# in the header of every generated file (tools/build/proto-codegen/src/header.rs,
# tools/build/cloud/aws_act.zig, tools/build/mojo/tools/proto_gen.zig);
# `tools/build/gen:command_agreement` holds them equal.
REGEN_COMMAND = "./buck2 run komira//tools/build/gen:regen --"

def _fresh_impl(ctx):
    gen = ctx.attrs.gen[DefaultInfo].default_outputs[0]

    # The committed files, at their path in the committed directory (a
    # source's `short_path` may or may not start at the package: find the
    # directory's own name in it).
    marker = ctx.attrs.committed_dir + "/"
    staged = {}
    for f in ctx.attrs.committed:
        p = f.short_path
        at = p.find(marker)
        if at < 0:
            fail("{}: {} is not under {}".format(ctx.label, p, ctx.attrs.committed_dir))
        staged[p[at + len(marker):]] = f
    committed = ctx.actions.copied_dir("committed", staged)
    stamp = ctx.actions.declare_output("fresh.passed")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._fresh[RunInfo],
            "--gen",
            gen,
            "--committed",
            committed,
            "--label",
            ctx.attrs.target,
            "--dir",
            ctx.label.package + "/" + ctx.attrs.committed_dir if ctx.label.package else ctx.attrs.committed_dir,
            "--regen",
            "{} {}".format(REGEN_COMMAND, ctx.attrs.target),
            "--out",
            stamp.as_output(),
        ),
        category = "gen_fresh",
    )
    return [DefaultInfo(default_output = stamp)]

# `kind('^gen_fresh$', ...)` is how regen.zig finds the libraries to regenerate:
# the rule is named for it, and carries what regen needs (`gen`, `committed_dir`).
gen_fresh = rule(
    impl = _fresh_impl,
    attrs = {
        # The committed files of the library (a glob of its directory).
        "committed": attrs.list(attrs.source(), default = []),
        # The directory of the committed files, from the package.
        "committed_dir": attrs.string(),
        # The generation target.
        "gen": attrs.dep(),
        # The library's label, for the message.
        "target": attrs.string(),
        "_fresh": attrs.exec_dep(default = "komira//tools/build/gen:fresh", providers = [RunInfo]),
    },
)

def _uncommitted_impl(ctx):
    # The generation is analysed first (a dependency): a refusal of the rule's
    # own, such as an operation the model does not have, is reported as itself.
    fail("{}: no generated sources are committed in {}/. Generate them with `{} {}` and commit the directory.".format(
        ctx.label.raw_target(),
        ctx.attrs.committed_dir,
        REGEN_COMMAND,
        ctx.attrs.target,
    ))

_uncommitted = rule(
    impl = _uncommitted_impl,
    attrs = {
        "committed_dir": attrs.string(),
        "gen": attrs.dep(),
        "target": attrs.string(),
    },
)

def _label(name):
    return "{}//{}:{}".format(native.repository_name().lstrip("@"), native.package_name(), name)

# The cells of this repository: their libraries are listed in transition.bzl.
_OWN_CELLS = ["komira", "tests"]

def _in_transition(target):
    """Whether `target` is built from the generator, as every library was before committed sources.

    A library of this repository is listed in transition.bzl. A library of a
    repository that uses komira as a cell is listed by that repository, in its
    root `.buckconfig`, as `[komira] generated_unmigrated`: labels separated by
    whitespace, which it empties as it commits the generated sources (README.md,
    "Transition"). Never a label of this repository's own cells.
    """
    if target in UNMIGRATED:
        return True
    if target.split("//")[0] in _OWN_CELLS:
        return False
    return target in (read_root_config("komira", "generated_unmigrated", "") or "").split()

def generated_state(name):
    """What a generated library `name` of this package is built from.

    A struct of: `legacy` (it is in the transition ledger: built from the
    generator, as before), `dir` (the package-relative committed directory),
    `files` (the committed files, sorted; none for a legacy library) and
    `target` (its label). Refuses a library that is in the ledger and has a
    committed directory: a library that is migrated leaves the ledger in the
    same commit, so the ledger never says what is not true.
    """
    target = _label(name)
    legacy = _in_transition(target)
    directory = GENERATED_DIR + "/" + name
    files = sorted(glob([directory + "/**"]))
    if legacy and files:
        fail("{}: `{}/` is committed, so the library is no longer in the transition: delete its line from tools/build/gen/transition.bzl".format(target, directory))
    return struct(legacy = legacy, dir = directory, files = files, target = target)

def committed_data(name, at = "gen", suffix = ""):
    """A test's `data` of the committed generated files of the library `name`, each at `<at>/<path in the committed directory>`.

    A file of a subdirectory (`_parts/x.mojo`) keeps its path, so a test that
    walks the staged tree finds it where the generator put it. `suffix` keeps
    only the files ending so (`.mojo`).

    For a test that reads every generated file (the environment scans): what it
    reads is what the library is built from, never `<name>_gen`. Empty while
    the library has no committed directory.
    """
    directory = GENERATED_DIR + "/" + name
    return {at + "/" + f[len(directory) + 1:]: f for f in sorted(glob([directory + "/**"])) if f.endswith(suffix)}

def committed_sources(state, exclude = []):
    """The `.mojo` files of a committed directory a library is built from, less the named files (their basenames)."""
    return [f for f in state.files if f.endswith(".mojo") and f.rsplit("/", 1)[-1] not in exclude]

def declare_fresh(name, gen, state, visibility = None):
    """Declares `<name>_fresh`, the check of the committed directory against `gen` (a label)."""
    vis = {"visibility": visibility} if visibility != None else {}
    gen_fresh(
        name = name + "_fresh",
        committed = state.files,
        committed_dir = state.dir,
        gen = gen,
        target = state.target,
        **vis
    )

def _unmigrated_impl(ctx):
    return [DefaultInfo()]

# The marker a library in the transition ledger declares, `<name>_unmigrated`:
# no action. `regen` counts them (`regen -- all` says how many it skipped) and
# recognises one to explain that a library is still in the ledger.
gen_unmigrated = rule(
    impl = _unmigrated_impl,
    attrs = {"target": attrs.string()},
)

def declare_unmigrated(name, state):
    """Declares `<name>_unmigrated` for a library of the transition ledger."""
    gen_unmigrated(name = name + "_unmigrated", target = state.target)

def declare_uncommitted(name, gen, state, visibility = None):
    """Declares `name` as the target that says to regenerate, for a library with nothing committed yet."""
    vis = {"visibility": visibility} if visibility != None else {}
    _uncommitted(
        name = name,
        committed_dir = state.dir,
        gen = gen,
        target = state.target,
        **vis
    )

def _transition_impl(ctx):
    listing = "".join([l + "\n" for l in sorted(UNMIGRATED)])
    return [DefaultInfo(default_output = ctx.actions.copied_dir("transition", {
        "max.txt": ctx.actions.write("max.txt", "{}\n".format(ctx.attrs.max)),
        "unmigrated.txt": ctx.actions.write("unmigrated.txt", listing),
    }))]

_transition = rule(
    impl = _transition_impl,
    attrs = {
        # The number of libraries the ledger holds, written in the BUCK file
        # that declares the target: a line added or removed is a change to two
        # files, and to a number a reviewer reads.
        "max": attrs.int(),
    },
)

# `transition`: the ledger (transition.bzl) as a directory of `unmigrated.txt`,
# one label per line, and `max.txt`, for the lint that holds it
# (transition_test.zig). Building it lists the libraries still to migrate.
gen_transition = declares_docs(_transition)
