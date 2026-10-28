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
        # The doc_tree targets (tools/build/lint/doc_tree.bzl) whose files
        # the check reads, as strings, each keyed by the path its cell has
        # in the repository ("" for the check's own cell).
        "trees": provider_field(dict[str, str], default = {}),
        # More files the check reads (the dotfiles a doc_tree's glob skips),
        # keyed by their path in the repository.
        "files": provider_field(dict[str, typing.Any], default = {}),
        # The allowlist of python_closure: `surface` holds package paths
        # whose findings are allowed, `ceiling` the exact findings allowed
        # today, which only shrinks (graph_checks.zig).
        "surface": provider_field(list[str], default = []),
        "ceiling": provider_field(list[str], default = []),
    },
)
