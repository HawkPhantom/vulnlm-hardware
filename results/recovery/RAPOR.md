# Recovery and E2 — local verification

Date: **1 November 2026**. This revision implements automatic compute reset with stream drain, a source-hold gate and real-device E2 receiver rearm. It includes a physical-board acceptance runner. **No KV260 run or Vivado implementation was performed.**

| Check | Result | Evidence |
| --- | --- | --- |
| Full RTL matrix, four shapes | PASS; 22 PASS lines | [RTL log](rtl-tests.log) |
| Recovery supervisor | PASS; 24 abort trials and 24 fresh jobs with different input/output values | [RTL log](rtl-tests.log) |
| E2 source gate | PASS; four shapes, source held even with downstream TREADY high, source identity retained across staged B settings | [RTL log](rtl-tests.log) |
| E1 reuse model | PASS; 36 runs | [E1 report](../reuse/RAPOR.md) |
| Original E2 receiver-reset model | PASS; 12 runs | [RTL log](rtl-tests.log) |
| macOS C self-test and Python tests | PASS; 32 Python tests | [Host log](host-tests.log) |
| JavaScript syntax and DOM contract | PASS; 3 tests | [Host log](host-tests.log) |
| ARM64 Linux module, W=1, KCFLAGS=-Werror | PASS; real Linux 6.12.113+deb13 headers | [Linux log](linux-tests.log), [manifest](linux-manifest.txt) |
| ARM64 C/Python ioctl ABI and Python tests | PASS; unchanged structure sizes, new offsets/operations checked; 32 Python tests | [ABI record](web-abi.json), [Linux log](linux-tests.log) |
| Device tree fixture compilation and merge | PASS | [Linux log](linux-tests.log) |
| Browser | E1/E2 selector switches title/description; execution remains disabled without hardware | Manual local browser check |
| Physical KV260, actual DMA reset/drain and E2 reproduction | **Not run** | Run the supplied board acceptance suite |
| Vivado synthesis, implementation and timing | **Not run** | Requires development tools |

Recovery RTL trials cover partial input, computation, long programmed delay, held output, partial output where the shape permits it, and malformed input. They check output packet length/TLAST, held-beat stability across abort, rejected premature release/new START, retained reset while software models a completion wait, count advancement and a correct fresh job whose values differ from A. The 1-row shape uses held output for the partial-output case. The supervisor tests use stream endpoints; the modeled wait is not an actual DDR transaction or kernel callback test.

The real-device E2 implementation is a receiver-**rearm** experiment. The source-hold gate prevents pre-arming S2MM from accepting early beats. Once the idle receive path is prepared and assigned, the driver opens the gate while source A remains active. P0 delivers actual A DMA bytes as B; P1 rejects A using controlled source identity and executes B; P2 retains A ownership through drain and executes B. This does not validate resetting an active DMA memory master. The original receiver-reset simulation remains separately labeled.

Unit fixtures exercise E2 dispatch and all three product policies, missing capability rejection, ioctl operation encoding, recovery-output discard and the acceptance runner's failure gates. Fixtures are restricted to tests. Their passing results do not establish that the board has recovered or reproduced E2.

The driver resets compute and drains the existing packets without resetting AXI DMA or the DDR interconnect. It releases reset only after successful DMA callback/cookie/residue/guard and supervisor checks. An unresponsive memory fabric still retains its buffers; no global bus recovery is claimed. Aborted output is never a product result.

The README now uses the user's supplied wide screenshot. The two former previews have been replaced/removed. This is an interface illustration with hardware offline, not an observed vulnerable board result.

Reproduce local checks with `make test-matrix`, `make host-test`, `make ui-test` and `make linux-test`. Follow [the recovery/E2 guide](../../docs/RECOVERY_E2.md) to build the matching FPGA/driver and run `scripts/run_recovery_suite.py` on the board. [Source and artifact fingerprints](summary.json) identify this verified revision. Earlier system/interface reports remain historical snapshots.
