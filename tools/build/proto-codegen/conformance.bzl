"""Rules over botocore's protocol conformance corpus (a directory: `input/`
and `output/` case files) and its ignore list. Every input is passed as an
argument.

`aws_conformance_driver_src`: runs :aws-conformance-gen for the named
protocols and writes one Mojo file: every suite of those protocols as a
generated module, and a `main` that prints the actuals file.

`aws_conformance_drivers`: a macro. For each protocol, an
`aws_conformance_driver_src` named `aws_conformance_driver_<protocol>_src`
and a `mojo_binary` named `aws_conformance_driver_<protocol>` (`-` becomes
`_`), so the drivers compile in parallel. It returns the labels of their
`[run_check]` sub-targets, whose stdout is each protocol's actuals file.

`xml_equiv_verdicts`: runs :xml-equiv-verdicts for the named protocols and
writes its verdicts file (`<name>.tsv`).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:defs.bzl", "mojo_binary")

def _impl(ctx):
    if not ctx.attrs.protocols:
        fail("{}: `protocols` is empty".format(ctx.label))
    out = ctx.actions.declare_output(ctx.label.name + ".mojo")
    gen = ctx.attrs._gen[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(
            gen,
            "--corpus",
            ctx.attrs.corpus,
            [["--protocol", p] for p in ctx.attrs.protocols],
            "--ignore-list",
            ctx.attrs.ignore_list,
            "--out",
            out.as_output(),
        ),
        category = "aws_conformance_gen",
    )
    return [DefaultInfo(default_output = out)]

_aws_conformance_driver_src = rule(
    impl = _impl,
    attrs = {
        # The corpus directory (botocore's tests/unit/protocols).
        "corpus": attrs.source(),
        "ignore_list": attrs.source(),
        # Suite `metadata.protocol` values to drive.
        "protocols": attrs.list(attrs.string()),
        "_gen": attrs.exec_dep(default = "komira//tools/build/proto-codegen:aws-conformance-gen"),
    },
)

aws_conformance_driver_src = declares_docs(_aws_conformance_driver_src)

def aws_conformance_drivers(protocols, corpus, ignore_list, deps):
    """One driver source and one `mojo_binary` per protocol.

    Returns the `[run_check]` label of each driver, in `protocols` order.
    """
    checks = []
    names = []
    for p in protocols:
        name = "aws_conformance_driver_" + p.replace("-", "_")
        if name in names:
            fail("aws_conformance_drivers: `{}` names two protocols".format(name))
        names.append(name)
        aws_conformance_driver_src(
            name = name + "_src",
            corpus = corpus,
            ignore_list = ignore_list,
            protocols = [p],
        )
        mojo_binary(
            name = name,
            srcs = [":" + name + "_src"],
            deps = deps,
            optimization_level = "1",
        )
        checks.append(":" + name + "[run_check]")
    return checks

def _verdicts_impl(ctx):
    if not ctx.attrs.protocols:
        fail("{}: `protocols` is empty".format(ctx.label))
    out = ctx.actions.declare_output(ctx.label.name + ".tsv")
    gen = ctx.attrs._gen[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(
            gen,
            "--corpus",
            ctx.attrs.corpus,
            [["--protocol", p] for p in ctx.attrs.protocols],
            "--ignore-list",
            ctx.attrs.ignore_list,
            "--out",
            out.as_output(),
        ),
        category = "xml_equiv_verdicts",
    )
    return [DefaultInfo(default_output = out)]

_xml_equiv_verdicts = rule(
    impl = _verdicts_impl,
    attrs = {
        "corpus": attrs.source(),
        "ignore_list": attrs.source(),
        "protocols": attrs.list(attrs.string()),
        "_gen": attrs.exec_dep(default = "komira//tools/build/proto-codegen:xml-equiv-verdicts"),
    },
)

xml_equiv_verdicts = declares_docs(_xml_equiv_verdicts)
