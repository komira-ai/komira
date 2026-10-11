"""coverage_census: the coverage census's doc and floors are its generator's.

`census.sh check` (census.sh says how) renders the ranked table and the
ratchet rows from `census` (census.tsv, the numbers of one coverage build of
every library) and `ratchet` (ratchet.tsv), and fails the build unless `doc`
and `ratchet` are exactly what it renders: the doc was not edited by hand,
and every floor is at least what the census measured (a floor is lowered
only by a hand edit of ratchet.tsv to a value the census does not exceed).
census.md.

A validation of one action, which writes the result Buck2 reads.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _coverage_census_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    result = ctx.actions.declare_output("validation.json")
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script, "check", bb, ctx.attrs.census, ctx.attrs.ratchet, ctx.attrs.doc, result.as_output()),
        category = "coverage_census",
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = "coverage_census", validation_result = result)]),
    ]

_coverage_census_rule = rule(
    impl = _coverage_census_impl,
    doc = "Fails the build unless `doc` and `ratchet` are what census.sh renders from `census` and `ratchet`. See census.bzl.",
    attrs = {
        "census": attrs.source(default = "komira//tools/build/coverage:census.tsv"),
        "doc": attrs.source(),
        "ratchet": attrs.source(default = "komira//tools/build/coverage:ratchet.tsv"),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_script": attrs.source(default = "komira//tools/build/coverage:census.sh"),
    },
)

def coverage_census(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _coverage_census_rule(**kwargs)
