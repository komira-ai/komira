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

Nothing reads the records yet: no gate reads them, and the library's
package does not wait for them. They are built when asked for:

```sh
./buck2 build 'komira//src/komira_retry:komira_retry[coverage][branch_info]' -c komira.coverage=true
./buck2 build 'komira//src/komira_retry:komira_retry[coverage][branch_info][test_decide]' -c komira.coverage=true --show-output
```

| target | what |
|---|---|
| `:cov_branch` | the directories every library's branch coverage links, runs and annotates from, and the classifier (`cov_branch_dir`, [`defs.bzl`](defs.bzl)), from `komira//tools/build/toolchains/llvm_branch:llvm_branch` (so its checks gate every use): `[link]`, [`cov_branch_link.sh`](cov_branch_link.sh) with `lld/` and `llvm/runtime/` (the profile runtime); `[run]`, [`cov_branch_run.sh`](cov_branch_run.sh) with `llvm/` (`llvm-profdata`) and `raw_version`, the raw profile version every run requires (`RAW_PROFILE_VERSION` of [`llvm_branch/defs.bzl`](../../toolchains/llvm_branch/defs.bzl)); `[annotate]`, [`cov_branch_annotate.sh`](cov_branch_annotate.sh) with `lld/`; `[classify]`, the `:cov_branch_classify` executable. One directory per action, as `cov_link` and `cov_run` are two: an edit of one script re-keys no other action. (Projections of one directory would not do it: an action given `dir.project(path)` is keyed on the whole directory, as measured remotely.) |
| `:cov_branch_classify` | [`cov_branch_classify.zig`](cov_branch_classify.zig) (importing [`cov_branch_source.zig`](cov_branch_source.zig): `zig_exe`'s `imports`), a static executable built with the pinned zig, gated by `:cov_branch_classify_cases` ([`cov_branch_classify_cases.sh`](cov_branch_classify_cases.sh) over [`fixtures/`](fixtures)), which run as a build action: no build hands out the classifier unless they pass. Zig, not Mojo: a Mojo tool would be in the closure of the libraries it measures, the cycle covcheck has (`COVERAGE_NO_GATE`) |
| `:cov_branch_link.sh`, `:cov_branch_run.sh`, `:cov_branch_annotate.sh` | the scripts, exported so a fixture of the tests cell can plant a defect in a copy (test 46) |

Per `test_srcs` entry that is a source file, five actions, each a
sub-target of the library's `[coverage]` (and each `[bc]`, `[pgo_bin]`,
`[branch]`, `[branch_ir]`, `[branch_info]` alone is every test's file):

| sub-target | action category | output | what it does |
|---|---|---|---|
| `[coverage][bc][<test>]` | `mojo_emit_cov_bc` | `cov/branch/<test>.bc` | `mojo_wrapper.sh` (unchanged) runs `mojo build --emit llvm-bitcode --optimization-level 0 --debug-level line-tables` against the same ungated closure, with the same source root, as the test's `[coverage][bin]` |
| `[coverage][pgo_bin][<test>]` | `mojo_cov_pgo_link` | `cov/branch/<test>` | [cov_branch_link](#cov_branch_link) |
| `[coverage][branch][<test>]` | `mojo_cov_branch_run` | `cov/branch/<test>.profdata` | [cov_branch_run](#cov_branch_run) |
| `[coverage][branch_ir][<test>]` | `mojo_cov_branch_annotate` | `cov/branch/<test>.ll` | [cov_branch_annotate](#cov_branch_annotate) |
| `[coverage][branch_info][<test>]` | `mojo_cov_branch_classify` | `cov/branch/<test>.info` | [cov_branch_classify](#cov_branch_classify) |

`[coverage]` itself (the kcov binaries, reports and gate) does not include
them, and a library whose `test_env` sets `LLVM_PROFILE_FILE` is refused at
analysis, since the run sets it. With the switch off the actions do not
exist, and with it on no release action changes
([test 41](../../tests/coverage_runs.md#test-41-coverage-builds)'s
`coverage_keys.sh` counts one of each per test and requires that no join
waits for them).

## cov_branch_link

1. `lld/bin/lld` reads the bitcode as an LTO link with `-r`, `--lto-O0` and
   the pass pipeline `pgo-instr-gen,instrprof,default<O0>`: a relocatable
   object whose code counts its edges. Only this LLVM 24 reads the bitcode
   ([toolchains/llvm_branch](../../toolchains/llvm_branch/README.md#why-llvm-23-tools-are-safe-next-to-llvm-24)).
2. The Mojo toolchain's zig links it as `mojo_wrapper.sh`'s `cc` shim links
   a release test (the line `mojo build` gives it: the compiler's
   `libKGENCompilerRTShared.so`, `--gc-sections`, `-lm`; the shim's
   `--strip-debug` and the one run path `$ORIGIN/lib`; then the C libraries
   of the closure), with `llvm/runtime/libclang_rt.profile-x86_64.a` as a
   whole archive. Test 46's `link_line` records the line zig is given by
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

0. The bitcode must hold no branch weights of its own (the bytes of a
   `branch_weights` metadata string): `pgo-instr-use` keeps a `!prof` it
   finds on a branch whose block never ran, which would then read as counts.
   Mojo's bitcode at -O0 holds none (`llvm.expect` is not lowered there).
1. `lld/bin/lld` reads the test's bitcode as `cov_branch_link.sh` does (`-r`,
   `--lto-O0`) with the one pass `pgo-instr-use`, given the merged profile
   (`-pgo-test-profile-file`), and prints the module after it
   (`-print-after=pgo-instr-use -print-module-scope`, on stderr): every
   `br i1`, `select i1` and `switch` of a function that ran carries `!prof
   !{!"branch_weights", ...}`, the counts of its arms; one that never ran
   carries none.
2. Any line of lld's own (`lld: `, `warning: `, `error: `) fails the
   action. The one LLVM prints when the profile does not fit the control
   flow, `function control flow change detected (hash mismatch)`, means that
   function's counts were dropped, and passing it on would read as branches
   that never ran (tests//negative/coverage:branchannotate plants it). So
   does `no profile data available for function` (`-pgo-warn-missing-function`):
   a run writes the counters of every instrumented function it links, zeros
   included, so a function of the bitcode the profile does not hold is a
   profile of other bitcode, not a function that never ran (branchmissing).
   The six tests of `komira_retry` and the two of test 46's `branchlib` give
   neither.
3. What lld printed is exactly one dump, starting with `; *** IR Dump After
   PGOInstrumentationUse on [module] ***`; it is `cov/branch/<test>.ll`,
   unchanged. `-print-after` output is LLVM's debug text, not an interface:
   the classifier parses it strictly and fails on what it does not expect.

## cov_branch_classify

Reads `cov/branch/<test>.ll` and writes `cov/branch/<test>.info`
([`cov_branch_classify.zig`](cov_branch_classify.zig), the IR side, and
[`cov_branch_source.zig`](cov_branch_source.zig), the source side).

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
buck-out/` would otherwise drop. Every `.mojo` file of `[src]` is read for
the functions it declares `@always_inline("nodebug")` (below).

**Classes.** The source token at the branch's line and column decides the
class, and each class takes only the instruction kinds in its row; any other
kind at its token fails the action. A compiler-made class takes only the
kinds it has shown, as it drops what it takes. A source decision also takes
kinds it has not shown where its meaning allows them (an `if` or `elif` as
a `switch`, an `elif` as anything an `if` is): that is safe because a
decision is recorded, never dropped, so a wrong guess shows as a record, not
as a branch missing from the count:

| class | tokens | kinds | evidence (`komira_retry`'s six tests and test 46's `branchlib`) |
|---|---|---|---|
| source decision | `if` (statement or ternary) | br, select, switch | `policy.mojo` 117:9 and every `if` statement; the ternaries 291:40 (`String("throttled") if verdict.throttled else ...`, a br) and `branchlib/shapes.mojo`'s `1 if flag else 2` (a select); the `if` of a plain `@always_inline` helper, a select at its own line with `inlinedAt` (`shapes.mojo`'s `pick`); `budget.mojo` 63:9 is both branched on and selected on (one decision, below). No switch has been seen; it is a decision by its meaning |
| source decision | `elif` | br, select, switch | Mojo gives an `elif`'s branch its `if`'s location (`branchlib/score.mojo`: three branches at 4:5), so none has shown at an `elif` column yet; allowed as a decision by its meaning |
| source decision | `while` | br | `branchlib/shapes.mojo`'s `while i < n` |
| source decision | `or`, `and` | br, select | `select` at `or` (`policy.mojo` 65:20, 94:27; `score.mojo` 4:18), a chain `a or b or c` (`shapes.mojo`: the first select's result is the second's condition), `br` at `or` (short-circuit, `budget.mojo` 63:21, whose result is a phi at the token), `select` at `and` (`score.mojo` 6:22) |
| source decision | the `(` of `range(` on a `for ... in range(` line | br | `policy.mojo` 121:23, `shapes.mojo`'s `for _ in range(n)`: two branches on one value per loop (one decision, below); arm 0 is the iterator's end (the loop exits), arm 1 an iteration |
| compiler-made | `+` | br | String concatenation: every `+` row of `policy.mojo` (216 in `test_decide` alone), `loop.mojo` 96:66, 96:83 |
| compiler-made | `//`, `%` | select | the selects of floor division and modulo: `policy.mojo` 137:56 (`// 100`), 140:35 (`% UInt64(...)`), `seams.mojo` 51:44 |
| compiler-made | the `(` of any other call, off a `for` line | br | code that carries the call's location: a raising call's error check (`loop.mojo` 100:31, `sleep_ms(`: `br i1` on the call's own `i1` result) and the code of standard-library functions declared `@always_inline("nodebug")` (no location of their own), e.g. the destructor of a temporary `String` (refcount tests at `loop.mojo` 96:74 `String(d.cost)`, 113:34 `after_failure(`, 100:31). This is broader than the design's "`String(` and error propagation at a call": it is any callee's code given the call's location. A `try`'s error check is one (the design's open question 1: the `except` body is held by line coverage) |

A branch at the `(` of a call to a function the library's own sources
declare `@always_inline("nodebug")` is refused: that function's code has no
location of its own, so its decisions land on the call (test 46's
`branchnodebug`: its `while` is a br at `count_down(`), where they cannot be
told from the compiler's. A plain `@always_inline` keeps its locations (with
`inlinedAt`), and its decisions are recorded where they are written. A
library source declaring an operator, constructor or destructor (`__<name>__`)
`@always_inline("nodebug")` refuses the run: its code lands on any token.

Anything else fails the action naming `file:line:col`, the instruction and
the token: another word or operator, `+=`, a `(` after `]` or on a `for`
line other than `range(` (another iteration), a column outside the line, a
class with a kind it has not shown (a select at `+`). The list grows only
with evidence. A branch with no `!dbg` fails too, and so does an
`indirectbr`, `callbr` or `invoke` in a measured file (Mojo emits none).

**Records.** Compiler-made branches are counted on stderr, not written. Each
source decision gives one `BRDA:<line>,<col>:<kind>:<n>/<N>,<arm>,<count>`
per arm: `<kind>` is `br`, `select`, `switch` or `rhs`; `<N>` is how many
decisions of that kind one copy of a function (one LLVM function, or one
inlined copy of it) holds at that location, and `<n>` which one, in IR
order: Mojo puts `if` and `elif` on one location (`branchlib`'s
`4,5:br:0/3`, `1/3`, `2/3`). Arms are numbered 0, 1, ... in the order of
LLVM's weights (true first for `br` and `select`, the default first for a
`switch`), not named true and false. The `<n>`-th of every copy (generic
instances, inlined copies) is summed arm by arm; every copy must hold as
many, and where both are known, compute the condition of its `<n>`-th at
the same line and column (an instance that folded away one `elif` and
another that folded away another would otherwise be summed crosswise). A
count of a branch that never ran is `-`, counted and not taken (lcov's
"never reached"), never 0.

One decision tested twice, two branches or selects on the same condition
value with the same weights node at the same location (a `range(` loop's
two; `budget.mojo` 63:9's br and the select of its return value), is one
record: the br is kept.

Every bool `and`/`or` must have its right operand counted, or the action
fails naming it: `rhs` is the right operand's outcomes when it decides,
derived from the left operand's counts (the and/or's own select or br) and
the whole condition's (the first branch or select that tests the result: the
select's result directly, the short-circuit form's phi at the token, either
through `xor ..., true`, its arms swapped, or as the condition of the next
select of a chain). For `or`, the whole's true count less the left's, and
the whole's false count; for `and`, the whole's true count, and the left's
true count less it. A short-circuit form's deciding constant (`true` for
`or`, `false` for `and`) must arrive at the phi from the block the and/or's
`br` jumps to for that value of the left operand (its true target for `or`,
its false target for `and`), as at `budget.mojo` 63:21 (`br i1 %3, label %4,
label %5` then `phi i1 [ %8, %5 ], [ true, %4 ]`, `%4` an empty block); a
constant from the other target is the phi of another expression (`not a or
b`) and is refused, as is one arriving straight from the `br`'s own block or
through a chain of forwarding blocks (a correct shape no IR has shown yet:
refused rather than read without evidence). A result that is returned, stored or passed on (`return
a or b`, test 46's `branchretor`) is never tested, so when the right operand
decides cannot be counted. A value `and`/`or` (not `i1`) has no right
operand that decides. Since an `elif` carries its `if`'s location, its
records name the `if`'s line.

Known shapes, with what each gives:

- `if c: return True` then `return False`: Mojo folds it into `return c`
  (`ret i1`, seen in a draft of `shapes.mojo`), so the `if` has no branch
  and no record, as the same function written `return c` would have none.
  Accepted. An `and`/`or` in such a condition is then never tested, and is
  refused as above.
- `<n>/<N>` numbers the decisions of one kind at one location in IR order.
  It cannot tell an `elif` (Mojo gives it the `if`'s location) from a second
  copy of one decision the optimizer made inside one function (loop
  unrolling, jump threading). Such a copy gets its own `<n>` and its own
  counts, so the original's arms look less taken than they are: the error is
  a false "arm not covered", never a silent pass. If two copies of a
  function disagree on `<N>` the action fails (above).

Every measured file with code on a line holding a decision word (`if`,
`elif`, `while`, `for`, `and`, `or`, outside strings and comments) must
have a branch parsed, or the action fails (the branches were not read).

Output: per measured file with a source decision, `SF:<repository path>`,
its records sorted by line, column, kind, `<n>` and arm, `end_of_record`;
files sorted bytewise. A test that runs none of the library's code writes an
empty file. The block field `<col>:<kind>:<n>/<N>` of these `BRDA` lines is
read by covcheck only: upstream lcov and genhtml take a block number there,
and these files are not for them. `<line>,<col>:<kind>:<n>/<N>,<arm>` is what covcheck will sum by
across tests; one test's action cannot see another's, so two tests whose
copies of a function hold as many decisions at a location but different
ones (each folded away another) are for covcheck to refuse (slice 4).

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
SF:src/komira_retry/budget.mojo
BRDA:63,9:br:0/1,0,8
BRDA:63,9:br:0/1,1,26
BRDA:63,21:br:0/1,0,1
BRDA:63,21:br:0/1,1,33
BRDA:63,21:rhs:0/1,0,7
BRDA:63,21:rhs:0/1,1,26
```

## Cost

Remote worker time (`buck2 log show`,
`execution_time_us`) for the six tests of `komira//src/komira_retry`:
`mojo_emit_cov_bc` 6.2 to 11.3 s, `mojo_cov_pgo_link` 6.9 to 8.4 s,
`mojo_cov_branch_run` 0.1 to 0.3 s per test; `mojo_cov_branch_annotate` 13
to 19 s (`buck2 log what-ran` durations, its IR text 9.8 to 12.4 MB). The
LLVM pieces are unpacked and checked once, by `toolchains/llvm_branch`.

## Tests

[Test 46](../../tests/coverage_runs.md#test-46-branch-coverage-runs) of
the tests cell: a fixture library whose test takes some arms of an
`if`/`elif`/`or`/`and` function and of a `while`, a `range(` loop, a
ternary, an `or` chain and a plain `@always_inline` helper, whose profile
must hold that function's counters, and whose branch records must be their
golden file; the link line check; a test that the run gives no `LC_ALL`; a
library with a C library in its closure; and the planted defects that must
go red, among them an annotation whose profile does not fit the bitcode or
lacks a function, a bitcode holding branch weights before the profile, a
`nodebug` helper's decision at its call, and an `or` whose result is
returned. The classifier's cases ([`cov_branch_classify_cases.sh`](cov_branch_classify_cases.sh))
gate every build that uses it; each names the mutant it kills.
