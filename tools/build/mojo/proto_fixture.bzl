"""proto_fixture_check and proto_encode: protoc, the reference implementation, reading committed wire fixtures.

A wire fixture is three committed files per message, `<stem>.hex`,
`<stem>.txtpb` and `<stem>.canonical.hex`:

  * `<stem>.hex`: the bytes a producer under test wrote (for example a Mojo
    encoder), as hex text (below).
  * `<stem>.txtpb`: a first line `# proto-message: <root>`, naming the root
    message the fixture is, then exactly what `protoc --decode=<root>` prints
    for those bytes.
  * `<stem>.canonical.hex`: what `protoc --encode=<root>` writes for the
    `.txtpb`: the bytes another protobuf implementation produces for the same
    message, for a decoder under test to read.

`proto_fixture_check(name, fixtures, dir, files, hex, canonical_producer,
srcs, import_prefix, proto_deps)` checks, in one build action
(`proto_fixture.sh check`), for each entry `<stem>: <root>` of `fixtures`:

  0. the `.hex` is not byte for byte the `.canonical.hex` (both ends protoc),
     unless `canonical_producer` lists the stem, and writes no singular field
     of `<root>` twice at the top level;
  1. `protoc --decode=<root>` of `<stem>.hex` is byte for byte the `.txtpb`
     after its first line;
  2. that decode holds no field the schema does not declare, at any depth
     (protoc prints one as a bare number, `99: 1` or `99 {`, and does not fail);
  3. `protoc --encode=<root>` of the `.txtpb` is the bytes of `<stem>.canonical.hex`;
  4. the `.txtpb` names `<root>` on its first line, so a fixture written for
     another message is refused even when its bytes and text are the same
     under both;
  5. every enum value in the decode has a name (protoc prints an undeclared
     value of an open enum as a number, `kind: 99`, and parses it back).

Legs 0 and 5 read the schema from protoc's descriptor set, never a list. Each
leg reads protoc's output and the committed files itself, never another leg's
verdict, so every leg runs whatever the others found, except that legs 2 and
5 need a decode and a file that is not hex fails its fixture before any leg
(`FIXTURE`). Each failure is reported with its leg number and the file read,
and the action fails if any leg failed. The target's output is the report,
one `PASS` line per fixture; it exists only when every leg of every fixture
passed, so building the target is the check.

What the legs cannot see: a scalar at its default is absent from a proto3
decode whether or not it was written, so a dropped field and a zero look
alike; a singular field written twice below the top level decodes as its last
value; leg 0 is a necessary condition, not provenance (bytes that differ from
protoc's can still be hand-made); leg 5 proves a name, not the right one; leg
4 compares two author-written strings. mojo/README.md says more.

Every proto_fixture_check and proto_encode action takes the verdicts of
`proto_fixture_case` targets (proto_fixture_testdata/BUCK) as inputs: each
runs the check over a planted defect and asserts its refusal and message, so
a check that stops refusing fails every build that checks a fixture.

`proto_encode(name, srcs, import_prefix, proto_deps, root, txtpb)` writes
`protoc --encode=<root>` of `txtpb` as `<name>.hex` in the hex format below,
as a build action (on the remote executors when the build executes remotely):
how a `.canonical.hex` is made. Regenerate one with
`./buck2 build <target> --out <path of the .canonical.hex>`. Its output read
as a `.hex` checks no producer (leg 0).

Hex format: hex digits, either case, two per byte; spaces, tabs and line
breaks anywhere are ignored, and anything else is refused, as are an odd
number of digits and zero bytes. proto_encode writes lowercase, 32 bytes (64
digits) per line, each line ending in a line break.

The `.proto` files are staged at `import_prefix` joined with their path in
the package, with every directory of the `proto_deps` closure and protoc's
well-known types on the proto path, as for mojo_proto_library (proto.bzl);
protoc reads every file of `srcs` and of that closure, and `<root>` is a
fully qualified message name declared in one of them. protoc comes from
`toolchains//:mojo_proto`; the macros default `exec_compatible_with` to linux
x86_64, the one platform that toolchain pins protoc for.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load(":proto.bzl", "MojoProtoToolchainInfo", "ProtoSrcsInfo", "proto_closure", "stage_proto_srcs")

_STEM = "^[A-Za-z0-9_][A-Za-z0-9_.-]*$"
_ROOT = "^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*$"

def _protoc_args(ctx):
    """The script's protoc arguments: the proto path directories, then the files to read."""
    tree, own_paths = stage_proto_srcs(ctx)
    trees, dep_paths = proto_closure(ctx, tree, own_paths)
    files = own_paths + dep_paths
    if not files:
        fail("{}: no `.proto` file to read: `srcs` and the `proto_deps` closure are empty".format(ctx.label))
    return [str(len(trees))] + trees + [str(len(files))] + files

