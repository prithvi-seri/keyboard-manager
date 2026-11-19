#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Apply Keyboard Mappings
# @raycast.mode fullOutput
# @raycast.packageName Keyboard Manager
# @raycast.description Apply Right Command mapping after Raycast Hyper Key is ready
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
exec "$project_dir/build/keyboard-manager" --apply
