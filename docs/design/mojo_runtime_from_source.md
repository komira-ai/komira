# The Mojo runtime libraries from Modular's published source

The Python wheel carries three Mojo runtime libraries, `libKGENCompilerRTShared`,
`libAsyncRTRuntimeGlobals` and `libMSupportGlobals`, copied unmodified from the pinned
`mojo-compiler` conda package ([wheel_licence_audit.md](wheel_licence_audit.md)), 1.1.0 today
(tools/build/platforms/table.bzl); this page's measurements were made when the pin was 1.0.0. That
package's licence is Modular's, not Apache-2.0. This page answers one question with evidence:
could komira build those three libraries itself, from the source Modular publishes at
github.com/modular/modular, and ship those instead?

Nothing here was built or uploaded. The page records what the published source, Modular's
packages and komira's own built library say.

Tags: **MEASURED** = read from downloaded files or from a built library; **STATED** = read in a
file of Modular's repository or of this one, at the path given; **INFERRED** = deduced, not run.

## The answer

The source of all three libraries is published, under Apache-2.0 with LLVM exceptions, but not at
the `mojo/v1.0.0` tag. The first release tag that holds it is `mojo/v1.1.0`, where every file of
the three libraries' own code carries the Apache header.

Modular's published history also holds the source state the 1.0.0 binaries were built from. There
its files still carry the header "This file is Modular Inc proprietary." The Apache headers arrive
a few commits later, in a commit whose runtime code differs from that state only in a handful of
lines.

libkomira needs five C functions from `libKGENCompilerRTShared` and nothing else from the three
libraries. All five are defined in three published files, and they are the same code in the
1.0.0 source state, at 1.1.0 and at 1.2.0.

The shipped `libKGENCompilerRTShared` also contains GPU device-context code (CUDA, HIP, Metal).
That code is not in the 1.1.0 or 1.2.0 trees, and on the main branch it is under the MAX
licence. Modular's own public build leaves it out, and libkomira uses none of it.

So a from-source runtime is possible. It is not a binary swap but a new third-party build:

- llvm-project's Support library;
- tcmalloc and abseil;
- fmt;
- Modular's `Support`, `AsyncRT` and `Mojo/lib/CompilerRT` code;
- a Mach-O link path komira does not have yet.

Two things hold the match between a from-source runtime and the pinned compiler, and nothing else
does:

- the C names of the entry points;
- choosing the source at the compiler's own release tag.

Modular provides no ABI version and no check. The GNU build ids of a from-source copy can never
equal Modular's, so komira's loader check (`python/komira/_runtime.py`) would then refuse any
Modular runtime already loaded in the process, including one of the same version.

The route that needs no untagged source moves the compiler pin to a release tag that carries the
source (1.1.0 or later) and builds the runtime from that same tag. Sized below (an estimate, not
measured) at roughly six to ten weeks of one engineer, with three places that could refuse.

## 1. Where the source is

### By tag (MEASURED, `git ls-tree` of each tag)

| tag | top-level directories with runtime code | runtime source present |
|---|---|---|
| `mojo/v1.0.0` | none: the tree has `bazel`, `docs`, `max`, `mojo`, `tools`, `utils` only; its only C/C++ files are C-API headers, examples, tests and Bazel helpers | no |
| `mojo/v1.1.0` | `AsyncRT`, `Mojo`, `Support`, `Config`, `Cache`, `Init` | yes |
| `mojo/v1.2.0` | the same | yes |
| main | the same, plus `MLRT`, `Target`, `GraphCompiler`, `Kernels`, `SDK` | yes |

The `mojo/v1.0.0` tree is a stripped export of the branch it was released from.

### The source state of the 1.0.0 binaries

The 1.0.0 release branch and `mojo/v1.1.0` share a merge base (`git merge-base`, MEASURED). That
merge base is the stripped commit "[packaging] Move AsyncRTMojoBindings and NVPTX to max-core".

Modular's published history also holds a full-tree commit with the same subject, which is an
ancestor of `mojo/v1.1.0` and of main. It came into the public history with the merge "Open source
Mojo", whose second parent carries the earlier history. At that commit the runtime paths are
`KGEN/lib/CompilerRT/`, `AsyncRT/` and `Support/`. A later commit, "[Mojo] Rename KGEN -> Mojo",
moved them to `Mojo/lib/CompilerRT/`.

The 1.0.0 binaries match that full-tree commit and nothing after it (MEASURED, linux-x86_64):

