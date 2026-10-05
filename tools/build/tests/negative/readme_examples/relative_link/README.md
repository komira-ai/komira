# relative_link

The example passes, but the link on line 11 is relative and this README ships
in the package, where `greet.mojo` does not exist: the gate fails naming
README.md:11.

```mojo
from relative_link import greet
print(greet("a"))
```
See [greet.mojo](greet.mojo).
