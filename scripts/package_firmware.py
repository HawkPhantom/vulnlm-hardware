#!/usr/bin/env python3
"""Package already-accepted Vivado outputs; never flashes/loads a board."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--vivado-dir', type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT/'build/firmware')
    args = p.parse_args()
    source, out = args.vivado_dir.resolve(), args.output.resolve()
    required = ['kv260_secx.bit', 'kv260_secx.xsa', 'tool-manifest.txt',
                'timing-summary.rpt', 'utilization.rpt', 'drc.rpt', 'accepted.json']
    for name in required:
        if not (source/name).is_file():
            p.error(f'Missing accepted build artifact: {source/name}')
    if json.loads((source/'accepted.json').read_text()).get('status') != 'vivado_implemented':
        p.error('Vivado acceptance marker is invalid')
    if out.exists(): p.error('Output exists; use a new package directory')
    for tool in ['bootgen', 'dtc']:
        if not shutil.which(tool): p.error(f'{tool} is required on the build host')
    out.mkdir(parents=True)
    for name in required: shutil.copy2(source/name, out/name)
    (out/'image.bif').write_text('all:\n{\n  kv260_secx.bit\n}\n')
    subprocess.run(['bootgen','-arch','zynqmp','-image','image.bif',
                    '-process_bitstream','bin'], cwd=out, check=True)
    if not (out/'kv260_secx.bit.bin').is_file(): raise SystemExit('bootgen output missing')
    subprocess.run(['dtc','-@','-I','dts','-O','dtb','-o',str(out/'kv260-secx.dtbo'),
                    str(ROOT/'linux/kv260-secx.dtso')], check=True)
    manifest = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(out.iterdir()) if path.is_file()}
    (out/'sha256.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(f'Packaged: {out}; no board was programmed')

if __name__ == '__main__': main()