- Each of the 47 `KGEN_CompilerRT_*` names `libKGENCompilerRTShared.so` exports
  (`nm -D --defined-only`) is defined in that commit's `KGEN/lib/CompilerRT`, and that source
  exports no other.
- At `mojo/v1.1.0` that source defines six more (`KGEN_CompilerRT_ExternalProfilerAnnotation*`
  and `KGEN_CompilerRT_RangeIsRecording`). The 1.0.0 binary has none of them.
- The compiler binary `bin/mojo` of the same package contains the diagnostic "is not a
  recognized target feature name", added by the commit's parent.
- It lacks the FP6 type names `f6e2m3fn` and `f6e3m2fn`, added by the next runtime commit, "[KGEN][Support]
  Represent the OCP MX FP6 dtypes in the compiler".
- `libKGENCompilerRTShared.so` holds two `sigaltstack` call sites, both in LLVM's own signal
  handler setup. It lacks the three that "[AsyncRT] Give worker threads an alternate signal stack"
  adds.

aarch64 and macOS were not fingerprinted. That they come from the same source is INFERRED.

### Licence header of that state (MEASURED, `git show <commit>:<path>`)

At the full-tree commit above, the runtime files open with:

> This file is Modular Inc proprietary.

The Apache header arrives in the commit "[lint] Adjust copyright headers for Mojo OSS files". From
there on, `Memory.cpp` and the other runtime files open with the line below, followed by the URL
of the LLVM project's `LICENSE.txt`:

> Licensed under the Apache License v2.0 with LLVM Exceptions:

Between the 1.0.0 source state and that commit, the non-header changes to `KGEN/lib/CompilerRT`,
`AsyncRT/lib`, `AsyncRT/include`, `Support/lib` and `Support/include` are these (MEASURED,
`git diff` with comment lines removed):

- the FP6 dtype rows (`Support/include/Support/ML/{DType.h,FloatTypes.def,FloatTypes.h}`,
  `Support/lib/ML/DType.cpp`);
- a sub-byte dtype sizing fix in `Support/lib/ML/DType.cpp`;
- a NIXL plugin helper (`Support/lib/NixlPluginDir.cpp` and its header).

None of them touches the files that define the five functions libkomira imports. The proprietary
header on the older state is a fact this page records. Whether it bears on reuse of that exact
state is not something this page decides; the Apache-headed commits are the ones whose files say
Apache.

### Per library, at `mojo/v1.1.0` and `mojo/v1.2.0` (STATED, BUILD files; MEASURED, header census)

| library | Bazel target | its own sources | header of those sources |
|---|---|---|---|
| `libMSupportGlobals` | `//Support:Globals` (`Support/BUILD.bazel`, `output_name = "MSupportGlobals"`) | `Support/lib/Globals/{ContextGlobal,Globals}.cpp` | Apache-2.0 with LLVM exceptions |
| `libAsyncRTRuntimeGlobals` | `//AsyncRT:RuntimeGlobals` (`AsyncRT/BUILD.bazel`, `output_name = "AsyncRTRuntimeGlobals"`) | `AsyncRT/lib/Runtime/Globals/*.cpp`, plus `AsyncRT/lib/Support/*.cpp` | Apache-2.0 with LLVM exceptions |
| `libKGENCompilerRTShared` | `//Mojo:CompilerRT` (`Mojo/BUILD.bazel`, `output_name = "KGENCompilerRTShared"`) | the 13 files of `Mojo/lib/CompilerRT/`, `Mojo/include/Mojo/CompilerRT/{BinaryID,Registration}.h`, `AsyncRT/lib/Runtime/*.cpp` | Apache-2.0 with LLVM exceptions |

All three closures draw on Modular's `Support/` (Base, ADT, Threading, Configuration, BinaryID,
Log, ML and others) and on `Config/lib/Version.cpp`.

Header census at 1.1.0, counting files whose first 30 lines carry "Apache License v2.0 with LLVM
Exceptions":

| directory | Apache | other |
|---|---|---|
| `Mojo/lib/CompilerRT` | 13 of 13 | none |
| `Mojo/include/Mojo` | 168 of 168 | none |
| `AsyncRT` | 63 of 71 | the rest are `BUILD.bazel` files, which carry no header |
| `Support` | 353 of 366 | the rest are `BUILD.bazel` files and one generated `.inc` |

No file in these directories says "MAX License" at either tag.

### What the shipped `libKGENCompilerRTShared` has that the published source does not

