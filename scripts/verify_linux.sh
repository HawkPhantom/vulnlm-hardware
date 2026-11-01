#!/bin/sh
set -eu
# Run in the disposable Linux verification container with /src read-only.
mkdir -p /work/src /out
cp -R /src/sw /work/src/
cd /work/src/sw/user
make clean
make test
./kv260ctl info >/out/no-device.stdout 2>/out/no-device.stderr && exit 1
cd /work/src/sw/kernel
kv_headers=$(find /usr/src -maxdepth 1 -type d -name 'linux-headers-*-arm64' | sort -V | tail -n 1)
test -n "$kv_headers"
make KDIR="$kv_headers" W=1 KCFLAGS=-Werror
cp kv260_lab.ko /out/kv260_lab-verification.ko
cc -std=c11 -Wall -Wextra -Werror -I/src/sw/include /src/tests/fixtures/web_abi.c -o /work/web-abi
/work/web-abi > /out/web-abi.json
PYTHONPATH=/src python3 - <<'PY'
import ctypes as C
import json
from web.hardware import Info, Run, GET_INFO, RUN, OP_CAPTURE, CAP_CAPTURE, OP_E2, OP_RECOVERY_TEST, CAP_E2, CAP_RECOVERY
expected={'info_size':C.sizeof(Info),'run_size':C.sizeof(Run),
          'input_offset':Run.input_ptr.offset,'status_offset':Run.status.offset,
          'submit_offset':Run.submit_ns.offset,'get_info':GET_INFO,'run':RUN,
          'capture_op':OP_CAPTURE,'capture_cap':CAP_CAPTURE,'recovery_offset':Run.recovery_flags.offset,
          'e2_op':OP_E2,'recovery_op':OP_RECOVERY_TEST,'e2_cap':CAP_E2,'recovery_cap':CAP_RECOVERY}
with open('/out/web-abi.json') as f:
    assert json.load(f)==expected
print('PASS Python/C ioctl ABI on real ARM64 Linux headers')
PY
dtc -@ -I dts -O dtb -o /out/base.dtb /src/tests/fixtures/base.dts
dtc -@ -I dts -O dtb -o /out/kv260-secx.dtbo /src/linux/kv260-secx.dtso
fdtoverlay -i /out/base.dtb -o /out/merged.dtb /out/kv260-secx.dtbo
test "$(fdtget -t x /out/merged.dtb /fpga-region/matvec@a0010000 reg)" = "0 a0010000 0 1000"
test "$(fdtget -t i /out/merged.dtb /fpga-region/dma@a0000000 xlnx,addrwidth)" = "40"
test "$(fdtget -t i /out/merged.dtb /fpga-region/dma@a0000000/dma-channel-mm2s interrupts)" = "0 89 4"
test "$(fdtget -t i /out/merged.dtb /fpga-region/dma@a0000000/dma-channel-s2mm interrupts)" = "0 90 4"
cd /src
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
printf 'PASS real ARM64 kernel module build and overlay merge (fixture, no board)\n'
{
    cat /etc/os-release
    cc --version | head -n 1
    printf 'headers=%s\n' "$kv_headers"
    dtc --version
    sha256sum /src/sw/kernel/kv260_lab.c /src/sw/include/*.h /src/linux/kv260-secx.dtso
} > /out/verification-manifest.txt
