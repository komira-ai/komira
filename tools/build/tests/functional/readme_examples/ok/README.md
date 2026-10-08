# ok

`greet` says hello:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from ok import greet

assert_equal(greet("komira"), "hello, komira")
```

A declaration is hoisted out of the example; a triple-quoted string is copied
as it is:

```mojo
from ok import greet


@fieldwise_init
struct Pair(Copyable):
    var a: String
    var b: String

    def both(self) -> String:
        return greet(self.a) + "; " + greet(self.b)


comptime NOTE = """two
  lines"""
var p = Pair("a", "b")
print(p.both())
print(NOTE)
```
<!-- mojo-hidden
assert_equal(Pair("x", "y").both(), "hello, x; hello, y")
-->

- In a list item:

  ```mojo
  from ok import greet
  print(greet("item"))
  ```

An import may run over several lines, in parentheses or after a backslash;
it is hoisted whole:

```mojo
from ok import (
    greet,
)
from ok import \
    greet as hello

assert_equal(hello("x"), greet("x"))
```

A `~~~~` fence may quote a ``` line; the example is all of it:

~~~~mojo
var fence = """
```
"""
print(fence)
~~~~
