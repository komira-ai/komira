"""A package whose `mojo doc` JSON test 52 reads (tools/build/mojo/doc.bzl)."""

from hellopkg import greeting


def shout() -> String:
    """Returns hellopkg's greeting in capitals."""
    return greeting().upper()


def _hidden() -> Int:
    return 1
