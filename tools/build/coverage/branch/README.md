# Branch coverage runs

With coverage on (`-c komira.coverage=true`, linux-x86_64;
[Coverage builds](../../mojo/README.md#coverage-builds)), each welded test
of a `mojo_library` is also built for branch coverage: compiled to LLVM
bitcode, instrumented with IR profile counters by the LLVM the Mojo compiler
is built on, linked with the LLVM profile runtime, and run through the
release gate's runner. What each run writes is the counts of every branch
the test's code took, as an indexed profile. The rules are
[`coverage_branch.bzl`](../../mojo/coverage_branch.bzl); the LLVM pieces are
[`toolchains/llvm_branch`](../../toolchains/llvm_branch/README.md).

Nothing reads the profiles yet: no branch is classified, no gate reads
them, and the library's package does not wait for them. They are built when
asked for:

```sh
./buck2 build 'komira//src/komira_retry:komira_retry[coverage][branch]' -c komira.coverage=true
./buck2 build 'komira//src/komira_retry:komira_retry[coverage][branch][test_decide]' -c komira.coverage=true --show-output
```

| target | what |
|---|---|
| `:cov_branch` | the two directories every library's branch coverage links and runs from (`cov_branch_dir`, [`defs.bzl`](defs.bzl)), from `komira//tools/build/toolchains/llvm_branch:llvm_branch` (so its checks gate every use): `[link]`, [`cov_branch_link.sh`](cov_branch_link.sh) with `lld/` and `llvm/runtime/` (the profile runtime); `[run]`, [`cov_branch_run.sh`](cov_branch_run.sh) with `llvm/` (`llvm-profdata`) and `raw_version`, the raw profile version every run requires (`RAW_PROFILE_VERSION` of [`llvm_branch/defs.bzl`](../../toolchains/llvm_branch/defs.bzl)). Two, as `cov_link` and `cov_run` are two: an edit of the run script re-keys no link. (Projections of one directory would not do it: an action given `dir.project(path)` is keyed on the whole directory, as measured remotely.) |
| `:cov_branch_link.sh`, `:cov_branch_run.sh` | the scripts, exported so a fixture of the tests cell can plant a defect in a copy (test 45) |

Per `test_srcs` entry that is a source file, three actions, each a
sub-target of the library's `[coverage]` (and each `[bc]`, `[pgo_bin]`,
`[branch]` alone is every test's file):

| sub-target | action category | output | what it does |
|---|---|---|---|
| `[coverage][bc][<test>]` | `mojo_emit_cov_bc` | `cov/branch/<test>.bc` | `mojo_wrapper.sh` (unchanged) runs `mojo build --emit llvm-bitcode --optimization-level 0 --debug-level line-tables` against the same ungated closure, with the same source root, as the test's `[coverage][bin]` |
| `[coverage][pgo_bin][<test>]` | `mojo_cov_pgo_link` | `cov/branch/<test>` | [cov_branch_link](#cov_branch_link) |
| `[coverage][branch][<test>]` | `mojo_cov_branch_run` | `cov/branch/<test>.profdata` | [cov_branch_run](#cov_branch_run) |

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
   whole archive. Test 45's `link_line` records the line zig is given by
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

## Cost

Remote worker time (`buck2 log show`,
`execution_time_us`) for the six tests of `komira//src/komira_retry`:
`mojo_emit_cov_bc` 6.2 to 11.3 s, `mojo_cov_pgo_link` 6.9 to 8.4 s,
`mojo_cov_branch_run` 0.1 to 0.3 s per test. The LLVM pieces are unpacked
and checked once, by `toolchains/llvm_branch`.

## Tests

[Test 45](../../tests/coverage_runs.md#test-45-branch-coverage-runs) of
the tests cell: a fixture library whose test takes some arms of an
`if`/`elif`/`or`/`and` function, whose profile must hold that function's
counters; the link line check; a test that the run gives no `LC_ALL`; a
library with a C library in its closure; and the planted defects that must
go red.
