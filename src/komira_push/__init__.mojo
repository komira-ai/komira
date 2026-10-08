"""`komira_push`: the caller side of a notify service, and the content-blind
wake.

Modules:
  - wake.mojo          : `WakeTrigger` {id, kind, source}, its plaintext, and
                         the payload-shape guard (`check_wake_fields`,
                         `check_wake_payload`).
  - notify_port.mojo   : the `NotifyPort` trait, its outcomes, the request
                         shape rules and strict parsers, `NoopNotify` and the
                         `RecordingNotify` test double.
  - remote_notify.mojo : `RemoteNotifyPort`, the notify wire over an
                         `HttpTransport` (docs/design/notify_wire.md).
  - device_proxy.mojo  : `register_device_for`, the application route that
                         registers its user's device with notify.

No public signature takes or returns a pointer.
"""

from .wake import (
    WAKE_FIELD_ID,
    WAKE_FIELD_KIND,
    WAKE_FIELD_SOURCE,
    WakeTrigger,
    check_wake_fields,
    check_wake_payload,
    check_wake_trigger_shape,
)
from .notify_port import (
    NIL_UUID,
    NOT_CONFIGURED,
    NoopNotify,
    NotifyOutcome,
    NotifyPort,
    RecordingNotify,
    RegisterOutcome,
    check_device_subscription,
    check_notify_request,
    check_principal_ref,
    check_register_device,
    parse_device_subscription,
    parse_notify_request,
    parse_register_device,
)
from .remote_notify import (
    DEVICES_PATH,
    DEVICE_REGISTERED,
    NOTIFY_ACCEPTED,
    NOTIFY_PATH,
    RemoteNotifyPort,
    check_notify_base_url,
)
from .device_proxy import ProxyReply, error_body, register_device_for
