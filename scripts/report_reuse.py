#!/usr/bin/env python3
"""Validate and summarize controlled E1 simulation records; standard library only."""
from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import datetime
import hashlib
import json
from pathlib import Path
from statistics import mean
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "rtl/axis_int8_matvec.sv", "rtl/matvec_axil_ctrl.sv", "rtl/kv260_matvec.sv",
    "sim/axil_master_bfm.sv", "sim/axil_signals.svh",
    "sim/models/s2mm_write_model.sv", "sim/models/axi_write_ram_model.sv",
    "sim/models/axi_write_checker.sv", "sim/models/axi_write_signals.svh",
    "sim/tb_dma_buffer_reuse.sv", "sim/tb_dma_models.sv",
]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(record: dict) -> None:
    rows, cols = record["rows"], record["cols"]
    assert rows >= 1 and cols >= 4 and cols % 4 == 0, record
    assert record["guard_violations"] == 0 and record["normal_followup_ok"] == 1, record
    assert record["core_done_before_dma_done"] == 1, record
    assert record["core_irq_cycle"] < record["dma_done_cycle"], record
    assert record["first_a_commit_cycle"] > record["timeout_cycle"], record
    policy = record["policy"]
    assert policy in ("P0", "P1", "P2"), record
    if policy == "P2":
        assert record["cross_owner_writes"] == record["cross_owner_bytes"] == 0, record
        assert record["reuse_cycle"] >= record["dma_done_cycle"], record
        assert record["quarantine_cycles"] == record["reuse_cycle"] - record["timeout_cycle"], record
        assert record["quarantine_cycles"] > 0 and record["changed_b_bytes"] == 0, record
    else:
        assert record["cross_owner_writes"] == rows, record
        assert record["cross_owner_bytes"] == 4 * rows, record
        assert 0 < record["changed_b_bytes"] <= 4 * rows, record
        assert record["reuse_cycle"] < record["first_a_commit_cycle"], record
        assert record["quarantine_cycles"] == 0, record
    if policy == "P0":
        assert record["mock_bad_b_response"] == 1, record
        assert record["a_payload_bytes_returned_to_b"] == 4 * rows, record
        assert record["old_completion_rejected"] == 0, record
    else:
        assert record["mock_bad_b_response"] == record["a_payload_bytes_returned_to_b"] == 0, record
        assert record["old_completion_rejected"] == 1, record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", nargs="+", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "results/reuse")
    parser.add_argument("--version-file", type=Path)
    args = parser.parse_args()
    records, inputs = [], []
    latest_source = max((ROOT / source).stat().st_mtime_ns for source in SOURCES)
    for path in args.inputs:
        path = path.resolve()
        if path.stat().st_mtime_ns < latest_source:
            raise SystemExit(f"Source changed after {path.name}; rerun the simulation first.")
        file_records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        if not file_records:
            raise SystemExit(f"Empty experiment input: {path}")
        for record in file_records:
            validate(record)
        records.extend(file_records)
        inputs.append({"path": str(path.relative_to(ROOT)), "sha256": digest(path)})

    matched = defaultdict(dict)
    groups = defaultdict(list)
    for record in records:
        key = (record["rows"], record["cols"], record["seed"], record["trial"])
        if record["policy"] in matched[key]:
            raise SystemExit(f"Duplicate experiment record: {key}, {record['policy']}")
        matched[key][record["policy"]] = record
        groups[(record["rows"], record["cols"], record["policy"])].append(record)
    for key, policies in matched.items():
        if set(policies) != {"P0", "P1", "P2"}:
            raise SystemExit(f"Unmatched policy conditions: {key}")
        # Fault and response delays must be identical for paired policies.
        for field in ("write_delay", "response_delay"):
            if len({row[field] for row in policies.values()}) != 1:
                raise SystemExit(f"Unpaired {field}: {key}")
        # Absolute cycle indices differ between cases; compare relative timing.
        for field in ("first_a_commit_cycle", "dma_done_cycle", "core_irq_cycle"):
            if len({row[field] - row["timeout_cycle"] for row in policies.values()}) != 1:
                raise SystemExit(f"Policy changed the injected A timing: {field}, {key}")

    summaries = []
    for (rows, cols, policy), samples in sorted(groups.items()):
        holds = [sample["quarantine_cycles"] for sample in samples]
        summaries.append({
            "rows": rows, "cols": cols, "policy": policy, "cases": len(samples),
            "cross_owner_writes_total": sum(s["cross_owner_writes"] for s in samples),
            "cross_owner_bytes_per_case": mean(s["cross_owner_bytes"] for s in samples),
            "bad_mock_responses": sum(s["mock_bad_b_response"] for s in samples),
            "a_payload_bytes_returned_total": sum(s["a_payload_bytes_returned_to_b"] for s in samples),
            "quarantine_cycles_min": min(holds), "quarantine_cycles_max": max(holds),
            "quarantine_cycles_mean": mean(holds),
            "normal_followups_passed": sum(s["normal_followup_ok"] for s in samples),
        })

    simulator = "not recorded"
    if args.version_file:
        simulator = args.version_file.read_text().splitlines()[0]
    date = datetime.now(ZoneInfo("Europe/Istanbul")).date().isoformat()
    result = {
        "schema_version": 1, "date_istanbul": date, "scope": "controlled_simulation_E1",
        "simulator": simulator, "case_count": len(records),
        "matched_conditions": len(matched), "inputs": inputs,
        "sources": [{"path": source, "sha256": digest(ROOT/source)} for source in SOURCES],
        "summary": summaries, "records": records,
        "limitations": [
            "The S2MM and RAM modules are bounded simulation models, not AMD AXI DMA or DDR.",
            "P0/P1/P2 are explicit test-harness policies, not a Linux driver or production runtime.",
            "Bad responses and returned A bytes refer to the deliberately minimal mock service.",
            "P0 follow-up is a recovery probe; it does not repair the earlier bad mock response.",
            "These selected deterministic fault cases are not independent samples of an attack rate.",
            "P2 cost includes draining, MMIO checks and harness scheduling; it is not a board benchmark.",
            "E2 leftover stream data, permanent DMA stalls, cache coherency and SMMU are not validated.",
        ],
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2)+"\n")
    lines = [
        "# E1 tampon yeniden kullanım deneyi", "", f"Tarih: {date} · {simulator}", "",
        f"**{len(records)} kontrollü koşu, {len(matched)} eşleştirilmiş zamanlama/boyut koşulu.**",
        "P0 ve P1'de A'nın gecikmiş yazıları B'ye verilmiş tamponu değiştirdi. "
        "P1 eski tamamlanmayı reddetti fakat yazıları durdurmadı. "
        "P2, bu koşullarda eski erişimler bitene kadar tamponu bekleterek çapraz yazıyı önledi.", "",
        "S2MM/RAM ve hizmet politikaları simülasyon modelidir. "
        "Sonuçlar KV260 veya AMD sürücüsünde bulunan bir açık anlamına gelmez.", "",
    ]
    dimensions = sorted({(s["rows"], s["cols"]) for s in summaries})
    for rows, cols in dimensions:
        lines += [f"## {rows} × {cols}", "",
                  "| Politika | Koşu | B belleğine A yazısı, toplam | Çapraz bayt/koşu | Yanlış örnek B yanıtı | Bekletme, çevrim |",
                  "| --- | ---: | ---: | ---: | ---: | ---: |"]
        for summary in summaries:
            if (summary["rows"], summary["cols"]) != (rows, cols):
                continue
            s = summary
            hold = f"{s['quarantine_cycles_min']}–{s['quarantine_cycles_max']}"
            lines.append(f"| {s['policy']} | {s['cases']} | {s['cross_owner_writes_total']} | "
                         f"{s['cross_owner_bytes_per_case']:g} | "
                         f"{s['bad_mock_responses']}/{s['cases']} | {hold} |")
        lines += [""]
    lines += [
        "## Ölçüm sınırları", "",
        "- Çapraz yazı, AXI adres/veri kabulünden sonraki gerçek model bellek yazma kenarında, tampon sahibiyle karşılaştırılarak sayılır.",
        "- Bellek bozulması ile örnek hizmetin yanlış yanıt kabulü ayrı alanlardır. P1'de ikinci değer sıfır olması birinciyi temizlemez.",
        "- Komşu tampon/kontrol desenleri değişmedi; bütün normal takip hesapları doğru tamamlandı.",
        "- Her koşuda çekirdek tamamlanması DMA'nın son yazma yanıtından önce gözlendi; çekirdek IRQ'su tampon serbest bırakma koşulu değildir.",
        "- Üç politika için aynı koşuldaki A zamanlaması rapor oluşturulurken yeniden eşleştirildi.",
        "- P2 bekletme süresi hesap, aktarımlar, MMIO kontrolleri ve test zamanlamasını içerir; FPGA performans ölçümü değildir.",
        "- Seçilmiş hata koşuları için başarı oranından bağımsız örneklem güven aralığı veya gerçek saldırı olasılığı çıkarılmaz.",
        "- E2, kalıcı takılma, cache tutarlılığı, SMMU, gerçek AXI DMA ve kart üzerinde doğrulama henüz kapsam dışındadır.", "",
        "Ham koşular, kaynak özetleri ve ayrıntılı metrikler [summary.json](summary.json) içinde. "
        "Zaman çizgileri `build/reuse_<ROWS>x<COLS>.trace.csv` dosyalarındadır.", "",
    ]
    (args.output_dir / "RAPOR.md").write_text("\n".join(lines))
    print(f"Validated {len(records)} cases / {len(matched)} matched conditions; report: {args.output_dir/'RAPOR.md'}")


if __name__ == "__main__":
    main()
