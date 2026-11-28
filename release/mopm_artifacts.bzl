"""The build artifacts `mopm stage` packs: one `.mojoc` per package moved to mopm.

    mopm_artifacts(
        name = "mopm_artifacts",
        packages = ["encoding", "json"],
        natives = {"libc": {"komira_libc_posix": "//src/libc:native_komira_libc_posix"}},
    )

A package is a library built with buildrules' `mojo_package` (its BUCK file has
`:lib`, the `.mojoc` that exists only once its tests passed). The output is one
directory in the layout `mopm stage --artifacts` reads,
`linux-64/<namespace>/<name>.mojoc` with the namespace of
//release/readme_e2e:packages.bzl (`komira-ai`; this rule is the linux-64 tree, built for the target
platform of the build), so what is packed and published is the library the tests passed, not a rebuild.
The osx-arm64 tree is //release:mopm_darwin_libs (darwin_libs.bzl), and `mopm_release_artifacts` (below)
merges the two, its macOS half configured for darwin-arm64 by a transition, into the one directory
release.yml's `mopm-stage` stages: `mopm stage` packs one `.conda` per subdir a member has a library in,
the two in the same group at the same version. mopm
reads no other layout: a `.mojoc` without the namespace directory is a member with
"no build artifact".

A package with a `[native.<id>] kind = "static"` in its mopm.toml also has `natives = {"<package>":
{"<id>": "<archive target>"}}`: the archive is `linux-64/<namespace>/<package>.native/lib<id>.a`, the file
`mopm stage` packs as the package's native. The target is the one the package's `mojo_conda` passes
to `--native`, so the archive staged is the one that was linked into the tests and packed into the
`.conda`. `mopm stage` refuses a package whose manifest names a native that this directory does not
hold ("has no archive for linux-64: expected ...").

The attribute is held to the packages' manifests at analysis, in both directions (mopm_native_ids.bzl
reads the ids from each package's unit graph): an id that is no `[native.<id>]` of that package is
refused, and so is a declared native with no entry, each naming the package and the ids it declares. So
a mistyped id no longer builds green and fails only in the release workflow's `mopm stage`.

The list is the one of //release/readme_e2e:packages.bzl (every `src/<name>`
that has a `mopm.toml`), which //:readme_e2e_complete holds to the files of the
checkout in both directions. `mopm stage` itself refuses a member of the
workspace that has no `.mojoc` here, so the two cannot disagree unseen.

//release:artifacts_layout_cases lists the files of the built directory and holds them to the
package list and the declared natives.

Nothing here runs buck2 or sends anything: the targets are dependencies.
"""

load("//release/readme_e2e:packages.bzl", "NAMESPACE")
load("//tools/build/toolchains:mojo_versions.bzl", "MOJO_NEXT", "MOJO_NEXT_CONSTRAINT")
load(":mopm_native_ids.bzl", "NATIVE_IDS")

def mojoc_path(subdir, name):
    """The path of package `name`'s library in the `mopm stage --artifacts` directory for `subdir`."""
    return "{}/{}/{}.mojoc".format(subdir, NAMESPACE, name)

def native_path(subdir, package, native_id):
    """The path of `package`'s `[native.<native_id>]` archive in the `mopm stage --artifacts` directory for `subdir`."""
    return "{}/{}/{}.native/lib{}.a".format(subdir, NAMESPACE, package, native_id)

# The files of one subdir of the `mopm stage --artifacts` directory: `subdir` (`linux-64`, `osx-arm64`) and
# `tree`, `{path: artifact}` with every path under `<subdir>/`. :mopm_artifacts and :mopm_darwin_libs give it,
# and mopm_release_artifacts merges the two into the one directory the release stages.
MopmTreeInfo = provider(fields = ["subdir", "tree"])

def _impl(ctx):
    tree = {}
    for name, lib in zip(ctx.attrs.names, ctx.attrs.libs):
        tree[mojoc_path("linux-64", name)] = lib[DefaultInfo].default_outputs[0]
    for package, archives in ctx.attrs.natives.items():
        for native_id, archive in archives.items():
            tree[native_path("linux-64", package, native_id)] = archive[DefaultInfo].default_outputs[0]
    return [DefaultInfo(default_output = ctx.actions.copied_dir("mopm_artifacts", tree)), MopmTreeInfo(subdir = "linux-64", tree = tree)]

_mopm_artifacts = rule(
    impl = _impl,
    attrs = {
        "libs": attrs.list(attrs.dep()),
        "names": attrs.list(attrs.string()),
        "natives": attrs.dict(attrs.string(), attrs.dict(attrs.string(), attrs.dep()), default = {}),
    },
)

