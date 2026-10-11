# loader_closure

What the dynamic loader would map for each program of a toolchain
distribution, read from its ELF files: [`loader_closure.zig`](loader_closure.zig),
built by `:loader_closure` (`zig build-exe`, static, musl) and run by the rule
`loader_closure_check` of [`defs.bzl`](defs.bzl) as a validation. It reads the
files and runs none of them, so it needs no shell, no decoy directory and no
`LD_TRACE_LOADED_OBJECTS`.

| validation | distribution | roots | glibc floor |
|---|---|---|---|
| [`kcov:kcov_closure`](../kcov/README.md#checks) | `:kcov_dist` | `bin/kcov` | the row's |
| [`llvm_branch:lld24_closure`](../llvm_branch/README.md#checks) | `:lld24` | `bin/lld` | none |
| [`llvm_branch:llvm23_closure`](../llvm_branch/README.md#checks) | `:llvm23` | `bin/llvm-nm`, `bin/llvm-profdata` | none |
| [`git:git_closure`](../../../../third_party/git/README.md#checks) | `:git_dist` | `bin/git`, `git-http-fetch`, `git-remote-http` | the row's |

```
loader_closure --prefix <dir> --out <validation.json>
    [--root <path in prefix>]... [--interp <path>] [--glibc-floor <n>]
```

## What it checks

Every regular file of the prefix that is an ELF file with a `PT_INTERP`
header is a program, and each is checked; a `--root` must be one, so a check
that finds no program cannot pass by reading nothing. For each program it
resolves `DT_NEEDED` breadth first, as glibc's loader does:

1. a name that an object already mapped has (the name it was loaded by, or
   its `DT_SONAME`) is that object;
2. otherwise, unless the needing object has a `DT_RUNPATH`: the `DT_RPATH` of
   the needing object, then of the object that loaded it, up to the program
   (an object with a `DT_RUNPATH` contributes no `DT_RPATH`);
3. then `LD_LIBRARY_PATH`, which a test runner sets (to the Mojo toolchain's
   `lib/`), and which nothing here may depend on;
4. then the needing object's `DT_RUNPATH`.

It is red, naming each failure and writing nothing, unless:

- every program's interpreter is `/lib64/ld-linux-x86-64.so.2` (`--interp`);
- every entry of the `DT_RPATH` and `DT_RUNPATH` of every object it maps is
  `$ORIGIN` or `$ORIGIN/<path>` (or `${ORIGIN}`) and stays inside the
  prefix. An absolute entry is searched wherever the prefix is installed,
  so it is outside the prefix; a relative or empty entry is the working
  directory; another token (`$LIB`, `$PLATFORM`) is refused. An entry is
  checked whether or not a search reaches it: a `dlopen`, or a name not
  found earlier, would;
- every needed name that is not one of glibc's (`libc.so.6`, `libm.so.6`,
  `libdl.so.2`, `libpthread.so.0`, `librt.so.1`, `ld-linux-x86-64.so.2`) is
  found in the prefix by step 2. Found only by step 4, `LD_LIBRARY_PATH`
  would supply it; not found, `LD_LIBRARY_PATH` or the worker would;
- no glibc name is found in the prefix: glibc comes from the system;
- every object it maps is an ELF64 little-endian file, and a symbolic link
  it follows stays inside the prefix;
- with `--glibc-floor <n>`, no ELF file of the prefix holds a string
  `GLIBC_2.<m>` with m > n (any string of the file, so a library embedded as
  bytes, as kcov embeds its preload library, counts), and at least one
  holds a `GLIBC_2.` version.

Green, it prints one line per name each program maps and writes the
validation result. A usage error exits 2.

## What it does not see

- Libraries a program `dlopen`s by name at run time (glibc's
  `pthread_cancel` loads `libgcc_s.so.1` that way). kcov's check 5 observes
  its real run under the loader's `LD_DEBUG=libs` for that.
- `LD_PRELOAD`, `/etc/ld.so.preload`, `DT_AUDIT` and the loader's cache:
  only the files of the prefix are read.
- Mach-O. This is Linux x86_64 only: a darwin prefix has no ELF program and
  is refused, and the darwin toolchain paths are not checked by it.

## Tests

One `zig test` target per scenario, each a build action; `:loader_closure`
is built only after all of them pass. Each test plants minimal ELF files
([`fixture.zig`](fixture.zig) writes the ELF header, a `PT_LOAD` whose
virtual address differs from its file offset, `PT_INTERP`, the string table
and the dynamic section) into a directory of its own, runs the check, and
requires exactly one finding naming the planted defect. A red scenario
next to a green twin shows the defect, not the tree, made it red. Each
mutant below was planted in `loader_closure.zig` and the build of the
scenarios was seen red on the farm, then removed.

| target | proves | mutant planted, red targets |
|---|---|---|
| `:green_test` | a program, its own library found through the program's `DT_RPATH` from a library with no run path, a library with `${ORIGIN}/.`, a link inside the prefix, non-ELF files and a floor are green, and the check reports what it maps; a name a mapped object already has is that object, whatever the run path of the object needing it | (the control of every red scenario) |
| `:missing_needed_test` | a needed library not in the prefix is red, for the program and for a library it maps (the closure is transitive) | not-found names accepted as the system's: `:missing_needed_test` |
| `:rpath_absolute_test` | an absolute `DT_RPATH` entry is red before and after the entry that finds the library, and an absolute `DT_RUNPATH` entry of a library | entries checked only when a search reads them: `:rpath_absolute_test`, `:rpath_escape_test` |
| `:rpath_escape_test` | an `$ORIGIN` entry climbing above the prefix, relative, empty and other-token entries, and a library that is a link leaving the prefix are red | (the same mutant) |
| `:runpath_test` | a library found only through a `DT_RUNPATH` is red; an object with both tags uses its `DT_RUNPATH` only and none of the chain's `DT_RPATH` | a `DT_RUNPATH` find accepted: `:runpath_test` |
| `:glibc_named_test` | a `libm.so.6` in the prefix's `lib/`, found through the `DT_RPATH`, is red | glibc names accepted wherever found: `:glibc_named_test` |
| `:interp_test` | another interpreter, a `--root` that is missing or a library, and a prefix with no program are red | the interpreter comparison dropped: `:interp_test` |
| `:glibc_floor_test` | a version above the floor in a library is red, each named once in order; `GLIBC_2.2.5`, the floor itself and `GLIBC_PRIVATE` are green; a prefix naming no glibc version is red under a floor | the comparison made `m > floor + 2`: `:glibc_floor_test` |
| `:malformed_test` | a truncated ELF file and an ELF32 file are red; a `DT_STRTAB` outside every `PT_LOAD` is a parse error | the ELF class test dropped (only the byte order read): `:malformed_test` |

On the distributions, each was also planted and seen red on the farm: see
the rows of [kcov](../kcov/README.md#checks),
[llvm_branch](../llvm_branch/README.md#checks) and
[git](../../../../third_party/git/README.md#checks).
