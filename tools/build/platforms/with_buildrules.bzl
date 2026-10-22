"""One more execution platform, for the buildrules rules, after komira's.

`[build] execution_platforms` names one target (komira//tools/build/platforms/default:default), so
the platform buildrules' rules need is registered by wrapping komira's registration, not by a
second setting.

buildrules' rules say `exec_compatible_with = [buildrules//platforms:linux, :x86_64]`. Komira's
linux execution platform carries komira's own constraints, so it does not match them and komira's
targets are placed exactly as before (its platform stays first, with the same label,
configuration and action keys). The platform added here has buildrules' configuration
(buildrules//platforms:linux_x86_64) and the executor of komira's linux platform: the same
worker property set, or the same local execution, whichever komira's registration chose.
"""

def _impl(ctx):
    base = ctx.attrs.base[ExecutionPlatformRegistrationInfo].platforms
    if len(base) == 0 or not str(base[0].label).endswith("platforms:linux-x86_64"):
        fail("{}: the first platform of {} must be komira's linux-x86_64, got {}".format(
            ctx.label,
            ctx.attrs.base.label,
            [str(p.label) for p in base],
        ))
    linux = base[0]
    extra = [
        ExecutionPlatformInfo(
            label = p.label.raw_target(),
            configuration = p[PlatformInfo].configuration,
            executor_config = linux.executor_config,
        )
        for p in ctx.attrs.extra
    ]
    return [DefaultInfo(), ExecutionPlatformRegistrationInfo(platforms = base + extra)]

execution_platforms_plus = rule(
    impl = _impl,
    attrs = {
        "base": attrs.dep(providers = [ExecutionPlatformRegistrationInfo]),
        "extra": attrs.list(attrs.dep(providers = [PlatformInfo])),
    },
)
