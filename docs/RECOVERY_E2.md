# Automatic reset recovery and real-device E2

This revision adds the compute reset/drain supervisor, the driver's automatic recovery path, a real-device E2 receiver-rearm operation, an E1/E2 selector in VulnLM Hardware, and a board acceptance runner. Source code and local checks are supplied; physical KV260 execution and Vivado implementation still require the board/tool environment.

## Install the matching revision

Rebuild the FPGA image with `hw/create_project.tcl` and install the matching driver using [the system guide](SISTEM_KURULUMU.md). RTL VERSION is now `0x00010001`; older images are rejected by the driver. The new `rtl/matvec_recovery.sv` file must be included in custom project flows. No additional board pin or reset-controller device tree entry is needed: recovery lives between the compute core and the existing DMA streams, with control through the existing AXI-Lite window.

On a clean matching FPGA/Linux setup, the module's first load can use:

```sh
sudo insmod sw/kernel/kv260_lab.ko allow_lab=1 recovery_grace_ms=2000
sudo sh web/run_on_board.sh --port 8080
```

Select **E2 · Stale stream / receiver rearm** to run E2 from the interface. Ordinary RUN requests use automatic recovery without enabling lab operations. E1/E2 and recovery acceptance injection require `allow_lab=1` and `CAP_SYS_RAWIO`.

## Recovery ordering

1. A normal RUN timeout issues ABORT_DRAIN. E1/E2 wait an extra `recovery_grace_ms` (1–60000 ms; default 2000) so the intended late-result experiment can finish before recovery.
2. The supervisor holds **compute only** in reset. AXI-Lite, AXI DMA, its descriptors and the DDR interconnect remain active.
3. It consumes the remaining fixed-size input packet and supplies the remaining output words as padding. A previously asserted output beat under backpressure is saved with its data/keep/last and remains unchanged until accepted.
4. The driver waits for both DMA callbacks, synchronizes them, checks successful cookie/result/residue and guard patterns, and requires the supervisor's drained status.
5. Only then does it issue RELEASE, verify that the reset count advanced and the core is idle, and admit another job. The aborted call returns `-ETIMEDOUT`, `recovery_flags=1` and `recovery_count`. Padding is never returned as a successful inference or diagnostic product result.

Local reset does not imply that DDR writes have completed. If the memory fabric or DMA itself cannot finish the drain, the driver retains memory and blocks reuse. A hardware bus failure can therefore still need controlled system recovery; this feature does not claim to repair an unresponsive AXI/DDR fabric. It also does not retry an aborted product request silently.

## Real-device E2 sequence

The board operation uses actual DMAengine transfers and the custom core:

1. Set RECEIVE_HOLD while idle, submit A through MM2S and leave S2MM unarmed. A holds its first output valid upstream of the gate; no output beat reaches the DMA. The gate is necessary because [AMD documents that an unconfigured S2MM can accept four stream beats](https://docs.amd.com/r/en-US/pg021_axi_dma/Typical-System-Interconnect).
2. After timeout, verify TX completion, a held output and zero output handshakes. Synchronize TX and terminate the **idle, unarmed** receive channel through DMAengine before preparing its new receive descriptor.
3. Under P0/P1 the receive destination is logically owned by B while the stream source remains A. Arm S2MM, then clear RECEIVE_HOLD; A's actual untagged stream reaches that destination. P0 delivers that result as B. P1 uses the known A source identity to reject it, then runs B independently.
4. P2 retains A's ownership until its output drains, then executes B independently. All policies verify raw words against independent references and check guard bytes.

This is the **receiver-rearm variant** of E2. It demonstrates stale payload crossing a newly assigned receive boundary. It does not reset an active DMA memory master or claim to validate such a reset. The original simulation's receiver-only reset remains a separate model experiment. Source identity comes from the controlled job and core terminal records; a descriptor label alone does not authenticate an untagged payload.

If A does not reach the held-output window within the observation interval, automatic abort/drain recovery discards that trial. It is not reported as an E2 reproduction. The core is checked as idle after a completed recovery.

## Board acceptance

Run from the repository on the board after installing the matching design and lab-enabled driver:

```sh
sudo python3 scripts/run_recovery_suite.py \
  --output results/board/recovery-e2-run1 --trials 3
```

Use a fresh output directory for every run. The runner:

- Verifies a real hardware baseline against the CPU reference.
- Programs an approximately 43-second compute delay, requests a 20 ms timeout and requires automatic drain/reset evidence, an incrementing reset count and intact guards.
- Immediately runs a fresh hardware calculation and checks every output word.
- Runs all three E2 policies, requiring an observed window, a wrong P0 product decision and correct P1/P2 delivery from B's own DMA job.
- Saves each raw result before checking acceptance, keeps failures and writes success only after all gates pass. It has no fixture or simulated-device option.

At 100 MHz the delay is a programmed setting, not a measured duration. JSON contains submission, timeout, completion and release times; callback timestamps describe software observation rather than physical DDR write edges. An observation hang does not grant permission to unload the driver or free DMA-owned memory.

## Register and ABI additions

| Offset | Register | Meaning |
| --- | --- | --- |
| `0x098` | RECOVERY | Write 1: ABORT_DRAIN; write 2: RELEASE after drain; read zero |
| `0x09c` | RECOVERY_STATUS | Bit 0: compute reset/drain active; bit 1: stream packets drained |
| `0x0a0` | RECOVERY_COUNT | Completed releases, 32-bit wrapping counter |
| `0x0a4` | FEATURES | Bit 0: recovery supervisor; bit 1: receive-hold gate (value 3) |
| `0x0a8` | STREAM_STATE | Bit 0: source output pending; bit 1: input packet consumed; bit 2: output packet accepted |
| `0x0ac` | STREAM_OUTPUT | Number of output beats accepted for this job |
| `0x0b0` | RECEIVE_HOLD | 1 holds output upstream of DMA; may be set only while idle; 0 releases it |

New operation 3 is E2; operation 4 is the lab recovery acceptance injection. Info capabilities are capture=1, recovery=2 and E2=4. Existing ioctl sizes remain info=32 and run=160 bytes; recovery flags/count occupy the former reserved result words at offsets 88/92. The stream's reset permission is distinct from DMA memory reuse permission: only the serialized driver issues RELEASE after successful DMA drain.

## Verification boundaries

[Current local verification](../results/recovery/RAPOR.md) records RTL aborts during partial input, computation, long delay, held output, partial output and input fault, with correct fresh jobs after each reset. Host tests check E2 policy dispatch, unsupported-feature refusal and discarded recovery output; ARM64 Linux builds check the actual kernel module and C/Python ABI. These are local results, not physical-board acceptance.

The driver keeps DMA ownership under the [Linux DMAengine client contract](https://docs.kernel.org/driver-api/dmaengine/client.html). It deliberately avoids a global hardware reset under pending memory operations; AMD's [AXI DMA reset requirements](https://docs.amd.com/r/en-US/pg021_axi_dma/Resets) apply separately to system reset.
