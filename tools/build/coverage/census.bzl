"""coverage_census: the coverage census's doc, rendered at build time, and its floors' check.

Two actions over `census` (census.tsv, the numbers of one coverage build of
every library) and `ratchet` (ratchet.tsv):

- `census.sh render` writes the doc (the ranked table, `<name>.md`), the
  target's default output: `./buck2 build //:coverage_census --show-output`.
  The doc is a build output and is never committed, so a change to one row
  of census.tsv or ratchet.tsv touches nothing else.
- `census.sh check` renders the ratchet rows into scratch and fails the
  build (a validation) unless `ratchet` is exactly what it renders: every
  floor is at least what the census measured (a floor is lowered only by a
  hand edit of ratchet.tsv to a value the census does not exceed), every
  package of the census has one row and no other row is there.

census.md.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _coverage_census_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    doc = ctx.actions.declare_output(ctx.label.name + ".md")
    floors = ctx.actions.declare_output("render/ratchet.tsv")
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script, "render", bb, ctx.attrs.census, ctx.attrs.ratchet, doc.as_output(), floors.as_output()),
        category = "coverage_census_render",
    )
    result = ctx.actions.declare_output("validation.json")
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script, "check", bb, ctx.attrs.census, ctx.attrs.ratchet, result.as_output()),
        category = "coverage_census",
    )
    return [
        DefaultInfo(default_output = doc, sub_targets = {"validation": [DefaultInfo(default_output = result)]}),
        ValidationInfo(validations = [ValidationSpec(name = "coverage_census", validation_result = result)]),
    ]

_coverage_census_rule = rule(
    impl = _coverage_census_impl,
    doc = "Renders the census doc from `census` and `ratchet` and fails the build unless `ratchet` is what census.sh renders. See census.bzl.",
    attrs = {
        "census": attrs.source(default = "komira//tools/build/coverage:census.tsv"),
        "ratchet": attrs.source(default = "komira//tools/build/coverage:ratchet.tsv"),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_script": attrs.source(default = "komira//tools/build/coverage:census.sh"),
    },
)

def coverage_census(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _coverage_census_rule(**kwargs)
