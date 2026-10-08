"""An ORACLE case's header: the `--` lines before its SELECT.

    -- order: total | none | keys=<c1>,<c2>     (required)
    -- float: ulps=<n> | rel=<x>                 (optional; ulps=0)
    -- not null: <c1>, <c2>                      (optional)

Read by gen_expected.py, which writes the policy into the expected file, and
by test_expected.py, which holds the file to it. Other `--` lines are
comments; the header ends at the first line that does not start with `--`.
"""

import render


class CaseError(ValueError):
    pass


def read_header(sql):
    """(render.Policy, set of not-null column names) from the leading `--`
    lines of `sql`."""
    fields = {}
    for line in sql.split("\n"):
        if not line.startswith("--"):
            break
        body = line[2:].strip()
        for key in ("order", "float", "not null"):
            if body.startswith(key + ":"):
                if key in fields:
                    raise CaseError("a second '-- %s:' line" % key)
                fields[key] = body[len(key) + 1 :].strip()
    if "order" not in fields:
        raise CaseError("no '-- order:' line")
    order = fields["order"]
    keys = ()
    if order.startswith("keys="):
        keys = [k.strip() for k in order[5:].split(",")]
        order = "keys"
    policy = render.Policy(order, keys, fields.get("float", "ulps=0"))
    not_null = set()
    if fields.get("not null"):
        not_null = {c.strip() for c in fields["not null"].split(",")}
    return policy, not_null