The shipped linux-x86_64 file exports 60 `M::Driver::*` symbols, and its strings name
`MLRT/lib/Driver/DeviceContext/{CPU,CUDA,HIP,Virtual}/*.cpp` (MEASURED). The macOS file exports
1664 `MTL::` and 209 `NS::` symbols (Metal) besides.

In the source, `//Mojo:CompilerRT` lists these under `internal_deps`:

- `//MLRT:Core`
- `//MLRT:Driver/DeviceContextImplCpp`
- `//Support:ProfilerHostGlue`
- `//Support:ExternalProfilerAnnotationHostGlue`
- `@tracy`

Modular's public build wrapper drops them: `modular_shared_library` in `bazel/api.bzl` ignores
`internal_deps` and stubs the `Profiling` targets. It also forces `MODULAR_KGEN_PROFILING_ENABLED=0`
and the accelerator-support defines to 0, and `bazel/config.bzl` sets
`MODULAR_ASYNCRT_MAX_PROFILING_LEVEL` to 0 (STATED).

`MLRT/` is absent from `mojo/v1.1.0` and `mojo/v1.2.0`. On main every file under `MLRT/lib/Driver`
(57) and `Target/` (116) carries:

> Licensed under the MAX License: https://modular.com/legal/max-license

The Tracy headers that `Mojo/lib/CompilerRT/TracyBridge.cpp` and
`AsyncRT/lib/Runtime/ThreadPoolWorkQueue.cpp` include, under the profiling `#if`s above, are not
published at any tag (`Support/BUILD.bazel` says so).

So a library built from the published source has Modular's `KGEN_CompilerRT_*` entry points (the
47 of the 1.0.0 binary at the 1.0.0 source state; those 47 plus the six above at `mojo/v1.1.0`),
without the device-context, Metal and profiler parts. No komira library imports any of
those parts (section 2).

### The LICENSE and README files of the source repository (STATED)

- **Root `LICENSE`**, `mojo/v1.1.0` and `mojo/v1.2.0`, line 2:

  > The Modular repository is licensed under the Apache License v2.0 with LLVM Exceptions:

  followed by the Apache-2.0 text and LLVM's exceptions. At `mojo/v1.0.0` the same line reads
  "The MAX repository is licensed under ...".

- **Root `LICENSE` on main**:

  > Mojo and its contributions are licensed under the Apache License v2.0 with LLVM Exceptions.
  > See Licenses/APACHE_LICENSE.
  >
  > Portions of the MAX source code and its binary distribution are licensed under the MAX
  > License. See Licenses/MAX_LICENSE. The remainder of the source is under the Apache License
  > v2.0 with LLVM Exceptions. See Licenses/APACHE_LICENSE.

