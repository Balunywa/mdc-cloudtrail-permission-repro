#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/deploy.sh"
"${SCRIPT_DIR}/test-access.sh" denied
"${SCRIPT_DIR}/apply-fix.sh"
"${SCRIPT_DIR}/test-access.sh" success

echo
echo "Demo complete. Resources remain deployed for inspection."
echo "Collect evidence: ${SCRIPT_DIR}/collect-evidence.sh"
echo "Remove the lab:  ${SCRIPT_DIR}/teardown.sh"

