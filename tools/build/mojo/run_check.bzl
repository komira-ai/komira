"""The run check of a binary as a validation.

`[run_check]` (mojo_binary, rust_binary) runs the binary in a build action
through run_check.sh and records its stdout; with `expected_stdout` the action
fails unless that stdout is exactly it. A sub-target alone runs only when a
build names it, so for a binary with `expected_stdout` the check is also a
`ValidationInfo` of the binary: every `buck2 build` or `buck2 test` whose graph
holds the binary runs it, and fails when it fails.

A validation result must be the one output of its action, and the run check's
action writes the stdout, so the result is a second action: a copy of a fixed
success result that takes the recorded stdout as an input. It can run only
once the run check has passed.
"""

def run_check_validation(ctx, busybox, stdout, category):
    """The providers that make the run check recorded in `stdout` a validation."""
    ok = ctx.actions.write_json(ctx.label.name + ".run_check_ok.json", {
        "data": {"message": "run_check: the binary printed its expected_stdout", "status": "success"},
        "version": 1,
    })
    result = ctx.actions.declare_output(ctx.label.name + ".run_check.json")
    ctx.actions.run(cmd_args(busybox, "cp", ok, result.as_output(), hidden = stdout), category = category)
    return [ValidationInfo(validations = [ValidationSpec(name = "run_check", validation_result = result)])]
