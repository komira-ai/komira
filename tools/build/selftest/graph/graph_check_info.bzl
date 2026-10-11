"""GraphCheckInfo: a graph check as its `graph_check` target declares it.

Separate from ../defs.bzl, which defines rules, so that checks.bxl can load
it.
"""

GraphCheckInfo = provider(
    doc = "A graph check as declared: checks.bxl reads it.",
    fields = {
        # The check's name, which selects what checks.bxl collects.
        "check": provider_field(str),
        # The cell of the graph_check target: the check reads labels of it.
        "cell": provider_field(str),
        # The Zig checker that runs over the collected facts.
        "checker": provider_field(typing.Any),
        "exec_compatible_with": provider_field(list[str]),
        "label": provider_field(str),
        # Target patterns the check queries, as strings.
        "targets": provider_field(list[str]),
    },
)
