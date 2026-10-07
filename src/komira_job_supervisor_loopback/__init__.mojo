"""`komira_job_supervisor_loopback`: test-only. komira_job_supervisor's run
loop against a stateful heartbeat receiver served by komira_http_server, over
127.0.0.1, in one build action.

  HeartbeatReceiver   a `RequestDispatcher` that decodes each
                      komira.job_report.v1 `JobHeartbeat`, keeps one run's
                      state (ASSIGNED, RUNNING, CANCELLING, then COMPLETED,
                      FAILED or CANCELLED), records every violation of that
                      machine, and answers with a `JobHeartbeatReply`.
  serve_while         steps a `DispatchServeLoop` on one thread while a
                      `ClientLeg` (a supervisor run) runs on another.
"""

from .heartbeat_receiver import (
    BEAT_PATH,
    CHILDREN_EXITED,
    CHILDREN_NONE,
    CHILDREN_NOT_PROBED,
    CHILDREN_PROBE_FAILED,
    CHILDREN_RUNNING,
    HeartbeatReceiver,
    RECEIVER_ASSIGNED,
    RECEIVER_CANCELLED,
    RECEIVER_CANCELLING,
    RECEIVER_COMPLETED,
    RECEIVER_FAILED,
    RECEIVER_RUNNING,
    REPLY_REFUSED,
    children_name,
    receiver_state_name,
)
from .duet import ClientLeg, DispatchServeLoop, serve_while
