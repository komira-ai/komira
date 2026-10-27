"""The run check of a binary as a validation.

`[run_check]` (mojo_binary, rust_binary) runs the binary in a build action
through `act run-check` (tools/build/mojo/tools/act.zig) and records its stdout; with `expected_stdout` the action
fails unless that stdout is exactly it. A sub-target alone runs only when a
build names it, so for a binary with `expected_stdout` the check is also a
`ValidationInfo` of the binary: every `buck2 build` or `buck2 test` whose graph
holds the binary runs it, and fails when it fails.

A validation result must be the one output of its action, and the run check's
action writes the stdout, so the result is written by a dynamic action that
reads the recorded stdout: it cannot be written before the run check has
passed, and it says "failure" unless the stdout is `expected_stdout` (a second
comparison, in Starlark, of what act compared). The stdout is what
the result is computed from, not a hidden input that could be dropped while
the result still builds.

`run_check_wired` holds the other half: that each binary listed returns the
validation at all. A rule that stops returning it builds every listed binary
green with no run check run; that target fails analysis instead.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _result_impl(actions, stdout, expected, label, result):
    got = stdout.read_string()
    if got == expected:
        status, message = "success", "run_check: {} printed its expected_stdout ({} bytes)".format(label, len(got))
    else:
        status, message = "failure", "run_check: the stdout of {} differs from its expected_stdout ({} bytes, want {})".format(label, len(got), len(expected))
    actions.write_json(result, {"data": {"message": message, "status": status}, "version": 1})
    return []

_result = dynamic_actions(
    impl = _result_impl,
    attrs = {
        "expected": dynattrs.value(str),
        "label": dynattrs.value(str),
        "result": dynattrs.output(),
        "stdout": dynattrs.artifact_value(),
    },
)

def run_check_validation(ctx, stdout, expected):
    """The providers that make the run check recorded in `stdout` (whose
    action compared it with `expected`, the target's expected_stdout) a
    validation."""
    result = ctx.actions.declare_output(ctx.label.name + ".run_check.json")
    ctx.actions.dynamic_output_new(_result(
        stdout = stdout,
        expected = expected,
        label = str(ctx.label.raw_target()),
        result = result.as_output(),
    ))
    return [ValidationInfo(validations = [ValidationSpec(name = "run_check", validation_result = result)])]

def _run_check_wired_impl(ctx):
    for b in ctx.attrs.binaries:
        v = b.get(ValidationInfo)
        names = [s.name for s in v.validations] if v else []
        if "run_check" not in names:
            fail("run_check_wired {}: {} has expected_stdout but returns no `run_check` validation (validations: {}), so no build runs its run check (tools/build/mojo/run_check.bzl)".format(ctx.label.raw_target(), b.label.raw_target(), names))
    return [DefaultInfo()]

_run_check_wired = rule(
    impl = _run_check_wired_impl,
    doc = "Fails analysis unless each of `binaries` (a mojo_binary or rust_binary with `expected_stdout`) returns a `ValidationInfo` holding the `run_check` validation. Its build runs no action of its own.",
    attrs = {"binaries": attrs.list(attrs.dep(), doc = "Binaries with `expected_stdout`.")},
)

run_check_wired = declares_docs(_run_check_wired)
