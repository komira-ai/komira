"""Execution platforms: local by default, remote when `.buckconfig.local` asks.

There is one execution platform per (os, cpu), one row of the platform table
(table.bzl) each: `linux-x86_64`, and `darwin-arm64` when macOS workers are
configured. A row komira reserves (`linux-arm64`) registers none. Each is registered under the label, and
with the configuration, of the target platform of the same name in
//tools/build/platforms, so a tool built to run in an action is configured
exactly like a target built for that OS. Nothing here says which worker of a
remote service runs an action: that is the service's choice, made from the
one property set of the platform.

- `komira_local_execution_platforms`: every action runs on this machine.
  No service, no property set. The one row that matches this host, so a Linux
  x86_64 machine registers `linux-x86_64`; a host with no registered row is
  refused, naming why.
- `komira_execution_platforms`: every action runs remotely, on workers whose
  property set is read from `.buckconfig.local`
  (`[komira_re] linux_x86_64_properties = key=value,...`, and
  `darwin_arm64_properties` for macOS), so that no service address or worker
  property is committed.
- `komira_default_execution_platforms`: the first when `[komira_re]` names no
  worker property set, the second when it does. A standalone checkout
  registers this one (//tools/build/platforms/default).

Both kinds register the same labels and configurations, so a target's
configuration, its output paths and the commands of its actions are the same
whichever kind runs them. Only the executor differs, and a remote action's
digest (command, inputs, property set) is the one a remote-only checkout
computes.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load(
    "@komira//tools/build/platforms:table.bzl",
    "PLATFORMS",
    "constraints",
    "host_refusal",
    "host_row",
    "label",
    "registered_names",
    "reserved_names",
    "row",
)

# The constraints of each platform's execution platform, for
# `exec_compatible_with` of a target whose actions run a binary built for that
# platform (every toolchain action runs linux x86_64 binaries today, including
# the unpacking of the macOS toolchain, which only moves bytes). Read from the
# platform table (table.bzl), the one place a platform is stated.
LINUX_X86_64 = constraints("linux-x86_64")

DARWIN_ARM64 = constraints("darwin-arm64")

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
            # Named after the platform whose configuration it uses, not after
            # this target: the configuration keys every exec dep (the
            # toolchain), so it appears in their output paths and in every
            # command that reads them. A repository mounting komira declares
            # its own execution platforms; naming both after
            # `komira//tools/build/platforms:<os>-<cpu>` keeps its action keys
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
            # Same label and configuration as the remote platform of the same
            # OS (see _remote_platforms_impl).
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

def _host_refused_impl(ctx):
    fail("{}: {}".format(ctx.label, ctx.attrs.message))

host_refused = rule(
    impl = _host_refused_impl,
    doc = "The default target platform of a host no registered row matches: analysing it, which is what a build stating no --target-platforms does, fails with `message`.",
    attrs = {"message": attrs.string()},
)

def komira_host_platform(name, visibility = None):
    """Declares `name`, the target platform of the machine running buck2.

    The detector (`[parser] target_platform_detector_spec` in .buckconfig)
    names it, so a build that states no `--target-platforms` builds for the
    client's own platform: the row of table.bzl whose `host` matches
    `host_info()`. It is an alias of that row's platform, so the platform's
    label, configuration and output paths are the row's own (a Linux x86_64
    client's are the pinned `linux-x86_64` ones). It only SELECTS a row: it
    supplies no tool, path or flag. A host no registered row matches gets a
    target that fails to analyse, naming why (host_refusal), so that stating
    `--target-platforms` still works from such a machine.
    """
    host = host_info()
    matched = host_row(host)
    if matched == None:
        host_refused(name = name, message = host_refusal(host), visibility = visibility)
    else:
        native.alias(name = name, actual = ":" + matched, visibility = visibility)

komira_host_platform = declares_docs(komira_host_platform)

# Registration order matters: a target that states no execution constraint
# gets the first platform, so linux comes first. The macOS arm64 platform
# comes LAST: a platform added later must never become the first match of an
# action that states no os. (Every komira target states its os through its
# toolchain; the order keeps it so for anything that does not.)
_LINUX_PLATFORM = label("linux-x86_64")
_DARWIN_PLATFORM = label("darwin-arm64")

# `[komira_re]` key of the linux execution platform's property set: the exact
# REAPI properties the service routes every linux action by. The table row
# names it (`re_key`); the value is the client's, never committed.
LINUX_PROPERTIES_KEY = row("linux-x86_64")["re_key"]

# `[komira_re]` key of the macOS arm64 execution platform's property set: the
# exact REAPI properties its workers advertise (e.g. `pool=macos`).
DARWIN_PROPERTIES_KEY = row("darwin-arm64")["re_key"]

# Keys of a platform komira reserves a row for but does not build for yet
# (the `registered = False` rows of table.bzl). Setting one is refused,
# naming the reason, rather than read as configuration for nothing.
_RESERVED_KEYS = {PLATFORMS[n]["re_key"]: n for n in reserved_names()}

# Keys of earlier layouts: one that split linux actions by worker class and
# NUMA placement, and the two that named a platform by its OS alone
# (`linux_properties`, `darwin_properties`) before there was one key per
# (os, cpu). A `.buckconfig.local` still naming one is refused, naming the key
# that replaces it, rather than read as half a configuration.
_RETIRED_KEYS = {
    "darwin_mojo_compile_properties": DARWIN_PROPERTIES_KEY,
    "darwin_properties": DARWIN_PROPERTIES_KEY,
    "light_properties": LINUX_PROPERTIES_KEY,
    "linux_properties": LINUX_PROPERTIES_KEY,
    "mojo_compile_multi_numa_properties": None,
    "mojo_compile_properties": LINUX_PROPERTIES_KEY,
}

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
        return "`darwin` must name at least one worker property; got {}".format(props)
    if not hosts:
        return ("`darwin` is set ({}), but `[komira_re] {}` of the root cell names no " +
                "macOS host. Set it to what tools/build/mojo/darwin/host_identity.sh prints on each " +
                "worker, separated by spaces.").format(props, DARWIN_HOSTS_KEY)
    for h in hosts:
        if "-" not in h or h.startswith("-") or h.endswith("-"):
            return "`[komira_re] {}`: `{}` is not a host identity (<sdk version>-<digest>)".format(DARWIN_HOSTS_KEY, h)
    return None

def komira_execution_platforms(name, linux = None, darwin = None, visibility = None):
    """Registers komira's remote execution platforms, given their worker property sets.

    `linux` is the exact REAPI platform property dict every linux x86_64
    action carries; the service picks the worker. `darwin` is the property
    dict of the macOS arm64 workers that build darwin-arm64 targets; it needs
    the root cell's `[komira_re] darwin_macos_hosts` (see DARWIN_HOSTS_KEY),
    and without it no darwin-arm64 Mojo target can configure. Each is
    optional (a platform without a property set is not registered, so its
    actions cannot run remotely), but at least one is required.
    """
    if linux != None and not linux:
        fail("komira_execution_platforms: `linux` must name at least one worker property; got {}".format(linux))
    if linux == None and darwin == None:
        fail("komira_execution_platforms: name the worker property set of at least one platform (`linux` or `darwin`)")
    names = []
    constraints = []
    properties = []
    if linux != None:
        names.append("linux")
        constraints.append(_LINUX_PLATFORM)
        properties.append(linux)
    if darwin != None:
        # A macOS action must never match a linux worker, nor the reverse.
        if darwin == linux:
            fail("komira_execution_platforms: `darwin` must name macOS workers, " +
                 "but it equals the linux property set ({})".format(darwin))
        refusal = darwin_properties_refusal(darwin, darwin_macos_hosts())
        if refusal:
            fail("komira_execution_platforms: " + refusal)
        names.append("darwin")
        constraints.append(_DARWIN_PLATFORM)
        properties.append(darwin)
    remote_execution_platforms(
        name = name,
        names = names,
        constraints = constraints,
        properties = properties,
        visibility = visibility,
    )

def komira_local_execution_platforms(name, visibility = None):
    """Registers komira's execution platform on this machine: the row of the platform table that matches the host.

    Every action runs locally. Fails when no row matches this host (a
    machine komira has no platform for, or one it has reserved a row for but
    does not build for yet), naming the reason; the way out is a
    remote-execution service, which names the platform to build for.
    """
    host = host_info()
    matched = host_row(host)
    if matched == None:
        fail("komira_local_execution_platforms: " + host_refusal(host) +
             " Local execution runs this machine's own platform, so copy " +
             ".buckconfig.local.example to .buckconfig.local and fill it in (DEVELOPMENT.md, step 3).")
    local_execution_platforms(
        name = name,
        constraints = [label(matched)],
        visibility = visibility,
    )

# `[komira] execution`: `auto` (the default) decides by the platform a build
# defaults to, which is this client's own (`platforms:host`). When `[komira_re]`
# names a worker property set for that platform, actions run remotely on it;
# when it does not, they run on this machine, even if it names another
# platform's set (that set is read only by a build that states
# `--target-platforms` for that platform: a client with only another platform's
# set never sends host-platform work to the wrong pool, and never fails because
# of it). A client whose host matches no registered row cannot run locally, so
# any property set selects remote there. `auto` also refuses when
# `[buck2_re_client]` names a service but `[komira_re]` names no property set at
# all. `local` and `remote` force one; `-c komira.execution=local` builds one
# command locally in a checkout configured for a remote service.
EXECUTION_MODES = ("auto", "local", "remote")

# The `[komira_re]` keys that name a platform's worker property set: one per
# registered row of the platform table.
_REMOTE_KEYS = tuple([PLATFORMS[n]["re_key"] for n in registered_names()])

def _set_keys():
    return [k for k in _REMOTE_KEYS if read_config("komira_re", k, "").strip()]

# The `[buck2_re_client]` keys that name a remote-execution service. A
# checkout that names one but no `[komira_re]` worker property set was meant
# to build remotely; `auto` refuses it rather than building on this machine.
# `address` is buck2's fallback for the other three, so it names a service on
# its own.
_RE_CLIENT_KEYS = ("address", "engine_address", "cas_address", "action_cache_address")

def _refuse_retired_keys():
    for old in sorted(_RETIRED_KEYS):
        if read_config("komira_re", old, "").strip():
            new = _RETIRED_KEYS[old]
            fail(("`[komira_re] {}` is no longer read: komira registers one execution platform " +
                  "per (os, cpu) and says nothing about worker classes or NUMA placement. {}").format(
                old,
                "Rename it to `{}` (one property set for every action of that platform).".format(new) if new else "Delete it.",
            ))
    for key in sorted(_RESERVED_KEYS):
        if read_config("komira_re", key, "").strip():
            fail(("`[komira_re] {}` is reserved for the {} platform, which komira declares " +
                  "(tools/build/platforms/table.bzl) but does not build for yet, so no execution " +
                  "platform reads it. Delete it.").format(key, _RESERVED_KEYS[key]))

def _host_key():
    """The `[komira_re]` key of this client's own platform (the linux one on a host no row matches)."""
    name = host_row(host_info())
    return PLATFORMS[name]["re_key"] if name != None else LINUX_PROPERTIES_KEY

