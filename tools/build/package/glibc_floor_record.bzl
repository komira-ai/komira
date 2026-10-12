"""`glibc_floor_record`: the glibc floor of each conda subdir the packer
writes, as a file, one `<subdir> <floor>` line per subdir, written at
analysis from the platform table itself (`os_floor_version`, no copy). kci
compiles its own copy (src/kci_release_set/glibc_floor.mojo, the one
`__glibc >=<floor>` requirement it accepts); its welded test reads this file
and holds the two equal, both ways.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:table.bzl", "os_floor_version", "row")

# The platform row of each subdir the packer writes (conda.bzl writes only
# linux-64, from the linux-x86_64 row).
_SUBDIR_ROWS = {"linux-64": "linux-x86_64"}

def _impl(ctx):
    lines = []
    for subdir in sorted(_SUBDIR_ROWS.keys()):
        name = _SUBDIR_ROWS[subdir]
        floor = row(name)["os_floor"]
        if not floor.startswith("glibc-"):
            fail("{}: platform row {} has os_floor {}, not a glibc floor".format(ctx.label, name, floor))
        lines.append("{} {}\n".format(subdir, os_floor_version(name)))
    return [DefaultInfo(default_output = ctx.actions.write(ctx.label.name + ".txt", "".join(lines)))]

_glibc_floor_record = rule(
    impl = _impl,
    doc = "The platform table's glibc floor of each conda subdir the packer writes, as `<subdir> <floor>` lines.",
    attrs = {},
)

glibc_floor_record = declares_docs(_glibc_floor_record)
