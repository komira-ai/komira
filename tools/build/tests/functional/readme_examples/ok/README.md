# ok

`greet` says hello:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from ok import greet

assert_equal(greet("komira"), "hello, komira")
```

A declaration is module-level, so its example is fenced `mojo module` and
has its own `main`; a triple-quoted string is copied as it is:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo module
from ok import greet


@fieldwise_init
struct Pair(Copyable):
    var a: String
    var b: String

    def both(self) -> String:
        return greet(self.a) + "; " + greet(self.b)


comptime NOTE = """two
  lines"""


def main() raises:
    var p = Pair("a", "b")
    assert_equal(p.both(), "hello, a; hello, b")
    print(NOTE)
```

- In a list item:

  ```mojo
  from ok import greet
  print(greet("item"))
  ```

A `~~~~` fence may quote a ``` line; the example is all of it:

~~~~mojo
var fence = """
```
"""
print(fence)
~~~~
