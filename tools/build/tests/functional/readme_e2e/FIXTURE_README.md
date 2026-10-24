# fixture_native

A Mojo package of the README e2e's tests that ships a native library: `native_add` adds two numbers
in C, in the static archive the package carries. A program that imports it links the archive only if
the installer's link command names it.

## Examples

The sum comes from the C library:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from fixture_native import native_add

assert_equal(native_add(40, 2), 42)
```
