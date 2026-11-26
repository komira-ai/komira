"""The set a release's `plan.json` must stage, written as data for `release_staged_verify expect`.

    mopm_plan_expectation(name = "mopm_plan_expectation", namespace = NAMESPACE, packages = PACKAGES, darwin = DARWIN_PACKAGES, mojos = [MOJO_DEFAULT, MOJO_NEXT])

`mopm stage` packs one `.conda` per subdir a member has a library in, and writes `plan.json`. Nothing in
`mopm stage` says the set is whole: a tree that lost a platform, or a package, stages a shorter set that
every later check (`verify`, `smoke`, `add`) passes, since they all read the plan. The release builds exactly
the packages of release/readme_e2e/packages.bzl (`PACKAGES`), each for linux-64, and each of
release/darwin_libs.bzl's `DARWIN_PACKAGES` (every package not in `DARWIN_EXCLUDED`) for osx-arm64 as well.
This rule writes that, from those lists and from no other, as one JSON file:

    {"mojos": ["1.1.0", "1.2.0"], "members": [{"name": "<namespace>/<name>", "subdirs": ["linux-64", "osx-arm64"]}, ...]}

one entry per package of `packages`, sorted by name, each with the subdirs it must have a file in and may
have one in (`linux-64`; `osx-arm64` too when it is in `darwin`), and `mojos`, the Mojo versions the release
publishes (tools/build/toolchains/mojo_versions.bzl): `mopm stage` is given one build of every package per
Mojo, so each package must have one file for every subdir and every Mojo. release.yml's `mopm-stage`
builds it and runs `release_staged_verify expect` with it on the plan `mopm stage` just wrote
(plan_expect.zig).

It refuses, at analysis, no package, an empty namespace, a `darwin` name that is not a package of
`packages`, no Mojo version and a Mojo version twice, so the file never names a package the release does not
build. `plan_expectation_cases`
holds `plan_expectation_members` to its cases.
"""

LINUX_SUBDIR = "linux-64"
DARWIN_SUBDIR = "osx-arm64"

def plan_expectation_members(namespace, packages, darwin):
    """`(members, None)`, the entries of the expectation (see the module documentation), or `(None, why)`.

    `packages` is a dict or a list of package names; `darwin` a list of names, each one of `packages`."""
    if not namespace:
        return None, "no namespace: a member's full name is <namespace>/<name>"
    names = sorted(packages)
    if not names:
        return None, "no package: an expectation of nothing would let an empty plan through"
    for name in darwin:
        if name not in names:
            return None, "the darwin set names {}, which is not a package of the release".format(name)
    members = []
    for name in names:
        subdirs = [LINUX_SUBDIR, DARWIN_SUBDIR] if name in darwin else [LINUX_SUBDIR]
        members.append({"name": "{}/{}".format(namespace, name), "subdirs": subdirs})
    return members, None

def plan_expectation_mojos(mojos):
    """`(mojos, None)`, the Mojo versions of the expectation in the order given, or `(None, why)`."""
    if not mojos:
        return None, "no Mojo version: an expectation of no compiler would let a plan with no Mojo build through"
    for i, m in enumerate(mojos):
        if m in mojos[:i]:
            return None, "the Mojo version {} is listed twice".format(m)
    return list(mojos), None

_MOJO_CASES = [
    ("two versions", ["1.1.0", "1.2.0"], ["1.1.0", "1.2.0"], None),
    ("no version", [], None, "no Mojo version: an expectation of no compiler would let a plan with no Mojo build through"),
    ("a version twice", ["1.1.0", "1.2.0", "1.1.0"], None, "the Mojo version 1.1.0 is listed twice"),
]

_CASES = [
    (
        "every package on linux-64, the darwin ones on osx-arm64 as well",
        ("ns", {"b": "0.1.0", "a": "0.1.0"}, ["a"]),
        [{"name": "ns/a", "subdirs": ["linux-64", "osx-arm64"]}, {"name": "ns/b", "subdirs": ["linux-64"]}],
        None,
    ),
    (
        "every package on both platforms",
        ("ns", ["a", "b"], ["b", "a"]),
        [{"name": "ns/a", "subdirs": ["linux-64", "osx-arm64"]}, {"name": "ns/b", "subdirs": ["linux-64", "osx-arm64"]}],
        None,
    ),
    (
        "a darwin name that is not a package",
        ("ns", ["a"], ["a", "gone"]),
        None,
        "the darwin set names gone, which is not a package of the release",
    ),
    (
        "no package",
        ("ns", {}, []),
        None,
        "no package: an expectation of nothing would let an empty plan through",
    ),
    (
        "no namespace",
        ("", ["a"], []),
        None,
        "no namespace: a member's full name is <namespace>/<name>",
    ),
]

def plan_expectation_cases():
    """Fails loading the package when plan_expectation_members gets a case of _CASES wrong, naming the case."""
    for name, args, want, want_why in _CASES:
        got, why = plan_expectation_members(args[0], args[1], args[2])
        if why != want_why:
            fail("plan_expectation_members, case '{}': the reason is {}, want {}".format(name, repr(why), repr(want_why)))
        if got != want:
            fail("plan_expectation_members, case '{}': the members are {}, want {}".format(name, repr(got), repr(want)))
    for name, mojos, want, want_why in _MOJO_CASES:
        got, why = plan_expectation_mojos(mojos)
        if why != want_why:
            fail("plan_expectation_mojos, case '{}': the reason is {}, want {}".format(name, repr(why), repr(want_why)))
        if got != want:
            fail("plan_expectation_mojos, case '{}': the versions are {}, want {}".format(name, repr(got), repr(want)))

def _impl(ctx):
    members, why = plan_expectation_members(ctx.attrs.namespace, ctx.attrs.packages, ctx.attrs.darwin)
    if why:
        fail("{}: {}".format(ctx.label, why))
    mojos, why = plan_expectation_mojos(ctx.attrs.mojos)
    if why:
        fail("{}: {}".format(ctx.label, why))
    out = ctx.actions.write_json("{}.json".format(ctx.label.name), {"mojos": mojos, "members": members})
    return [DefaultInfo(default_output = out)]

mopm_plan_expectation = rule(
    impl = _impl,
    attrs = {
        "darwin": attrs.list(attrs.string()),
        "mojos": attrs.list(attrs.string()),
        "namespace": attrs.string(),
        "packages": attrs.list(attrs.string()),
    },
)
