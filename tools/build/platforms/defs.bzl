"""Execution platforms: local by default, remote when `.buckconfig.local` asks.

Each execution platform realizes one of the abstract configurations in
//tools/build/platforms (`exec-light`, `exec-mojo`, `exec-mojo-multi-numa`).

- `komira_local_execution_platforms`: every action runs on this machine.
  No service, no property set. Linux x86_64 hosts only.
- `komira_execution_platforms`: every action runs remotely, on workers whose
  property sets are read from `.buckconfig.local`
  (`[komira_re] <key> = key=value,...`), so that no service address or pool
  name is committed.
- `komira_default_execution_platforms`: the first when `[komira_re]` names no
  worker property set, the second when it does. A standalone checkout
  registers this one (//tools/build/platforms/default).

Both kinds register each platform under the label of the abstract
configuration it realizes, so a target's configuration, its output paths and
the commands of its actions are the same whichever kind runs them. Only the
executor differs, and a remote action's digest (command, inputs, property
set) is the one a remote-only checkout computes.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def re_properties(key, required = True):
    """Parse `[komira_re] <key>` into a dict.

    Fails if unset and `required`; returns None if unset and not `required`.
    """
    raw = read_config("komira_re", key, "")
    if not raw.strip():
        if not required:
            return None
        fail(("`[komira_re] {}` is not set. Copy .buckconfig.local.example to " +
              ".buckconfig.local and fill in your remote-execution worker properties.").format(key))
    props = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if not pair:
            continue
        if "=" not in pair:
            fail("`[komira_re] {}`: expected key=value, got `{}`".format(key, pair))
        k, v = pair.split("=", 1)
        props[k.strip()] = v.strip()
    return props

def _remote_platforms_impl(ctx):
    platforms = []
    for name, (constraints_dep, props) in zip(ctx.attrs.names, zip(ctx.attrs.constraints, ctx.attrs.properties)):
        platforms.append(ExecutionPlatformInfo(
            # Named after the abstract platform it realizes, not after this
            # target: the name keys the configuration of every exec dep (the
            # toolchain) and so appears in their output paths and in every
            # command that reads them. A repository mounting komira declares
            # its own execution platform; naming both after
            # `komira//tools/build/platforms:<name>` keeps its action keys
            # equal to a standalone checkout's.
            label = constraints_dep.label.raw_target(),
            configuration = constraints_dep[PlatformInfo].configuration,
            executor_config = CommandExecutorConfig(
                local_enabled = False,
                remote_enabled = True,
                remote_execution_properties = props,
                remote_execution_use_case = "buck2-default",
                remote_cache_enabled = True,
                allow_cache_uploads = False,
                use_limited_hybrid = False,
            ),
        ))
    return [DefaultInfo(), ExecutionPlatformRegistrationInfo(platforms = platforms)]

def _local_platforms_impl(ctx):
    platforms = []
    for constraints_dep in ctx.attrs.constraints:
        platforms.append(ExecutionPlatformInfo(
            # Same label and configuration as the remote platform realizing the
            # same abstract configuration (see _remote_platforms_impl).
            label = constraints_dep.label.raw_target(),
            configuration = constraints_dep[PlatformInfo].configuration,
            executor_config = CommandExecutorConfig(
                local_enabled = True,
                remote_enabled = False,
                use_limited_hybrid = False,
            ),
        ))
    return [DefaultInfo(), ExecutionPlatformRegistrationInfo(platforms = platforms)]

local_execution_platforms = rule(
    impl = _local_platforms_impl,
    attrs = {
        "constraints": attrs.list(attrs.dep(providers = [PlatformInfo])),
    },
)

remote_execution_platforms = rule(
    impl = _remote_platforms_impl,
    attrs = {
        "constraints": attrs.list(attrs.dep(providers = [PlatformInfo])),
        "names": attrs.list(attrs.string()),
        "properties": attrs.list(attrs.dict(attrs.string(), attrs.string())),
    },
)

# Registration order matters: a target that states no execution constraint
# gets the first platform, so `exec-mojo` comes first (an unconstrained action
# lands on a worker able to run anything komira runs). Mojo targets state
# `mojo_compile` + `numa_single` through their toolchain; toolchain unpack and
# copy targets state `light`.
#
# The macOS arm64 platform comes LAST: a platform added later must never become
# the first match of an action that states no os. (Every komira target states
# its os through its toolchain; the order keeps it so for anything that does
# not.)
_EXEC_PLATFORMS = [
    ("mojo_compile", "komira//tools/build/platforms:exec-mojo"),
    ("light", "komira//tools/build/platforms:exec-light"),
    ("mojo_compile_multi_numa", "komira//tools/build/platforms:exec-mojo-multi-numa"),
    ("mojo_compile_darwin", "komira//tools/build/platforms:exec-mojo-darwin-arm64"),
]

# `[komira_re]` key of the macOS arm64 execution platform's property set: the
# exact REAPI properties its workers advertise (e.g. `pool=macos`), like
# every other set.
DARWIN_PROPERTIES_KEY = "darwin_mojo_compile_properties"

# `[komira_re]` key naming the macOS hosts those workers run on: the value
# tools/build/mojo/darwin/host_identity.sh prints on each (the SDK version,
# then a digest of the developer dir, the SDK version and build, the cc and
# ld builds, and the OS build), separated by spaces.
#
# Those are the host's, not inputs of the action, so they must reach the
# action key some other way. The workers advertise no property that tells
# them apart (a worker's property set is its operator's; a pool of macOS
# hosts is typically one set), so the key cannot come from the platform. The
# macOS toolchain writes this list into every compile's inputs instead, and
# the compile refuses (exit 2) a host whose identity is not in it. A cached
# result is therefore keyed on the SET of hosts: it was built by one of
# them, which one is not part of the key. To key on one host, give each its
# own worker property and property set.
DARWIN_HOSTS_KEY = "darwin_macos_hosts"

def darwin_macos_hosts():
    """The host identities the root cell names for its macOS workers, sorted.

    Read from the ROOT cell's config, where the execution platforms are
    configured (`.buckconfig.local` belongs to the root cell only).
    """
    return sorted([h for h in read_root_config("komira_re", DARWIN_HOSTS_KEY, "").split(" ") if h])

def darwin_properties_refusal(props, hosts):
    """Why a macOS property set cannot be registered, or None.

    `props` is the property dict of the macOS execution platform, `hosts` the
    host identities the toolchain accepts (`darwin_macos_hosts()`). Without
    hosts every compile would refuse its worker, and a property set naming no
    property would match any worker.
    """
    if not props:
        return "`mojo_compile_darwin` must name at least one worker property; got {}".format(props)
    if not hosts:
        return ("`mojo_compile_darwin` is set ({}), but `[komira_re] {}` of the root cell names no " +
                "macOS host. Set it to what tools/build/mojo/darwin/host_identity.sh prints on each " +
                "worker, separated by spaces.").format(props, DARWIN_HOSTS_KEY)
    for h in hosts:
        if "-" not in h or h.startswith("-") or h.endswith("-"):
            return "`[komira_re] {}`: `{}` is not a host identity (<sdk version>-<digest>)".format(DARWIN_HOSTS_KEY, h)
    return None

def komira_execution_platforms(name, light, mojo_compile, mojo_compile_multi_numa = None, mojo_compile_darwin = None, visibility = None):
    """Registers komira's execution platforms, given their worker property sets.

    Each argument is the exact REAPI platform property dict of the workers that
    realize that configuration. `mojo_compile_multi_numa` is optional: when it
    is None no platform provides `numa_multi`, and a target that requires it
    fails to configure ("no compatible execution platform") instead of running
    on a single-NUMA worker. Give it only for workers that span more than one
    NUMA node. `mojo_compile_darwin` is optional too: macOS arm64 workers
    that build darwin-arm64 targets; it needs the root cell's
    `[komira_re] darwin_macos_hosts` (see DARWIN_HOSTS_KEY), and without it
    no darwin-arm64 Mojo target can configure.
    """
    if mojo_compile_multi_numa != None and mojo_compile_multi_numa == mojo_compile:
        # The same property set routes to the same workers: a numa_multi run
        # would land on the single-NUMA pool. (The run itself also refuses a
        # worker it finds with fewer nodes; this catches the mistake at load.)
        fail("komira_execution_platforms: `mojo_compile_multi_numa` must name workers " +
             "spanning more than one NUMA node, but it equals `mojo_compile` ({})".format(mojo_compile))
    if mojo_compile_darwin != None:
        # A macOS action must never match a linux worker, nor the reverse.
        if mojo_compile_darwin in (light, mojo_compile, mojo_compile_multi_numa):
            fail("komira_execution_platforms: `mojo_compile_darwin` must name macOS workers, " +
                 "but it equals a linux property set ({})".format(mojo_compile_darwin))
        refusal = darwin_properties_refusal(mojo_compile_darwin, darwin_macos_hosts())
        if refusal:
            fail("komira_execution_platforms: " + refusal)
    props = {
        "light": light,
        "mojo_compile": mojo_compile,
        "mojo_compile_darwin": mojo_compile_darwin,
        "mojo_compile_multi_numa": mojo_compile_multi_numa,
    }
    names = []
    constraints = []
    properties = []
    for key, platform in _EXEC_PLATFORMS:
        if props[key] == None:
            if key in ("mojo_compile_multi_numa", "mojo_compile_darwin"):
                continue
            fail("komira_execution_platforms: `{}` is required".format(key))
        names.append(key)
        constraints.append(platform)
        properties.append(props[key])
    remote_execution_platforms(
        name = name,
        names = names,
        constraints = constraints,
        properties = properties,
        visibility = visibility,
    )

# The abstract configurations a local host realizes, in registration order
# (the first is the default of an action that states no constraint; see
# _EXEC_PLATFORMS). Not `exec-mojo-multi-numa`: nothing here knows how many
# NUMA nodes the host has, and a target requiring more than one must fail to
# configure rather than run on a host that may have one. Not
# `exec-mojo-darwin-arm64`: every toolchain action is a linux x86_64 binary.
_LOCAL_EXEC_PLATFORMS = [
    "komira//tools/build/platforms:exec-mojo",
    "komira//tools/build/platforms:exec-light",
]

def local_host_refusal():
    """Why this host cannot run komira's actions locally, or None."""
    host = host_info()
    if host.os.is_linux and host.arch.is_x86_64:
        return None
    return ("local execution runs the pinned linux x86_64 toolchain on this machine, " +
            "which is not Linux x86_64. Use a remote-execution service: copy " +
            ".buckconfig.local.example to .buckconfig.local and fill it in " +
            "(DEVELOPMENT.md, step 3).")