def execution_mode():
    """`local` or `remote`: where a standalone checkout's actions run."""
    _refuse_retired_keys()
    mode = read_config("komira", "execution", "auto").strip() or "auto"
    if mode not in EXECUTION_MODES:
        fail("`[komira] execution`: expected one of {}, got `{}`".format(EXECUTION_MODES, mode))
    if mode != "auto":
        return mode
    host_name = host_row(host_info())
    set_keys = _set_keys()
    if host_name == None and set_keys:
        # No row runs here, so nothing can run locally: a set names the
        # service that builds for a platform stated with --target-platforms.
        return "remote"
    if host_name != None and PLATFORMS[host_name]["re_key"] in set_keys:
        return "remote"
    if set_keys:
        # Another platform's set only: this client's own platform builds here.
        return "local"
    named = [k for k in _RE_CLIENT_KEYS if read_config("buck2_re_client", k, "").strip()]
    if named:
        fail(("`[buck2_re_client] {}` names a remote-execution service, but `[komira_re]` " +
              "names no worker property set ({}), so it is not clear whether to build here " +
              "or there. Set `[komira_re] {}` to build remotely (.buckconfig.local.example), " +
              "or pass `-c komira.execution=local` to build on this machine.").format(
            named[0],
            ", ".join(_REMOTE_KEYS),
            _host_key(),
        ))
    return "local"

