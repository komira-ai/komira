# Written by `buildrules mojo sync`. Do not edit: `buildrules check` fails when this differs from what sync writes.
# Binds the generated table (buildrules.mojo.lock.bzl) to the macro of @buildrules//rules/mojo:defs.bzl.
load("@buildrules//rules/mojo:defs.bzl", _mojo_package = "mojo_package")
load(":buildrules.mojo.lock.bzl", "CLOSURE_SHA256", "GRAPH", "GRAPHS", "MANIFEST_SHA256", "MOJO", "MOPM", "SCHEMA")

TABLE = {
    "CLOSURE_SHA256": CLOSURE_SHA256,
    "GRAPH": GRAPH,
    "GRAPHS": GRAPHS,
    "MANIFEST_SHA256": MANIFEST_SHA256,
    "MOJO": MOJO,
    "MOPM": MOPM,
    "SCHEMA": SCHEMA,
}

def mojo_package(path = ".", **kwargs):
    _mojo_package(path = path, table = TABLE, **kwargs)
