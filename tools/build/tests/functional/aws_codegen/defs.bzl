"""Check actions over `aws-client-gen`: text goldens and refusals.

`aws_codegen_golden` generates a module (and optionally its layout probe) in
one action, whose directory is the `[gen]` sub-target, and compares it with
the checked-in goldens in a second action, the default output. No generated
file may reach 1000 lines: the generator writes a module that would as a
facade and its parts (`golden_parts`). The second
action also requires each `must_contain` string in the GENERATED module, as
whole lines compared with leading spaces removed, so a string may span lines:
a property that holds even when someone re-copies the golden over a
regression. An empty `must_contain` string is refused at analysis, since it
would match every module. To update a golden after a deliberate change to the
emitter, build `[gen]` and copy the file over the golden.

`aws_codegen_refusal` runs the generator on inputs it must refuse, and passes
only when it exits non-zero, says `expect` on stderr and writes no file.
It passes `--probe-out` unless `probe_out = False`.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

_GEN = "komira//tools/build/proto-codegen:aws-client-gen"

def _common(ctx):
    act = ctx.attrs._act[RunInfo]
    gen = ctx.attrs._gen[DefaultInfo].default_outputs[0]
    return act, gen

def _golden_impl(ctx):
    for s in ctx.attrs.must_contain:
        if s.strip() == "":
            fail("{}: a must_contain entry is empty; it matches every module".format(
                ctx.label,
            ))
    act, gen = _common(ctx)
    gen_dir = ctx.actions.declare_output(ctx.label.name + "_gen", dir = True)
    probe = "1" if ctx.attrs.golden_probe else "0"
    ctx.actions.run(
        cmd_args(
            act,
            "aws-gen",
            gen,
            gen_dir.as_output(),
            ctx.attrs.module,
            probe,
            "--",
            "--model",
            ctx.attrs.model,
            ctx.attrs.gen_args,
        ),
        category = "aws_codegen_gen",
    )
    # The goldens of the parts of a module the generator split, as the
    # `_parts` directory it writes: each file under its own name.
    parts_golden = "-"
    if ctx.attrs.golden_parts:
        parts_golden = ctx.actions.copied_dir(
            ctx.label.name + "_golden_parts",
            {g.basename: g for g in ctx.attrs.golden_parts},
        )
    stamp = ctx.actions.declare_output(ctx.label.name + ".ok")
    ctx.actions.run(
        cmd_args(
            act,
            "aws-cmp",
            stamp.as_output(),
            gen_dir,
            ctx.attrs.module,
            ctx.attrs.golden,
            ctx.attrs.golden_probe if ctx.attrs.golden_probe else "-",
            parts_golden,
            ctx.attrs.must_contain,
        ),
        category = "aws_codegen_cmp",
    )
    return [DefaultInfo(
        default_output = stamp,
        sub_targets = {"gen": [DefaultInfo(default_output = gen_dir)]},
    )]

def _refusal_impl(ctx):
    act, gen = _common(ctx)
    stamp = ctx.actions.declare_output(ctx.label.name + ".ok")
    ctx.actions.run(
        cmd_args(
            act,
            "aws-refuse",
            gen,
            stamp.as_output(),
            ctx.attrs.expect,
            "1" if ctx.attrs.probe_out else "0",
            "--",
            "--model",
            ctx.attrs.model,
            ctx.attrs.gen_args,
        ),
        category = "aws_codegen_refuse",
    )
    return [DefaultInfo(default_output = stamp)]

_TOOLS = {
    "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
    "_gen": attrs.exec_dep(default = _GEN),
}

aws_codegen_golden_rule = rule(
    impl = _golden_impl,
    attrs = {
        # Every generator flag except --model, --module, --out and --probe-out.
        "gen_args": attrs.list(attrs.string()),
        "golden": attrs.source(),
        # When set, the probe is generated and compared with this file.
        "golden_probe": attrs.option(attrs.source(), default = None),
        # The goldens of the parts of a module that reaches the generator's
        # line limit (a facade, `golden`, and the files of `_parts/`): each a
        # file named as the generated part, in a directory of its own. Empty
        # for a module under the limit, which must not be split.
        "golden_parts": attrs.list(attrs.source(), default = []),
        "model": attrs.source(),
        "module": attrs.string(),
        # Strings the generated module must contain, beside the golden match.
        "must_contain": attrs.list(attrs.string(), default = []),
    } | _TOOLS,
)

aws_codegen_refusal_rule = rule(
    impl = _refusal_impl,
    attrs = {
        "gen_args": attrs.list(attrs.string()),
        "expect": attrs.string(),
        "model": attrs.source(),
        # When False, the generator is run without --probe-out.
        "probe_out": attrs.bool(default = True),
    } | _TOOLS,
)

# Each declares its package's doc_tree too (tools/build/lint/doc_tree.bzl), so
# a BUCK file calling only these, as tests//negative/aws_codegen does, still
# has one for //:docs.
aws_codegen_golden = declares_docs(aws_codegen_golden_rule)
aws_codegen_refusal = declares_docs(aws_codegen_refusal_rule)