def check_natives(name, packages, natives, declared = NATIVE_IDS):
    """Refuses `natives` unless it is, for every package of `packages`, exactly the `[native.<id>]` its manifest declares (`declared`, `{package: [id]}`)."""
    for package in packages:
        if package not in declared:
            fail("{}: {} has no row in release/mopm_native_ids.bzl (add its load and its row there)".format(name, package))
    for package in natives:
        if package not in packages:
            fail("{}: natives names {}, which is not in packages".format(name, package))
    for package in packages:
        ids = declared[package]
        given = natives.get(package, {})
        for native_id in sorted(given):
            if native_id not in ids:
                fail("{}: natives names {}.{}, but the mopm.toml of {} declares no [native.{}] (it declares: {})".format(
                    name,
                    package,
                    native_id,
                    package,
                    native_id,
                    ", ".join(ids) if ids else "none",
                ))
        for native_id in ids:
            if native_id not in given:
                fail("{}: {} declares [native.{}] in its mopm.toml, and natives has no entry for it: add `{{\"{}\": {{\"{}\": <the archive target>}}}}`".format(
                    name,
                    package,
                    native_id,
                    package,
                    native_id,
                ))

def mopm_artifacts(name, packages, natives = {}, **kwargs):
    """See the module documentation. `packages` are directory names under src/; `natives` is `{package: {id: archive target}}`."""
    if not packages:
        fail("{}: no package".format(name))
    check_natives(name, packages, natives)
    _mopm_artifacts(
        name = name,
        names = packages,
        libs = ["komira//src/{}:lib".format(p) for p in packages],
        natives = natives,
        **kwargs
    )

def _native_ids_json_impl(ctx):
    return [DefaultInfo(default_output = ctx.actions.write_json("native_ids.json", NATIVE_IDS))]

# `NATIVE_IDS` (mopm_native_ids.bzl) as JSON, `{package: [id, ...]}`: what //release:native_ids_cases
# holds to the `[native.<id>]` tables of each package's `mopm.toml`.
native_ids_json = rule(impl = _native_ids_json_impl, attrs = {})

def _release_packages_json_impl(ctx):
    data = {"namespace": ctx.attrs.namespace, "natives": sorted(ctx.attrs.natives), "packages": sorted(ctx.attrs.packages)}
    return [DefaultInfo(default_output = ctx.actions.write_json("release_packages.json", data))]

# The release's package names as JSON, `{"namespace": ..., "natives": [...], "packages": [...]}`: the packages of
# //release/readme_e2e:packages.bzl and those of them that ship a native archive (the keys of `RELEASE_NATIVES` in
# release/BUCK, a table no other package can load). //tools/build/ci:prod_add_set_cases holds the names
# `release_staged_verify add` installs from prod to it.
release_packages_json = rule(impl = _release_packages_json_impl, attrs = {
    "namespace": attrs.string(),
    "natives": attrs.list(attrs.string()),
    "packages": attrs.list(attrs.string()),
})

# The subdirs of a release, in the order their trees are merged: the platforms the release publishes.
RELEASE_SUBDIRS = ["linux-64", "osx-arm64"]

def merge_trees(parts, subdirs = RELEASE_SUBDIRS):
    """Merges `parts`, a list of `(subdir, {path: value})`, into one `{path: value}`.

    Returns `(merged, None)`, or `(None, reason)` when the parts are not exactly one non-empty tree for each
    subdir of `subdirs`, in that order, each path under its own subdir: a release that would stage a platform
    twice, leave one out, or put a file of one platform under another's directory is refused at analysis.
    """
    got = [subdir for subdir, _ in parts]
    if got != subdirs:
        return (None, "the trees are for the subdirs {}; a release stages exactly {}, in that order".format(got, subdirs))
    merged = {}
    for subdir, tree in parts:
        if not tree:
            return (None, "the {} tree has no file: that platform would be staged with no package".format(subdir))
        for path in sorted(tree):
            if not path.startswith(subdir + "/"):
                return (None, "{} is in the {} tree but not under {}/".format(path, subdir, subdir))
            merged[path] = tree[path]
    return (merged, None)

