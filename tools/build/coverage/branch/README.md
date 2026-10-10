# Branch coverage runs

With coverage on (`-c komira.coverage=true`, linux-x86_64;
[Coverage builds](../../mojo/README.md#coverage-builds)), each welded test
of a `mojo_library` is also built for branch coverage: compiled to LLVM
bitcode, instrumented with IR profile counters by the LLVM the Mojo compiler
is built on, linked with the LLVM profile runtime, and run through the
release gate's runner. What each run writes is the counts of every branch
the test's code took, as an indexed profile; that profile is then applied to
the bitcode, and each branch of the library's own sources is classified (a
source decision, or a branch the compiler made) and written as lcov `BRDA`
records. The rules are
[`coverage_branch.bzl`](../../mojo/coverage_branch.bzl); the LLVM pieces are
[`toolchains/llvm_branch`](../../toolchains/llvm_branch/README.md).

The coverage gate reads the records (`covcheck gate --branch-lcov`,
[The build gate](../README.md#the-build-gate)) of a library of
`COVERAGE_BRANCH_GATE` ([`policy.bzl`](../policy.bzl): every library
whose tests' branches all classify, as the sweep of every library found
them) and of every fixture of the tests cell: their gates wait for these
actions, so a test failing instrumented or a branch the classifier refuses
fails the gate with the switch on, in every mode, which leaves the
library's conda package (what ships) unbuilt and nothing else. The
classifier refuses what it has no evidence for, and the other libraries
have such shapes (Refusals that stay, below), hold no arm, or have a
coverage build that fails, so for them nothing waits for these actions,
and they are built when asked for:

```sh
./buck2 build 'komira//src/komira_retry:komira_retry[coverage][branch_info]' -c komira.coverage=true
./buck2 build 'komira//src/komira_retry:komira_retry[coverage][branch_info][test_decide]' -c komira.coverage=true --show-output
```

| target | what |
|---|---|
| `:cov_branch` | the directories every library's branch coverage links, runs and annotates from, and the classifier (`cov_branch_dir`, [`defs.bzl`](defs.bzl)), from `komira//tools/build/toolchains/llvm_branch:llvm_branch` (so its checks gate every use): `[link]`, [`cov_branch_link.sh`](cov_branch_link.sh) with `lld/` and `llvm/runtime/` (the profile runtime); `[run]`, [`cov_branch_run.sh`](cov_branch_run.sh) with `llvm/` (`llvm-profdata`) and `raw_version`, the raw profile version every run requires (`RAW_PROFILE_VERSION` of [`llvm_branch/defs.bzl`](../../toolchains/llvm_branch/defs.bzl)); `[annotate]`, [`cov_branch_annotate.sh`](cov_branch_annotate.sh) with `lld/` and `llvm/` (`llvm-profdata`); `[classify]`, the `:cov_branch_classify` executable. One directory per action, as `cov_link` and `cov_run` are two: an edit of one script re-keys no other action. (Projections of one directory would not do it: an action given `dir.project(path)` is keyed on the whole directory, as measured remotely.) |
| `:cov_branch_classify` | [`cov_branch_classify.zig`](cov_branch_classify.zig) (importing [`cov_branch_andor.zig`](cov_branch_andor.zig), [`cov_branch_source.zig`](cov_branch_source.zig), [`cov_branch_ir.zig`](cov_branch_ir.zig) and [`cov_branch_records.zig`](cov_branch_records.zig): `zig_exe`'s `imports`), a static executable built with the pinned zig, gated by `:cov_branch_classify_cases` ([`cov_branch_classify_cases.sh`](cov_branch_classify_cases.sh) over [`fixtures/`](fixtures)), which run as a build action: no build hands out the classifier unless they pass. Zig, not Mojo: a Mojo tool would be in the closure of the libraries it measures, the cycle covcheck has (`COVERAGE_NO_GATE`) |
| `:cov_branch_link.sh`, `:cov_branch_run.sh`, `:cov_branch_annotate.sh` | the scripts, exported so a fixture of the tests cell can plant a defect in a copy (test 47) |

Per `test_srcs` entry that is a source file, five actions, each a
sub-target of the library's `[coverage]` (and each `[bc]`, `[pgo_bin]`,
`[branch]`, `[branch_ir]`, `[branch_info]` alone is every test's file):

| sub-target | action category | output | what it does |
|---|---|---|---|
| `[coverage][bc][<test>]` | `mojo_emit_cov_bc` | `cov/branch/<test>.bc` | `mojo_wrapper.sh` (unchanged) runs `mojo build --emit llvm-bitcode --optimization-level 0 --debug-level line-tables`, with the same `-D` arguments (the library's `test_assert_level` and `test_defines`), against the same closure (the ungated package, its deps and the library's `test_deps`), with the same source root, as the test's `[coverage][bin]` and its release build |
| `[coverage][pgo_bin][<test>]` | `mojo_cov_pgo_link` | `cov/branch/<test>` | [cov_branch_link](#cov_branch_link) |
| `[coverage][branch][<test>]` | `mojo_cov_branch_run` | `cov/branch/<test>.profdata` | [cov_branch_run](#cov_branch_run) |
| `[coverage][branch_ir][<test>]` | `mojo_cov_branch_annotate` | `cov/branch/<test>.ll` | [cov_branch_annotate](#cov_branch_annotate) |
| `[coverage][branch_info][<test>]` | `mojo_cov_branch_classify` | `cov/branch/<test>.info` | [cov_branch_classify](#cov_branch_classify) |

`[coverage]` itself (the kcov binaries, reports and gate) does not include
them, and a library whose `test_env` sets `LLVM_PROFILE_FILE` is refused at
analysis, since the run sets it. With the switch off the actions do not
exist, and with it on no release action changes
([test 41](../../tests/coverage_runs.md#test-41-coverage-builds)'s
`coverage_keys.sh` counts one of each per test, requires that no join
waits for them directly, and that the gate's inputs hold each test's
records).

## cov_branch_link

1. `lld/bin/lld` reads the bitcode as an LTO link with `-r`, `--lto-O0` and
   the pass pipeline `pgo-instr-gen,instrprof,default<O0>`: a relocatable
   object whose code counts its edges. Only this LLVM 24 reads the bitcode
   ([toolchains/llvm_branch](../../toolchains/llvm_branch/README.md#why-llvm-23-tools-are-safe-next-to-llvm-24)).
2. The Mojo toolchain's zig links it as `mojo_wrapper.sh`'s `cc` shim links
   a release test (the line `mojo build` gives it: the compiler's
   `libKGENCompilerRTShared.so`, `--gc-sections`, `-lm`; the shim's
   `--strip-debug` and the one run path `$ORIGIN/lib`; then the C libraries
   of the closure, `test_deps` included), with `llvm/runtime/libclang_rt.profile-x86_64.a` as a
   whole archive. Test 47's `link_line` records the line zig is given by
   both links (a stand-in zig) and fails when they differ by more than the
   profile runtime, so a Mojo release that links with another library, or
   another flag, is caught there.
3. The binary must be an ELF file holding no path of the action (its
   working directory or scratch directory).

**Why no debug info.** The binary's debug info is stripped, as in a release
link. Nothing reads it: what each counter means in the source is read
later from the bitcode (the IR the profile is applied to, which keeps the
line tables, with each branch's line and column), never from the binary.
The strip also removes the only directory of the action in the link, the
compilation directory zig's C runtime objects record, so no relocation (the
kcov binaries' [`cov_zig`](../kcov/README.md#cov_zig)) is needed, and
step 3 shows it: with `--strip-debug` left out, the link fails with `the
binary holds this action's directory`.

## cov_branch_run

1. `gate_runner.sh` (unchanged) runs the test from the release gate's
   staged tree (its data under `share/`), with the gate's environment (the
   script exports nothing of its own to the test: its `LC_ALL=C` is set
   after the run), the test's `test_env`, and one more variable, `LLVM_PROFILE_FILE` =
   `<scratch>/prof/%p.profraw` (`%p`, the pid: a child the test starts
   writes a profile of its own). The test must pass. When it fails, so does
   the action, with the test's output and `BRANCH COVERAGE RUN FAILED`, not
   gate_runner's banner (which says the release gate's test failed: that
   one passed).
2. At least one `.profraw` was written there; otherwise `The test passed but
   wrote no .profraw` (the runtime was not linked, the variable did not
   reach the test, or the test left without running its exit handlers).
3. Each raw profile starts with the 64-bit raw magic, has version
   `raw_version` (11) and carries the IR-instrumentation flag `0x01000000`,
   read as `:raw_version_check` reads its fixture's
   ([The version coupling](../../toolchains/llvm_branch/README.md#the-version-coupling)).
4. `llvm/bin/llvm-profdata merge` writes the indexed profile; a refusal
   that is LLVM's `raw profile version mismatch` says which version it
   expected. `llvm-profdata show` must report IR instrumentation and at
   least one function.

What differs from the release gate: the binary is the test at -O0, compiled
by Mojo to bitcode and instrumented and code-generated by lld, not Mojo's
own -O1 build; its environment also holds `LLVM_PROFILE_FILE`. Like the
gate, the run waits for the test alone: a child still running when it exits
writes its profile after the merge, or never. Like the gate, it has no time
limit of its own (the kcov run, `cov_run.sh`, has one, with a kill of the
test's process group): a test that hangs instrumented holds its action
until the executor's timeout.

## cov_branch_annotate

It reads the test's bitcode, the merged profile and the instrumented binary
that wrote it (`[coverage][pgo_bin][<test>]`).

0. The bitcode must hold no branch weights of its own (the bytes of a
   `branch_weights` metadata string): `pgo-instr-use` keeps a `!prof` it
   finds on a branch whose block never ran, which would then read as counts.
   Mojo's bitcode at -O0 holds none (`llvm.expect` is not lowered there).
   Nor may it hold entry counts (`function_entry_count`), which step 3
   counts.
1. The profile holds exactly the functions the binary links. Every function
   of the bitcode is instrumented, but the link (`--gc-sections`, as a
   release test's) drops a function nothing live calls, with its counters
   and its profile data record. Mojo leaves such calls in the bitcode: an
   `assert_equal` of two values it knows are equal compiles to `br i1
   false` into the failure path, which calls the standard library's
   `_assert_cmp_error`, `String(...)` of both values and their `write_to`;
   LLVM's code generation (CodeGenPrepare) folds that branch and deletes the
   path, so nothing calls those functions and the link drops them. A run
   writes the record of every function its binary links, zeros included,
   and of no other. So the (name MD5, hash) pairs of the binary's
   `__llvm_prf_data` records (72 bytes each, whose counter counts must add
   up to `__llvm_prf_cnts`) and of the profile's functions (`llvm-profdata
   show`) must be one set. A record the profile lacks is a profile of
   another binary, or a merge that lost records (tests//negative/coverage:branchmissing
   plants one); one it holds besides, a profile of another binary.
2. `lld/bin/lld` reads the test's bitcode as `cov_branch_link.sh` does (`-r`,
   `--lto-O0`) with the one pass `pgo-instr-use`, given the merged profile
   (`-pgo-test-profile-file`), and prints the module after it
   (`-print-after=pgo-instr-use -print-module-scope`, on stderr): every
   `br i1`, `select i1` and `switch` of a function that ran carries `!prof
   !{!"branch_weights", ...}`, the counts of its arms; one that never ran
   carries none. Before the dump, LLVM names each function of the bitcode
   the profile does not hold (`no profile data available for function`,
   `-pgo-warn-missing-function`). Such a function is not in the binary, by
   step 1 and step 3's entry-count check together (step 1 alone does not
   give it: `branchinternal`'s `main` ran, yet is named here, because its
   profile name is not the run's), so it never ran: its branches carry no
   weights and read as never run, zero counts, as those of a function that
   ran no time do. A measured
   one is recorded, every arm `-` (test 47's `test_unrun`: `Tag.write_to`).
3. Any other line of lld's own (`lld: `, `warning: `, `error: `), or
   anything before the dump that is not one of those lines, fails the
   action. The one LLVM prints when the profile does not fit the control
   flow, `function control flow change detected (hash mismatch)`, means that
   function's counts were dropped, and passing it on would read as branches
   that never ran (tests//negative/coverage:branchannotate plants it). In
   the dump, `pgo-instr-use` must have given an entry count (`!prof` on the
   `define`) to as many functions as the profile holds: each function the
   binary links is one of this bitcode. Fewer is a binary made from other
   bitcode, or a hash mismatch LLVM does not warn about (a comdat
   function's, by default) (branchinternal plants it: the bitcode internalized, so `main`'s
   profile name is not the run's).
4. What lld printed is then exactly one dump, starting with `; *** IR Dump After
   PGOInstrumentationUse on [module] ***`; it is `cov/branch/<test>.ll`,
   unchanged. `-print-after` output is LLVM's debug text, not an interface:
   the classifier parses it strictly and fails on what it does not expect.

## cov_branch_classify

Reads `cov/branch/<test>.ll` and writes `cov/branch/<test>.info`
([`cov_branch_classify.zig`](cov_branch_classify.zig), the branch walk,
importing [`cov_branch_andor.zig`](cov_branch_andor.zig), the `and`/`or`
rules, [`cov_branch_source.zig`](cov_branch_source.zig), the source side,
[`cov_branch_ir.zig`](cov_branch_ir.zig), the metadata, one function's
index and the instruction shapes, and
[`cov_branch_records.zig`](cov_branch_records.zig), the output).

**Files.** Each branch is attributed to its innermost `!dbg` location (an
inlined instruction's own file, line and column, not its call site's). The
library's sources are named in the IR by their path in its `[src]`
(`buck-out/v2/art/.../__<lib>__/<content hash>/src/<lib>/...`: the package is
compiled from it), given as `--map <[src]>/=<repository dir>/`, so a record
names `src/<lib>/policy.mojo`; a generated source (`--gen`) is not measured.
The standard library (`oss/modular/`), the closure's other libraries (under
`buck-out/`), the test itself and `<unknown>` are left out by name; any
other name fails the action, and so does any name holding `/<content
hash>/src/<lib>/` that is not `--map`'s (the library's sources under another
`[src]`: another hash, target or configuration directory), which `--exclude
buck-out/` would otherwise drop. `--stdlib oss/modular/` says where the
standard library's sources are named (a String's last-reference test, below,
is its code). Every `.mojo` file of `[src]` is read for the functions it
declares `@always_inline("nodebug")` (below).

**String lifetime.** Mojo 1.0's `String` destructor and copy are
`nodebug` inline code: their branches carry the location of whatever token
used or consumed the String (`==`, `!=`, `+=`, `+`, `.`, `[`, `^`, a name,
`self`, `out`, a call's `(`, and an `if`, `while`, `and`, `or` or loop head
where a String dies). Each destroy gives four branches (the standard
library's `_drop_ref`: the refcounted flag, bit 62 of the capacity word;
the last reference, `fetch_sub(1) == 1`; the inline flag, bit 63; the
negated bit-62 test) and the capacity computation gives selects. A br or
select whose condition is one of these is compiler-made at any token,
checked before the token:

- (a) `icmp ne i64 (and i64 W, M), 0`, M bit 62 or bit 63, the `and` and
  the `icmp` at one `!dbg`, W the flags word: a `load i64` of field 2 of a
  `{ ptr, i64, i64 }`, or a web of `phi i64` (a raising callee inlined at a
  call carries its error String in values) whose leaves are such loads,
  i64 constants and `undef`, one leaf at least such a load or a static
  String's flags (1 << 61);
- (b) `xor i1 (a), true`;
- (c) `icmp eq i64 X, 1`, X an `atomicrmw sub ptr _, i64 1` (directly or
  through a one-incoming `phi i64`) whose location is under `--stdlib`,
  inlined at the branch's own `!dbg`.

The tested instruction (the `icmp` of a and c, the `xor` of b) carries the
branch's own `!dbg`; only (a)'s may sit at another location, and only at a
token that is no decision (a call's branch reusing an earlier destructor's
test: 74 in the triage sample). So a decision on such a test is recorded,
never dropped: user code computes its test at its own tokens, not at the
`if`. Test 47's `branchlib/mask.mojo` masks a List's capacity (a field-2
load of a `{ ptr, i64, i64 }`) with bit 62: `if ys.capacity() & (1 <<
62):` gives the `and` and an `icmp ne` both at the `&`, shape (a) whole,
and is kept a decision by this location check alone (relaxing it drops
the record there); `!= 0` gives `icmp eq` and `xor` at the `!=`, none of
the shapes, the `and` at the `&` (41 user masks in the sample put the
`and` and the comparison on two columns, among them `(mode &
ADVICE_HUGEPAGE) != 0` and `(flg & 0x08) == 0`). A `nodebug` helper of the
library's would give its `icmp` the helper call's column, not the `if`'s. A branch at
the `(` of a measured `nodebug` function's call is refused whatever its
shape (below). Evidence: the sweep's sample of 20 libraries' IR (every
refusal class), e.g. `kci_api/exit_codes.mojo` 101:17 (`if error_id ==
ERROR_INTERNAL:`, the temporary's destroy at `==`, the `if` a branch of its
own at 101:5 on `String.__eq__`'s result), `kci_api/result.mojo` 481:9 (two
owned arguments destroyed on the `if`'s return path: eight branches at the
`if`), `komira_eval/expression_executor.mojo` 3979:13 (the capacity select
at a `while`), `komira_parquet/delta.mojo` 329:54 (the phi web, an inlined
`read_uleb128`'s error String). Before this rule a destroy at a decision's
token was recorded as more decisions: `komira_parquet_codec`'s
`lz4_ffi.mojo` 227:9 (`if Int(is_err) != 0:`) held five records `br:0/5`
to `4/5`, one of them the `if`; its library's arms went from 469 of 590 to
404 of 438, `komira_name_registry`'s from 25/40 to 24/32 (`komira_retry`'s
74 had none). Of the sweep's 41,730 refusal messages, 33,736 were this
shape at a token the classifier did not know.

**Classes.** Then the source token at the branch's line and column decides
the class, and each class takes only the instruction kinds in its row; any
other kind at its token fails the action. A compiler-made class takes only
the kinds and shapes it has shown, as it drops what it takes. A source
decision also takes kinds it has not shown where its meaning allows them (an
`if` or `elif` as a `switch`, an `elif` as anything an `if` is): that is
safe because a decision is recorded, never dropped, so a wrong guess shows
as a record, not as a branch missing from the count:

| class | tokens | kinds | evidence (`komira_retry`'s six tests, test 47's `branchlib`, the sweep) |
|---|---|---|---|
| source decision | `if` (statement or ternary) | br, select, switch | `policy.mojo` 117:9 and every `if` statement; the ternaries 291:40 (`String("throttled") if verdict.throttled else ...`, a br) and `branchlib/shapes.mojo`'s `1 if flag else 2` (a select); the `if` of a plain `@always_inline` helper, a select at its own line with `inlinedAt` (`shapes.mojo`'s `pick`); `budget.mojo` 63:9 is both branched on and selected on (one decision, below). No switch has been seen; it is a decision by its meaning |
| source decision | `elif` | br, select, switch | Mojo gives an `elif`'s branch its `if`'s location (`branchlib/score.mojo`: three branches at 4:5), so none has shown at an `elif` column yet; allowed as a decision by its meaning |
| source decision | `while` | br | `branchlib/shapes.mojo`'s `while i < n` (a select at a `while` is a String's capacity: above) |
| source decision | `or`, `and` | br, select | `select` at `or` (`policy.mojo` 65:20, 94:27; `score.mojo` 4:18), a chain `a or b or c` (`shapes.mojo`: the first select's result is the second's condition), `br` at `or` (short-circuit, `budget.mojo` 63:21, whose result is a phi at the token), `select` at `and` (`score.mojo` 6:22) |
| source decision | the head of a `for <targets> in <iterable>:` line's iterable: a call's `(` when it ends in `)` (`range(`, `reversed(`, `x.items(`, `f[T](`), an attribute's last `.` (`self.cases`, `p.data().keys`), a name's first character, a list literal's `[` (one running over lines too); a chain may start at a string literal (`"ab".as_bytes()`). Any other iterable (a subscript, an operator, a tuple) has no head | br | `policy.mojo` 121:23, `shapes.mojo`'s `for _ in range(n)`: two branches on one value per loop (one decision, below); arm 0 is the iterator's end (the loop exits), arm 1 an iteration. The sweep's `for` lines: the iteration branch at the head in every one (`clouds.mojo` 207:27 `env.items(`, `float32_parse.mojo` 178:24 `reversed(`, `split.mojo` 976:14 a name, `expr.mojo` 1983:22 `self.cases`, `auto_promotion.mojo` 336:16 a list literal, `plan_validator.mojo` 463:36 `plan.join_data_ref().left_on`, `workflow_reader.mojo` 235:14 `[` over lines, `split.mojo` 967:32 `"THSPLIT".as_bytes(`). Iterator shapes: `icmp eq i8 (extractvalue {T, i8} next, 1), 0` (arm 0 the end, as for `range(`) or `call i1 @...__next__` (a list literal's, `_ArrayIterOwned::__next__`: the `i1` is its raising flag, true when it raises StopIteration, so arm 0 is the end too). Test 47's `branchlib/loops.mojo` pins both: `for x in xs:` 9,14 is 2,3 (a three-element and an empty List), `for s in [String("a"), String("bcd")]:` 16,14 is 1,2. A raising call's error check at the head is a decision too (no rule drops it there: `__next__`'s bare `i1` would match one), so a raise never taken reads as an arm not covered, never as a pass. A select at the head is refused |
| compiler-made | `+` | br | a String temporary's destructor before the String-lifetime rule read it: every `+` row of `policy.mojo` (216 in `test_decide` alone), `loop.mojo` 96:66, 96:83 |
| compiler-made | `//`, `//=`, `%` | select | the selects of floor division and modulo: `policy.mojo` 137:56 (`// 100`), 140:35 (`% UInt64(...)`), `seams.mojo` 51:44; `timestamp.mojo` 161:15 (`v //= 10`: `sdiv`, `mul`, `icmp eq`, `select`, the `//` family). `%=` has shown none and is refused |
| compiler-made | a subscript's `[` (after a name, `]` or `)`) | br on a raising call's error flag: the `i1` a `[tail] call i1 @...` at the branch's location returns, or field 0 of the `{ i1, ... }` one returns | `clouds.mojo` 211:20 (`env[sorted[i]]`, `Dict.__getitem__`'s KeyError: `extractvalue { i1, ptr } (call), 0`); 18 such in the sample; test 47's `branchlib/lookup.mojo` 7:13 (`d[key]`). Any other branch at `[` is refused (no user decision sits there). In a `try:` body the error check is a decision ([try](#try)) |
| compiler-made | the `(` of a call off a `for` line's head: `name(`, or `name[...](` (the name before the `[`, which may be lines above: a call whose parameters run over lines; brackets in one-line string literals and comments are skipped; a `"""` or `'''` between the `[` and `]`, which can open a string running over lines, refuses the branch) | br; select on a raising call's error flag (field 0 of a `{ i1, ... }`) or on a value a br at the same location with the same weights tests | code that carries the call's location: a raising call's error check (`loop.mojo` 100:31, `sleep_ms(`: `br i1` on the call's own `i1` result; `ipc_decoder_dispatch.mojo` 3401:56 at `_decode_column_nested_zerocopy[...](`; `parallel_fork_join.mojo` 239:14, `](` under a `run_with_state[` two lines up) and the code of standard-library functions declared `@always_inline("nodebug")` (no location of their own). A select on the error flag keeps the old value when the call raised (`ipc_encoder_dispatch.mojo` 223:59: `select i1 %err, i64 %old, i64 %new`); one on the value the call's error check branches on (`decimal256_arith.mojo` 179:31, an inlined raising callee's flag; `name_matcher.mojo` 379:39, a call's `i1`; `byte_hash_agg_table.mojo` 382:50) is that check's. Any other select at a call is refused (a `nodebug` `min(` would need evidence first). The error check of a call whose error goes to its caller (outside a `try:` body) is one; in a `try:` body it is a decision ([try](#try)), and any other br at the call is refused there |

A branch at the `(` of a call to a function the library's own sources
declare `@always_inline("nodebug")` is refused, whatever its shape: that
function's code has no location of its own, so its decisions land on the
call (test 47's `branchnodebug`: its `while` is a br at `count_down(`),
where they cannot be told from the compiler's. A plain `@always_inline`
keeps its locations (with `inlinedAt`), and its decisions are recorded where
they are written. A library source declaring an operator, constructor or
destructor (`__<name>__`) `@always_inline("nodebug")` refuses the run: its
code lands on any token.

Anything else fails the action naming `file:line:col`, the instruction and
the token: another word or operator, `%=`, a `(` not after a name or a
`name[...]`, a `(` on a `for` line off the head (another iteration), a
column outside the line, a class with a kind or shape it has not shown (a
select at `+`, a br at `[` on a comparison, a br at a call in a `try:` body
on anything but the call's error flag). The list grows only with
evidence. A branch with no `!dbg` fails too, and so does an `indirectbr`,
`callbr` or `invoke` in a measured file (Mojo emits none).

**Records.** Compiler-made branches are counted on stderr, not written. Each
source decision gives one `BRDA:<line>,<col>:<kind>:<n>/<N>,<arm>,<count>`
per arm: `<kind>` is `br`, `select`, `switch`, `try` or `rhs`; `<N>` is how many
decisions of that kind one copy of a function (one LLVM function, or one
inlined copy of it) holds at that location, and `<n>` which one, in IR
order: Mojo puts `if` and `elif` on one location (`branchlib`'s
`4,5:br:0/3`, `1/3`, `2/3`). Arms are numbered 0, 1, ... in the order of
LLVM's weights (true first for `br` and `select`, the default first for a
`switch`), not named true and false; a `try` decision's are returned (0)
and raised (1). The `<n>`-th of every copy (generic
instances, inlined copies) is summed arm by arm; every copy must hold as
many, and where both are known, compute the condition of its `<n>`-th at
the same line and column, or, for a decision at an `if`, `elif` or `while`
statement's keyword, inside its header (from the keyword to the `:` closing
it, over continuation lines): a copy may fold part of the condition away
(`primitive_array.mojo` 386:9, `if index < 0 or index >= self.length:`,
whose copies inlined with a constant index compute the condition at the
`>=`, the others at the `or`). An instance that folded away one `elif` and
another that folded away another would otherwise be summed crosswise, and
an `elif` has a header of its own, so it is still refused
(`column.mojo` 2583:13: a copy for `int32` computes its condition in the
`if`'s header, one for `int64` in the `elif`'s). A count of a branch that
never ran is `-`, counted and not taken (lcov's "never reached"), never 0.

One decision tested twice, two branches or selects on the same condition
value with the same weights node at the same location (a loop's two at
its head; `budget.mojo` 63:9's br and the select of its return value), is
one record: the br is kept.

**And, or.** A bool `and`/`or` is a decision where the user wrote it: its left
operand's branch or select at its token, two arms, the right operand
skipped or evaluated (for `or`, arm 0 is the left operand true, the right
operand skipped; for `and`, arm 0 is the left operand true, the right
operand evaluated). That holds wherever the result goes: tested by an `if`
or `while`, returned (`return a or b`), stored (`var r = a and b`) or
passed on (`f(a or b)`); a test must take both arms, which line coverage
cannot see (test 46's `covandor`: every line run, one arm of `return a or
b` never taken).

When a source decision tests the result, the right operand's own outcomes
are counted as well: `rhs`, derived from the left operand's counts (the
and/or's own select or br) and the whole condition's (the first branch or
select of a source decision that tests the result: the select's result
directly, the short-circuit form's phi at the token, either through `xor
..., true`, its arms swapped, through a phi forwarding that one value (one
incoming value, or every incoming value that one), or as the condition of
the next select of a chain). For `or`, the whole's true count less the
left's, and the whole's false count; for `and`, the whole's true count,
and the left's true count less it. An `and`/`or` that is itself the right
operand of a short-circuit one (`not st.break_glass and not (has_main and
has_push)`, `auto_promotion.mojo` 273) and that no branch tests takes the
outer one's derived right operand as its whole condition, swapped through
each `xor`: the inner value is computed exactly when the outer right
operand is. A select LLVM gave no weights never ran; with a whole of zero
counts, neither did its right operand.

A test is the result's only when it ran as many times as the left operand,
and its counts can be the whole's (an `or` true at least as often as its
left operand, an `and` at most as often): a test of the value that runs
another number of times reads it on some paths only, or elsewhere (`var
lower = c >= 97 and c <= 122`, then `lower or ...` only when `i != 0`:
`kci_api`'s `run_identity.mojo` 98, test 47's `values.mojo` 80:29), and
one that never ran while the left operand did (or the reverse) is not its
test either. Matching counts are necessary, not sufficient: a test whose
counts happen to match is read as the result's (`r = a or g(b)`, then a
loop testing `r` as many times as the `or` ran, on other values than each
run's), and the derived right operand is then wrong. A known limit; a
structural check (the test in the block the result is computed in, or
one only it reaches) would close it. Such a test gives no `rhs` (a later test may), and the and/or
is then its two arms alone, as one whose result is returned. Which tests
count depends on the counts, so one test's run of a function may give an
`rhs` and another's not: covcheck sums what each gives, and an arm a test
did not give is never a pass. A result merged with other values in a phi
(Mojo folds `if a and b: x = True` into `x = phi [a and b, ...]`,
`regexp_nfa.mojo` 1879) and tested after the merge is not followed: the
and/or alone.

The phi of a short-circuit form is at the and/or's token and joins one
value arriving under the `br`'s target for the deciding left value (its
true target for `or`, its false target for `and`) and one under the other
target: every path from the `br` to the incoming block passes through that
target, which only the `br` jumps to (the walk follows LLVM's `; preds =`
backwards and never past the target; reaching the `br`'s own block or the
entry refuses). The value under the deciding target must be the constant
that decides (`true` for `or`, `false` for `and`), as at `budget.mojo`
63:21 (`br i1 %3, label %4, label %5` then `phi i1 [ %8, %5 ], [ true, %4
]`, `%4` an empty block) or `auto_promotion.mojo` 709:24 (the constant
reaches the phi through a String destructor's diamonds), or a reload of
the left operand: `load i1, ptr P` of the pointer the left operand's load
reads, the first instruction of the target (lifetime markers and `nop` asm
aside) after a left operand loaded last before the `br`, so no write can
fall between (`rules.mojo` 556:26, 669:26, `auto_promotion.mojo` 280:25).
A constant under the other target is the phi of another expression (`not a
or b`) and is refused, and so is one arriving straight from the `br`'s own
block (a correct shape no IR has shown yet: refused rather than read
without evidence). A short-circuit br with no such phi at its token is
refused, tested or not: the phi is the evidence that the br is the
and/or's left operand (`runtime.mojo` 816:27, below). Several phis may join
the targets: a raising right operand's error flag beside the result
(`expression_executor.mojo` 4830:15; test 47's `values.mojo` 52:18, `return
a > 0 and strict(b)`). For an `and` the flag has the result's shape, and
each phi of that shape is a candidate: the result is the one a source
decision's branch tests (a call's error check testing the flag is no such
test, nor is a `try` decision). For an `or` the flag is `false` under the
deciding target and field 0 of the `{ i1, ... }` the right operand's call
returns under the other, which is no result. Any other `i1` phi at the
token (but a forward of one value), joining the targets in another shape
or not joining them, refuses an and/or whose result no test reads: which
phi its result is cannot be told, so it is not read as untested (a test of
a candidate reads it as before, and such a phi is refused only when no
candidate is). A value `and`/`or` (not `i1`) has no right operand that
decides. Since an `elif` carries its `if`'s location, its records name the
`if`'s line.

Known shapes, with what each gives:

- `if c: return True` then `return False`: Mojo folds it into `return c`
  (`ret i1`, seen in a draft of `shapes.mojo`), so the `if` has no branch
  and no record, as the same function written `return c` would have none.
  Accepted. An `and`/`or` in such a condition is then never tested, and is
  its own two arms (above).
- `<n>/<N>` numbers the decisions of one kind at one location in IR order.
  It cannot tell an `elif` (Mojo gives it the `if`'s location) from a second
  copy of one decision the optimizer made inside one function (loop
  unrolling, jump threading). Such a copy gets its own `<n>` and its own
  counts, so the original's arms look less taken than they are: the error is
  a false "arm not covered", never a silent pass. If two copies of a
  function disagree on `<N>` the action fails (above).
- A String's destructor or copy at a decision's token whose tested
  instruction sits at another location (a destroy reusing an earlier
  destroy's flags test) is recorded as a decision of that token (the rule
  above reads only the tested instruction's location there): a false "arm
  not covered" at worst, never a dropped decision.

Refusals that stay, from a census of the 98 libraries that refused before
the and/or rule (messages, at most 40 a test; locations; libraries): copies
holding different numbers of decisions at a location (231, 19, 9, among
them `regexp_nfa.mojo` 94:9; a `comptime for`'s unrolled calls sharing one `inlinedAt`, `primitive_array.mojo` 386:9
in `test_batch_view_u3_extensions`, 4 and 8 per copy); a br at a call in a
`try:` body on something else than the call's flag (179, 32, 5, among them
`close_and_remove(`); a short-circuit and/or with no result phi (23, 4, 4: an
`if` folded away when both arms return alike, `runtime.mojo` 816:27; a
`debug_assert` condition, `hyperloglog.mojo` 285:13; a non-`Bool` `and`
whose result goes through memory, `pplan_wire_equal.mojo` 189:21); a select
at a call on something else than a raising call's flag (20, 6, 2); a phi at
an and/or that is no short-circuit one's (14, 8, 4: a reload of the left
operand after String destructor code, `expr_interpreter.mojo` 368:51,
`supervisor_runner.mojo` 111:28); copies computing a condition in different
headers (8, 2, 2, above); zero branches parsed in a file with code on a
decision line (6, 1, 1: `komira_async`'s `wake_primitives.mojo` 236, not
explained yet). 23 of the 98 still refuse; 69 classify every test, and 5
more every test whose run and annotation pass (a sixth,
`komira_objectstore_s3`, has an annotation the census did not see finish
and refused no test it saw). No and/or was refused for an odd phi at its
token.

Every measured file with code on a line holding a decision word (`if`,
`elif`, `while`, `for`, `and`, `or`, outside strings and comments) must
have a branch parsed, or the action fails (the branches were not read).

Output: per measured file the IR holds code of, `SF:<repository path>`,
its records sorted by line, column, kind, `<n>` and arm, `end_of_record`;
files sorted bytewise. A file with code and no source decision is named
with no record (`SF:` then `end_of_record`), so covcheck counts its
package's branches as measured with none to take, rather than not measured
(a package with no decision at all, test 46's `covfull`, then passes on
branches). A test whose IR holds no code of the library writes an empty
file. The block field `<col>:<kind>:<n>/<N>` of these `BRDA` lines is
read by covcheck only: upstream lcov and genhtml take a block number there,
and these files are not for them. `<line>,<col>:<kind>:<n>/<N>,<arm>` is what covcheck sums by
across tests; one test's action cannot see another's, so covcheck refuses
two tests' records that give one location (line, column, kind) a different
`<N>`, or one decision a different number of arms
([Reading the reports](../README.md#reading-the-reports)). Two tests whose
copies of a function hold as many decisions at a location but different
ones (each folded away another) look the same to it and are summed
crosswise: like `<n>/<N>` within one test (Known shapes), a limit, not a
check.

`komira//src/komira_retry`, `test_decide` and `test_budget` (excerpts;
`budget.mojo` 63 is `if cost < 0 or cost > self._available:`, a
short-circuit `or` whose right operand decided true 7 times and false 26):

```
SF:src/komira_retry/policy.mojo
BRDA:65,9:br:0/1,0,0
BRDA:65,9:br:0/1,1,6
BRDA:65,20:rhs:0/1,0,0
BRDA:65,20:rhs:0/1,1,6
BRDA:65,20:select:0/1,0,0
BRDA:65,20:select:0/1,1,6
BRDA:117,9:br:0/1,0,0
BRDA:117,9:br:0/1,1,16
end_of_record
SF:src/komira_retry/budget.mojo
BRDA:63,9:br:0/1,0,8
BRDA:63,9:br:0/1,1,26
BRDA:63,21:br:0/1,0,1
BRDA:63,21:br:0/1,1,33
BRDA:63,21:rhs:0/1,0,7
BRDA:63,21:rhs:0/1,1,26
end_of_record
```

### try

A raising call lexically in the body of a `try:` of its own function is a
source decision of two arms, of kind `try`: arm 0, the call returned; arm
1, it raised into the handler (an `except`, or the `finally` before the
error goes on). A test must take both: a call in a `try:` body that never
raises leaves its handler path untested for that call, even when the
`except` body runs (another call raising) and line coverage is full
(tests//negative/coverage's `covtry`: 9 of 9 lines, 5 of 6 arms). The
arms are not LLVM's order (true, the call raised, comes first there).

What Mojo 1.0 emits is the same at a call in a `try:` body and outside
one: a `br i1` at the call's `(` (a subscript's `[`), on the call's error
flag, its raised target the handler or the propagation to the caller. So
the scope is read from the source, and the shape from the IR:

- Scope. From the call's line back, over the lines indented less than the
  last one met (blank, comment and triple-quoted-string lines skipped, and
  continuation lines, which start inside an open bracket: the `) raises:`
  closing a nested `def`'s signature over lines has the `def`'s
  indentation, and read as a statement it would hide the `def`; a file
  whose brackets do not balance, outside strings and comments, is refused
  at its first such branch, naming the line that opens the last bracket
  never closed or closes one never opened: no line's statement can be
  told there), a
  `try` line met before a `def`, `fn`, `struct`, `trait` or `class` line
  (another function: a `def` nested in a `try:` body is one), or the
  call's own line `try: <statement>`. An `except`, `else` or `finally`
  clause has its `try`'s indentation, so a call in its body is in that
  `try`'s body only if the whole `try` is in another's: a call in an
  `except` body of an inner `try` counts for the outer one (test 47's
  `nested`, 39:25); one in an `else` or `finally` body, or after the
  `try`, does not (its error goes to the caller), nor does one in a
  `with` body outside a `try:` body.
- Shape, at a call, a subscript or a `+` in the scope: the br must test
  the call's flag at its own location (the `i1` of `call i1`: `touch(x)`,
  a raising constructor `Box(x)`; field 0 of the `{ i1, ... }` one
  returns: `checked(x)`, a method `b.get(x)`, `d[key]`), or a `phi i1`
  of such flags, of `true`/`false` and of the code of a callee inlined at
  the call (whose `inlinedAt` chain holds the br's location: a plain
  `@always_inline` raising callee, the `phi i1` of its `if`'s condition,
  test 47's `inl(x)`; `Int(s)`, a phi of `String.__int__`'s flag; the
  raising right operand of an `and`, a phi of its flag and `false` at
  the `and`), with one such value at least, or one constant arriving from
  a block of the inlined callee's code (`komira_parquet`'s `rle.mojo`
  226:54, `read_uleb128` inlined: `phi i1 [ false, <its return> ], [
  true, <its raise> ]`). A phi of constants alone says which arm is which
  by its constants only, so each one from the callee's code must match its
  block: `true` from the raise path (the block calling
  `__mojo_debugger_raise_hook`, which Mojo emits at every `raise`: both
  shapes seen), `false` from any other; a phi saying `true` from the
  return (with `false` or `true` from the raise path) would swap or blur
  the arms, and is refused. Any other br there is refused: whether it is the call's
  error check is not known. A String's destructor at the call (the
  handler destroying the error's String) is the String's, as anywhere; a
  select on the flag stays compiler-made (the br is the decision).
- A `try` decision is no test of an `and`/`or` result: a raising right
  operand's flag beside the result (above) is tested by the call's error
  check, and the `if` is the and/or's test (the cases' 49,16).

Not decisions: a `raise` statement (a jump to the handler, no branch: test
47's `raise_in_try`, whose `if` is the decision); a call outside a `try:`
body, whose error goes to the caller (`outside`: Mojo returns the callee's
`{ i1, ... }` as its own, no branch at all; `with_else`'s `else` body: a
br the classifier drops); a `for` loop's end (`__next__`'s StopIteration
flag at the head is the loop's decision, `for-in`, in a `try:` body or
not). A `with` block keeps its own branches at the `with` keyword (the
`__exit__(err)` result that suppresses the error, and the context
manager's state), which no rule reads: a library with a `with` in
measured code is refused there, so no `with` body has been classified
(a call in one inside a `try:` body is a `try` decision as any other).
A branch at the `try`, `except`, `else` or `finally` keyword is refused
(none has been seen: a `finally` body's code carries the standard
library's locations, inlined at the `try`).

Refused in a `try:` body, by the shape rule: the destructor of an inlined
callee's error String whose flags word reaches the call through a `select`
(not a phi web the String rule reads): `komira_parquet`'s
`def_level_bitmap.mojo` 99:40 (`read_byte(`) and `footer_header.mojo`
325:31 (`byte_at(`), two branches per call beside the accepted error
check; outside a `try:` body they were dropped as the call's, and the
select there was already refused. The census of `COVERAGE_BRANCH_GATE`
with the rule: 11 of its libraries hold `try` arms (`policy.bzl`).

Evidence: test 47's `branchlib/trial.mojo`, every shape above, read from
its IR (`both`, `normal_only`, `nested`, `with_finally`, `with_else`,
`keyed`, `calls`, `looped`), and the classifier's cases (12, 12a:
`fixtures/try.ll`). A `with` was read once in a scratch copy of
`trial.mojo`: at the `with`, a `br i1` on `__exit__(err)`'s `i1` and two
on phis of the context manager's state (beside four of a String's
destructor), three refusals.

## Cost

Remote worker time (`buck2 log show`,
`execution_time_us`) for the six tests of `komira//src/komira_retry`:
`mojo_emit_cov_bc` 6.2 to 11.3 s, `mojo_cov_pgo_link` 6.9 to 8.4 s,
`mojo_cov_branch_run` 0.1 to 0.3 s per test; `mojo_cov_branch_annotate` 13
to 19 s (`buck2 log what-ran` durations, its IR text 9.8 to 12.4 MB). The
LLVM pieces are unpacked and checked once, by `toolchains/llvm_branch`.

## Tests

[Test 47](../../tests/coverage_runs.md#test-47-branch-coverage-runs) of
the tests cell: a fixture library whose test takes some arms of an
`if`/`elif`/`or`/`and` function and of a `while`, a `range(` loop, a
ternary, an `or` chain, a plain `@always_inline` helper, raising calls
in `try:` bodies (some never raising) and `and`/`or`s whose result is
returned, stored or passed on, whose profile must hold that
function's counters, and whose branch records must be their golden file;
test 46's `covtry`, whose gate is red on a `try` decision's raise arm alone
(and `covtry_both`, green), and `covandor`, red on the arm of `return a or
b` that skips its right operand (and `covandor_both`, green); the link line check; a test that the run gives no `LC_ALL`; a
library with a C library in its closure; one whose test needs a `test_deps`
package with a C library; and the planted defects that must go red, among
them an annotation whose profile does not fit the bitcode or lacks a
function, a bitcode holding branch weights before the profile, and a
`nodebug` helper's decision at its call. The
classifier's cases ([`cov_branch_classify_cases.sh`](cov_branch_classify_cases.sh))
gate every build that uses it; each names the mutant it kills.
