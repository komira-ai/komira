"""The fixtures of release_ledger_case (tools/build/package/BUCK).

The accepted fixture: komira_a declared; komira_b native with no README
(NATIVE takes precedence), komira_c with no README, komira_d depending on
komira_e (not declared), komira_e pending, komira_f opening a library at
run time with no README (DLOPEN takes precedence). Each other case changes
one thing and names the text its refusal must hold.
"""

_LEDGER_CENSUS = [
    "komira_a\t0\t1\t-",
    "komira_b\t1\t0\tkomira_a",
    "komira_c\t0\t0\tkomira_a",
    "komira_d\t0\t1\tkomira_a,komira_e",
    "komira_e\t0\t1\tkomira_a",
    "komira_f\t0\t0\t-",
]

_LEDGER_ROWS = [
    "libraries {{ name: \"{}\" reason: {} }}".format(n, r)
    for n, r in [
        ("komira_b", "NATIVE"),
        ("komira_c", "NO_README"),
        ("komira_d", "UNDECLARED_DEP"),
        ("komira_e", "PENDING_DECLARE pr: 1"),
        ("komira_f", "DLOPEN"),
    ]
]

def _ledger_with(name, row):
    """The accepted ledger with `name`'s row replaced by `row`."""
    return [row if "\"{}\"".format(name) in r else r for r in _LEDGER_ROWS]

# name: (census, declared, ledger, the text the refusal must hold; "" accepts)
LEDGER_CASES = {
    "accepts": (_LEDGER_CENSUS, ["komira_a"], ["# a comment", ""] + _LEDGER_ROWS, ""),
    # (a) a library in neither file.
    "neither": (_LEDGER_CENSUS + ["komira_g\t0\t1\t-"], ["komira_a"], _LEDGER_ROWS, "komira_g: src/komira_g is a library in neither"),
    # (b) a library in both.
    "both": (_LEDGER_CENSUS, ["komira_a", "komira_b"], _LEDGER_ROWS, "komira_b: declared in release/artifacts.textproto and listed in the ledger"),
    # (c) a row, or a declaration, for a directory that holds no library.
    "stale_row": (_LEDGER_CENSUS, ["komira_a"], _LEDGER_ROWS + ["libraries { name: \"komira_gone\" reason: NATIVE }"], "komira_gone: listed in the ledger (NATIVE), but src/komira_gone holds no library"),
    "stale_declared": (_LEDGER_CENSUS, ["komira_a", "komira_gone"], _LEDGER_ROWS, "komira_gone: declared in release/artifacts.textproto, but src/komira_gone holds no library"),
    # (d) a reason outside the set.
    "unknown_reason": (_LEDGER_CENSUS, ["komira_a"], _ledger_with("komira_f", "libraries { name: \"komira_f\" reason: SLOW }"), "komira_f: unknown reason SLOW"),
    # A reason the build computes, disagreeing with it.
    "native_not_native": (_LEDGER_CENSUS, ["komira_a"], _ledger_with("komira_e", "libraries { name: \"komira_e\" reason: NATIVE }"), "komira_e: listed NATIVE, but its closure links no native code"),
    "native_as_pending": (_LEDGER_CENSUS, ["komira_a"], _ledger_with("komira_b", "libraries { name: \"komira_b\" reason: PENDING_DECLARE pr: 1 }"), "komira_b: its closure links native code, so its reason is NATIVE, not PENDING_DECLARE"),
    "no_readme_has_one": (_LEDGER_CENSUS, ["komira_a"], _ledger_with("komira_e", "libraries { name: \"komira_e\" reason: NO_README }"), "komira_e: listed NO_README, but it has a README"),
    "no_readme_as_dep": (_LEDGER_CENSUS, ["komira_a"], _ledger_with("komira_c", "libraries { name: \"komira_c\" reason: UNDECLARED_DEP }"), "komira_c: it has no README, so its reason is NO_README, not UNDECLARED_DEP"),
    "dep_declared": (_LEDGER_CENSUS, ["komira_a", "komira_e"], [r for r in _LEDGER_ROWS if "komira_e" not in r], "komira_d: listed UNDECLARED_DEP, but every library it depends on is declared"),
    # The form of the files.
    "listed_twice": (_LEDGER_CENSUS, ["komira_a"], _LEDGER_ROWS[:1] + _LEDGER_ROWS, "komira_b: listed twice in the ledger"),
    "declared_twice": (_LEDGER_CENSUS, ["komira_a", "komira_a"], _LEDGER_ROWS, "komira_a: komira_a:komira_a_conda is declared twice"),
    "pending_without_pr": (_LEDGER_CENSUS, ["komira_a"], _ledger_with("komira_e", "libraries { name: \"komira_e\" reason: PENDING_DECLARE }"), "komira_e: PENDING_DECLARE names the pull request"),
    "pr_on_native": (_LEDGER_CENSUS, ["komira_a"], _ledger_with("komira_b", "libraries { name: \"komira_b\" reason: NATIVE pr: 1 }"), "komira_b: only PENDING_DECLARE takes `pr:`"),
    "not_a_row": (_LEDGER_CENSUS, ["komira_a"], _ledger_with("komira_b", "libraries { name: \"komira_b\" reason: NATIVE"), "line 1 of the ledger is not"),
    "unsorted": (_LEDGER_CENSUS, ["komira_a"], [_LEDGER_ROWS[1], _LEDGER_ROWS[0]] + _LEDGER_ROWS[2:], "komira_b: the ledger is not sorted by name"),
    "census_line": (_LEDGER_CENSUS + ["komira_g\t2\t1\t-"], ["komira_a"], _LEDGER_ROWS, "census line is not"),
    # Inputs that would make the check read nothing.
    "census_empty": ([], ["komira_a"], _LEDGER_ROWS, "the census lists no library"),
    "nothing_declared": (_LEDGER_CENSUS, [], ["libraries { name: \"komira_a\" reason: TEST_SUPPORT }"] + _LEDGER_ROWS, "the artifacts file declares no library"),
}
