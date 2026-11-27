# expected_output

A fixture of the README examples tool: a source-first README whose example
carries `examples/greet.expected_output.txt`, so its welded test holds what
the example prints to that file byte for byte.

<!-- include examples/greet.mojo -->
```mojo
def main():
    print("hello")
    print(2 + 3)
```

It prints:

<!-- include examples/greet.expected_output.txt -->
```text
hello
5
```
