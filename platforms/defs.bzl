"""Execution platforms. Every action runs remotely; nothing runs on the client.

The remote worker property set is read from `.buckconfig.local`
(`[komira_re] linux_x86_64_properties = key=value,...`) so that no service
address or pool name is committed.
"""

def re_properties(key):
    """Parse `[komira_re] <key>` into a dict. Fails if unset."""
    raw = read_config("komira_re", key, "")
    if not raw.strip():
        fail("`[komira_re] {}` is not set. Copy .buckconfig.local.example to " +
             ".buckconfig.local and fill in your remote-execution worker properties.".format(key))
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
            label = ctx.label.raw_target(),
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

remote_execution_platforms = rule(
    impl = _remote_platforms_impl,
    attrs = {
        "constraints": attrs.list(attrs.dep(providers = [PlatformInfo])),
        "names": attrs.list(attrs.string()),
        "properties": attrs.list(attrs.dict(attrs.string(), attrs.string())),
    },
)
