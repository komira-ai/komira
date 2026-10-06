# komira_collections

The typed slab, a type-erased inline value, a variadic pack, a HyperLogLog cardinality sketch: generic containers with no dependencies.

The example below runs as a test when the package is built.

## DynValue: one value of any type, stored inline

`DynValue[MAX_SIZE]` holds one value of any `Movable` type of at most
`MAX_SIZE` bytes, with no heap allocation, and destroys it when dropped.
`get[T]()` returns a reference to the value, mutable when the `DynValue` is.
It is checked: it raises when the `DynValue` is empty or holds another type
(the stored type's qualified name and size are compared). `holds[T]()` asks
the same question without raising.

```mojo
from komira_collections.dyn_value import DynValue
from std.testing import assert_equal, assert_false, assert_raises, assert_true

@fieldwise_init
struct Point(Movable):
    var x: Int
    var y: Int

var dv = DynValue[32].create[Point](Point(3, 4))
assert_true(dv.holds[Point]())
assert_equal(dv.get[Point]().x, 3)

dv.get[Point]().y = 10
assert_equal(dv.get[Point]().y, 10)

assert_false(dv.holds[Int]())
with assert_raises(contains="asked for"):
    _ = dv.get[Int]()
```
