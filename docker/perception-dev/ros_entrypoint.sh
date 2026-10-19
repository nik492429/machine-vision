#!/bin/bash
set -e
source /opt/ros/${ROS_DISTRO}/setup.bash
[ -f /workspace/install/setup.bash ] && source /workspace/install/setup.bash
exec "$@"
