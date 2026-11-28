# Adding a plan vocabulary member without conflicts

Status: design, not built. Counts about the tree were measured at main `437184291`. Counts about
open pull requests are a snapshot taken while main was at that commit. Anything else is marked
"inferred".

A pull request that adds one member to an enum of
[plan_vocabulary.proto](../../src/plan_proto/plan_vocabulary.proto) conflicts with every other
pull request that does the same, even when the two touch different enums. This document decides
how a contributor gets a wire number without asking anyone, and how the committed generated code
changes so that such pull requests merge with no conflict. The hand-written total
`PLAN_WIRE_VOCABULARY_MEMBERS` in `src/plan_wire` is a separate change and is not covered here.
Until that change lands, every member pull request also edits that one line.

## What happens today

The measurement:

- The open pull requests whose diff adds a member to `plan_vocabulary.proto` were fetched into a
  clone: six of them, adding twelve members across four enums.
- Each of the 15 pairs was merged with `git merge-tree --write-tree --name-only`. All 15 fail.

The conflicts come from three places:

- **The input digest.** The generator writes `# input komira/plan/v1/plan_vocabulary.proto
  sha256:<digest>` on line 2 of every file it makes from the `.proto`
  ([header.rs](../../tools/build/proto-codegen/src/header.rs)). The digest is taken over protoc's
  description of the file, without comments, so any added member changes it.
  - Seven committed files carry it: `plan_vocabulary.mojo` and its six
    `_parts/plan_vocabulary_pNN.mojo`.
  - All seven conflicted in all 15 pairs: 105 files, which is 15 times 7.
  - In 99 of those 105 files, the digest line was the only conflict.
  - Nothing reads that line back. The freshness check compares whole files
    ([fresh.zig](../../tools/build/gen/fresh.zig)), and the coverage gate reads only line 1.
- **The part split.** The generator splits a module over 1000 lines into parts
  ([split.rs](../../tools/build/proto-codegen/src/split.rs)).
  - It fills each part with declarations, in declaration order, up to 880 lines. It then halves
    any part that still does not fit.
  - One enum member costs 7 generated lines. Parts 4 and 5 have 4 free lines each.
  - So one new member in an enum of part 4 moves `RegexpOp` to part 5, and the tail of part 5 moves
    to part 6.
  - That accounts for the other 6 of the 105 conflicted files: part 4, in each pair where both pull
    requests added to part 4.
- **The lock.** [buildrules.mojo.lock.bzl](../../src/plan_proto/buildrules.mojo.lock.bzl) lists
  every source of the library with its sha256, sorted by path, one line per file.
  - It does so once for each of three platforms: 57 lines for the 19 generated files.
  - It is written by `buildrules mojo sync`, which `regen` does not run.
  - The lock conflicted in all 15 pairs on the generated-file lines. In 6 of the pairs it also
    conflicted on the line of a ledger test that both pull requests edited.

The `.proto` text itself conflicted in 2 of the 15 pairs. In both, the two pull requests added to
the same enum and had taken the same numbers: 27 and 28 in `ExtractField`, and 15 and 16 in
`StringFnN`. Each had taken "the next free number" on its own base.

So these pull requests land one at a time. After each one lands, every other one must merge main,
run `regen` and the lock sync, push, and wait for a whole new check.

## The decision

1. **Numbers.** Each wire number is a file, `src/plan_proto/numbers/<Enum>/<number>`, that holds
   the member's name.
   - A contributor takes a number by adding its file, ideally in a small pull request that lands
     first.
   - Two people who take the same number add the same path, and git refuses that merge.
2. **Generated files stay committed.**
   - The generator stops writing the input digest for inputs that are files of this repository.
   - A module over the line limit is split into one directory per declaration, instead of being
     packed by size.
3. **Result.** A pull request that adds a member to one enum touches four files.
   - Two such pull requests on different enums merge with no conflict in them.
   - Two on the same enum still conflict in that enum's lines. They can no longer hold the same
     number, though, so the fix is to keep both sides' lines and regenerate, never to renumber.

## Numbers

### How a number is chosen today, and what guards it

