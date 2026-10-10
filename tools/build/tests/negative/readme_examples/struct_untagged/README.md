# struct_untagged

The example declares a struct but is fenced plain `mojo`: the mode comes
from the fence tag only, so the struct is pasted into `def main()`, where a
struct may not be declared, and the example's compile fails.

```mojo
@fieldwise_init
struct Pair(Copyable):
    var n: Int

print(Pair(1).n)
```
