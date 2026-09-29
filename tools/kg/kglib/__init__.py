"""kg: the repository knowledge graph. Generated library pages, a map and a docs graph
(committed, rebuilt by the pre-commit hook), and the Buck2 code graph (committed, re-derived
by `kg graph` and proven by the `kg` CI job).

Standard library only; Python >= 3.9, git >= 2.25. Usage and the page contract:
tools/kg/README.md.
"""

PAGE_FORMAT = 2


class KgError(Exception):
    """A refusal. The message names what is wrong and the one command that fixes it."""
