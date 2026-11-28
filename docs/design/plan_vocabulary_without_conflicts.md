# Adding a plan vocabulary member without conflicts

Status: design, not built. Counts about the tree were measured at main `437184291`. Counts about
open pull requests are a snapshot taken while main was at that commit. Anything else is marked
"inferred".

A pull request that adds one member to an enum of
[plan_vocabulary.proto](../../src/plan_proto/plan_vocabulary.proto) conflicts with every other
pull request that does the same, even when the two touch different enums. This document decides
how a contributor takes a wire number that no other pull request is working on, and how the
committed generated code changes so that such pull requests stop conflicting.

What it does not cover:

- **The hand-written total.** `PLAN_WIRE_VOCABULARY_MEMBERS` is two lines in two files:
  `src/plan_wire/plan_wire_vocabulary.mojo` line 61, and the assertion in
  `src/plan_wire/tests/test_plan_wire_vocabulary.mojo` line 179.
  - Every member pull request edits both lines.
  - Two pull requests that each add the same number of members merge cleanly, to a wrong total.
    Two measured pairs did this. Only the welded test catches it.
  - A separate change makes the total no longer hand-written. Until it lands, no pair of member
    pull requests merges cleanly.
- **Other numbers.** Field numbers and `oneof` arm numbers of `plan.proto` race the same way. One
  measured pull request adds a `WirePlan` field. The claims below cover the vocabulary enums only.
- **Hand-written code.** Engine code, `plan_wire` code and golden fixtures that a member needs
  conflict like any hand-written code.

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
  - One enum member costs 7 generated lines. Parts 4 and 5 have 4 free lines each. That figure is
    inferred by applying the packing rule to the committed parts.
  - So a new member in an enum of part 4 moves `RegexpOp` to part 5, and the tail of part 5 moves to
    part 6.
  - That accounts for the other 6 of the 105 conflicted files: part 4, in each pair where both pull
    requests added to part 4.
- **The lock.** [buildrules.mojo.lock.bzl](../../src/plan_proto/buildrules.mojo.lock.bzl) lists
  every source of the library with its sha256, sorted by path, one line per file.
  - It does so once for each of three platforms: 57 lines for the 19 generated files.
  - It is written by `buildrules mojo sync`, which `regen` does not run.
  - The lock conflicted in all 15 pairs on the generated-file lines. In 7 of the pairs it also
    conflicted on the line of a ledger test that both pull requests edited.

The `.proto` text itself conflicted in 2 of the 15 pairs. In both, the two pull requests added to
the same enum and had taken the same numbers: 27 and 28 in `ExtractField`, and 15 and 16 in
`StringFnN`. Each had taken "the next free number" on its own base.

So these pull requests land one at a time. After each one lands, every other one must merge main,
run `regen` and the lock sync, push, and wait for a whole new check.

## The decision

1. **Open claims.** A number that someone is working on, but that is not yet declared, is a file:
   `src/plan_proto/numbers/<Enum>/<number>`, holding the member's name.
   - The claim lands first, in a small pull request of its own.
   - The member's pull request declares the value and deletes the claim.
   - The first claim to land wins. The second one to land is refused at merge, as an add/add
     conflict on the same path, and its author takes another number.
   - That refusal comes no earlier than today's `.proto` conflict or protoc's refusal of a
     duplicate number. A claim does not stop two open pull requests from choosing the same number.
     What it adds is that a claim already on main is visible to everyone who starts work after it,
     so it helps exactly when the claim lands before the work starts.
2. **Generated files stay committed.** Two changes make each one local:
   - the generator stops writing the input digest for inputs that are files of this repository;
   - a module over the line limit is split into one directory per declaration, instead of being
     packed by size.
3. **The result.** With both changes, and with the total no longer hand-written:
   - 13 of the 15 measured pairs, the ones on different enums, merge with no conflict in the
     vocabulary's files. Hand-written code that two pull requests both change can still conflict
     there, as any hand-written code can;
   - the 2 same-enum pairs still conflict in that enum's lines. When their claims landed first,
     their numbers differ, and the fix is to keep both sides' lines and regenerate. Nothing has to
     be renumbered.

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

