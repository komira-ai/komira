# native_reach

The call half of `mojo_library`'s native-reach check
([`../README.md`](../README.md), "Native reach"; the rule side is
[`../native_reach.bzl`](../native_reach.bzl)).

```
native_reach --out <file> --library <label> --src <dir> (--refuse <prefix>=<owner>)...
```

It reads every `*.mojo` file under `<dir>`, a library's staged sources, and
finds each string literal starting with a refused prefix: the prefix of an
owner the rule found outside the library's Mojo deps closure. A line is read
up to its first `#` outside a string; a string opens with `"` or `'`, and `\`
escapes the next character. `<out>` is a Buck2 validation result: failure,
naming each name with its file and line, or success. Exit 0 when `<out>` is
written, 2 on a usage error or an unreadable source.

`:native_reach_unit` runs the cases of
[`native_reach_test.zig`](native_reach_test.zig) as a build action, and
`:native_reach` is built behind it.
