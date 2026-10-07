"""branchretor: an `or` whose result is returned, never branched on (test
46): when its right operand decides cannot be counted, and branch coverage
refuses it rather than count the left operand alone."""


def either(a: Bool, b: Bool) -> Bool:
    return a or b
