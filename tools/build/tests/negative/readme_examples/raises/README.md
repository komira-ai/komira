# raises

The first example passes; the second raises, so the library's gate fails
naming README.md:13, and the first still counts.

```mojo
from raises import greet
print(greet("a"))
```

The planted failure:

```mojo
from raises import greet
if greet("b") != "goodbye, b":
    raise Error("planted: greet does not say goodbye")
```