def _check_root(ctx, root, what):
    if not regex_match(_ROOT, root):
        fail("{}: {} `{}` is not a fully qualified message name (`package.Message`, no leading dot)".format(ctx.label, what, root))

def _check_args(ctx):
    """`proto_fixture.sh check`'s arguments after its report: the schema, `--`, a group per fixture."""
    stems = sorted(ctx.attrs.fixtures.keys())
    if not stems:
        fail("{}: `fixtures` is empty: there is nothing to check".format(ctx.label))
    for files, what in [(ctx.attrs.hex, "hex"), (ctx.attrs.txtpb, "txtpb"), (ctx.attrs.canonical, "canonical")]:
        if sorted(files.keys()) != stems:
            fail("{}: `{}` has fixtures {} but `fixtures` names {}".format(ctx.label, what, sorted(files.keys()), stems))
    for stem in ctx.attrs.canonical_producer:
        if stem not in ctx.attrs.fixtures:
            fail("{}: `canonical_producer` names `{}`, which `fixtures` does not".format(ctx.label, stem))
    groups = []
    for stem in stems:
        if not regex_match(_STEM, stem):
            fail("{}: fixture name `{}` is not a file stem".format(ctx.label, stem))
        root = ctx.attrs.fixtures[stem]
        _check_root(ctx, root, "the root of fixture `{}`,".format(stem))
        groups += [
            stem,
            root,
            ctx.attrs.hex[stem],
            ctx.attrs.txtpb[stem],
            ctx.attrs.canonical[stem],
            "1" if stem in ctx.attrs.canonical_producer else "0",
        ]
    return cmd_args(_protoc_args(ctx), "--", groups)

def _selftest(ctx):
    # The verdicts of proto_fixture_case over the planted defects
    # (proto_fixture_testdata/BUCK): the action runs only once every leg has
    # refused its defect, so a script that stops refusing fails every check.
    return [d[DefaultInfo].default_outputs for d in ctx.attrs._selftest]

def _proto_fixture_check_impl(ctx):
    ptc = ctx.attrs.proto_toolchain[MojoProtoToolchainInfo]
    report = ctx.actions.declare_output(ctx.label.name + ".txt")
    ctx.actions.run(
        cmd_args(
            ptc.busybox,
            "sh",
            ctx.attrs._script,
            ptc.busybox,
            ptc.protoc,
            "check",
            report.as_output(),
            _check_args(ctx),
            hidden = _selftest(ctx),
        ),
        category = "proto_fixture_check",
    )
    return [DefaultInfo(default_output = report)]

_COMMON = {
    "import_prefix": attrs.string(default = ""),
    # Targets (mojo_proto_library, its welded `<name>_gen`, proto_srcs) whose
    # `.proto` files `srcs` import, or that declare the roots themselves.
    "proto_deps": attrs.list(attrs.dep(providers = [ProtoSrcsInfo]), default = []),
    "proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
    "srcs": attrs.list(attrs.source(), default = []),
    "_script": attrs.source(default = "komira//tools/build/mojo:proto_fixture.sh"),
}

_FIXTURES = {
    # Fixture stem -> its three files.
    "canonical": attrs.dict(attrs.string(), attrs.source()),
    # Stems whose producer writes protoc's bytes, so their .hex may equal
    # their .canonical.hex (leg 0).
    "canonical_producer": attrs.list(attrs.string(), default = []),
    # Fixture stem -> the fully qualified root message.
    "fixtures": attrs.dict(attrs.string(), attrs.string()),
    "hex": attrs.dict(attrs.string(), attrs.source()),
    "txtpb": attrs.dict(attrs.string(), attrs.source()),
}

_SELFTEST = {
    "_selftest": attrs.list(attrs.dep(), default = ["komira//tools/build/mojo/proto_fixture_testdata:selftest"]),
}

proto_fixture_check_rule = rule(
    impl = _proto_fixture_check_impl,
    attrs = _COMMON | _FIXTURES | _SELFTEST,
)

def _proto_encode_impl(ctx):
    ptc = ctx.attrs.proto_toolchain[MojoProtoToolchainInfo]
    _check_root(ctx, ctx.attrs.root, "`root`")
    out = ctx.actions.declare_output(ctx.label.name + ".hex")
    ctx.actions.run(
        cmd_args(
            ptc.busybox,
            "sh",
            ctx.attrs._script,
            ptc.busybox,
            ptc.protoc,
            "encode",
            out.as_output(),
            _protoc_args(ctx),
            "--",
            ctx.attrs.root,
            ctx.attrs.txtpb,
            hidden = _selftest(ctx),
        ),
        category = "proto_encode",
    )
    return [DefaultInfo(default_output = out)]

proto_encode_rule = rule(
    impl = _proto_encode_impl,
    attrs = _COMMON | _SELFTEST | {
        "root": attrs.string(),
        "txtpb": attrs.source(),
    },
)

