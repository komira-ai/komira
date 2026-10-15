"""The heavy actions, named to the remote-execution service.

A remote-execution request carries the action's command, its inputs and its
environment, but not its buckconfig `category`. A service that books memory
per action needs to tell a Mojo compile from a file copy, so every heavy
action (a compiler run: `mojo build`, `mojo precompile`, rustc, zig, the C
compiles and links of komira's own rules) is run through `run_heavy`, which
adds one environment variable, `KBF_ACTION_CATEGORY`, whose value is the
action's category: the same string `buck2 log what-ran` and the console show.
Every other action carries no such variable, and the service gives it its
default.

The variable is part of the action's key, like all of its environment. The
programs these actions run ignore it: `mojo_compile` builds the compiler's
environment from nothing, and rustc, zig and the C compilers read no such
name. What reads it is the service, from the request (as
komira-ai/komira-build-farm does); a service that does not read it runs the
action unchanged.

The C/C++ compiles and links of the prelude's `cxx_library` are not run
here: the prelude gives a toolchain no way to add an environment variable to
them, so they carry none.
"""

# The variable's name, as the service reads it.
ACTION_CATEGORY_ENV = "KBF_ACTION_CATEGORY"

def heavy_env(category, env = {}):
    """`env` (unchanged) plus the action-category variable set to `category`."""
    if not category:
        fail("heavy_env: a heavy action needs a category")
    if ACTION_CATEGORY_ENV in env:
        fail("heavy_env: {} is set by heavy_env, not by the caller (category {})".format(ACTION_CATEGORY_ENV, repr(category)))
    out = dict(env)
    out[ACTION_CATEGORY_ENV] = category
    return out

def run_heavy(actions, cmd, category, env = {}, **kwargs):
    """`actions.run(cmd, category = category, ...)`, its environment `env`
    plus the action-category variable (`heavy_env`)."""
    actions.run(cmd, category = category, env = heavy_env(category, env), **kwargs)
