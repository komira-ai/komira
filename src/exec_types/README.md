# exec_types

The result and error types that cross the operator / scheduler / caller boundary: EngineError, ExecResult, ProcessResult, QueryContext, the byte-budget parser, the PartitionBy output contract.

## Examples

An operator reports a failure as an `EngineError`, which carries a code, tests with predicates and becomes a Mojo `Error` for `raise`.

```mojo
from std.testing import assert_equal, assert_true
from exec_types.engine_error import EngineError, ERR_IO, io_error, udf_error

var e = io_error("disk full")
assert_equal(e.code, ERR_IO)
assert_true(e.is_io())
assert_true(not e.is_udf())
assert_true("[IO]" in String(e.to_error()))

var u = udf_error("my_udf", "null input")
assert_true(u.is_udf())
assert_true("'my_udf'" in String(u.to_error()))

var wrapped = EngineError.from_error(Error("something broke"))
assert_true("something broke" in wrapped.message)
```

An operator tells the scheduler what to do next with an `ExecResult`, and a byte budget such as `8M` is parsed with `parse_byte_size`.

```mojo
from std.testing import assert_equal, assert_true
from exec_types.exec_result import ExecResult, NEED_MORE_INPUT, FINISHED
from exec_types.byte_size import parse_byte_size

var r = ExecResult(NEED_MORE_INPUT)
assert_true(r.is_need_more_input())
assert_true(not r.is_finished())
assert_true(ExecResult(FINISHED).is_finished())

assert_equal(parse_byte_size("8M"), 8 * 1024 * 1024)
assert_equal(parse_byte_size("4k"), 4096)
assert_equal(parse_byte_size("nonsense"), 0)
```