# The check over fixtures, its verdict asserted: accepted when `expect` is
# empty, otherwise refused with a message holding `expect`.
_CASE_SCRIPT = """
SCRIPT="$1"; EXPECT="$2"; VERDICT="$3"; BB="$4"; shift 3
# Scratch in the action's own directory: a local action runs in the checkout
# root beside every other local action, so a fixed path under $PWD is shared.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.proto_fixture_case" ;;
    /*) T="$BUCK_SCRATCH_PATH/proto_fixture_case" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/proto_fixture_case" ;;
esac
"$BB" rm -rf "$T"
"$BB" mkdir -p "$T"
# The check's arguments: BB PROTOC check, the report, the rest.
B1="$1"; B2="$2"; B3="$3"; shift 3
rc=0
"$BB" sh "$SCRIPT" "$B1" "$B2" "$B3" "$T/report" "$@" 2> "$T/err" || rc=$?
if [ -z "$EXPECT" ]; then
    if [ "$rc" -ne 0 ]; then
        echo "proto_fixture_case: the check refused fixtures it must accept:" >&2
        "$BB" cat "$T/err" >&2
        exit 1
    fi
    "$BB" test -s "$T/report" || { echo "proto_fixture_case: the check wrote no report" >&2; exit 1; }
    { echo "accepted"; "$BB" cat "$T/report"; } > "$VERDICT"
elif [ "$rc" -eq 0 ]; then
    echo "proto_fixture_case: the check accepted fixtures it must refuse with: $EXPECT" >&2
    exit 1
elif ! "$BB" grep -qF -- "$EXPECT" "$T/err"; then
    echo "proto_fixture_case: the check refused, but not with: $EXPECT" >&2
    "$BB" cat "$T/err" >&2
    exit 1
elif [ -e "$T/report" ]; then
    echo "proto_fixture_case: the check refused but wrote its report" >&2
    exit 1
else
    { echo "refused"; "$BB" cat "$T/err"; } > "$VERDICT"
fi
"$BB" rm -rf "$T"
"""

def _proto_fixture_case_impl(ctx):
    ptc = ctx.attrs.proto_toolchain[MojoProtoToolchainInfo]
    verdict = ctx.actions.declare_output(ctx.label.name + ".verdict.txt")
    ctx.actions.run(
        cmd_args(
            ptc.busybox,
            "sh",
            "-euc",
            _CASE_SCRIPT,
            "sh",
            ctx.attrs._script,
            ctx.attrs.expect,
            verdict.as_output(),
            ptc.busybox,
            ptc.protoc,
            "check",
            _check_args(ctx),
        ),
        category = "proto_fixture_case",
    )
    return [DefaultInfo(default_output = verdict)]

proto_fixture_case_rule = rule(
    impl = _proto_fixture_case_impl,
    attrs = _COMMON | _FIXTURES | {
        "expect": attrs.string(default = ""),
    },
)

def _fixture_kwargs(name, fixtures, dir, files, hex):
    """The three file dicts of `fixtures`, from `dir` (in `files`, a staged_files target, if given)."""
    for stem in hex:
        if stem not in fixtures:
            fail("{}//{}:{}: `hex` names `{}`, which `fixtures` does not".format(native.get_cell_name(), native.package_name(), name, stem))
    prefix = dir.rstrip("/") + "/" if dir else ""

    def path(s, ext):
        return "{}[{}{}{}]".format(files, prefix, s, ext) if files else prefix + s + ext

    return {
        "canonical": {s: path(s, ".canonical.hex") for s in fixtures},
        "fixtures": fixtures,
        "hex": {s: hex.get(s, path(s, ".hex")) for s in fixtures},
        "txtpb": {s: path(s, ".txtpb") for s in fixtures},
    }

def _proto_fixture_check(name, fixtures, dir = "", files = None, hex = {}, **kwargs):
    """`fixtures` maps each stem to its root; its files are `<dir>/<stem>.hex`, `.txtpb`, `.canonical.hex`.

    `files` names a staged_files target holding them (`<files>[<dir>/<stem>.hex]`)
    when they are another package's. `hex` replaces the `.hex` source of the
    stems it names (a label of a build output, for example a producer's run).
    """
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    proto_fixture_check_rule(name = name, **(_fixture_kwargs(name, fixtures, dir, files, hex) | kwargs))

def _proto_fixture_case(name, fixtures, dir = "", files = None, hex = {}, **kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    proto_fixture_case_rule(name = name, **(_fixture_kwargs(name, fixtures, dir, files, hex) | kwargs))

def _proto_encode(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    proto_encode_rule(**kwargs)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
proto_encode = declares_docs(_proto_encode)
proto_fixture_case = declares_docs(_proto_fixture_case)
proto_fixture_check = declares_docs(_proto_fixture_check)
