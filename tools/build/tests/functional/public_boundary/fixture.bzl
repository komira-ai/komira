"""The planted tree of test 44 (the public boundary lint), as {path in the tree: file}.

held.mojo and shim.c hold findings of every rule in each spelling the reader
knows (a date in each of its forms, the three home directory forms, each
private range and each way of writing an address, hosts of each kind, email
addresses, commit ids in a docstring, a comment, a trailing comment, a C line
comment and a C block comment), and holds.tsv holds each rule at its exact
count there: a spelling the reader misses leaves a row above its count, which
fails the build, so `ok` building proves each one is found.

near.md, near.mojo and near.c hold every near miss, which must not be a
finding: dates at or after the public history and before the window, a year
alone, placeholder home directories, loopback, documentation and published
cloud metadata addresses, OIDs and section numbers, reserved example hosts,
templates and patterns, noreply addresses, digests and UUIDs, quoted and
fenced hex, and hex in code rather than prose.

upstream.c (under third_party/ and under the trimmed upstream trees) and
data.arrow (binary data, by suffix) hold findings of every rule and are not
read; third_party/up/BUCK is read, and the only URL of the github.com row of
hosts.tsv is there, so the row is used only if that file is read.
functional/public_boundary/BUCK exports the files, so negative/public_boundary
plants its defects in the same tree.
"""

_DIR = "tests//functional/public_boundary:"

PB_TREE = {
    "docs/near.md": _DIR + "near_md.txt",
    "src/komira_a/held.mojo": _DIR + "held_mojo.txt",
    "src/komira_a/near.c": _DIR + "near_c.txt",
    "src/komira_a/near.mojo": _DIR + "near_mojo.txt",
    "src/komira_a/shim.c": _DIR + "held_c.txt",
    "src/komira_a/tests/fixtures/data.arrow": _DIR + "data_arrow.txt",
    "third_party/up/BUCK": _DIR + "upstream_buck.txt",
    "third_party/up/upstream.c": _DIR + "upstream_c.txt",
    "tools/build/third_party_srcs/testdata/up/upstream.c": _DIR + "upstream_c.txt",
}

PB_HOLDS = _DIR + "holds.tsv"

PB_HOSTS = _DIR + "hosts.tsv"

# The window of the planted tree: from 2030 up to 2031-09-01, so that a
# planted date is in it and no file here holds a date before the root
# target's public_from.
PB_WINDOW = {"public_from": "2031-09-01", "window_from": 2030}
