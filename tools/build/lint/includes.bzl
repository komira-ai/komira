"""Loaded into every BUCK file of the komira and tests cells.

`[buildfile] includes` in .buckconfig (and in the tests cell's) names this
module: each symbol it exports is a global of every BUCK file there, as the
prelude's rules are. It exports the prelude rules the repository's BUCK files
call, each calling `package_docs()` first (doc_tree.bzl), so a package that
calls only prelude rules has its doc_tree too. A BUCK file's own `load()`
of a name takes precedence over this module.
"""

load(":doc_tree.bzl", "declares_docs")

constraint_setting = declares_docs(native.constraint_setting)
constraint_value = declares_docs(native.constraint_value)
cxx_library = declares_docs(native.cxx_library)
export_file = declares_docs(native.export_file)
filegroup = declares_docs(native.filegroup)
platform = declares_docs(native.platform)
