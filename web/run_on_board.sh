#!/bin/sh
set -eu
kv_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$kv_repo"
if [ "$(uname -s)" != Linux ]; then
    echo 'VulnLM Hardware must execute on the KV260 Linux system.' >&2
    exit 1
fi
if [ ! -c /dev/kv260-lab ]; then
    echo 'Load the matching FPGA image and capture-capable kv260_lab driver first.' >&2
    exit 1
fi
python3 - <<'PY'
from web.hardware import device_status
status=device_status()
if not status['ready']:
    raise SystemExit(status['reason'])
print('VulnLM Hardware: real device ready.')
PY
exec python3 -m web.server "$@"
