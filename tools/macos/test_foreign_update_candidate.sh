#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/../.." && pwd)"
# The former global-state fixture is preserved in the local checkpoint commit.
# Current production isolates state by canonical installation path. Reuse its
# regression so this legacy entry point exercises the supported protocol.
exec bash "$source_root/tools/macos/test_installation_update_state.sh"
