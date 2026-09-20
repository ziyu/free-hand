#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash Scripts/build.sh "$@" --install