- **`README.md`, "License"**, `mojo/v1.1.0`:

  > This repository and its contributions are licensed under the Apache License v2.0 with LLVM
  > Exceptions. See LICENSE. MAX usage and distribution are licensed under the
  > [Modular Community License](https://www.modular.com/legal/community).

- **`Licenses/README.md` on main**:

  > All `Mojo` code is licensed under Apache License v2.0 with LLVM Exceptions.

  and:

  > Different parts of the MAX source are licensed under either the APACHE_LICENSE or the
  > MAX_LICENSE. Refer to each file's comments for the correct license.

- **`Licenses/LICENSE`** at `mojo/v1.1.0` and `mojo/v1.2.0`, titled "Modular MAX Community
  License" (sha256 `f35ac2dfeb4a3e9482468874a50ce4dfb16fc11c3aefd2a1b4d51c44515ed02d`), section 1.4:

  > 1.4 Separately Licensed Components. Portions of MAX have been made available under the Apache
  > License, Version 2.0 with LLVM Exception or under other separate license terms, as identified
  > in the LICENSE file or license header accompanying each such component. Those terms govern
  > those components, and control over these Terms in the event of any conflict. Nothing in these
  > Terms revokes, narrows, conditions or otherwise modifies any right granted under any such
  > separate license.

  Main's `Licenses/MAX_LICENSE` has the same paragraph as its section 1.5.

- **`Licenses/LICENSE` at `mojo/v1.0.0`** is byte-identical to the pinned package's
  `info/licenses/LICENSE` (`cmp`, MEASURED). That is the text quoted in section 5.

## 2. What each library is, and what libkomira needs from it

| library | what it is (STATED, sources and BUILD comments) |
|---|---|
| `libMSupportGlobals` | Process-wide singletons of Modular's support layer: the global `M::Context` pointer and its mutex, config overrides, the type-info table, the profiler context. `Support/BUILD.bazel`: "This library should not have any deps to avoid shared object linking issues". `ContextGlobal.h`: "Implemented in the Globals shared library so there is a single definition per process". |
| `libAsyncRTRuntimeGlobals` | The async runtime's singletons: the CPU device table and its thread-local current device, a task id counter, and the tcmalloc instance the runtime allocates from (`Globals.h`: tcmalloc "has internal global state that needs to live here"; a patched tcmalloc "that doesn't replace malloc"). |
| `libKGENCompilerRTShared` | The runtime entry points compiled Mojo code calls by C name (`KGEN_CompilerRT_*`): aligned allocation (through `libAsyncRTRuntimeGlobals`' tcmalloc by default, `Memory.cpp:23-26`), the named-global registry, stack traces, `fprintf`, the async runtime's CPU device and chains, profiling ranges, core counts. Plus, in Modular's binary, the device-context code above. |

### What komira's built libraries import (MEASURED)

Method: `nm -D --undefined-only` of a farm-built `//src/so:libkomira[runnable]` (its
`libkomira.so` is the 3,524,608 bytes of the src/so/README.md table) against
`nm -D --defined-only` of each runtime library, names without versions, `LC_ALL=C` sort. The
runtime copies in that directory are byte-identical to the pinned linux-x86_64 package's (`cmp`).

| importer | from `libKGENCompilerRTShared` | from `libAsyncRTRuntimeGlobals` | from `libMSupportGlobals` |
|---|---|---|---|
| `libkomira.so` | 5 | 0 | 0 |
| each of the eight `libkomira_*_native.so.1` | 0 | 0 | 0 |

This agrees with the "target's undefined symbols it defines" column of the table in
[src/so/README.md](../../src/so/README.md). `strings` finds no other runtime name in
`libkomira.so`, so nothing is looked up by a literal name with `dlsym`.

The five functions, with their definitions at `mojo/v1.1.0` (STATED):

| symbol | defined at | C signature |
|---|---|---|
| `KGEN_CompilerRT_AlignedAlloc` | `Mojo/lib/CompilerRT/Memory.cpp:37` | `void *(ssize_t alignment, ssize_t size)` |
| `KGEN_CompilerRT_AlignedFree` | `Mojo/lib/CompilerRT/Memory.cpp:49` | `void (void *ptr)` |
| `KGEN_CompilerRT_GetOrCreateGlobal` | `Mojo/lib/CompilerRT/Globals.cpp:28` | `void *(llvm::StringRef name, void *(*init)(), void (*destroy)(void *))` |
| `KGEN_CompilerRT_GetStackTrace` | `Mojo/lib/CompilerRT/System.cpp:132` | `int (char **strings, unsigned depth)` |
| `KGEN_CompilerRT_fprintf` | `Mojo/lib/CompilerRT/System.cpp:53` | `int (FILE *stream, const char *format, ...)` |

All five are `extern "C"` (`COMPILERRT_EXPORT` in `Support/include/Support/SymbolExport.h`), and
all are defined in published Apache-headed source.

- `Memory.cpp`, `Memory.h`, `Globals.cpp` and `System.cpp` are byte-identical at `mojo/v1.1.0` and
  `mojo/v1.2.0`.
- Below their licence header, `Globals.cpp`, `Memory.cpp` and `System.cpp` are identical to the
  1.0.0 source state (MEASURED, `diff`).
- The callers are the compiler and the standard library. The compiler's lowering names
  `KGEN_CompilerRT_AlignedAlloc` and `AlignedFree` as string literals
  (`Mojo/lib/KGENToLLVM/LowerPOPToLLVM.cpp`). The standard library calls the other three through
  `external_call` (`std/builtin/error.mojo`, `std/io/io.mojo`, `std/ffi/__init__.mojo`), and those
  calls are the same at 1.0.0, 1.1.0 and 1.2.0.

The runtime libraries need each other (MEASURED, linux-x86_64):

- `libKGENCompilerRTShared` imports 5 C++ symbols from `libMSupportGlobals` (`M::Globals::*`) and
  14 from `libAsyncRTRuntimeGlobals` (`TCMallocGlobals`, CPU device table, virtual device
  settings).
- The other two import nothing from `libKGENCompilerRTShared`, and `libAsyncRTRuntimeGlobals`
  imports nothing from `libMSupportGlobals`.

### Exports across versions (MEASURED, linux-x86_64 conda packages)

| library | 1.0.0 | 1.1.0 | 1.2.0 | removed between versions |
|---|---|---|---|---|
| `libMSupportGlobals` | 35 | 36 | 37 | none |
| `libAsyncRTRuntimeGlobals` | 66 | 66 | 68 | none |
| `libKGENCompilerRTShared` | 199 | 208 | 211 | one weak libstdc++ template instantiation per step |

No `KGEN_CompilerRT_*` name was removed, and the five above are present in all three versions. The
counts include weak libstdc++ instantiations, which depend on the toolchain, so a from-source
build will not reproduce them.

Packages compared:

- 1.1.0: `mojo-compiler-1.1.0-release.conda`, sha256 `1ff52b39a0d2a1bedb8c4705aadc460205ca62fc19f63426bc545e4b60a31aa0`.
- 1.2.0: `mojo-compiler-1.2.0-release.conda`, sha256 `a746d7db173a9882e7073ae6d905acfe383a754faecb4a53710b7b90db377e6b`.

Each was checked against `repodata.json` of the same channel.

## 3. Could komira's build produce them

### What the published build uses (STATED, `mojo/v1.1.0` and `mojo/v1.2.0`)

| input | what the source names | how it is fetched |
|---|---|---|
| Build system | Bazel through `bazelw` and a pinned BuildBuddy CLI (`.bazelversion`); bzlmod (`MODULE.bazel`, `bazel/common.MODULE.bazel`) | public downloads |
| C/C++ compiler | clang 22.1.4 at 1.1.0, clang 23.1.1 at 1.2.0, hermetic (`bazel/common.MODULE.bazel`) | prebuilt tarballs on a public object-storage bucket of Modular's; no recipe in the tree |
| Linux sysroot | Ubuntu jammy, x86_64 and aarch64 | same bucket, prebuilt |
| macOS SDK | the host's Xcode (`macos_sysroot_repository.bzl` runs `xcrun`) | host |
| C++ dialect and library | `-std=c++20`; libstdc++ on Linux, libc++ on macOS (`bazel/internal/cc-toolchain/args/BUILD.bazel`) | |
| Link | lld, `-Wl,--build-id=md5`, `-z defs`, `-z nodelete`, `-z now` | |
| LLVM | upstream llvm-project at a commit pinned in `bazel/public-patches/llvm_source.bzl`, plus nine patches; built with upstream's Bazel overlay | GitHub archive with sha256 |
| tcmalloc (Linux) | the BCR tcmalloc snapshot named in `bazel/common.MODULE.bazel`, plus four patches in `bazel/public-patches/` (visibility, local-dynamic TLS, NUMA entry points, glibc rseq) | BCR, source |
| tcmalloc (macOS) | `@gperftools-macos`: a prebuilt `libtcmalloc_minimal.a` of gperftools 2.15 (`bazel/common.MODULE.bazel`, `bazel/public-patches/gperftools-macos.BUILD`) | same bucket, prebuilt; no recipe in the tree |
| abseil | the BCR `abseil-cpp` release named there (through tcmalloc) | BCR, source |
| fmt | `fmt 11.2.0` (`Support:Log`) | BCR, source |
| compiler-rt | none linked: `__truncsfbf2` and `__truncdfbf2` are defined in `Mojo/lib/CompilerRT/Support.cpp` | |

By default Modular's own build does not compile these libraries at all.
`//:use_prebuilt_mojo_toolchain` defaults to true, and `bazel/api.bzl` then replaces
`//Mojo:CompilerRT` with a `cc_import` of the library from a downloaded Modular wheel. The source
build is `--config=build-mojo` (`.bazelrc`).

The declared Bazel closure is large because `Support:ML` and `Support:Context` pull in MLIR IR and
Pass, and `Support:MArchTarget` pulls in all LLVM targets and clang's `basic`. Read file by file,
the sources these three libraries compile include only these from LLVM and MLIR:

- `llvm/ADT/*`
- `llvm/Support/*`
- `llvm/TargetParser/Triple.h`
- `mlir/Support/{LLVM,LogicalResult}.h`

Two inputs are generated: `Config/include/GeneratedVersion.h` from a template, and
`Support/MDialect/*.h.inc` from tablegen. That reading is INFERRED; a hand-written build must
confirm it.

`libAsyncRTRuntimeGlobals` needs `GLIBC_2.35` because of exactly one symbol: the weak object
`__rseq_size`, which the "glibc rseq" tcmalloc patch reads (MEASURED, `readelf -W --dyn-syms`). A
build without that patch would not need it (INFERRED).

### What komira's build has (STATED, this repository)

- **C and C++ compiler:** the pinned zig 0.12.0 on all three release platforms
  (`tools/build/cells/toolchains/mojo_pins.bzl`). Its clang and libc++ are LLVM 17 (zig's 0.12.0
  release notes; not measured here). A second pin, `zig_next` 0.15.2, exists for targets that
  name it (`tools/build/platforms/table.bzl`).
- **C++ code:** compiled today (snappy), with zig's libc++ linked statically
  (`tools/build/toolchains/BUCK`, `libcxx`; [mojo_rules_and_toolchain.md](mojo_rules_and_toolchain.md)).
- **macOS:** C and C++ objects and archives are compiled by zig on Linux for the macOS target;
  every link (Mojo programs, and the `.dylib` of each owner's `native_shared_library`,
  `tools/build/native/shared.bzl`) runs on darwin workers with the host's `cc` and ld.
- **LLVM:** none pinned as source, headers or static libraries. The only LLVM pins are the
  conda-forge LLVM 23 binaries of the coverage tools, linux-x86_64 only
  (`tools/build/toolchains/llvm_branch/`).
- **Where the runtime comes from:** the toolchain, not from `src/so`.
  `tools/build/mojo/toolchain.bzl` (`mojo_runtime`) copies the three files from the unpacked
  compiler package's `lib/`. `mojo build` links every Mojo shared library against them, and
  `//src/so:libkomira[dist]` and the wheel take them from there.

### Could the pinned zig compile the source?

INFERRED from reading; nothing was compiled.

- **Modular's own code, probably yes.** It uses C++20 that clang 17 and libc++ 17 have
  (`constinit`, designated initializers, `<span>`, `std::erase_if`). It includes none of
  `<expected>`, `<format>`, `<print>`, `<ranges>`, concepts or `<=>`. Its platform code is guarded
  by `#if` for x86, aarch64 and Apple.
- **LLVM Support, unknown.** The pinned llvm-project commit is recent upstream. Its
  `CheckCompilerVersion.cmake` states a host floor of clang 5.0, but no build of it with clang 17
  was tried. `zig_next` (0.15.2) is the fallback if clang 17 refuses.
- **The C++ standard library, a choice to make.** Modular builds Linux against libstdc++ (GCC 11,
  jammy). The three libraries pass `std::string`, `std::function` and libstdc++ `[abi:cxx11]`
  types to each other, and `bin/mojo` imports them too. komira's C++ links libc++ statically.
  - Building all three against libc++ works only if all three use one shared copy, not three static
    ones. They exchange heap-owning C++ objects and allocate through one tcmalloc.
  - The alternative is to build against the conda-forge libstdc++ the toolchain already pins,
    which needs its headers pinned too.
  - Either way the from-source files cannot replace the toolchain's `lib/` for `bin/mojo`, which
    expects Modular's libstdc++ C++ symbols. They can only be what the wheel ships.

### What guarantees a from-source runtime matches the pinned compiler's code

STATED and MEASURED in Modular's source:

- **Nothing checks it.** `M::KGEN::getCompilerRTBinaryID()` (`Mojo/lib/CompilerRT/BinaryID.cpp`)
  and `M::AsyncRT::getRuntimeGlobalsBinaryID()` return the library's build id "for the purposes
  of MEF cache invalidation". No published code compares either with anything at load or run time.
  `KGEN_CompilerRT_Initialize` is `return true;`. The dialect checksum
  (`Mojo/lib/DialectChecksum`) compares precompiled package files with the compiler, not with the
  runtime.
- **The C ABI is unversioned.** There is no symbol versioning (`readelf -V` shows only glibc and
  libstdc++ needs), the SONAMEs are bare file names, and there is no ABI constant.
  - `KGEN_CompilerRT_GetOrCreateGlobal` takes `llvm::StringRef` by value.
  - The indexed-globals count (`NUM_INDEXED_GLOBALS 3`) is kept equal to the standard library's
    only by a comment.
- **Binding is by name.** libkomira's `DT_NEEDED libKGENCompilerRTShared.so` and five symbol names
  are the whole contract (section 2).

So the match must be held by the choice of source and by komira's own tests:

1. **Source at the compiler's own release tag.** Compiler and runtime then come from one tree.
   With the pin at 1.0.0 the nearest Apache-headed source was not a tag (section 1); at the 1.1.0
   pin it is the `mojo/v1.1.0` tag.
2. **Exports gate.** A test that the from-source `libKGENCompilerRTShared` defines every runtime
   symbol of every library komira ships, read from the built files as above. The library check
   `-z defs` at link time does not cover this, because libkomira is linked against the toolchain's
   copy.
3. **Behaviour tests** of the five functions through libkomira: allocation alignment, the
   named-global registry across two lookups, and stack trace off by default
   (`max-debug.stack-trace-on-error`).

**GNU build ids.**

- The pinned files carry 16-byte lld `--build-id=md5` notes (MEASURED, `readelf -n`).
- md5 of the shipped bytes with the note zeroed does not reproduce them. The files were changed
  after the link; the conda and PyPI copies differ in RPATH yet share ids
  ([mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md)).
- A from-source build has other ids, and no build komira controls can reproduce Modular's.
- `check_loaded_runtime` (`python/komira/_runtime.py`) accepts an already-loaded runtime only
  when it is komira's own file or its build id equals komira's copy's. With a from-source copy it would refuse every Modular
  runtime already in the process, Modular's 1.0.0 included, where it now accepts that one.
- The `beside_modular` install tests that load Modular's 1.0.0 runtime first would change from
  "loads" to "refused by name". INFERRED: refusing is what the check is
  for, since two builds' copies of the globals of section 2 would be separate state, and nothing
  in either build shows them compatible.

## 4. The work, as tasks

Route: move the compiler pin to a Modular release tag that holds the runtime source, and build the
three libraries from that same tag. Keeping the 1.0.0 pin would have built from an untagged commit of
Modular's history whose source is not exactly the shipped one (section 1). The tasks are the same
either way.

| # | task | where | estimate | what could refuse |
|---|---|---|---|---|
| 1 | Move the Mojo toolchain pin to 1.1.0 or 1.2.0 (all three platforms) and fix what the new compiler breaks in komira's Mojo | `mojo_pins.bzl` through `buildrules mojo sync`, goldens | 3-10 days, depending on the stdlib changes between versions | not this page's to measure |
| 2 | Pin llvm-project at the commit the chosen tag names; build Support, Demangle and the TargetParser pieces the sources include, plus the MLIR `TypeID` support the Globals link names, with zig for three platforms; hand-written `llvm/Config/*.h` (no CMake step: the repo builds C and C++ with Buck2 rules only, rule B4) | new `third_party/llvm` | 1-2 weeks | clang 17 may not compile that LLVM: fall back to `zig_next` 0.15.2, or stop |
| 3 | Pin tcmalloc and abseil with Modular's four patches (Linux); for macOS, gperftools 2.15 from source, since Modular ships only a prebuilt archive | new `third_party/tcmalloc`, `third_party/abseil` | 1 week | gperftools' macOS build without its autotools, or a decision to use the system allocator there (a departure from Modular's binary) |
| 4 | Pin fmt 11.2.0 | new `third_party/fmt` | half a day | |
| 5 | Pin Modular's source archive at the tag; list each library's sources (about 140 files read from the includes); generate `GeneratedVersion.h`; produce the `MDialect` `.inc` files (build `mlir-tblgen` from task 2, or show they are not needed) | `third_party/modular` | 1-2 weeks | tablegen needs more of LLVM than Support |
| 6 | Choose and build the C++ library (one shared libc++, or the pinned conda-forge libstdc++ with pinned headers); link the three as `.so` (Linux) and `.dylib` (macOS) with their SONAMEs, RPATHs and NEEDED order | `tools/build/native`, a Mach-O link path | 1 week | macOS has no shared-library rule today |
| 7 | `[dist]` and the wheel take the from-source files; licence files become the ones the chosen sources carry (Modular's repository `LICENSE`, LLVM's, tcmalloc's, abseil's and fmt's), and `License-Expression` and `NOTICE` say what those files name | `tools/build/mojo`, `python/BUCK`, `NOTICE`, [wheel_licence_audit.md](wheel_licence_audit.md) | 2-3 days | |
| 8 | Exports gate and behaviour tests (section 3), the `beside_modular` expectations, the `runtime_libs` loader record | `src/so`, `python/tests` | 3-5 days | |

Total: about six to ten weeks of one engineer (the sum of the rows at five days a week). The
estimates are INFERRED from the size of each input, not measured. The three places that could
refuse are LLVM with clang 17 (task 2), tablegen (task 5) and macOS tcmalloc (task 3). Every
input is published source.

A smaller variant is open while libkomira's imports stay at five functions. That limit would be
held by the exports gate of task 8.

- **What it would build.** Only `libKGENCompilerRTShared`, from the files that define those five
  functions and what they include. libkomira's `DT_NEEDED` names only that library.
- **Why it does not drop tcmalloc.** `KGEN_CompilerRT_AlignedAlloc` and `AlignedFree` call
  `AsyncRT::TCMallocGlobals::tc_new` and `tc_delete` by default (`Mojo/lib/CompilerRT/Memory.cpp`,
  `mojo/v1.2.0`). Those live in `libAsyncRTRuntimeGlobals` with the tcmalloc instance. So either
  the variant keeps that library and tasks 3 and 6, or it switches the default to `M::alignedAlloc`.
  That is the allocator `KGEN_CompilerRT_SetAsanAllocators` selects, and switching it changes
  Modular's code: a fork, not a rebuild.
- **Status.** Recorded as an option; it needs its own decision.

## 5. Modular's licence texts, as the pinned download and the source repository give them

The `mojo-compiler` 1.0.0 package, the pin when this was measured, carries three licence files under `info/`. Their sha256s
are the same on all three platforms (MEASURED).

| file | sha256 |
|---|---|
| `info/licenses/LICENSE`, "Modular Community License Terms", 71 lines | `5fb3aa787b79bccc736a08ef9c0c54dfa5b83ddea81025c5c501021305821bca` |
| `info/licenses/Third-Party-Notices`, 706 lines | `3d178e4fc82279b8f943c2e76500fb494eeaabc1fbe66e7f457ed309b2aeba2c` |
| `info/about.json` | `4184e9f05f0b6cdc44bcdd17a930dfab211ea6fba1a440681baa3765341f70b5` |

`info/about.json` says `"license": "LicenseRef-Modular-Proprietary"` and `"summary": "The Modular
MAX Platform."`.

The sentences that matter in `info/licenses/LICENSE`, quoted:

**1. SDK AND DOCUMENTATION LICENSE GRANT**

> This license does not grant Licensee the right to distribute the SDK or any part thereof to
> third parties, except as expressly stated otherwise herein. For the avoidance of doubt, Licensee
> may under no circumstances redistribute the SDK itself outside of any Applications.

**3. REDISTRIBUTABLE COMPONENTS & LIMITATIONS**

> Modular hereby grants Licensee the limited right to redistribute certain components of the SDK
> as part of Licensee's Applications, subject to the conditions and limitations set forth in this
> clause, including the Distribution Requirements. The redistributable components of the SDK
> ("Redistributable Components") are specified in the accompanying SDK documentation or materials
> provided by Modular (the "Documentation").

> (d) Licensee shall not redistribute the Redistributable Components as standalone components,
> libraries, or tools in any way that would enable third parties to violate the terms of this
> License;

> (e) Licensee shall not modify, reverse engineer, decompile, disassemble, or attempt to derive
> the source code of the Redistributable Components, except to the extent expressly permitted by
> applicable law;

> (g) The text of this Agreement shall be conspicuously displayed in each original or modified
> copy of the SDK; and

**2. Restrictions**

> (a) modify, adapt, translate, reverse engineer, decompile, or disassemble the SDK or any part
> thereof, or otherwise attempt to derive or gain access to SDK source code;

The text names no Redistributable Components itself, and does not mention Apache or open source.

`Third-Party-Notices` lists third-party components. Its item 1 reads:

> Licensee's use of LLVM is subject to the terms and conditions of the Apache License v2.0 with
> LLVM Exceptions.

It says nothing of Modular's own code.

The source repository's texts are in section 1, "The LICENSE and README files". This page does not
interpret any of these texts beyond quoting them.

## How this was measured

- **Downloads.** The pinned conda packages, fetched from the URLs in
  `tools/build/cells/toolchains/mojo_pins.bzl`; each hashed to its pin. The 1.1.0 and 1.2.0
  packages are named above.
- **Source.** A blobless clone of github.com/modular/modular, with the four trees above checked
  out; read with `git ls-tree`, `git show`, `git diff`, `git merge-base` and `grep`.
- **komira's library.** `//src/so:libkomira[runnable]`, built on the farm from a tree whose
  `libkomira.so` has the size and runtime imports of the src/so/README.md table, read with `nm`, `readelf`, `strings` and `cmp`.
- **macOS files.** Read with a short Mach-O reader of their load commands and export trie, since
  the host's `nm` does not read Mach-O.

The library imports are the same measurement `libkomira_elf_report` makes for its counts. A change
to that table's runtime column changes section 2.
