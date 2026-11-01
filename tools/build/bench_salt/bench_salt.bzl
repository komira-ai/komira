"""A benchmark salt: `-c komira.bench_salt=<string>` re-keys a target's own
actions so each one executes (tools/build/bench_salt/README.md).

The value is read once, when this file is loaded, from the root cell's
`[komira] bench_salt`. A rule passes the environment of an action through
`salted`: with no value (the default) that is the environment as given, so
no action key moves; with a value it is that environment plus
`KOMIRA_BENCH_SALT=<value>`, and an environment is part of an action's key.
"""

BENCH_SALT_ENV = "KOMIRA_BENCH_SALT"

def _read():
    v = (read_root_config("komira", "bench_salt", "") or "").strip()
    if v and not regex_match("^[A-Za-z0-9._-]+$", v):
        fail("[komira] bench_salt = {}: it must be empty or letters, digits, `.`, `_` and `-` (tools/build/bench_salt/README.md)".format(repr(v)))
    return v

# The value; empty when there is none.
BENCH_SALT = _read()

def salted(env = None):
    """`env` (a dict, or None) with `KOMIRA_BENCH_SALT` added when a salt is
    set; the dict as given, or an empty one for None, otherwise."""
    env = dict(env) if env else {}
    if BENCH_SALT:
        env[BENCH_SALT_ENV] = BENCH_SALT
    return env
