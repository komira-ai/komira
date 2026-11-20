# Mojo runtime libraries: the PyPI wheels against the pinned conda package

The pip package of `libkomira` does not carry the Mojo runtime. If the library needs runtime
libraries at load time, the package depends on Modular's own published package for them. This
note records what that package, `mojo-compiler` 1.0.0 on PyPI, contains, how its runtime
libraries compare with the conda package pinned in
[`tools/build/platforms/table.bzl`](../../tools/build/platforms/table.bzl) (`mojo_compiler`, one
pin per release platform), and what that means for the wheel's layout and run path.

Tags: **MEASURED** = read from the downloaded files in this note's session; **INDEX** = read from the PyPI index (JSON queries and name lookups), not from downloaded files; **STATED** = read in
a file of this repository; **INFERRED** = deduced, not run; **NOT RUN** = needs a farm build and
was not done here.

## What was compared

Three wheels from PyPI (`py3-none` tags), the wheel they require, and the three pinned conda
packages. Each wheel and package was downloaded, its sha256 checked against the PyPI JSON
digest or the pin, and unpacked into an empty directory (no build, no test, nothing loaded).

| Artifact | Bytes | sha256 |
| --- | --- | --- |
| `mojo_compiler-1.0.0-py3-none-manylinux_2_34_x86_64.whl` | 79,142,588 | `e9e60f9638e69ca0f4be7292468523fc98a143f58dbf9024f60ed68b874a867e` |
| `mojo_compiler-1.0.0-py3-none-manylinux_2_34_aarch64.whl` | 76,295,262 | `3ae3eb0c58a8956f542e324f736866df0ae2f9f875e8a279cbeea961ec4e9ee8` |
| `mojo_compiler-1.0.0-py3-none-macosx_13_0_arm64.whl` | 70,979,164 | `5077ee27c0dfbbdf138a11ec12838b0d3f10148a874cf95040c9ca2332ae2622` |
| `mojo_compiler_mojo_libs-1.0.0-py3-none-any.whl` | 3,187,048 | `20a92e37ecbd19e2dbb1a525612a8de4c9f266f5536def55c5e2b0786320e8b3` |
| pin `mojo_compiler_1.0.0_linux-64.conda` | 68,511,359 | `4394c6146d47ec7794a9a3ed5775ae158f59f83f8e1aed59408b17c4909821b3` |
| pin `mojo_compiler_1.0.0_linux-aarch64.conda` | 66,479,788 | `da1772742c54f1f8f7b883e6338b1fe5de4592f2c882220dcceae623cc661e57` |
| pin `mojo_compiler_1.0.0_osx-arm64.conda` | 61,221,085 | `c52054bc444d851e5c38cc33e790fb011a1080470244aaa59351ac5056d08c59` |

The three conda downloads hash to the recorded pins (MEASURED). The pins name whole packages;
no per-library hash is recorded in the repository, so the per-library hashes below are new.

## Layout (MEASURED)

`mojo-compiler` is a compiler wheel, not a runtime-only package, and it requires a second wheel:

- `Requires-Dist: mojo-compiler-mojo-libs==1.0.0` (exact pin). That wheel is platform-independent
  (`py3-none-any`, 3.2 MB) and holds only `modular/lib/mojo/std.mojoc`, byte-identical to the
  conda package's `lib/mojo/std.mojoc` on all three platforms.
- The compiler wheel's files install, through the wheel's `platlib` data directory, into
  `<site-packages>/modular/bin/` (`mojo`, `lld`, `modular-crashpad-handler`) and
  `<site-packages>/modular/lib/` (the three runtime libraries), plus the Python package
  `<site-packages>/mojo/` (`importer.py`, `run.py`, `paths.py`, `_entrypoints.py`, `notebook.py`,
  `_package_root.py`). So the layout is `site-packages/modular/lib`: yes.
- The conda package has the same files at `bin/` and `lib/` of the prefix, plus `etc/conda/activate.d`,
  `share/`, and no Python package.
- The wheel ships no licence file in `.dist-info`; the licence is only the metadata field
  `LicenseRef-MAX-Platform-Software-License`. The Python sources carry Apache-2.0 with LLVM
  Exceptions headers. Whether the dependency, or carrying the libraries, is acceptable is a
  separate ruling this note does not make.
- (INDEX) No smaller runtime-only package exists on PyPI under the names tried (`mojo-runtime`,
  `mojo-libs`, `mojo_runtime`, `modular-runtime` are all absent). The `mojo` package is larger
  (it adds `mblack` and `mojo-lldb-libs`).
