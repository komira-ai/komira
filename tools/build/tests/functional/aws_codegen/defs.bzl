"""Check actions over `aws-client-gen`: text goldens and refusals.

`aws_codegen_golden` generates a module (and optionally its layout probe) in
one action, whose directory is the `[gen]` sub-target, and compares it with
the checked-in goldens in a second action, the default output. The second
action also requires each `must_contain` string in the GENERATED module (lines
compared with leading spaces removed, so a string may span lines): a property
that holds even when someone re-copies the golden over a regression. To update a
golden after a deliberate change to the emitter, build `[gen]` and copy the
file over the golden.

`aws_codegen_refusal` runs the generator on inputs it must refuse, and passes
only when it exits non-zero, says `expect` on stderr and writes no file.
It passes `--probe-out` unless `probe_out = False`.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

_GEN = "komira//tools/build/proto-codegen:aws-client-gen"
_SCRIPT = "tests//functional/aws_codegen:aws_codegen.sh"

def _common(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    gen = ctx.attrs._gen[DefaultInfo].default_outputs[0]
    script = ctx.attrs._script[DefaultInfo].default_outputs[0]
    return bb, gen, script

def _golden_impl(ctx):
    bb, gen, script = _common(ctx)
    gen_dir = ctx.actions.declare_output(ctx.label.name + "_gen", dir = True)
    probe = "1" if ctx.attrs.golden_probe else "0"
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            script,
            bb,
            "gen",
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
    stamp = ctx.actions.declare_output(ctx.label.name + ".ok")
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            script,
            bb,
            "cmp",
            stamp.as_output(),
            gen_dir,
            ctx.attrs.module,
            ctx.attrs.golden,
            ctx.attrs.golden_probe if ctx.attrs.golden_probe else "-",
            ctx.attrs.must_contain,
        ),
        category = "aws_codegen_cmp",
    )
    return [DefaultInfo(
        default_output = stamp,
        sub_targets = {"gen": [DefaultInfo(default_output = gen_dir)]},
    )]

def _refusal_impl(ctx):
    bb, gen, script = _common(ctx)
    stamp = ctx.actions.declare_output(ctx.label.name + ".ok")
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            script,
            bb,
            "refuse",
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
    "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    "_gen": attrs.exec_dep(default = _GEN),
    "_script": attrs.dep(default = _SCRIPT),
}

aws_codegen_golden_rule = rule(
    impl = _golden_impl,
    attrs = {
        # Every generator flag except --model, --module, --out and --probe-out.
        "gen_args": attrs.list(attrs.string()),
        "golden": attrs.source(),
        # When set, the probe is generated and compared with this file.
        "golden_probe": attrs.option(attrs.source(), default = None),
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