def komira_local_execution_platforms(name, visibility = None):
    """Registers komira's execution platforms on this machine.

    Every action runs locally. Fails on a host that is not Linux x86_64.
    """
    refusal = local_host_refusal()
    if refusal:
        fail("komira_local_execution_platforms: " + refusal)
    local_execution_platforms(
        name = name,
        constraints = _LOCAL_EXEC_PLATFORMS,
        visibility = visibility,
    )

# `[komira] execution`: `auto` (the default) runs remotely when `[komira_re]`
# names a worker property set, refuses when `[buck2_re_client]` names a
# service but `[komira_re]` does not, and runs locally when neither is set;
# `local` and `remote` force one. `-c komira.execution=local` builds one command locally
# in a checkout configured for a remote service.
EXECUTION_MODES = ("auto", "local", "remote")

# The `[komira_re]` keys whose presence opts a checkout into remote execution.
# Any one of them does: the two required sets then fail, naming the missing
# one, instead of a partly filled-in section building on this machine.
_REMOTE_KEYS = (
    "light_properties",
    "mojo_compile_properties",
    "mojo_compile_multi_numa_properties",
    DARWIN_PROPERTIES_KEY,
    DARWIN_HOSTS_KEY,
)

# The `[buck2_re_client]` keys that name a remote-execution service. A
# checkout that names one but no `[komira_re]` worker property set was meant
# to build remotely; `auto` refuses it rather than building on this machine.
# `address` is buck2's fallback for the other three, so it names a service on
# its own.
_RE_CLIENT_KEYS = ("address", "engine_address", "cas_address", "action_cache_address")