- Install weight of route A is the compiler wheel plus the libs wheel: about 82 MB on
  linux-x86_64, 79.5 MB on linux-arm64, 74 MB on macos-arm64. The three runtime libraries are
  1.96 MB, 1.87 MB and 1.57 MB of that.

## Runtime libraries: hashes against the pin (MEASURED)

| platform | library | conda bytes | conda sha256 | PyPI bytes | PyPI sha256 | bytes |
| --- | --- | --- | --- | --- | --- | --- |
| linux-x86_64 | `libKGENCompilerRTShared.so` | 1222584 | `70db9f3a7c95fe78b5b0104433e339e32986c63b014e4b5f30082495e44d6321` | 1222584 | `a9f66ba5bde1e0252b256cad9be4326285938c5dd2d22d2c94e47d895654d48f` | differs |
| linux-x86_64 | `libAsyncRTRuntimeGlobals.so` | 685176 | `b2bc321899e288422c6e09069b39cfe81c13d9d646426a0b5348e3b5a56f8f18` | 685176 | `364b5324f16b7ea27fc880734242c014fb321f3f4039f88ee76a4fb6653c1d0e` | differs |
| linux-x86_64 | `libMSupportGlobals.so` | 49200 | `9ab7ddcb1f2eae79db3056841224d1167d13ec2da21e69a416fdc6a632ec85b9` | 49200 | `9ab7ddcb1f2eae79db3056841224d1167d13ec2da21e69a416fdc6a632ec85b9` | identical |
| linux-arm64 | `libKGENCompilerRTShared.so` | 1154680 | `aa4d4f13a87738632b50703432bf79aeb6134c63b5b3e539cff674fd4ce2e28c` | 1154680 | `e39b887af55621140fb85c2184a00dbc5e01615e44624a030dd2570651d5f18b` | differs |
| linux-arm64 | `libAsyncRTRuntimeGlobals.so` | 668584 | `1a3a1fd2eb2dd0ac09136fc5c1ee632eaad4c630211767ee5a83d45cbdc67b98` | 668584 | `b84f3a7dda9c1782fef9e981af71f8071418c791f42959034083921500b85267` | differs |
| linux-arm64 | `libMSupportGlobals.so` | 49344 | `b7e295a69bf0bf21c3ec8d9fd66dedccf25729a9d743e6537813c7b64963d1df` | 49344 | `b7e295a69bf0bf21c3ec8d9fd66dedccf25729a9d743e6537813c7b64963d1df` | identical |
| macos-arm64 | `libKGENCompilerRTShared.dylib` | 1122336 | `688f466aa14e830f4b4f0a5448bb7b24024aa58d64c53fb35b256118fc3ef588` | 1116816 | `bc2dbecc67c1130af11d0bddde6f290f3d6a696fb2819e08111c1f7cdb581e15` | differs |
| macos-arm64 | `libAsyncRTRuntimeGlobals.dylib` | 339488 | `6f8b1b88974d5f9b937434639c74b598ab861b177debf8e20ce60b10e4ca59eb` | 334032 | `446b6661a5f089aa0b1ad5722028966e7cd0be331c3867b5aebda4f4486186b5` | differs |
| macos-arm64 | `libMSupportGlobals.dylib` | 123472 | `ebc40cfcb2859c3c66f3f27d5a068c7c153fba65996670b4989c0f51cad2c332` | 123472 | `ebc40cfcb2859c3c66f3f27d5a068c7c153fba65996670b4989c0f51cad2c332` | identical |

Result: `libMSupportGlobals` is byte-identical on all three platforms. `libKGENCompilerRTShared`
and `libAsyncRTRuntimeGlobals` are **not** byte-identical on any platform, so the PyPI wheels do
not reproduce the pinned conda bytes. The `mojo` executable differs on all three platforms too.

Why they differ, as far as the files show (MEASURED, with the reading INFERRED):

- Linux (both architectures): the two libraries have the same size, the same `DT_NEEDED` list, the
  same `DT_SONAME`, and byte-identical `.text`, `.rodata`, `.data`, `.data.rel.ro`, `.eh_frame`,
  `.dynsym` and `.gnu.hash` (x86-64: all seven sections; arm64: `.text`, `.rodata`,
  `.data.rel.ro`, `.eh_frame`, `.dynsym`). The only difference found is the `DT_RPATH` string: the
  PyPI libraries carry one more entry (`$ORIGIN/../../_solib_<arch>/_USupport`, and for
  `libKGENCompilerRTShared` also `.../_UAsyncRT`). The conda libraries have the
  shorter list. Both have `DT_RPATH` (not `DT_RUNPATH`) beginning `$ORIGIN:$ORIGIN/../lib`.
  Inferred: the two builds are the same compile with a different link-time run path.
