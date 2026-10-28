"""The Mojo Markdown reader `buildtools.doc_links` (tools/build/inspect)
still imports: `markdown` (what is code: CommonMark fences; and the links)
and `text` (its byte helpers). Nothing else is left of the Mojo README
examples generator: the README examples are the Zig tool's
(`//tools/build/readme_examples:tool`, on the shared Zig Markdown module
`//tools/build/markdown`). This library is deleted by the doc_links port of
komira-ai/komira#1281, which moves doc_links onto that Zig module.
"""
