# komira_deploy_fault -- the deploy-fault raise protocol shared by raisers and reconcilers.
from komira_deploy_fault.deploy_fault import (
    PERMANENT_FAULT_PREFIX,
    fault_is_permanent,
    mark_permanent_fault,
    IN_FLIGHT_FAULT_MARKER,
    fault_is_in_flight,
    mark_in_flight_fault,
)
