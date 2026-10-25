"""The transition ledger: generated libraries still built from the generator.

`mojo_aws_client`, `mojo_gcp_client`, `mojo_proto_library` and
`mojo_db_proto_library` build a library from its committed directory
`generated/<name>/` (defs.bzl). A library listed here has no committed
directory yet and is built from the generator, as every one was before; it has
no `<name>_fresh`. This is a switch with an end: the list only shrinks, and
when it is empty the code that builds from the generator is deleted.

To migrate a library: delete its line here and lower `max` of `:transition` in
BUCK by one, run
`./buck2 run komira//tools/build/gen:regen -- <library target>`, commit the
directory. A line for a library that has a committed directory is an error at
load. Never add a line: a new generated library starts committed.

Keep the lines sorted (`:transition_lint`).
"""

UNMIGRATED = [
    "tests//negative/mojo_gcp_client:rest_reaches_plugin",
    "tests//negative/proto:tasks_db_wrong_outs",
]
