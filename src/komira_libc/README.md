# komira_libc

The libc and POSIX layer every package shares: one getenv, the access probes and pthread_self, file and memory-map syscall wrappers with the C shim symbols they call, chunked large writes, RAII file descriptor.

`getenv` is declared here and nowhere else, so a program never links two
conflicting declarations of it, and the `komira_*` C shim symbols are defined
only in this package's C file. The package root re-exports nothing; import
each name from its module:

- `komira_libc.posix_io`: `RawWriteFd`, an owning handle for a write-only file
  descriptor (`open_truncate`, `open_existing_append`,
  `open_create_exclusive`; `write_bytes`, `pwrite_at`, `writev_addr_len`,
  `seek_to_end`, `ftruncate_size`, `fsync`, `close`; it closes itself when
  dropped), and the path helpers `fsync_path`, `fsync_dir` and
  `prefetch_file_into_page_cache`.
- `komira_libc.fd_write_all`: `write_all_fd`, which writes a whole byte span to
  a descriptor, at most `max_call_bytes` (64 MiB by default) per `write(2)`,
  and raises rather than return after a partial write.
- `komira_libc.chunked_write`: `write_chunked` and `write_chunked_string`,
  which write to a standard-library `FileHandle` in 64 MiB pieces.
- `komira_libc.owned_fd`: `OwnedFd`, which closes a descriptor it owns when
  dropped.
- `komira_libc.posix`: the one `getenv` (`_read_env`, and `_read_env_into`
  for secrets), the one `unsetenv` (`_unset_env`, which removes a secret's
  variable once it is read), the `access(2)` probes `_path_is_directory` and
  `_path_is_executable`, and `_thread_self`.
- The C shim (`native/komira_libc_posix.c`) holds the fixed-arity wrappers
  over the variadic and platform-width POSIX calls, including the read-only
  memory-map, `munmap` and `madvise` wrappers `komira_buffer` calls.

## Examples

Write a file through a raw descriptor in a temporary directory, which the
example removes even if a step fails: a positional write leaves the
descriptor's offset alone, a second descriptor opened to append starts at the
end, and an exclusive create of an existing path is refused:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.os import remove, rmdir
from std.os.path import exists
from std.tempfile import mkdtemp
from komira_libc.chunked_write import write_chunked_string
from komira_libc.posix_io import RawWriteFd, fsync_dir, fsync_path

var dir = mkdtemp()
var path = dir + "/data.txt"
var notes = dir + "/notes.txt"
try:
    var fd = RawWriteFd.open_truncate(path)
    fd.write_bytes("hello, world".as_bytes())
    fd.pwrite_at(7, "WORLD".as_bytes())  # the offset stays at 12
    fd.write_bytes("!".as_bytes())
    fd.close()
    fd.close()  # closing twice is a no-op
    assert_true(fd.is_closed())

    var appender = RawWriteFd.open_existing_append(path)
    assert_equal(appender.seek_to_end(), 13)  # the file's size
    appender.write_bytes(" bye".as_bytes())
    appender.ftruncate_size(15)  # cut back to 15 bytes
    appender.close()
    fsync_path(path)
    fsync_dir(dir)
    with open(path, "r") as f:
        assert_equal(f.read(), "hello, WORLD! b")

    var refused = False
    try:
        _ = RawWriteFd.open_create_exclusive(path)
    except:
        refused = True
    assert_true(refused)

    with open(notes, "w") as handle:
        write_chunked_string(handle, "one write, at most 64 MiB a piece")
    with open(notes, "r") as f:
        assert_equal(f.read(), "one write, at most 64 MiB a piece")
finally:
    if exists(path):
        remove(path)
    if exists(notes):
        remove(notes)
    rmdir(dir)
```

`write_all_fd` issues no system call for an empty span, refuses a clamp that
cannot make progress, and names the caller's context in every error. `OwnedFd`
treats a negative descriptor as nothing to close:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_libc.fd_write_all import write_all_fd
from komira_libc.owned_fd import OwnedFd

var nothing = OwnedFd(Int32(-1))
assert_false(nothing.is_valid())
assert_equal(write_all_fd(nothing.raw(), "".as_bytes(), "demo"), 0)

var clamp_error = String()
try:
    _ = write_all_fd(nothing.raw(), "data".as_bytes(), "demo", max_call_bytes=0)
except e:
    clamp_error = String(e)
assert_true(clamp_error.startswith("demo: write_all_fd was given max_call_bytes=0"))

var write_error = String()
try:
    _ = write_all_fd(nothing.raw(), "data".as_bytes(), "demo")
except e:
    write_error = String(e)
assert_true(write_error.startswith("demo: write(2) returned -1 for a 4-byte call"))
```

## Files

| file | what it holds |
|---|---|
| `posix.mojo` | the one `getenv` and `unsetenv`, the `access(2)` probes and `_thread_self` |
| `posix_io.mojo` | `RawWriteFd` and the path helpers `fsync_path`, `fsync_dir`, `prefetch_file_into_page_cache` |
| `fd_write_all.mojo` | `write_all_fd` |
| `chunked_write.mojo` | `write_chunked` and `write_chunked_string` |
| `owned_fd.mojo` | `OwnedFd` |
| `native/komira_libc_posix.c` | the C shim: the `komira_*` wrappers and the two memory-map counters |

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_libc`, version 0.1.0
(`mopm.toml`). The library is `src/komira_libc/` (the Mojo files of the table above), its tests are `tests/`.
The C shim is a native library of the package, `[native.komira_libc_posix]` in `mopm.toml`: `mojo_package`
compiles it into `libkomira_libc_posix.a`, links it into the tests of this package and of every package that
depends on it, and packs it into the package under `lib/`. A program that imports `komira_libc` from the
installed package links that archive. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the native library, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a
source, a test, the C file, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`,
commit what it writes, and build `komira//src/komira_libc:lib` on the farm.

`:conda` is the `.conda` of the mopm package (`mojo-komira_libc-0.1.0-mojo1.0.0_0.conda`): the `.mojoc` and
`lib/libkomira_libc_posix.a`. `:komira_libc` is `:lib` as komira's Mojo rules take it
(`mojo_adopted_library`): a package that lists it in `deps` links the same archive. It also compiles and runs
the README's examples above (`[tests][readme]`) against `:lib` and the archive. The shared library
`libkomira_libc_native.so.1` (`:komira_libc_native`) is the release set's packaging of the same C file.
