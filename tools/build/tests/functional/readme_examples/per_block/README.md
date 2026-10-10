# per_block

Each example is a program of its own, so two examples may declare the same
names, and each imports what it uses inside its own `main`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from per_block import greet

def twice(s: String) -> String:
    return s + s

var said = twice(greet("a"))
assert_equal(said, "hello, ahello, a")
```

```mojo
from per_block import greet

def twice(s: String) -> String:
    return greet(s) + "; " + greet(s)

var said = twice("b")
print(said)
```
<!-- mojo-hidden
from std.testing import assert_equal
assert_equal(said, "hello, b; hello, b")
-->

A multi-line string is pasted as it is, indented with the rest:

```mojo
var note = """two
lines"""
print(note)
```
