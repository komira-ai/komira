# covreadme

A fixture of the coverage tests (43 and 46): its only test is this example,
which its coverage build runs under kcov, so `twice` is covered.

```mojo
from covreadme import twice
from std.testing import assert_equal

assert_equal(twice(3), 6)
```
