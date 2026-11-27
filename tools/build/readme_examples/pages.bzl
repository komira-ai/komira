"""The check and the fill of documents that show files, one implementation for every kind.

A package README (tools/build/mojo/readme.bzl, a source-first library's
`[tests][readme]`) and the task pages of a language
(python/task_examples.bzl, `:pages`) are held by the same two commands of
the README examples tool (//tools/build/readme_examples:tool, include.zig):
`check`, the freshness check, and `fill`, the patch that mends a stale page.
The kind (`readme` or `task`) is the row of the tool's rule table that says
where a page's files are and how each is fenced; every rule is the same.
Both callers expose the two outputs as the sub-targets `[check]` and
`[fill]` (docs/design/documentation_tests.md, "Include, `fill` and
freshness").

This module loads nothing, so any rule file can load it.
"""

def page(src, display, files):
    """One page: `src` (an artifact), the name a refusal gives it
    (`display`, its path from the repository root), and `files`, a list of
    (path, artifact): each file it may show, `path` as an include names it,
    relative to the page."""
    return struct(src = src, display = display, files = files)

def _pages_args(pages):
    args = []
    for p in pages:
        args.extend(["--page", p.src, "--display", p.display])
        for path, f in p.files:
            args.append(cmd_args("--example", cmd_args(path, f, delimiter = "=")))
    return args

def pages_check_and_fill(ctx, tool, kind, pages, check_out, fill_out, env = {}, category = "pages"):
    """Declares `check` and `fill` of `pages` (each made by `page`), of the
    kind `kind`, with the tool `tool` (a RunInfo): the check writes
    `check_out` (one line per page; a refusal fails the action, naming
    `<display>:<line>`), and `fill` writes `fill_out`, the patch `git apply`
    takes from the repository root (empty when every page is fresh).
    Returns struct(check, fill), the two outputs."""
    args = _pages_args(pages)
    check = ctx.actions.declare_output(check_out)
    ctx.actions.run(
        cmd_args(tool, "check", "--kind", kind, args, "--out", check.as_output()),
        env = env,
        category = category + "_check",
    )
    fill = ctx.actions.declare_output(fill_out)
    ctx.actions.run(
        cmd_args(tool, "fill", "--kind", kind, args, "--out", fill.as_output()),
        env = env,
        category = category + "_fill",
    )
    return struct(check = check, fill = fill)