def execution_mode():
    """`local` or `remote`: where a standalone checkout's actions run."""
    mode = read_config("komira", "execution", "auto").strip() or "auto"
    if mode not in EXECUTION_MODES:
        fail("`[komira] execution`: expected one of {}, got `{}`".format(EXECUTION_MODES, mode))
    if mode != "auto":
        return mode
    for key in _REMOTE_KEYS:
        if read_config("komira_re", key, "").strip():
            return "remote"
    named = [k for k in _RE_CLIENT_KEYS if read_config("buck2_re_client", k, "").strip()]
    if named:
        fail(("`[buck2_re_client] {}` names a remote-execution service, but `[komira_re]` " +
              "names no worker property set ({}), so it is not clear whether to build here " +
              "or there. Set `[komira_re] light_properties` and `mojo_compile_properties` " +
              "to build remotely (.buckconfig.local.example), or pass " +
              "`-c komira.execution=local` to build on this machine.").format(
            named[0],
            ", ".join(_REMOTE_KEYS[:2]),
        ))
    return "local"

def komira_default_execution_platforms(name, visibility = None):
    """Local execution platforms, or remote ones when `.buckconfig.local` names workers.

    See `execution_mode`. Remote mode registers exactly what
    `komira_execution_platforms` registers from `[komira_re]`.
    """
    if execution_mode() == "local":
        komira_local_execution_platforms(name = name, visibility = visibility)
        return
    komira_execution_platforms(
        name = name,
        light = re_properties("light_properties"),
        mojo_compile = re_properties("mojo_compile_properties"),
        mojo_compile_multi_numa = re_properties("mojo_compile_multi_numa_properties", required = False),
        mojo_compile_darwin = re_properties(DARWIN_PROPERTIES_KEY, required = False),
        visibility = visibility,
    )

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
komira_default_execution_platforms = declares_docs(komira_default_execution_platforms)