A wire number is the engine tag plus one, as the header of `plan_vocabulary.proto` says.
`DTypeCode` is the exception: its codes are published as they are. The engine tag is a `comptime`
constant in engine code, such as `src/plan_expr/expr.mojo` for the expression enums and
`src/plan_ir/logical_plan.mojo` for `PlanTag`.

A contributor takes the highest number plus one. Design documents sometimes hand numbers out in
advance. [plan_models.md](plan_models.md) section 2.2.3 gives the window-assign node `PlanTag` 24,
and adds "if the specs before it change their numbers, these move with them".

The rules are in [optimized_plan.md](optimized_plan.md) section 9.2:

- never renumber;
- never reuse a number or a name;
- a value removed before any release could carry it is `reserved`, number and name.

Nothing compares a pull request with main or with a release. The guards all work inside one tree:

- The ledgers in `tests/test_plan_enum_numbers_nodes.mojo` and
  `tests/test_plan_enum_numbers_functions.mojo` hold each name to its number in the generated codec.
  They are written by hand in the same pull request as the `.proto`. So they catch a number the
  generator gets wrong, not a deliberate edit.
- `tests/test_plan_census_complete.mojo` requires a ledger row for every declared value. It
  compares names only.
- `tests/test_plan_reservations.mojo` holds every `reserved` line.
- protoc refuses two values with one number in one enum, because no enum sets `allow_alias`.

The repository has no release tags and no record of shipped numbers. Suppose one member has
already landed on main, and a conflict with it is resolved by moving it to another number. Every
test still passes.

### The ways weighed

| | A file per number | A reserved range per enum, one line per range in a shared file | A number derived from the name | A gate check that refuses a number another open pull request takes |
|---|---|---|---|---|
| Who hands the number out | the first pull request to add the file; git refuses a second file at the same path | a person, whenever a range fills up and must be widened | nobody | the gate |
| Two different claims | separate files, no conflict | two ranges that sort next to each other are adjacent lines, which git treats as a conflict | — | — |
| Stable and readable | yes | yes | no: a hash of the name can collide, and the number moves if the name or the formula changes | yes |
| Fits the engine | yes | no: `PlanTag` and `ExprTag` must stay dense (below), so a range leaves holes they cannot have | no: wire numbers must be permanent and small (the engine tag is a `UInt8`) | — |
| Can it work | yes | yes, with a person widening ranges | no | no: a build sees one tree; listing other open pull requests needs the network, which a hermetic check may not use |

