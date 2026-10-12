"""The parity cases of //tools/build/ci:affected and :derive_checks.

`ci_parity_case` is one build action: runner.zig runs the subject in a tree
of the case's making, with replay.zig answering every buck2 and git call
from the case's transcript, and writes its output only when the subject's
stdout, stderr, exit code and calls all equal the case's goldens (runner.zig's
header says what a case is). Its `[record]` subtarget runs the same case and
keeps what the subject did instead of checking it: the goldens are made from
it, and reviewed.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _run(ctx, mode, out):
    ctx.actions.run(
        cmd_args(
            ctx.attrs.runner[RunInfo],
            "--subject",
            ctx.attrs.subject[RunInfo],
            "--replay",
            _out(ctx.attrs.replay),
            "--case",
            ctx.attrs.case,
            "--common",
            ctx.attrs.common,
            mode,
            out.as_output(),
        ),
        category = "ci_parity_case",
        identifier = mode[2:],
    )

def _ci_parity_case_impl(ctx):
    passed = ctx.actions.declare_output(ctx.label.name + ".passed")
    _run(ctx, "--out", passed)
    record = ctx.actions.declare_output(ctx.label.name + ".record", dir = True)
    _run(ctx, "--record", record)
    return [DefaultInfo(
        default_output = passed,
        sub_targets = {"record": [DefaultInfo(default_output = record)]},
    )]

_ci_parity_case = rule(
    impl = _ci_parity_case_impl,
    doc = "One parity case (runner.zig), run as a build action: the target exists only if the subject's stdout, stderr, exit code and buck2/git calls equal the case's. `[record]` is what the subject did, unchecked.",
    attrs = {
        "case": attrs.source(allow_directory = True, doc = "The case directory: case.txt, transcript.txt, stdout, stderr and the files they name."),
        "common": attrs.source(allow_directory = True, doc = "The files the cases share (`%name` in a case)."),
        "replay": attrs.exec_dep(providers = [RunInfo], doc = "replay.zig, built: the buck2 and git the subject calls."),
        "runner": attrs.exec_dep(providers = [RunInfo], doc = "runner.zig, built."),
        "subject": attrs.exec_dep(providers = [RunInfo], doc = "The tool under test."),
    },
)

ci_parity_case = declares_docs(_ci_parity_case)
