#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"
load_selected_kernel

bash "$SCRIPT_DIR/fetch_kernel_source.sh"
bash "$SCRIPT_DIR/fetch_symvers.sh"
bash "$SCRIPT_DIR/prepare_kernel.sh" --keep-config
