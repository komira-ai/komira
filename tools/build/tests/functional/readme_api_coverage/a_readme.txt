# komira_a

`top_level` is named in prose only, so it is not used; the ledger excepts it.

<!-- mojo-hidden
from komira_a import bye
_ = bye("hidden")
-->
```mojo
from komira_a import greet, Greeter, Square, Box, area

var g = Greeter("x")
print(g.hello())  # g.wave() is named only in a comment
for wave in range(2):
    print(wave)  # a bare `wave` is not the method `.wave`
var s = Square(side=2)
var squared_area = s.perimeter()
var b = Box[Int](item=squared_area)
print(b.get(), squared_area)
```

```mojo
print(greet("y"), MISSING)
print("ANSWER and make() in a string")
print("""errors
in a triple-quoted string""")
```

`area` is only imported above; a README's own declaration of a name is not a
use either, so this `area` uses neither `area` nor `Square.area`:

```mojo
struct Local:
    def area(self) -> Int:
        return 0
```

A sketch is not an example:

```text
area(Square(side=1))
```
