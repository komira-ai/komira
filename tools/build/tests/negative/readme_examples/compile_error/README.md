# compile_error

The example calls a function the package does not have; the compiler's
error quotes the line, which ends with its README line.

```mojo
from compile_error import greet
print(greet("a"))
print(farewell("a"))
```
