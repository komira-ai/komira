# Per-ISA variants of libkomira: levels, layout, selector and size

Status: design, partly built. What already exists is marked **EXISTS**, with the path on `main` that
does it; everything else is **PROPOSED**. Built: the `isa_variants` field and its checks, the
x86-64-v2 toolchain, C at the floor, the variant links, the variants directory with its manifest and
the load of each variant from it, and the Python and Node selectors (**EXISTS** marks below). Not
built yet: the wheel's and the npm packages' copy of that directory, `target_features` in
the compile, and the generic-arm64 guard of `quote_region_mask_u64`. Scope: the `libkomira` that the Python wheel and the npm platform packages carry
([python_package.md](python_package.md), [typescript_package.md](typescript_package.md)). The Mojo
program bundles of `tools/build/package` already have their own level check and are not changed here
(see [What is not changed](#what-is-not-changed)).

## What problem does this solve?

Each platform row compiles for exactly one CPU. **EXISTS:** `target_cpu` in
[tools/build/platforms/table.bzl](../../tools/build/platforms/table.bzl) is `x86-64-v3` for
linux-x86_64, `apple-m1` for darwin-arm64, and `generic` with `+outline-atomics` for the
linux-arm64 row (registered, with no toolchain building for it yet). Every `mojo build` passes that value as `--target-cpu`
([tools/build/mojo/compile.bzl](../../tools/build/mojo/compile.bzl), `_build_executable`), and so does
every Linux C compile through zig's `-mcpu` ([tools/build/mojo/cxx.bzl](../../tools/build/mojo/cxx.bzl));
macOS C compiles at zig's generic arm64.
One value per row costs users in two ways:

- **Machines below the level cannot load the library at all.** On linux-x86_64 the Python loader
  refuses any CPU without the flags of x86-64-v3, with `UnsupportedCpuError` (**EXISTS:**
  `_check_cpu` in [python/komira/_native.py](../../python/komira/_native.py), tests in
  [python/tests/test_cpu.py](../../python/tests/test_cpu.py)). Several kinds of machine are refused:
  - Sandy Bridge and Ivy Bridge servers;
  - Atom-class and low-end Pentium or Celeron parts without AVX;
  - virtual machines whose CPU model hides AVX2;
  - x86 emulators that stop at SSE4.2, for example a `linux/amd64` container on an Apple silicon Mac
    under an emulator without AVX2.

  The check is correct: without it these machines would die of an illegal instruction. They are
  still refused.
- **Machines above the level do not get their wider instructions.** SIMD widths in the Mojo source
  are chosen at compile time from the target: `simd_width_of` has 239 non-test uses
  (`grep -rn 'simd_width_of\|simdwidthof' --include=*.mojo src | grep -v /tests/`).
  - The AVX-512 kernels exist, but only a target that reports a 512-bit native width emits them.
    They are the gathers of `src/simd_ops/src/simd_ops/gather.mojo` and the compress of
    `compress.mojo`, which `src/kernels/sel_kernels.mojo` uses.
  - At x86-64-v3 they take their scalar per-lane fallback.
  - No code in `src/` detects the CPU at run time (no `cpuid`, `getauxval`, ifunc or
    `target_clones`), so the only way to run those kernels is a library built for a CPU that has
    them.

A wheel or npm platform tag cannot say which CPU level a file needs. A PEP 425/600 platform tag names
the OS, libc and architecture; npm's `os`, `cpu` and `libc` fields name the same three. Any choice by
CPU level therefore happens after install, in the code that opens the library.

## Decisions

### 1. Which variants exist

A **variant** is one link of `libkomira` for one `target_cpu`. Each platform row lists its variants
from lowest to highest. Each variant's required CPU features include all the features of the variant
below it.

| row | variants, lowest first | built now? |
|---|---|---|
| linux-x86_64 | `x86-64-v2`, `x86-64-v3`, `x86-64-v4` | v2 and v3. v4 waits for [the conditions in 4](#4-when-a-higher-variant-is-added) |
| darwin-arm64 | `apple-m1` | yes, as today: one variant |
| linux-arm64 | `generic` (+outline-atomics), `neoverse-n1` | generic once a toolchain builds for the row (it is registered, with none yet). neoverse-n1 waits for the conditions in 4 |

- **linux-x86_64 gets an x86-64-v2 floor.**
  - The floor library runs on every x86-64 CPU sold in the last fifteen years except the rare parts
    without SSE4.2.
  - It costs one more link of `libkomira` (see [Size cost](#size-cost)) and the source fixes of
    [Prerequisites](#prerequisites-in-the-source).
  - It is testable now: every linux-x86_64 worker implements x86-64-v3 (the host floor,
    [tools/build/toolchains/README.md](../../tools/build/toolchains/README.md)), so a worker also runs
    x86-64-v2 code.
- **x86-64-v3 stays, and is the default.** It is the level today's unit tests, coverage and goldens
  are built for, so the code most users load is the code every pull request tests. Below, "default"
  means the row's `target_cpu`, which the decision leaves at `x86-64-v3`.
- **x86-64-v4 is designed now and built later.** The AVX-512 kernels are its only clear gain, and
  nothing in the tree measures it.
  - `src/simd_ops/src/simd_ops/width_policy.mojo` caps the policy width at 256 bits on AVX-512
    targets unless `KOMIRA_SIMD_ALLOW_AVX512` is defined. It records that a parquet encode path ran
    within noise at every width.
  - A v4 variant does **not** set that define: a define changes the `.mojoc` of `simd_ops` and of
    every package above it (see 3). The v4 variant gets the 512-bit gathers and compress, the wider
    `simd_width_of` loops, and AVX-512 forms of 256-bit code. The policy-width callers stay at
    256 bits.
- **darwin-arm64 keeps one variant.** Every Apple silicon Mac implements `apple-m1`. Later chips add
  BF16, I8MM and SME, which no komira source uses, and no Apple chip offers SVE outside SME's
  streaming mode. A second variant would add size and no faster code.
- **linux-arm64 gets `generic` and `neoverse-n1`.**
  - The row's comment already sets a generic ARMv8-A floor, because a Raspberry Pi must run
    what the servers build. The Pi 4's Cortex-A72 is ARMv8.0 without the crypto extension.
  - `neoverse-n1` (ARMv8.2 with LSE atomics, dot product, FP16 and the crypto extension) is the CPU of
    the Neoverse N1 servers, and every later Neoverse core implements it.
  - There is no SVE variant: the tree has no SVE code (`grep -rn 'llvm.aarch64.sve' --include=*.mojo src`
    is empty). An SVE variant is proposed when SVE kernels exist.

### 2. Where the variants live, and how the loader finds them

The self-contained native directory is the one build output that the wheel's `komira/_lib/` and the
npm platform packages copy ([typescript_package.md](typescript_package.md), "The package is
self-contained"). That directory is itself not on `main` yet: it lands with the change that makes the
wheel self-contained, and today's wheel carries `libkomira.so` and the owners in `lib/` and takes the
Mojo runtime from `mojo-compiler` (**EXISTS:** [python/BUCK](../../python/BUCK)). The variants build on
that change. The layout for linux-x86_64 (**EXISTS** as a directory of its own:
`//tools/build/package/libkomira:libkomira_variants`, [variants.bzl](../../tools/build/package/libkomira/variants.bzl);
no package copies it yet):

```
VARIANTS                               the manifest (below)
libkomira.so                           the floor variant: x86-64-v2
variants/x86-64-v3/libkomira.so        RUNPATH $ORIGIN/../../lib
variants/x86-64-v4/libkomira.so        (when built)
lib/...                                native owners and the Mojo runtime libraries, one copy
```

- **The floor keeps today's path.** A reader that knows nothing of variants still opens
  `<dir>/libkomira.so` and gets a library that runs on every CPU the package supports.
- **One copy of everything else.** The native owners and the three Mojo runtime libraries are shared
  by all variants. Each variant's run path reaches the directory's `lib/` from two levels down.
  - Today `libkomira`'s run path is `$ORIGIN/lib:$ORIGIN` ([src/so/README.md](../../src/so/README.md)).
    The link target of a variant takes `$ORIGIN/../../lib` instead, and the gates that hold the run
    path and "every library is mapped from the prefix" (`libkomira_elf_report`, `libkomira_install`)
    accept it for a variant.
  - The runtime libraries are the vendor's files, and they are the same for every variant.
  - The owners are built once, at the floor CPU (see 3).
- **One directory naming for every row:** `variants/<name>/`, not `glibc-hwcaps/<level>/`.
  - glibc's hwcaps search would not help the packages, because both loaders open the library by
    absolute path. **EXISTS:** `ctypes.CDLL(path)` in `_native.py`; `dlopen(path, ...)` in
    [node/komira_addon.c](../../node/komira_addon.c).
  - glibc searches the hwcaps subdirectories only for a name without a slash.
  - The hwcaps search exists only on glibc, and only for the x86-64 levels among our platforms.
- **The manifest `VARIANTS`** is UTF-8 text with one line per variant, lowest first. Each line has
  three tab-separated fields: the name, the path relative to the directory, and the space-separated
  CPU features the variant needs, in the spelling of Linux's `/proc/cpuinfo`. The build writes the
  manifest from the platform row, so the row is the only place the variants and their features are
  written down. A darwin-arm64 manifest is one line with an empty feature list.

  ```
  x86-64-v2	libkomira.so	cx16 lahf_lm pni popcnt sse4_1 sse4_2 ssse3
  x86-64-v3	variants/x86-64-v3/libkomira.so	abm avx avx2 bmi1 bmi2 cx16 f16c fma lahf_lm movbe pni popcnt sse4_1 sse4_2 ssse3
  ```

  The loaders of decision 5 ignore fields after the third, so the manifest can grow by adding fields
  at the end.

### 3. How the build makes a variant

- **The platform table gains `isa_variants`** (**EXISTS:**
  [tools/build/platforms/isa_variants.bzl](../../tools/build/platforms/isa_variants.bzl); the table
  lists only the variants that are built, so v4 and `neoverse-n1` are not in it). It is a field of every row: a list of
  `isa_variant(name, target_cpu, requires, target_features = [])`, lowest first. The completeness check
  at the bottom of the table refuses a row in each of these cases:
  - the list is empty;
  - two variants share a name;
  - a name is not a plain path segment;
  - a variant's `requires` does not contain all of the previous variant's;
  - no variant's `target_cpu` is the row's own `target_cpu`.

  The last rule means the default build, the one the tests run, is always one of the shipped files.
  The field joins the table's field list and its unknown-field check. The platforms and toolchains
  BUCK files are templates that consuming repositories copy, so this change and the variant toolchains
  land together with every copy (rule B3).
- **Proposed rows.** These are the requirement lists in cpuinfo spelling:

  | variant | `target_cpu` | `requires` |
  |---|---|---|
  | `x86-64-v2` | `x86-64-v2` | `cx16 lahf_lm pni popcnt sse4_1 sse4_2 ssse3` |
  | `x86-64-v3` | `x86-64-v3` | v2's plus `abm avx avx2 bmi1 bmi2 f16c fma movbe` (the list `_check_cpu` holds today) |
  | `x86-64-v4` | `x86-64-v4` | v3's plus `avx512bw avx512cd avx512dq avx512f avx512vl` |
  | `apple-m1` | `apple-m1` | none |
  | `generic` | `generic`, features `+outline-atomics` | `asimd fp` |
  | `neoverse-n1` | `neoverse-n1` | `aes asimd asimddp asimdhp asimdrdm atomics crc32 dcpop fp fphp lrcpc pmull sha1 sha2` |

  The build task checks each `requires` against the features LLVM enables for its `target_cpu`. A
  feature the compiler may use that is missing from `requires` is a defect, because it would let a
  CPU load code it cannot run.
- **One extra Mojo toolchain per extra variant.**
  - Today `komira_mojo_toolchains` declares one toolchain per OS. The variant toolchains copy it with
    another `target_cpu` and `target_features`. They are not new platforms or constraints, so
    `golden_config_hash` and every Mojo action of the default configuration stay as they are.
  - The default toolchain keeps the row's `target_cpu`.
  - The libkomira link target is declared once per variant. Each declaration names its toolchain
    through the rule's existing `toolchain` attribute.
- **Only the final link runs per variant.** A `.mojoc` holds no machine code, and `mojo precompile`
  rejects `--target-cpu` ([mojo_rules_and_toolchain.md](mojo_rules_and_toolchain.md)). So every
  `.mojoc` of the closure is the default configuration's, shared by all variants. Only the
  `mojo build --emit shared-lib` of `libkomira` runs once per variant.
  - Variants therefore differ in `--target-cpu` and target features only, never in a `-D` define.
  - This is why the v4 variant does not set `KOMIRA_SIMD_ALLOW_AVX512`.
- **C is compiled at the floor, once.**
  - The native owners are separate shared libraries in the shared `lib/`, so they must run on the
    floor CPU.
  - The C toolchain's CPU becomes its own setting, the row's floor variant (`x86-64-v2` on
    linux-x86_64). Today it reuses the Mojo `target_cpu` (`tools/build/toolchains/defs.bzl`).
  - Every C object of the row is then compiled at the floor, including vendored C linked into Mojo
    binaries. Vendored C with hot SIMD paths, such as aws-lc and zstd, already picks its paths at
    run time from the CPU.
  - The aquery golden of the C actions changes once. The configuration hash does not.
  - It is a cost for x86-64-v3 users: the owners lose whatever the compiler auto-vectorized with AVX2.
    The build task measures the owners with hot loops (`compression`, `parquet_codec`) at both
    levels. If one is slower at v2, that owner gets one build per variant in the variant's own
    `lib/`, instead of moving the whole directory's C to v3.
- **`target_features` is wired into the compile.** No rule passes it to a compile today: only the
  table, its checks and its README read it, so the generic arm64 row's `+outline-atomics` is not
  applied yet, and the table refuses a variant other than the row's own build that sets it
  (**EXISTS**, `variant_refusals` in `tools/build/platforms/isa_variants.bzl`). A later task passes
  the field to `mojo build` and to zig's `-mcpu` suffixes.

### 4. When a higher variant is added

A variant is never shipped untested. `x86-64-v4` and `neoverse-n1` are added to the built set when
two things hold:

1. **A worker runs it.** The row's remote execution must reach workers whose CPUs implement the
   variant. They are selected only through the properties the workers' daemons report, with no
   hand-set label (rule B11).
   - The variant's load test and its conformance run go there (see [Tests](#how-is-it-tested)).
   - No worker pool today is recorded as implementing AVX-512. linux-arm64 has no registered row at
     all.
2. **A measurement shows a gain.** The benchmark programs
   ([benchmark_programs.md](benchmark_programs.md)) run on one machine against both the variant and
   the one below it.
   - The result is committed with the change that adds the variant.
   - A variant whose queries run within run-to-run noise of the one below it is not shipped. It
     would add its full size for nothing.

Adding a variant then takes three changes: the variant is added to the list of built variants, a
link target is declared, and the manifest gains its line. Neither loader changes.

### 5. How the loader picks a variant

The selector lives in each language package's loader, just before the library is opened.
**EXISTS** for Python: `_select_variant`, called by `_native.load`
([python/komira/_native.py](../../python/komira/_native.py)). **EXISTS** for Node: `selectVariant`,
called by the main package's loading step ([node/src/cpu.ts](../../node/src/cpu.ts)), in place of
"on linux-x64, it runs the CPU check" ([typescript_package.md](typescript_package.md), "How the
package finds libkomira"); its test reads the Python selector's fixtures and table of choices.

Until the wheel copies the variants directory, the Python loader also opens a directory without a
`VARIANTS` manifest, which is what the wheel's `komira/_lib/` and the tests' library directories
are today: it holds one `libkomira`, built for the row's own `target_cpu`, and the fixed x86-64-v3
check of `_check_cpu` still guards it. Only a directory that has a manifest goes through the steps
below. When the wheel carries the variants directory, a missing manifest becomes the
`LibraryLoadError` of step 1 and `_check_cpu` goes.

1. Read `<dir>/VARIANTS`. A missing or malformed manifest is a `LibraryLoadError` naming the file.
   An installed package always carries one, so without it the install is damaged.
2. If any line lists features, read the CPU's features. On Linux they are the words of the `flags`
   line (x86) or the `Features` line (arm64) that every processor of `/proc/cpuinfo` lists. This is
   the rule `_cpu_flags` applies today: only that key counts, a flag is a whole word, and a processor
   lacking a flag removes it. An unreadable `/proc/cpuinfo` is a `LibraryLoadError`, as today. If no
   line lists features (darwin-arm64), nothing is read.
3. Take the **last** line whose features the CPU all has. If there is none, raise
   `UnsupportedCpuError`, naming the floor variant and the features of its line that the CPU lacks.
   The class is unchanged. On linux-x86_64 the threshold moves from x86-64-v3 to x86-64-v2, and the
   message names x86-64-v2.
4. Open that line's file by absolute path. If a listed file is missing, raise `LibraryLoadError`
   naming it. The loader never falls back to a lower variant, because a damaged install would then
   load and run slower, and nothing would say why.

The rest of the load is unchanged. The library is opened once per process and never closed, and a
second load from another path is refused. So a process holds one variant, and the zygote-forked UDF
workers inherit it. The selector takes the directory and the cpuinfo path as private arguments, as
`_check_cpu` takes `cpuinfo` today, so tests plant both. The loader keeps the directory it loaded
from, so a second load of the same directory returns the same library without reading the CPU
again, and the runtime check is given the directory's own `lib/`, not one beside the variant.

The selector adds no environment variable (rule S2), no user setting, and no public name. A user
whose virtual machine hides a flag gets the lower variant. That is correct: the hidden flag may not
work there.

## What must always hold?

- **Every variant gives the same answer.** For the same plan and input, every variant returns the
  same Arrow bytes. Results equal DuckDB's (rule B21) on every machine, not on some.
  - `SumOfProduct` in `src/agg/builtin_agg_fns_sum_product.mojo` keeps its per-row accumulation
    order (its note on `update_chunk`), and the vector SUM, MIN, MAX and AVG cells of
    `src/agg/builtin_agg_fns_vec.mojo` dropped their SIMD reductions. So those are bit-exact across
    lane widths.
  - A floating-point reduction whose lane count follows `simd_width_of` would break this. So would a
    compile that contracts `a * b + c` into a fused multiply-add at v3 but not at v2; `SumOfProduct`'s
    `state + a * b` is that shape. The cross-variant test below catches both, and its cases include a
    float `SUM(a * b)`.
- **No variant runs on a CPU that lacks a feature it was built for.** The selector compares the
  manifest's features with the CPU's, and the table check ties each variant's `requires` to its
  `target_cpu`.
- **No silent downgrade.** A listed file that is missing is an error, never a quiet load of a lower
  variant.
- **The floor is at the old path.** `<dir>/libkomira.so` is always the floor, so the layout change
  only adds files.
- **The default is shipped.** The tests run against the row's `target_cpu`, and the table check
  requires one variant to be exactly that build.

## Size cost

Each variant is a full copy of `libkomira`. The rest of the directory is shared. Deflate compresses
each zip member on its own, so near-identical variants do not compress against each other: the
compressed size also grows by about one library per variant.

Measured: the `so_report` table in [src/so/README.md](../../src/so/README.md) gives the sizes, in
bytes, of `libkomira` as it is linked today (against `sdk`, not the whole engine).

| part | bytes |
|---|---|
| `libkomira.so` | 3,524,608 |
| the eight native owners | 490,856 |
| the three Mojo runtime libraries (`libAsyncRTRuntimeGlobals`, `libKGENCompilerRTShared`, `libMSupportGlobals`) | 1,956,960 |

Inferred from those numbers, uncompressed, linux-x86_64:

| variants | directory | change |
|---|---|---|
| v3 only (the self-contained directory, before variants) | 5,972,424 | none |
| v2 and v3 (this design) | 9,497,032 | +59% |
| v2, v3 and v4 | 13,021,640 | +118% |

- The engine link will make `libkomira` larger, and then the library is most of the directory. In
  general the directory is 2.45 MB plus N times the library size, and the wheel grows about linearly
  with N.
- PyPI's default limit is 100 MiB per file. The build task records each variant's size in the
  `so_report` table.
  - If the compressed linux-x86_64 wheel passes 50 MiB, the variant set is decided again before a
    release adds to it. Half the limit leaves room for the engine to grow and for one more variant.
- darwin-arm64 does not change. A registered linux-arm64 row starts at one variant.
- Build cost: one more `libkomira` link per extra variant. No precompile action is added.

## How is it tested?

The tests are written in each package's own language, in the manner of today's `test_cpu.py`.
Timing is never asserted.

- **The table check** has a refusal case for each rule of decision 3, in
  [tools/build/tests/functional/platform_table/cases.bzl](../../tools/build/tests/functional/platform_table/cases.bzl):
  an empty list, a duplicate name, a non-increasing `requires`, and no variant equal to `target_cpu`.
- **The selector**, from planted cpuinfo files and planted directories, in Python and in the Node
  package's tests. **EXISTS** for Python: `variants_test`
  ([python/tests/test_variants.py](../../python/tests/test_variants.py)), with the fixtures and the
  table of expected choices in
  [python/tests/fixtures/isa_variants](../../python/tests/fixtures/isa_variants/README.md) and the
  shipped manifest read from `//tools/build/package/libkomira:libkomira_variants_manifest`, written
  from the row. **EXISTS** for Node: `//node:package_test`
  ([node/tests/variants.test.ts](../../node/tests/variants.test.ts)), on the same fixtures, table
  and manifest.
  - Both languages share one fixture set and one table of expected choices, so the two loaders cannot
    disagree.
  - The fixtures are written from real `/proc/cpuinfo` files of each level. The cases:
    - a CPU at each level, which picks that level;
    - a v4 CPU when v4 is not shipped, which picks v3;
    - a v3 CPU lacking one v3 flag, which picks v2;
    - a CPU below v2, which raises `UnsupportedCpuError` naming the missing v2 flags;
    - two processors where only one has `avx2`, which picks v2;
    - `avx2` only on a `vmx flags` line, which picks v2;
    - an unreadable cpuinfo, which raises `LibraryLoadError`;
    - a missing manifest, a malformed line and a listed file that is missing, each a
      `LibraryLoadError` naming it;
    - a manifest line with an extra field, which loads;
    - a manifest with no features, whose cpuinfo path does not exist, which loads without reading
      it;
    - a Raspberry Pi 4 and a Neoverse N1 `Features` line, which pick `generic` and `neoverse-n1`.
  - This list covers each branch of the four steps of decision 5. Each failure has its own message,
    asserted by exact equality.
- **Each variant loads and answers.** The installed-wheel test on linux-x86_64 installs the wheel
  into an empty environment. A process holds one library, so it runs one subprocess per built
  variant. Each subprocess forces its variant through the selector's private cpuinfo argument (a
  planted cpuinfo of that level) and runs the SQL conformance cases. The test then requires every
  variant's Arrow output to be byte-equal to the default's. linux-x86_64 workers implement v3, so v2
  and v3 both run there.
- **Today's CPU test is rewritten, not weakened.** `python/tests/test_cpu.py` asserts the v3
  threshold. With the selector its cases move to the new threshold and the selection cases above,
  and each refusal is still asserted by exact message.
- **The source builds at each variant.** The variant link builds in the pull request's check, like
  any target whose inputs changed.

## Prerequisites in the source

An x86-64-v2 or generic arm64 link is the first compile of the tree below today's levels. Code
guarded only by `CompilationTarget.is_x86()` or `not is_x86()` that uses a higher feature fails there,
at compile time or as an illegal instruction. Found by reading, before any build:

- `table_lookup_u8x32` in `src/simd_ops/src/simd_ops/byte_class/table_lookup.mojo` uses AVX2's
  `vpshufb ymm` under `is_x86()` alone.
  - At v2 it needs the `CompilationTarget._has_feature["avx2"]()` guard and a two-`pshufb` form.
  - `quote_region_mask.mojo` already guards PCLMULQDQ this way.
- `quote_region_mask_u64` in `src/simd_ops/src/simd_ops/byte_class/quote_region_mask.mojo` uses PMULL
  on every non-x86 target.
  - PMULL is part of the arm64 crypto extension, which the Raspberry Pi 4 lacks.
  - The generic arm64 floor needs the `_has_feature["aes"]()` guard and the shift-XOR fallback that
    already follows.

The build task fixes whatever else the first v2 link refuses, each fix with a test that fails at v2
without it.

## What is not changed

- **The program bundles** (`mojo_bundle`, [tools/build/package/README.md](../../tools/build/package/README.md))
  keep their launcher and their `lib/glibc-hwcaps/<level>/` layout.
  - The launcher opens the program by name, so glibc's own search already picks among level
    directories there. Its `VERSION` file already has a `cpu_levels` key.
  - A bundle with several levels is a separate change on the same table field.
- **The conda package of libkomira** keeps one `lib/libkomira.so`, built at the default.
- **The default configuration**: platforms, constraints, `golden_config_hash`, the unit tests and
  coverage all stay at the row's Mojo `target_cpu`. Only the C compiles move, to the floor
  (decision 3).
- **The C ABI.** Variants are links of one source with one export list, and `komira_abi_version` is
  the same in each.

## Alternatives considered

- **One floor build (x86-64-v2 only).** Smallest. Every user loses AVX2 and BMI2, including the
  `simd_width_of` loops at 256 bits.
- **Keep one build at v3 and refuse the rest (today).** No size cost. Machines below the level and
  emulated x86 stay refused.
- **Choose at run time inside one library.** Mojo 1.0 has no per-function target attribute,
  ifunc or multiversioning, and widths are compile-time parameters. One library would have to hold
  every kernel compiled several times, behind a dispatch at hundreds of call sites. Its size would be
  about the same as separate links, and its source far larger. Revisit if Mojo gains per-function
  targets: then only the hot kernels would be duplicated.
- **A forwarding library that opens the right variant.** Every export would have to be forwarded,
  and two komira libraries would be mapped in one process. The loaders already run code before the
  library opens, so the choice costs nothing there.
- **Separate distributions per level** (a `-compat` package). The user picks after a crash, and two
  names install the same import.
- **glibc-hwcaps for the packages.** It needs a load by name, which neither loader does. It exists
  on glibc alone, and covers none of the arm64 variants.
- **CPU-level wheel tags.** Proposals for wheel variants exist. pip does not support them, and npm
  has nothing comparable. Revisit when pip selects wheels by CPU level.

## Task plan

1. **Source prerequisites** (small, independent): the two guards above, each with a Mojo test of the
   fallback form.
2. **Build the variants**, after the change that makes the wheel self-contained has merged: `isa_variants` in the table, with its check and its refusal cases. Then
   the variant toolchains, the C toolchain at the floor, `target_features` wired into the compile,
   one link target per variant, and the directory layout and manifest. Then the wheel's `komira/_lib/`
   copy, the size rows and the per-variant installed-wheel run.
3. **The selector** in Python and in the Node package, with the shared fixtures and expected-choice
   table. Both halves are built (decision 5).
4. **Later, each on its own:** `x86-64-v4` and `neoverse-n1`, when [decision 4](#4-when-a-higher-variant-is-added)
   holds.

## What are the limits and open questions?

- **No variant's speed gain is measured yet.** v2 is justified by who it admits, and v3 by being
  today's tested default. v4 and `neoverse-n1` wait for a number (decision 4).
- **Mojo accepting the levels.** Mojo must accept `--target-cpu x86-64-v2` and `x86-64-v4` and the
  arm64 names, which only an aquery checks today
  ([tools/build/tests/README.md](../../tools/build/tests/README.md), the consumer override case). This
  is the first thing the build task confirms.
- **The kernel's flags.** The selector trusts that Linux lists an AVX-512 flag in `/proc/cpuinfo`
  only when the kernel also enables that register state. The bundle launcher checks `XCR0` itself
  (`tools/build/package/launcher/cpu_level.h`). The build task confirms the kernel rule before v4
  ships.
- **The size of the engine link** is unknown until `so` links the engine. The size rule above
  decides from the measured number.
