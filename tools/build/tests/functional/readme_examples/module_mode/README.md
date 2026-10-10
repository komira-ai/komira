# module_mode

An example that declares a struct is fenced `mojo module`: it is a whole
program, copied as it is, with its own `main`.

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo module
from module_mode import greet


@fieldwise_init
struct Pair(Copyable):
    var a: String
    var b: String

    def both(self) -> String:
        return greet(self.a) + "; " + greet(self.b)


def main() raises:
    assert_equal(Pair("x", "y").both(), "hello, x; hello, y")
```

A second module example declares the same struct name: it is another program.

```mojo module
@fieldwise_init
struct Pair(Copyable):
    var n: Int


def main():
    print(Pair(2).n)
```

- A `mojo module` fence inside a list item is a whole program too, dedented
  by the fence's indent:

  ```mojo module
  @fieldwise_init
  struct Pair(Copyable):
      var n: Int


  def main():
      print(Pair(3).n)
  ```
