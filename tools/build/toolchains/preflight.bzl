"""The DEPLOY_PROBE pre-flight (src/kci_validate/deploy_probe.mojo): its helper image's pin, and the exit contract of busybox's `nc -z`.

`preflight_image_record`: the platform table's helper image of one row as a one-line file, `image <reference>`, for
checks that hold a copy elsewhere (kci.yml's validate job) to it.

`busybox_nc_exit_contract`: a remote linux action that runs the pinned busybox binary's `nc`: a listener on a loopback
port, then `nc -z -w 1` against it must exit 0, and against a closed port (127.0.0.1:1) must exit 1. kci reads exactly
those two exits from the pre-flight container (0: the address answered; 1: nothing did); any other exit is
INDETERMINATE. The binary is the same upstream applet as the helper image's, not the image's own build.
"""

def _record_impl(ctx):
    out = ctx.actions.write(ctx.label.name + ".txt", "image {}\n".format(ctx.attrs.image))
    return [DefaultInfo(default_output = out)]

# Writes no action that runs a program: the value is the rule's attribute.
preflight_image_record = rule(
    impl = _record_impl,
    doc = "A file of one line, `image <reference>`: one row's pre-flight helper image.",
    attrs = {"image": attrs.string()},
)

# The listener is polled until the first connect succeeds (a failed connect does not use it up); a listener that
# cannot bind its port exits, and the case says so rather than reading the next refusal as the contract.
_SCRIPT = """
set -u
bb=$1 out=$2 closed=$3
port=$((20000 + $$ % 20000))
"$bb" nc -l -p "$port" > /dev/null 2>&1 < /dev/null &
srv=$!
ok= i=0
while [ "$i" -lt 30 ]; do
    "$bb" nc -z -w 1 127.0.0.1 "$port"
    rc=$?
    if [ "$rc" = 0 ]; then ok=1; break; fi
    if [ "$rc" != 1 ]; then echo "nc -z -w 1 against a listener on 127.0.0.1:$port exited $rc, neither 0 nor 1" >&2; exit 1; fi
    kill -0 "$srv" 2> /dev/null || { echo "the listener on 127.0.0.1:$port exited before any connect (the port is in use?)" >&2; exit 1; }
    i=$((i + 1))
    "$bb" sleep 1
done
[ -n "$ok" ] || { echo "nc -z -w 1 never exited 0 against a listener on 127.0.0.1:$port" >&2; exit 1; }
"$bb" nc -z -w 1 127.0.0.1 "$closed"
rc=$?
[ "$rc" = 1 ] || { echo "nc -z -w 1 against the closed port 127.0.0.1:$closed exited $rc, not 1" >&2; exit 1; }
kill "$srv" 2> /dev/null
printf 'nc -z -w 1: exit 0 against a listener, exit 1 against the closed port %s\\n' "$closed" > "$out"
"""

def _contract_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    ctx.actions.run(
        cmd_args(bb, "sh", "-c", _SCRIPT, "sh", bb, out.as_output(), str(ctx.attrs.closed_port)),
        category = "busybox_nc_exit_contract",
    )
    return [DefaultInfo(default_output = out)]

busybox_nc_exit_contract = rule(
    impl = _contract_impl,
    doc = "Fails unless the pinned busybox's `nc -z -w 1` exits 0 against a loopback listener and 1 against a closed port.",
    attrs = {
        # A loopback port nothing listens on: 1 (tcpmux) needs privilege to bind and nothing on a build worker serves it.
        "closed_port": attrs.int(default = 1),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)
