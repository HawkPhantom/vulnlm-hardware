# VulnLM Hardware

VulnLM Hardware is Cyberdes's local hardware security lab for the AMD Kria KV260. It demonstrates how a delayed result assigned to the wrong request can change a product decision. This repository supplies the custom accelerator, driver, service and browser interface. The experiment deliberately introduces a lifecycle fault in our own system; it does not establish a vulnerability in an AMD product.

The interface opens in English and offers EN/TR switching. A selected language is remembered in that browser. The workspace adapts from three columns on wide screens to stacked panels on smaller screens.

## Prepare the board

Complete the FPGA, matching Linux image, DMA configuration and device tree steps in [the system guide](SISTEM_KURULUMU.md). The runtime requires Python 3.9 or later and its standard library. Node.js is only needed for development tests.

Build this revision's driver against the **running board kernel**, using that kernel's configuration, headers and Module.symvers. The generic ARM64 module from local verification is not a deployment binary for an arbitrary AMD kernel.

On the board, after a fresh, matching FPGA image is active and before loading the module:

```sh
make -C sw/kernel KDIR=/lib/modules/$(uname -r)/build
sudo insmod sw/kernel/kv260_lab.ko allow_lab=1
sudo sh web/run_on_board.sh --port 8080
```

The driver requires a clean initial core state. Do not unload/rebind a used driver to enable the lab option; follow the controlled restart/reload procedure in the system guide. An active transfer must finish before changing the FPGA or removing the driver.

The launcher checks `/dev/kv260-lab`, readiness, lab enablement and capture capability. The service uses `CAP_SYS_RAWIO`; the command above runs it as root for this isolated experiment. It listens only on `127.0.0.1`, uses a per-process request token and checks browser Origin/Host. It is a local lab service, not a public deployment.

From the Mac, forward the board's loopback port through SSH (replace the login and host):

```sh
ssh -N -L 8080:127.0.0.1:8080 your-user@kv260-host
```

Open <http://127.0.0.1:8080/> on the Mac. Stop any existing local preview on port 8080 first, or choose a different local forwarded port. For appearance-only development, `make ui` starts a local preview; without the real Linux device, execution stays disabled and no result is supplied.

## Run the experiment

Enter a part name and four deviation measurements for request B. Each measurement is an integer from 0 (ideal) to 100. The previous request A and timing settings can be expanded on the left.

The intentionally simple rule is:

```text
score = 4 × (100 − surface) + 3 × (100 − dimension)
      + 2 × (100 − temperature) + 1 × (100 − vibration)
accept when score ≥ 700; otherwise reject
```

This is an illustrative quality gate, not a trained industrial model or a language model. Its vector and weights are encoded into the existing INT8 matrix/vector core; unused entries and rows are zero. All returned INT32 words are checked independently against the CPU reference.

Default A measurements (5, 4, 6, 8) have a reference score of **948**, while default B measurements (70, 55, 40, 30) have a reference score of **445**. These are arithmetic expectations, **not measurements from a board**. They make a wrong association visible: A would pass the gate, B would fail.

| Policy | Hardware and service behaviour |
| --- | --- |
| P0 — Vulnerable service | Reassign the private output buffer logically before A drains. After a verified late completion, return A's actual DMA word as B's product result. |
| P1 — Identity check | Reassign early but reject A as B's reply. Record any buffer changes, then execute B as a new real hardware job. |
| P2 — Protected service | Wait for A to drain before assigning B. Execute B as a new real hardware job. |

Each request first runs B independently on the real accelerator as a control. It then submits delayed A through the diagnostic capture operation and checks the returned words, guard patterns, completion metadata and ownership timestamps. Only an observed timeout/handoff window permits a product-level result. A missed window remains visible without a manufactured wrong answer. A corrupted capture or failed control produces an error instead of a product decision.

The default requested delay is 50 million cycles (about 500 ms at the design's 100 MHz), with a 20 ms observation deadline. These settings do not guarantee reproduction on a board. Callback timing and the observed window determine whether a trial counts.

## Trace the real output

`web/hardware.py` opens the Linux character device and uses the C-compatible ioctl ABI. `web/product.py` supplies real input frames and implements the deliberately vulnerable reply association. The frontend displays that service result; it never substitutes a CPU score for a hardware result. There is no simulator, replay-file or random-result runtime backend.

`KV_OP_CAPTURE=2` and `KV_CAP_CAPTURE=1` are required. The info structure remains 32 bytes and the run structure 160 bytes; the former reserved info word advertises capture support. An old driver without that capability is refused. Capture returns A-tagged diagnostic bytes only after DMA drains, including on an observed timeout. Normal RUN still rejects late output. P0/P1 exercise a private kernel-owned lab buffer, not arbitrary physical addresses or another process's memory.

The evidence panel distinguishes the requested B, actual source job, hardware control, delivered score, product decision, raw A output and DMA hashes. A different score, a changed decision and a wrong request association are separate outcomes. JSON downloads preserve nanosecond timestamps as decimal strings, avoiding JavaScript precision loss.

Records are stored under `results/board-ui/` with directory mode 0700 and file mode 0600. They contain submitted measurements and hardware metadata; this runtime folder is excluded from version control. Only one hardware worker runs at a time.

## Failure behaviour and remaining validation

Missing hardware, wrong ABI, disabled lab mode or a non-ready device prevents execution. An ioctl runs in a separate process so the HTTP server remains responsive. If DMA never drains, that worker and the device remain occupied; the service does not kill the worker and free DMA-owned memory. Proven reset recovery is not implemented. Follow the system guide's controlled recovery procedure rather than unloading an active module.

Local compilation, ABI, service, browser-contract and offline browser checks are recorded in [the interface report](../results/interface/RAPOR.md). Unit fixtures test response handling; they are not card measurements. Vivado synthesis/implementation and physical KV260 execution still need to be performed on the user's equipment.

Development checks:

```sh
make host-test
make ui-test
make linux-test
```

## Design attribution

The navy/cyan palette and workspace structure were adapted from [Cyberdes VulnLM](https://github.com/cyberdes-security/vulnlm), reference commit `a4334f8a58cdba7480795a9986ce6c3894182c5e`. Its [BSD 3-Clause notice](licenses/VulnLM-BSD-3-Clause.txt) is retained. The supplied Cyberdes logo is copied unchanged to `web/static/assets/cyberdes-logo.png` (SHA-256 `a023a0952d1af7942dd6dfdeaaf92b2a9b314bab1cf6654c6b78203d4a755e3f`).
