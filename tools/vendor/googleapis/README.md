# Vendored googleapis protos

The `.proto` files komira generates Google Cloud clients from, and nothing
else: for each set of roots, exactly their import closure, at one pinned
googleapis commit. The generated clients are built from these at build time;
no generated code is checked in. The well-known types (`google/protobuf/*`)
are not vendored: protoc provides them.

| file | what it is |
|---|---|
| [PIN.tsv](PIN.tsv) | the googleapis commit, the roots, and the sha256 of LICENSE and of every vendored file |
| `google/...` | the files, as googleapis has them at that commit |
| [LICENSE](LICENSE) | googleapis's (Apache-2.0), unmodified |
| [NOTICE](NOTICE) | where the files come from |
| [vendor.sh](vendor.sh) | how the tree and PIN.tsv are made: fetches the closure over HTTPS |
| [proto_check.bzl](proto_check.bzl), [proto_check.sh](proto_check.sh) | the check, and its fixtures in `testdata/` |

Each set of roots is a `proto_check` target of [BUCK](BUCK) that refuses the
tree unless its files, LICENSE and roots are exactly PIN.tsv's, and protoc
parses the roots from the tree alone into a descriptor set that names every
vendored file. A file the closure needs and the tree lacks fails there, and so
does a vendored file nothing imports. The build never fetches.

| target | roots | for |
|---|---|---|
| `logging_v2_check` | `google/logging/v2/{logging,log_entry}.proto` | Cloud Logging v2 `ListLogEntries` |

A target's `[tree]` output, and the `ProtoSrcsInfo` it provides, is the
checked copy of the tree, so a `mojo_proto_library` that names it in
`proto_deps` reads only checked files.

## Adding roots or bumping the commit

1. Pick the commit: a full sha of googleapis's default branch.
2. From the repository root, run `tools/vendor/googleapis/vendor.sh <commit>`
   with every root of every target in BUCK. It replaces `google/`, LICENSE
   and PIN.tsv; run again at the same commit, it reproduces them byte for
   byte.
3. Name the roots in BUCK (one `proto_check` per set of roots) and build the
   package. Today one PIN.tsv covers the one target, so its roots are the
   target's; a second target needs its own pin, or the check taught to take
   the union.