- macOS: every file-backed section of the two libraries read as identical (`__text`, `__stubs`,
  `__cstring`, `__const`, `__unwind_info`, `__got`, `__la_symbol_ptr`, `__data`, thread sections); the
  PyPI files have one or two more load commands and are 5.5 KB smaller. The comparison read the
  zero-fill sections (`__bss`, `__common`, `__thread_bss`) as if they had file content, so those rows
  are not evidence either way. Not checked: which load commands differ, and the code signature.

## Does libkomira need the runtime libraries? (STATED, INFERRED)

Yes. The repository already says so, and the platform table's `runtime_libs` lists them (with libgcc_s and libstdc++):

- `tools/build/mojo/README.md` ("Not self-contained"): a `mojo_shared_lib` output has
  `DT_NEEDED libKGENCompilerRTShared.so`, which the compiler's link adds to every Mojo binary and
  shared library; it needs `libMSupportGlobals`, `libAsyncRTRuntimeGlobals`, libstdc++ and libgcc_s
  to resolve. macOS: `@rpath/libKGENCompilerRTShared.dylib`.
- `libKGENCompilerRTShared` itself has `NEEDED` on the other two (MEASURED above), so the
  runtime closure is exactly the three libraries; libstdc++, libgcc_s and glibc are not in the wheel.
- The library's run path is `$ORIGIN/lib:$ORIGIN` (Linux) and `@loader_path/lib` (macOS).

## Does libkomira built on the pin load against the PyPI libraries?

**NOT RUN.** Loading needs a built `libkomira` and a farm action; this change builds and tests
nothing. What the files support (INFERRED), per platform:

- Linux: the exported symbol table (`.dynsym`), code and data of both differing libraries are
  identical to the pin's, so a `libkomira` that binds to the pinned libraries binds to the PyPI ones the
  same way. The ELF `NEEDED` names (`libKGENCompilerRTShared.so`, `libMSupportGlobals.so`,
  `libAsyncRTRuntimeGlobals.so`) are the same, and the PyPI libraries find each other through
  their own `DT_RPATH $ORIGIN`.
- macOS: the same for the file-backed sections; the code signature and the extra load commands are
  unchecked, so this is the weakest of the three.
- The **run path does not carry over**. The PyPI libraries sit in `site-packages/modular/lib`, but
  `libkomira`'s `$ORIGIN/lib:$ORIGIN` finds libraries only beside itself or in its own `lib/`. A
  wheel that puts `libkomira.so` in `site-packages/komira/` loads it against the PyPI runtime only
  if either its run path gains a sibling-relative entry (for example `$ORIGIN/../modular/lib`;
  macOS `@loader_path/../modular/lib`) or the Python loader opens the three libraries by absolute
  path first, in dependency order (`libMSupportGlobals`, `libAsyncRTRuntimeGlobals`,
  `libKGENCompilerRTShared`), so that the later `NEEDED` names match libraries already loaded.
  Neither was tried.

Follow-up check, for whoever builds the wheel (not done here): extend the install check
(`tools/build/package/install_check`) with a variant whose runtime libraries are the PyPI wheel's
files at `modular/lib`, and run it for each release platform. It would settle load-time
compatibility and the run path in one farm action.

## Version coupling (INDEX)

`mojo-compiler` and `mojo-compiler-mojo-libs` are each pinned `==` to one version, and PyPI's
latest is 1.2.0 (also `==1.2.0` on its libs wheel; wheels 72.7, 78.6 and 81.8 MB). A package that
requires `mojo-compiler==1.0.0` conflicts with an environment that already holds another
version; a range would not protect the load, because the runtime libraries are only
compared here at 1.0.0. The 1.2.0 libraries were not opened.

## Summary of answers

| Question | Answer |
| --- | --- |
| Wheels contain the three runtime libraries | yes, in `modular/lib/` of the compiler wheel |
| Layout is `site-packages/modular/lib` | yes (wheel `platlib` data) |
| Bytes equal the pin | `libMSupportGlobals`: yes. The other two: no, on all three platforms; code, symbols and `NEEDED` equal, run path string differs |
| libkomira needs the runtime libraries | yes (`DT_NEEDED libKGENCompilerRTShared`) |
| libkomira built on the pin loads against the PyPI libraries | not run; inferred yes on Linux from identical code and symbols; run path must be changed or the libraries preloaded |
| Runtime-only package on PyPI | none found; the dependency is the whole compiler, 79 / 76 / 71 MB, plus a 3 MB libs wheel |