# The cases of merge_trees: (name, parts, the reason wanted, or None for a merge).
_MERGE_CASES = [
    ("both platforms merge", [("linux-64", {"linux-64/ns/a.mojoc": 1}), ("osx-arm64", {"osx-arm64/ns/a.mojoc": 2})], None),
    ("the macOS tree is missing", [("linux-64", {"linux-64/ns/a.mojoc": 1})], "the trees are for the subdirs [\"linux-64\"]; a release stages exactly [\"linux-64\", \"osx-arm64\"], in that order"),
    ("a platform twice", [("linux-64", {"linux-64/ns/a.mojoc": 1}), ("linux-64", {"linux-64/ns/b.mojoc": 2})], "the trees are for the subdirs [\"linux-64\", \"linux-64\"]; a release stages exactly [\"linux-64\", \"osx-arm64\"], in that order"),
    ("the order swapped", [("osx-arm64", {"osx-arm64/ns/a.mojoc": 2}), ("linux-64", {"linux-64/ns/a.mojoc": 1})], "the trees are for the subdirs [\"osx-arm64\", \"linux-64\"]; a release stages exactly [\"linux-64\", \"osx-arm64\"], in that order"),
    ("an empty macOS tree", [("linux-64", {"linux-64/ns/a.mojoc": 1}), ("osx-arm64", {})], "the osx-arm64 tree has no file: that platform would be staged with no package"),
    ("a Linux file in the macOS tree", [("linux-64", {"linux-64/ns/a.mojoc": 1}), ("osx-arm64", {"linux-64/ns/b.mojoc": 2})], "linux-64/ns/b.mojoc is in the osx-arm64 tree but not under osx-arm64/"),
    ("a subdir name as a prefix of a file name", [("linux-64", {"linux-64x/ns/a.mojoc": 1}), ("osx-arm64", {"osx-arm64/ns/a.mojoc": 2})], "linux-64x/ns/a.mojoc is in the linux-64 tree but not under linux-64/"),
]

def merge_tree_cases():
    """Fails loading the package when merge_trees gets a case of _MERGE_CASES wrong, naming the case."""
    for name, parts, want in _MERGE_CASES:
        merged, why = merge_trees(parts)
        if why != want:
            fail("merge_trees, case '{}': the reason is {}, want {}".format(name, repr(why), repr(want)))
        if want == None:
            paths = []
            for _, tree in parts:
                paths += tree.keys()
            if sorted(merged.keys()) != sorted(paths):
                fail("merge_trees, case '{}': merged {}, want every path of the parts {}".format(name, sorted(merged.keys()), sorted(paths)))

def _darwin_arm64_impl(platform, refs):
    # the platform `--target-platforms komira//tools/build/platforms:darwin-arm64` names, unchanged: the libraries
    # are configured exactly as release-macos.yml and pr.yml's macOS part configure them, so their actions are the
    # same actions (and the same cache entries). Of `platform`, the dependent's, only the Mojo compiler is read: a
    # dependent built with the second compiler (`<row>-mojo-<version>`, toolchains/mojo_versions.bzl) gets
    # `darwin-arm64-mojo-<version>`, so both halves of one artifacts directory are built with one compiler.
    nxt = refs.mojo_next[ConstraintValueInfo]
    chosen = platform.configuration.constraints.get(nxt.setting.label)
    if chosen and chosen.label == nxt.label:
        return refs.darwin_arm64_next[PlatformInfo]
    return refs.darwin_arm64[PlatformInfo]

_DARWIN_ARM64 = transition(impl = _darwin_arm64_impl, refs = {
    "darwin_arm64": "komira//tools/build/platforms:darwin-arm64",
    "darwin_arm64_next": "komira//tools/build/platforms:darwin-arm64-mojo-" + MOJO_NEXT,
    "mojo_next": MOJO_NEXT_CONSTRAINT,
})

def _release_impl(ctx):
    linux = ctx.attrs.linux[MopmTreeInfo]
    mac = ctx.attrs.mac[MopmTreeInfo]
    merged, why = merge_trees([(linux.subdir, linux.tree), (mac.subdir, mac.tree)])
    if why:
        fail("{}: {}".format(ctx.label, why))
    layout = ctx.actions.write_json("mopm_release_artifacts.layout.json", sorted(merged.keys()))
    return [DefaultInfo(
        default_output = ctx.actions.copied_dir("mopm_release_artifacts", merged),
        sub_targets = {"layout": [DefaultInfo(default_output = layout)]},
    )]

# The directory `mopm stage --artifacts` reads in release.yml's `mopm-stage`: the linux-64 tree of `linux` (built for
# the target platform of the build, linux-x86_64) and the osx-arm64 tree of `mac`, configured for darwin-arm64 by
# the transition, so its libraries compile and run their welded tests on the farm's macOS workers.
mopm_release_artifacts = rule(
    impl = _release_impl,
    attrs = {
        "linux": attrs.dep(providers = [MopmTreeInfo]),
        "mac": attrs.transition_dep(cfg = _DARWIN_ARM64, providers = [MopmTreeInfo]),
    },
)