Section 9.2 also says each new value comes under a new `format_version`. In practice, members are
added without a version bump. `PLAN_WIRE_FORMAT_VERSION` is 4
(`src/plan_wire/plan_wire_codec.mojo:711`), and it last changed for a deleted field, not for any
vocabulary member. This design changes neither the rule nor the practice.

What holds a number today, all inside one tree:

| What | Held by |
|---|---|
| each name maps to its number in the generated codec | the ledgers `tests/test_plan_enum_numbers_nodes.mojo` and `tests/test_plan_enum_numbers_functions.mojo`, written by hand in the same pull request |
| each declared value has a ledger row (names only) | `tests/test_plan_census_complete.mojo` |
| every `reserved` number and name | `tests/test_plan_reservations.mojo` |
| the Mojo vocabulary of `plan_wire` equals protoc's, name by name and number by number | `src/plan_wire/tests/test_plan_wire_vocabulary_names.mojo` |
| encoded plans keep their bytes | the golden byte fixtures of `src/plan_wire/tests`; a moved number changes the bytes of every golden that uses that member |
| one number per value within an enum | protoc, because no enum sets `allow_alias` |

Nothing compares a pull request with main or with a release, and the repository has no release
tags. Moving a member that has already landed is caught only if a golden covers that member, and
only if the author does not also rewrite the golden in the same pull request.

### The ways weighed

| | An open claim file per number | A reserved range per enum, one line per range in a shared file | A number derived from the name | A gate check that refuses a number another open pull request takes |
|---|---|---|---|---|
| Who hands the number out | the first claim to land; git refuses a second claim at the same path | a person, whenever a range fills up and must be widened | nobody | the gate |
| Two different claims | separate files, no conflict | two ranges that sort next to each other are adjacent lines, which git treats as a conflict | — | — |
| Stable and readable | yes | yes | no: a hash of the name can collide, and the number moves if the name or the formula changes | yes |
| Fits the engine | yes | no: `PlanTag` and `ExprTag` must stay dense (below), so a range leaves holes they cannot have | no: wire numbers must be permanent and small (the engine tag is a `UInt8`) | — |
| Can it work | yes | yes, with a person widening ranges | no | no: a build sees one tree; listing other open pull requests needs the network, which a hermetic check may not use |