def _remote_properties(key):
    """The property set of `[komira_re] <key>`, or None; remote mode requires this client's own platform's."""
    props = re_properties(key, required = False)
    if props or key != _host_key():
        return props
    fail(("remote execution is selected (`[komira] execution = remote`, or a `[komira_re]` " +
          "key is set; check `buck2 audit config komira` for the file it comes from, " +
          "such as a ~/.buckconfig.d file), but `[komira_re] {}` " +
          "is not set (it is the key of this client's own platform). Set it (.buckconfig.local.example), or build on " +
          "this machine with `-c komira.execution=local`.").format(key))

def komira_default_execution_platforms(name, visibility = None):
    """Local execution platforms, or remote ones when `.buckconfig.local` names workers.

    See `execution_mode`. Remote mode registers exactly what
    `komira_execution_platforms` registers from `[komira_re]`: the property
    set of every platform that names one, and it requires this client's own
    platform's.
    """
    if execution_mode() == "local":
        komira_local_execution_platforms(name = name, visibility = visibility)
        return
    komira_execution_platforms(
        name = name,
        linux = _remote_properties(LINUX_PROPERTIES_KEY),
        darwin = _remote_properties(DARWIN_PROPERTIES_KEY),
        visibility = visibility,
    )

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
komira_default_execution_platforms = declares_docs(komira_default_execution_platforms)
