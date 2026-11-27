#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin
export HOME=/home/pengwin
exec /usr/bin/make -C /home/pengwin/repos/HyperQwen up-batch
