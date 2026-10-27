# komira_so

The C ABI of komira's one shared library, `libkomira` (`libkomira.so` on Linux,
`libkomira.dylib` on macOS arm64). Every language binding links against that
one library and its flat C surface: no Mojo type crosses it. This package holds
the surface's skeleton: the status codes, the version, the context handle and
the last-error call. No source, plan or query call is exported yet.

- `status.mojo`: the five status codes, `abi_version`, `buffer_status`.
- `session.mojo`: `Session`, the state a context handle stands for.
- `_c_abi.mojo`: the exports. It is the only file here that holds pointers, it
  is not part of the Mojo package (it is the source of the `libkomira`
  target), and its header says who owns and frees each pointer.

## The C surface

```text
int32_t  komira_abi_version(void);
void    *komira_ctx_new(void);
void     komira_ctx_free(void *ctx);
int32_t  komira_last_error(void *ctx, uint8_t *out_buf, uint64_t out_cap,
                           uint64_t *out_len);
```

**Status codes.** Every fallible call returns one: `KOMIRA_OK` (0),
`KOMIRA_ERR_NULL_CTX` (-1, the context is NULL), `KOMIRA_ERR_NULL_ARG` (-2, a
required pointer other than the context is NULL), `KOMIRA_ERR_ENGINE` (-3, the
engine refused; the context's last error says why) and
`KOMIRA_ERR_BUFFER_TOO_SMALL` (-4, below).

A caller tells the codes apart by value alone: success is zero, every failure
is negative.

```mojo
from komira_so import (
    KOMIRA_ERR_BUFFER_TOO_SMALL,
    KOMIRA_ERR_ENGINE,
    KOMIRA_ERR_NULL_ARG,
    KOMIRA_ERR_NULL_CTX,
    KOMIRA_OK,
)
from std.testing import assert_equal, assert_true

assert_equal(KOMIRA_OK, Int32(0))
assert_equal(KOMIRA_ERR_NULL_CTX, Int32(-1))
assert_equal(KOMIRA_ERR_NULL_ARG, Int32(-2))
assert_equal(KOMIRA_ERR_ENGINE, Int32(-3))
assert_equal(KOMIRA_ERR_BUFFER_TOO_SMALL, Int32(-4))
assert_true(KOMIRA_ERR_ENGINE < KOMIRA_OK)
```

**Version.** `komira_abi_version()` is `major * 1000 + minor`: 1000 is 1.0.
Adding a symbol raises the minor version; changing or removing one raises the
major version and resets the minor to 0. The minor version stays below 1000.

```mojo
from komira_so import ABI_MAJOR, ABI_MINOR, abi_version
from std.testing import assert_equal

assert_equal(abi_version(), ABI_MAJOR * 1000 + ABI_MINOR)
assert_equal(abi_version(), Int32(1000))
```

**The handle.** `komira_ctx_new` returns a context the caller owns until it
passes it to `komira_ctx_free`. A handle is not safe to use from two threads at
once, freeing one twice or using it after the free is undefined (as for
`free(3)`), and `komira_ctx_free(NULL)` does nothing. A context holds a
`Session`: today, the text of the last error, empty on a fresh one.

```mojo
from komira_so import Session
from std.testing import assert_equal, assert_false, assert_true

var session = Session()
assert_false(session.has_error())
session.set_error(String("the file does not exist"))
assert_true(session.has_error())
assert_equal(session.last_error(), String("the file does not exist"))
session.clear_error()
assert_equal(session.last_error(), String(""))
```

**The two-call output protocol.** A call that returns bytes takes
`out_buf`, `out_cap` and `out_len`. It stores the byte count in `*out_len`
first. If `out_cap` is below the count it returns `KOMIRA_ERR_BUFFER_TOO_SMALL`
and writes nothing, so a caller never parses a truncated answer. So a caller
calls once with `out_cap` 0 (and `out_buf` NULL) to learn the length, allocates
that many bytes, and calls again.

```mojo
from komira_so import KOMIRA_ERR_BUFFER_TOO_SMALL, KOMIRA_OK, buffer_status
from std.testing import assert_equal

assert_equal(buffer_status(12, UInt64(0)), KOMIRA_ERR_BUFFER_TOO_SMALL)
assert_equal(buffer_status(12, UInt64(11)), KOMIRA_ERR_BUFFER_TOO_SMALL)
assert_equal(buffer_status(12, UInt64(12)), KOMIRA_OK)
assert_equal(buffer_status(0, UInt64(0)), KOMIRA_OK)
```

**`komira_last_error`.** It copies the session's last error text, which is
UTF-8 and not NUL-terminated, into `out_buf` by that protocol. A fresh session's
text is empty: the call returns `KOMIRA_OK` with `*out_len` 0 and needs no
buffer. A NULL `ctx` is checked first (-1); then a NULL `out_len` (-2); a NULL
`out_buf` is refused (-2) only when there is text to write. A call refused for
a NULL argument on a live context stores its refusal as that context's last
error; a too-small buffer stores nothing, so the text a probe measured is the
text the next call returns.

## Building and testing

```sh
./buck2 build komira//src/komira_so:komira_so       # the package and its tests
./buck2 build komira//src/komira_so:libkomira       # the shared library, behind its gate
```

The library is published only if the gate passes: the exports check, then six
drivers (`tests/gate/`) that open it with `RTLD_NOW` and call it as a foreign
host would: the version, create and free, a fresh session's empty error, the
two-call protocol (zero capacity, one byte short, exact, larger), a NULL
context, and a NULL `out_len`. `exports_exact` makes the four names above the
whole dynamic symbol table.

Like every Mojo library, `libkomira` has `DT_NEEDED libKGENCompilerRTShared.so`
and finds the Mojo runtime in `lib/` beside it
(see "C-ABI shared libraries" in `tools/build/mojo/README.md`).

## Not done

No golden file, generated header or version check yet; no source, plan or query
call; no engine in the session; no language binding.