**Choice: an open claim file per number.** It conflicts exactly when two claims take the same
number. A check can only see the tree the merge queue builds, which is main plus the pull request
([ci.md](../ci.md#the-merge-queue)), so the check below runs there.

### The claims and their check

- `src/plan_proto/numbers/<Enum>/<number>` holds one line: the member's name. `<Enum>` is the
  enum's name in the `.proto`, and `<number>` is the wire number in decimal.
- The directory holds open claims only. A declared value has no file: its pull request deletes the
  claim.
- The files are staged by a glob in `src/plan_proto/BUCK`, so a claim changes no BUCK line. They
  are not `.mojo`, so the lock does not list them.
- A welded test of `plan_proto` reads the claims and the `.proto`. It refuses a claim:
  - whose number is declared in its enum;
  - whose name is declared under any number;
  - that sits on a `reserved` number.
- **`PlanTag` and `ExprTag` stay dense.**
  - Engine code walks every tag in `[0, PLAN_TAG_COUNT)`, skipping only the two retired ids
    (`plan_tag_is_retired`).
  - It walks every tag in `[0, EXPR_TAG_COUNT)` with no holes at all.
  - So in these two enums, the test also refuses a declared value above an open claim. The author
    of the higher number lands after the lower one, and the claims on main show which one that is.
  - The other enums already have holes. The membership check of `plan_wire_vocabulary.mojo` lists
    runs, such as `[(0, 14), (16, 25)]` for `ExtractField`.

### Taking a number

1. Take the highest number of the enum in the `.proto` or in `numbers/<Enum>/` on main, plus one.
   Add it as a claim file, in a pull request of its own. It touches no generated file, so it lands
   in one check.
2. Start the member's work once the claim has landed.
3. If git reports an add/add conflict on that path, the number is someone else's. Take the next
   one.

The claim step is advice, not enforced. A pull request that skips it can still declare a value
directly. If another pull request lands the same number first, the late one pays what it pays
today: it renumbers its engine tag, its ledger rows, its `plan_wire` entry and its goldens.

**Stale claims.** Anyone may delete a claim in their own pull request when no open pull request
declares it. The claim's commit names its author. This matters most in `PlanTag` and `ExprTag`, where
a stale claim blocks every later member of the enum. In the other enums, a stale claim only wastes
a number.

### What guards a number after the change

Every guard in the table above stays. Two things are added:

- A number someone is working on is on main before the work starts, so the next contributor sees
  it.
- The new test refuses a claim that collides with a declared or reserved value. In the two dense
  enums, it refuses a value declared above an open claim.

Moving a member that has already landed still passes, unless a golden covers it, because a build
cannot read main's history.

There is a later step, which may never be needed: keep a file for every declared value, not only
for open claims. Seeding from main would make 367 files: every value other than the 33
`*_WIRE_UNSPECIFIED`, `DTypeCode`'s real code 0 included. The ledger rows of the 34 enums would be
read from those files.

- What it buys: a record of every number on main, and one hand-written place for each number
  instead of two.
- What it costs: a moved number becomes an edit of a one-line file instead of a ledger row. It also
  needs a rewrite of the two ledger tests and of the census test.

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
| Build | the costs below | one cached generation action | unchanged |
| Package publication | unchanged: the package holds only the `.mojoc` (`:conda_holds` with `sole = True`) | `mojo_package` takes its sources only from the lock and has no input for another target's output; a lock cannot hash a file that does not exist yet. This needs a new kind of source in mopm's unit graph, plus changes in buildrules, in the `plan_proto` adopted library (its `srcs` is a glob of the directory) and in the release packaging | unchanged |
| Review | generated changes stay in the diff, now limited to the declaration that changed | generated code is never seen | unchanged |
| Cost of each landing | none | none | every open pull request merges main, regenerates, syncs the lock and runs a new check |

**Choice: keep them committed and make a change local.**

- It needs no change to any format or to any other repository.
- Stopping the commits is the "generated-source input" option that generated_sources.md already
  describes, and it needs its own design in mopm first.
- Naming the command does not remove a single conflict, and the freshness check already names
  `regen`.

### The two generator changes

Both apply to `mojo_proto_library` and `mojo_db_proto_library`, whose inputs are `.proto` files
committed next to the output.

**No input digest.** The header says `# input <path>`, and its last line says the inputs are named
rather than pinned.

- The text the generator writes changes, so `PLUGIN_GENERATOR_VERSION` in `header.rs` is bumped,
  as its comment requires.
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
- Adding a member rewrites only its own declaration's file.
- The layout is shaped by how git merges.
  - The lock lists paths sorted, one file per line, so the unchanging `__init__.mojo` of
    `string_fn_n/` sits between the files of `string_fn/` and `string_fn_n/`.
  - Without it, a change to each of those two enums would change two adjacent lock lines, and
    adjacent lines conflict.
  - A new enum still adds two lock lines next to its sorted neighbour, so a new-enum pull request
    and a member pull request on that neighbour can still conflict.
- The largest declaration in a split module of this repository is `ArrowType`, at 405 lines, so
  every file stays under the limit. A single declaration that reached 1000 lines would be refused
  by name.

**Costs.**

- The lock grows. Split modules of these rules today have this many declarations: `plan_proto` 107
  (`plan` 73, `plan_vocabulary` 34), chat 65, managed mail 43, CRM 24, contacts 18.
- For `plan_proto` the generated tree goes from 19 files to 222: two per declaration, two module
  `__init__.mojo`, and the six files that are not parts (five beside `_parts`, and `_parts/__init__.mojo`). Its lock goes from 19 lines to 222 per
  platform: about 600 more lines across the three platforms.
- Each regeneration lands once and rebuilds every library built from the regenerated trees once.
- Every open member pull request merges main once, into the new layout.
- **Unproven: nested packages that import each other.** The 73 messages of `plan` import one
  another, and the split today relies on Mojo allowing imports in a cycle between sibling modules.
  Whether it allows them between sibling packages is not yet shown.
  - So the first step of that slice is a build on the farm of `komira//src/plan_proto:lib` in the
    new layout, with its compile time before and after.
  - The fallback, if imports between packages are refused: one flat file per declaration, with the
    lock lines kept apart another way. One way is for the lock to write each file's path and hash
    on separate lines, which is a change in the package tool's repository.

### Other generated trees of the same shape

| Tree | Same shape? | Covered? |
|---|---|---|
| The other trees of `mojo_proto_library` and `mojo_db_proto_library`: the chat, mail, contacts, CRM, calendar, job report, supervisor and broker packages, `db_sqlite`, and the test protos of `proto_codec` and `wkt` | yes: the digest in every file, packed parts where a module is over the limit, one lock line per file | yes, by the same two generator changes; each is regenerated once |
| The AWS and Google Cloud clients | same split and digest | no, on purpose: their inputs change in bulk |
| The check set under `ci/roots/` | was the same problem: shard files that every pull request edited | already one file per root ([ci.md](../ci.md), "Adding a target: one file per root") |
| Release lists (`release/darwin_libs.bzl`, `release/readme_e2e/packages.bzl`, `release/artifacts.textproto`) | no: hand-written lists with no digest and no generator | no; an entry goes on its own line in sorted position |

## What a pull request that adds one member looks like

In `src/plan_proto` it touches four files. Engine code, `plan_wire` code, goldens and the total
come on top:

```text
src/plan_proto/plan_vocabulary.proto                                                     one new line
src/plan_proto/numbers/StringFnN/15                                                      the claim, deleted
src/plan_proto/generated/plan_proto/_parts/plan_vocabulary/string_fn_n/declaration.mojo  7 new lines, 1 changed
src/plan_proto/buildrules.mojo.lock.bzl                                                  3 changed lines, one per platform
```

**The merge, shown with git.** A shallow clone of main got two commits:

- the layout above: the vocabulary's six parts rewritten into 34 declaration directories, no digest
  in any file, and the lock's lines rewritten from the files on disk;
- four claims landed on top of it: `StringFnN` 15 and 16, `StringFn` 20 and `AggFn` 39.

Each branch was then made from those commits. A scratch script wrote each branch's generated change
by copying the lines of the enum's last member, which follows the 7-line pattern of the committed
code. This proves the text merge, not the generator.

| Branch | Does |
|---|---|
| `string-fn-n-15` | declares `StringFnN` `STRFNN_EXAMPLE_A = 15` and deletes its claim |
| `string-fn-20` | declares `StringFn` `STRFN_EXAMPLE_B = 20`: the neighbouring enum, with neighbouring lock lines |
| `agg-fn-39` | declares `AggFn` `AGG_EXAMPLE_E = 39` |
| `string-fn-n-16` | declares `StringFnN` `STRFNN_EXAMPLE_C = 16`: the same enum as `string-fn-n-15` |
| `claim-17-first`, `claim-17-second` | each claims `StringFnN` 17, with different names |
| `claim-17-same` | claims `StringFnN` 17 with the same name as `claim-17-first` |

```text
$ git diff --stat base string-fn-n-15
 src/plan_proto/buildrules.mojo.lock.bzl                          | 6 +++---
 .../_parts/plan_vocabulary/string_fn_n/declaration.mojo          | 9 ++++++++-
 src/plan_proto/numbers/StringFnN/15                              | 1 -
 src/plan_proto/plan_vocabulary.proto                             | 1 +
 4 files changed, 12 insertions(+), 5 deletions(-)

$ git merge-tree --write-tree --name-only string-fn-n-15 string-fn-20    # exit 0
$ git merge-tree --write-tree --name-only string-fn-n-15 agg-fn-39       # exit 0
$ git merge-tree --write-tree --name-only string-fn-20 agg-fn-39         # exit 0

$ git merge-tree --write-tree --name-only string-fn-n-15 string-fn-n-16  # exit 1
src/plan_proto/buildrules.mojo.lock.bzl
src/plan_proto/generated/plan_proto/_parts/plan_vocabulary/string_fn_n/declaration.mojo
src/plan_proto/plan_vocabulary.proto

$ git merge-tree --write-tree --name-only claim-17-first claim-17-second  # exit 1
src/plan_proto/numbers/StringFnN/17
CONFLICT (add/add): Merge conflict in src/plan_proto/numbers/StringFnN/17

$ git merge-tree --write-tree --name-only claim-17-first claim-17-same    # exit 0
```

Next, `string-fn-n-15`, `string-fn-20` and `agg-fn-39` were merged into one tree.

- Its lock equals, byte for byte, the lock rewritten from that tree's own files. So the merged lock
  is already what `buildrules mojo sync` would write.
- Every generated file in it is one side's file, unchanged.
- That the merged files also equal what the generator would write is inferred: each declaration's
  file depends only on its own declaration.

Two controls show what each piece does:

- Without the separator: the `__init__.mojo` lines were removed from the locks of the base,
  `string-fn-n-15` and `string-fn-20`, leaving one flat file per declaration. `git merge-file` of
  those locks then exits 3: one conflicting hunk per platform.
- Today's layout: each of the six measured pull requests changes the digest line of all seven
  files, so every pair conflicts.

The same-enum pair still conflicts. The second to land takes both sides' lines in number order,
then runs `regen` and the lock sync. Its claim gave it a different number, so nothing has to be
renumbered.

## Order of work

Pairs of member pull requests merge cleanly only when slices 2 and 3 have landed and the total is
no longer hand-written. Slice 1 prevents number collisions; it does not change merging.

1. **Open claims.** This slice changes:
   - the `numbers/` directory, which starts empty, with its glob in `src/plan_proto/BUCK`;
   - the welded test of the claims;
   - the steps of "Taking a number", in `src/plan_proto/README.md`.

   It changes no ledger and no generated file, and waits on nothing. Had claims landed before the
   work, it would have prevented both measured number collisions.
2. **No input digest for the two proto rules.** This slice changes:
   - the header in `header.rs`: no digest, "inputs named above" in its last line, and a bump of
     `PLUGIN_GENERATOR_VERSION`;
   - the `__init__.mojo` text of the Zig rule actions, together with the other spellings that
     `tools/build/gen:command_agreement` holds equal;
   - the Rust tests that assert the digest;
   - a one-time regeneration of every tree of the two rules, including the committed fixture trees
     under `tools/build/tests`;
   - the paragraph "What does a generated file look like?" of generated_sources.md.

   Alone, it removes the digest-only conflicts inside files: 99 of the 105 measured. Every pair
   still conflicts, though, on the lock and on the parts that shift.
3. **One directory per declaration for the two proto rules.** It pays off only after slice 2.
   Without it, the digest would still change every declaration's file. This slice:
   - first builds `komira//src/plan_proto:lib` on the farm in the new layout, with its compile time
     before and after, and takes the fallback above if that fails;
   - changes the generator's split;
   - changes the check of `_parts` in `tools/build/act_util` and
     `tools/build/mojo/tools/proto_gen.zig`. Today that check refuses anything but a flat list of
     `.mojo` files. Nested directories become allowed for these two rules only, and the AWS and
     Google Cloud actions keep the flat check;
   - changes the layout that `tools/build/mojo/proto.bzl` and `tools/build/tests/proto_tests.sh`
     describe, and the facades' generated import lines, which become one per declaration;
   - moves the generator's goldens;
   - regenerates the trees;
   - updates the paragraph "The line limit" of generated_sources.md.
4. **Later, possibly never:** a file for every declared value, as described above.
5. **A convenience, not part of the fix:** `regen` also runs the lock sync of the package it
   rewrote. That couples `regen` to a tool from another repository.

## The owner's decision

Keep generated code checked in and make a pull request touch only its own declaration's file
(recommended), or stop checking it in, which needs work in the package tool and the build rules
first and means nobody reviews generated code. With the recommended way, 13 of the 15 measured pairs of pull requests would no longer conflict
over the vocabulary; the other 2, which add to the same enum, would still conflict, but a number taken twice
is refused when the second one lands.

The rest is information, decided as engineering changes, not questions:

- the claim files;
- dropping the input line's hash from generated files of this repository's own `.proto` files,
  which edits one sentence of generated_sources.md;
- the landing order in `PlanTag` and `ExprTag`, which writes down what the engine already requires.
