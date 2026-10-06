# komira_test_verdict

The exit-code vocabulary of a test that can do more than pass or fail. A
`Verdict` records what a teardown or a leak check found: CLEAN (0),
CANNOT_TELL (3) or LEAK (6). When findings disagree the worst wins, LEAK
ranking above CANNOT_TELL, and every residue key and reason is kept.
`exit_skip` (77) and `exit_cannot_tell` (3) print one marker line naming why a
test could not run and end the process; neither ever exits 0. The package
imports only the standard library.

## Examples

Fold findings together; the worst kind wins and nothing is dropped:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_test_verdict import Verdict, VERDICT_LEAK

var teardown = Verdict()
teardown.add_cannot_tell("list: HTTP 503")
var check = Verdict()
check.add_residue("run-1/part-0")
teardown.merge(check)
assert_equal(teardown.kind, VERDICT_LEAK)
assert_equal(teardown.exit_code(), 6)
assert_equal(String(teardown), "LEAK residue=[run-1/part-0] reasons=[list: HTTP 503]")
```

`require_clean` raises with the whole verdict unless it is CLEAN:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_test_verdict import Verdict

Verdict().require_clean()
var v = Verdict()
v.add_cannot_tell("stop not confirmed")
var message = String()
try:
    v.require_clean()
except e:
    message = String(e)
assert_true(not v.is_clean())
assert_equal(message, "komira_test_verdict: teardown verdict CANNOT_TELL reasons=[stop not confirmed]")
```

The marker lines a skipped or undecided test prints, kept on one line (calling
`exit_skip` or `exit_cannot_tell` itself would end the process):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_test_verdict import CANNOT_TELL_EXIT_CODE, SKIP_EXIT_CODE
from komira_test_verdict import cannot_tell_line, skip_line

assert_equal(skip_line("nothing configured"), "KOMIRA-TEST: SKIP reason=nothing configured")
assert_equal(cannot_tell_line("a\nb"), "KOMIRA-TEST: CANNOT_TELL reason=a b")
assert_equal(skip_line(""), "KOMIRA-TEST: SKIP reason=unspecified")
assert_equal(SKIP_EXIT_CODE, 77)
assert_equal(CANNOT_TELL_EXIT_CODE, 3)
```