**Choice: a file per number.** It conflicts exactly when two people take the same number, and at
no other time. What a check can see is the tree the merge queue builds: main plus the pull request
([ci.md](../ci.md#the-merge-queue)). The check below runs there.

### The files and their check

- `src/plan_proto/numbers/<Enum>/<number>` holds one line: the member's name. `<Enum>` is the
  enum's name in the `.proto`, and `<number>` is the wire number in decimal.
- The 33 `*_WIRE_UNSPECIFIED = 0` values have no file. Every other declared value has one,
  including `DTypeCode`'s real code 0. Seeding from main makes 367 files across the 34 enums.
- These files replace the ledger rows of the 34 vocabulary enums, other than their
  `*_WIRE_UNSPECIFIED` rows. So each number is written by hand in one place, not two.
- The ledger tests read the files as test data. Their byte checks against the generated codec
  stay; only where the rows come from changes.
- These rows stay in the ledgers: the `*_WIRE_UNSPECIFIED` rows, which never change; and the rows
  of enums outside the vocabulary, such as `AddressingStyleWire` of `bound_source.proto` and the
  enums of `plan.proto`.
- The files are staged by a glob in `src/plan_proto/BUCK`, so adding one changes no BUCK line. They
  are not `.mojo`, so the lock does not list them. With no ledger edit, the ledger tests' lines in
  the lock stop changing as well.
- A welded test of `plan_proto` holds the files and the `.proto` to each other:
  - every declared value other than the 33 `*_WIRE_UNSPECIFIED` has its file, and the file holds
    its name;
  - a file whose number is declared names that value;
  - a file whose number is not declared is an open claim: it may name no value declared under
    another number, and it may sit on no `reserved` number.
- **`PlanTag` and `ExprTag` stay dense.**
  - Engine code walks every tag in `[0, PLAN_TAG_COUNT)`, skipping only the two retired ids
    (`plan_tag_is_retired`).
  - It walks every tag in `[0, EXPR_TAG_COUNT)` with no holes at all.
  - So in these two enums, a value may be declared only when no lower open claim remains, and the
    test refuses a declared value above an open claim.
  - The author of the higher number lands after the lower one. The files on main show which claim
    that pull request waits for, so nobody needs to be asked.
  - The other enums already have holes. The membership check of `plan_wire_vocabulary.mojo` lists
    runs, such as `[(0, 14), (16, 25)]` for `ExtractField`.

### Taking a number

1. Find the highest number in `numbers/<Enum>/` on main, and add the next one as a file.
2. When other pull requests in the same enum may be in flight, open that file as a pull request of
   its own. It touches no generated file, so it lands in one check.
3. If git reports an add/add conflict on that path, someone else holds the number. Take the next
   one.
4. To give up a claim, delete its file. The test refuses deleting the file of a declared value.

### What guards a released number after the change

The same in-tree tests still run. Three things are added:

- The number files on main are the record of every number in use.
- Two open pull requests that take the same number cannot both land.
- A member can move to a number held by another name only by editing an existing file.

Every legitimate change to `numbers/` adds or deletes a file, so a modified file stands out in
review. A check cannot refuse that edit, because a build cannot read main's history. A test
against the previous release's vocabulary would need a published copy pinned by sha256, and these
slices do not build one.

## Generated files

### Why they are committed

[generated_sources.md](generated_sources.md) (status: decided) commits them for three reasons:

- mopm's unit graph, which buildrules writes into the lock, hashes the `.mojo` files of a library
  directory offline, so the sources must be files in the tree;
- a change to a generator or to a pinned input should show up as reviewable code;
- the freshness check proves that the committed files are what the generator writes today.

No document gives bootstrap as a reason. The generator is Rust and needs nothing from
`plan_proto`. Users installing from a registry get a compiled `.mojoc`, never these sources. The
Python modules `plan_pb2` and `plan_vocabulary_pb2` are already generated at build time from the
`.proto` ([python/BUCK](../../python/BUCK)) and are not committed.

### Three ways weighed

| | Keep them committed; make a change local | Stop committing them | Keep everything; the gate names the command |
|---|---|---|---|
| What a member pull request conflicts on | that enum's lines, only when the other pull request touches the same enum | nothing generated | the 7 files and the lock, every time |
| Build | regeneration is already a cached check; `plan_proto` gains about 200 small files (inferred) | one cached generation action | unchanged |
| Package publication | unchanged | `mojo_package` takes its sources only from the lock and has no input for another target's output; a lock cannot hash a file that does not exist yet. This needs a new kind of source in mopm's unit graph, plus changes in buildrules, in the `plan_proto` adopted library (its `srcs` is a glob of the directory) and in the release packaging | unchanged |
| Review | generated changes stay in the diff, now limited to the declaration that changed | generated code is never seen | unchanged |
| Cost of each landing | none | none | every open pull request merges main, regenerates, syncs the lock and runs a new check |

**Choice: keep them committed and make a change local.**

- It needs no change to any format or to any other repository.
- Stopping the commits is the "generated-source input" option that generated_sources.md already
  describes, and it needs its own design in mopm first.
- Naming the command does not remove a single conflict, and the freshness check already names
  `regen`. Its cheap part is kept as the last slice below: `regen` also syncs the lock.

### The two generator changes

Both apply to `mojo_proto_library` and `mojo_db_proto_library`, whose inputs are `.proto` files
committed next to the output.

**No input digest.** The header says `# input <path>`, and its last line says the inputs are named
rather than pinned.

- The tree already ties output to input: the freshness check fails on any difference, and the lock
  pins the bytes of every output file.
- The AWS and Google Cloud clients keep the digest. Their inputs are archives fetched at build time,
  so the digest is the only place a reviewer sees which model the code came from. Those inputs also
  change all at once when a pin moves, never one member at a time.

**One directory per declaration.** A module over the line limit is written as:

```text
_parts/<module>/__init__.mojo
_parts/<module>/<declaration>/__init__.mojo
_parts/<module>/<declaration>/declaration.mojo
```

- `<declaration>` is the name in lower snake case, so `StringFnN` becomes `string_fn_n`.
- The facade re-exports each declaration on its own line.
- Adding a member rewrites only its own declaration's file. Adding an enum adds a directory and one
  facade line.
- The unchanging `__init__.mojo` of each declaration is there for the lock. The lock lists paths
  sorted, one file per line. So `string_fn_n/__init__.mojo` sits between the files of `string_fn/`
  and `string_fn_n/`. Without it, a change to each of those two enums would change two adjacent
  lock lines, and adjacent lines conflict.
- The largest declaration in a split module of this repository is `ArrowType`, at 405 lines, so
  every file stays under the limit. A single declaration that reached 1000 lines would be refused
  by name.

### Other generated trees of the same shape

| Tree | Same shape? | Covered? |
|---|---|---|
| The other trees of `mojo_proto_library` and `mojo_db_proto_library`: the chat, mail, contacts, CRM, calendar, job report, supervisor and broker packages, `db_sqlite`, and the test protos of `proto_codec` and `wkt` | yes: the digest in every file, packed parts where a module is over the limit, one lock line per file | yes, by the same two generator changes; each is regenerated once |
| The AWS and Google Cloud clients | same split and digest | no, on purpose: their inputs change in bulk |
| The check set under `ci/roots/` | was the same problem: shard files that every pull request edited | already one file per root ([ci.md](../ci.md), "Adding a target: one file per root") |
| Release lists (`release/darwin_libs.bzl`, `release/readme_e2e/packages.bzl`, `release/artifacts.textproto`) | no: hand-written lists with no digest and no generator | no; an entry goes on its own line in sorted position |

## What a pull request that adds one member looks like

In `src/plan_proto` it touches four files. The engine and `plan_wire` code it needs come on top:

```text
src/plan_proto/plan_vocabulary.proto                                                     one new line
src/plan_proto/numbers/StringFnN/15                                                      new file, one line
src/plan_proto/generated/plan_proto/_parts/plan_vocabulary/string_fn_n/declaration.mojo  7 new lines, 1 changed
src/plan_proto/buildrules.mojo.lock.bzl                                                  3 changed lines, one per platform
```

**The merge, shown with git.** A shallow clone of main got a base commit with this layout:

- the vocabulary's six parts rewritten into 34 declaration directories;
- no digest in any file;
- the 367 number files;
- the lock's rows rewritten from the files on disk.

Each branch was then made from that base and adds one member. A scratch script wrote each branch's
generated change by copying the lines of the enum's last member, which follows the 7-line pattern
of the committed code. This proves the text merge, not the generator.

| Branch | Adds |
|---|---|
| `string-fn-n-15` | `StringFnN` `STRFNN_EXAMPLE_A = 15` |
| `string-fn-20` | `StringFn` `STRFN_EXAMPLE_B = 20`: the neighbouring enum, with neighbouring lock lines |
| `agg-fn-39` | `AggFn` `AGG_EXAMPLE_E = 39` |
| `string-fn-n-16` | `StringFnN` `STRFNN_EXAMPLE_C = 16`: the same enum as `string-fn-n-15`, at another number |
| `string-fn-n-15-other-name` | only the file `numbers/StringFnN/15`, naming `STRFNN_EXAMPLE_D`: the same number as `string-fn-n-15` |

```text
$ git diff --stat base string-fn-n-15
 src/plan_proto/buildrules.mojo.lock.bzl                          | 6 +++---
 .../_parts/plan_vocabulary/string_fn_n/declaration.mojo          | 9 ++++++++-
 src/plan_proto/numbers/StringFnN/15                              | 1 +
 src/plan_proto/plan_vocabulary.proto                             | 1 +
 4 files changed, 13 insertions(+), 4 deletions(-)

$ git merge-tree --write-tree --name-only string-fn-n-15 string-fn-20    # exit 0
$ git merge-tree --write-tree --name-only string-fn-n-15 agg-fn-39       # exit 0
$ git merge-tree --write-tree --name-only string-fn-20 agg-fn-39         # exit 0

$ git merge-tree --write-tree --name-only string-fn-n-15 string-fn-n-16  # exit 1
src/plan_proto/buildrules.mojo.lock.bzl
src/plan_proto/generated/plan_proto/_parts/plan_vocabulary/string_fn_n/declaration.mojo
src/plan_proto/plan_vocabulary.proto

$ git merge-tree --write-tree --name-only string-fn-n-15 string-fn-n-15-other-name  # exit 1
src/plan_proto/numbers/StringFnN/15
CONFLICT (add/add): Merge conflict in src/plan_proto/numbers/StringFnN/15
```

Next, `string-fn-n-15`, `string-fn-20` and `agg-fn-39` were merged into one tree.

- Its lock equals, byte for byte, the lock rewritten from that tree's own files. So the merged lock
  is already what `buildrules mojo sync` would write.
- Every generated file in it is one side's file, unchanged.
- That the merged files also equal what the generator would write is inferred: each declaration's
  file depends only on its own declaration.

Two controls show what each piece does:

- Without the separator: the `__init__.mojo` lines were removed from the base lock and from the
  locks of `string-fn-n-15` and `string-fn-20`, leaving one flat file per declaration. `git
  merge-file` of those two locks then reports 3 conflicting hunks, one per platform.
- Today's layout: each of the six measured pull requests changes the digest line of all seven
  files, so every pair conflicts.

The same-enum pair (`string-fn-n-15` and `string-fn-n-16`) still conflicts. The second to land
takes both sides' lines in number order, then runs `regen` and the lock sync. Their numbers already
differ, so nothing in engine code, the ledgers or `plan_wire` needs renumbering.

## Order of work

Each slice lands on its own, and each one helps without the others. With all three of the first
slices, and with the `plan_wire` total no longer written by hand, two member pull requests on
different enums merge with no conflict.

1. **No input digest for the two proto rules.** This slice changes:
   - the header in `header.rs`: no digest, and "inputs named above" in its last line;
   - the `__init__.mojo` text of the Zig rule actions, together with the other spellings that
     `tools/build/gen:command_agreement` holds equal;
   - the Rust tests that assert the digest;
   - a one-time regeneration of every tree of the two rules, including the committed fixture trees
     under `tools/build/tests`;
   - the paragraph "What does a generated file look like?" of generated_sources.md.

   Alone, this removes the conflicts that were only the digest line: 99 of the 105 measured.
2. **One directory per declaration for the two proto rules.** This slice changes:
   - the generator's split;
   - the check of `_parts` in `tools/build/act_util` and `tools/build/mojo/tools/proto_gen.zig`,
     which refuses anything but a flat list of `.mojo` files today: nested directories become
     allowed for these two rules only, and the AWS and Google Cloud actions keep the flat check;
   - the layout that `tools/build/mojo/proto.bzl` and `tools/build/tests/proto_tests.sh` describe;
   - the generator's goldens;
   - the regeneration;
   - the paragraph "The line limit" of generated_sources.md.

   Alone, this ends parts shifting.
3. **Number files.** This slice changes:
   - the 367 seeded files and their glob in `src/plan_proto/BUCK`;
   - the welded test;
   - the ledger tests, which read the files;
   - `tests/test_plan_census_complete.mojo`, which takes the files as well as the remaining ledger
     rows;
   - the steps of "Taking a number", in `src/plan_proto/README.md`.

   It does not depend on slices 1 or 2.
4. **`regen` also syncs the lock** of the package it rewrote, so that after a same-enum merge one
   command does both. Small and optional.

**The owner's decision.** Slice 1 is the owner's decision, because it changes a decided rule of
generated_sources.md: that every generated file pins each input by name and sha256. No slice
changes the rule that generated code is committed. No slice changes a wire format or the rules of
section 9.2. The ordering check of slice 3 for `PlanTag` and `ExprTag` writes down what the engine
already requires.

The choice: keep generated code committed and drop the digest for inputs in this repository, which
removes 99 of the 105 measured conflicts and needs no change outside this repository; or stop
committing generated code, which removes it from pull requests entirely but first needs a new kind
of source in mopm and buildrules, and gives up reviewing generated code. **Recommended: the
first.**
