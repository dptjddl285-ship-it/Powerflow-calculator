import os
import sys

# Re-export from core.pandapower_engine
try:
    from core.pandapower_engine import (
        build_net_from_elements,
        render_single_line_diagram,
        run_power_flow_simulation
    )
except ImportError:
    from backend_api.core.pandapower_engine import (
        build_net_from_elements,
        render_single_line_diagram,
        run_power_flow_simulation
    )
