# komira_awslc

aws-lc 1.39.0's libcrypto as a static archive, `libawslc.a`, for linux x86_64 and macOS arm64. Every global symbol it defines is renamed `komira_awslc_X`, so it can share
a process with any other libcrypto. It is the one copy of aws-lc that `komira_crypto` and `komira_uuid` link: a program that holds both links a single archive.

The package has no Mojo code. Its library is the archive; its test calls aws-lc's own known-answer self test (`BORINGSSL_self_test`) and SHA-256, AES-128 and ChaCha20
known-answer vectors through the C API. The C names a caller uses (`komira_awslc_SHA256`, ...) are declared by the caller, in the module that owns the foreign resource.

- Source: the aws-lc 1.39.0 release archive, pinned by url, sha256 and size in `BUCK`. The files that are built are listed, not globbed: `third_party/aws-lc/files.bzl`
  holds the lists, generated from the archive's `CMakeLists.txt` and held to it by a drift test.
- Build: the way aws-lc's CMake build builds it with Perl and Go off and FIPS off, by the pinned zig. On linux x86_64 it assembles aws-lc's ELF assembly
  (`generated-src/linux-x86_64`) and s2n-bignum's x86_64 assembly. On macOS arm64 it assembles aws-lc's Apple arm64 set (`generated-src/ios-aarch64`) and s2n-bignum's arm
  assembly, at the Apple M1 CPU; `native/CommonCrypto/CommonRandom.h` stands in for the macOS SDK header the pinned zig does not ship (the function it declares is libSystem's).
- Symbols: the prefix is applied to the C names and to the names the assembly defines (a Mach-O assembly name carries a leading underscore). `__umodti3`, defined by
  `native/umodti3.c` so that zig's compiler runtime stays out of the link, is the one name left as it is.
- Not built: aws-lc's `libssl` and `bssl` (see `third_party/aws-lc`), and the linux arm64 assembly set.

## Examples

The archive's names are `komira_awslc_` followed by aws-lc's own. A caller declares the ones it uses, in the module that owns the foreign resource, and the program links
`libawslc.a` with no flag of its own. SHA-256 of "abc" (FIPS 180-2, appendix B.1) through aws-lc's `SHA256`, after its known-answer self test:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.ffi import external_call

assert_equal(external_call["komira_awslc_BORINGSSL_self_test", Int32](), 1)

var message: List[UInt8] = [0x61, 0x62, 0x63]
var digest = List[UInt8](length=32, fill=0)
# SHA256 returns its output pointer; read as an address and ignored.
_ = external_call["komira_awslc_SHA256", Int](message.unsafe_ptr(), UInt64(3), digest.unsafe_ptr())
var want: List[UInt8] = [
    0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde,
    0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
    0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
]
for i in range(32):
    assert_equal(digest[i], want[i])
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_awslc`, version 0.1.0 (`mopm.toml`). `libawslc.a` is built by the `native_library`
target `:awslc` of `BUCK`, and `mojo_package(natives = ...)` takes it as `[native.awslc]` of `mopm.toml`: it links the archive into the tests of this package and of every
package that depends on it, and packs it into the package under `lib/`. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the native library, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |
| `native/awslc_provided.c` | named by `[native.awslc]` because the manifest has no entry for a library the package does not compile; it is not compiled |
| `native/umodti3.c`, `native/CommonCrypto/CommonRandom.h` | the compiler builtin, and the macOS SDK header stand-in, described above |

`:lib` is the library file and exists only once the test of `tests/` has passed. After any change to a source, a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run
`buildrules mojo sync`, commit what it writes, and build `komira//src/komira_awslc:lib` on the farm.

`:conda` is the `.conda` of the mopm package (`mojo-komira_awslc-0.1.0-mojo1.0.0_0.conda`): the `.mojoc` and `lib/libawslc.a`. `:komira_awslc` is `:lib` as komira's Mojo rules
take it (`mojo_adopted_library`): a package that lists it in `deps` links the same archive.
