"""The time limit of a `mojo_test` under `buck2 test` (test_deadline.sh).

buck2 runs a test that gives ExternalRunnerTestInfo (every test rule here)
through its test runner, which gives each test a timeout: the runner's
`--timeout`, 600 s unless `buck2 test <targets> -- --timeout <s>` sets another.
buck2 sends it to the executor as the action's timeout (buck2's `[test]
timeout_default_s` is the timeout of InternalRunnerTestInfo tests, and does not
reach these). A remote executor stops the action there, and buck2 then reports
an ordinary failure, with no word of the timeout; the test's output, which its
runner holds until the test exits, is lost with it. So a mojo_test runs under
test_deadline.sh, which kills the test TEST_LIMIT_MARGIN_S seconds earlier and
says so (`TEST TIME LIMIT: killed <label> after <n> s, ...`).

The runner's `--timeout` is a command-line argument, which no rule can read,
so the root cell's `[komira] test_timeout_s` states it (600, buck2's default,
when unset); with `-- --timeout <s>`, pass `-c komira.test_timeout_s=<s>`
too. The `mojo_test` macro reads the key when the BUCK file is loaded (a rule
cannot read configuration) and passes it as `test_timeout_s`; a BUCK file may
not set it. A library's `test_srcs` are build actions, not tests: buck2 gives
them no timeout, and this limit does not apply to them (README.md, "Time
limits").
"""

# The `--timeout` of buck2's test runner when `buck2 test` passes none.
BUCK2_TEST_RUNNER_TIMEOUT_S = 600

# How long before the runner's timeout test_deadline.sh kills the test: the
# time the action spends around the test itself (staging its tree,
# gate_runner.sh's report, the kill's 10 s grace), with room to spare.
TEST_LIMIT_MARGIN_S = 60

def test_timeout_s():
    """`[komira] test_timeout_s` of the root cell: the runner's timeout."""
    raw = read_root_config("komira", "test_timeout_s", None)
    if raw == None:
        return BUCK2_TEST_RUNNER_TIMEOUT_S
    raw = raw.strip()
    if not regex_match("^[0-9]+$", raw):
        fail("[komira] test_timeout_s = {} is not a whole number of seconds".format(repr(raw)))
    timeout = int(raw)
    if timeout <= TEST_LIMIT_MARGIN_S:
        fail("[komira] test_timeout_s = {} must be over {} s: a mojo_test is stopped {} s before it".format(timeout, TEST_LIMIT_MARGIN_S, TEST_LIMIT_MARGIN_S))
    return timeout

def with_test_limit(test_rule):
    """`test_rule` (mojo_test_rule), given `test_timeout_s` from the config."""
    def call(**kwargs):
        if "test_timeout_s" in kwargs:
            fail("{}: test_timeout_s is [komira] test_timeout_s of the root .buckconfig; a BUCK file may not set it".format(kwargs.get("name", "?")))
        return test_rule(test_timeout_s = test_timeout_s(), **kwargs)
    return call

TEST_LIMIT_ATTRS = {
    # Set by the mojo_test macro; see with_test_limit.
    "test_timeout_s": attrs.int(),
    "_test_deadline": attrs.dep(default = "komira//tools/build/mojo:test_deadline.sh"),
}

def deadline_prefix(ctx, busybox, label):
    """The words that run a test command under test_deadline.sh."""
    timeout = ctx.attrs.test_timeout_s
    if timeout <= TEST_LIMIT_MARGIN_S:
        fail("{}: test_timeout_s = {} must be over {} s".format(label, timeout, TEST_LIMIT_MARGIN_S))
    script = ctx.attrs._test_deadline[DefaultInfo].default_outputs[0]
    return [busybox, "sh", script, busybox, str(timeout - TEST_LIMIT_MARGIN_S), str(timeout), label, "--"]
