#!/usr/bin/env python3
"""Collect real-device runs. Keeps misses/errors; never substitutes simulation."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import random
import subprocess

def capture(command, path, timeout):
    # Stream each completed record to disk. If hardware stalls, the partial
    # file and timeout marker remain; process timeout cannot revoke kernel DMA.
    # No PIPE: a stuck kernel ioctl must not leave the collector waiting for
    # communicate()/kill to reap an uninterruptible process after a deadline.
    with path.open('w') as output, path.with_suffix('.stderr').open('w') as errors:
        try:
            process = subprocess.Popen(command, stdout=output, stderr=errors,
                                       stdin=subprocess.DEVNULL, start_new_session=True)
        except OSError as error:
            return {'command':command, 'record_file':path.name, 'returncode':127, 'error':str(error)}
        try:
            returncode = process.wait(timeout=timeout)
            return {'command':command, 'record_file':path.name, 'returncode':returncode,
                    'stderr_file':path.with_suffix('.stderr').name}
        except subprocess.TimeoutExpired:
            return {'command':command, 'record_file':path.name, 'returncode':None,
                    'draining_process_pid':process.pid,
                    'error':'observation_timeout_kernel_may_still_be_draining'}

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ctl', default='./sw/user/kv260ctl')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--count', type=int, default=10000)
    p.add_argument('--seed', type=int, default=20261030)
    p.add_argument('--e1', action='store_true')
    p.add_argument('--trials', type=int, default=3)
    p.add_argument('--delay-cycles', type=int, default=50000000)
    p.add_argument('--timeout-ms', type=int, default=20)
    p.add_argument('--observation-seconds', type=int, default=600)
    args = p.parse_args()
    if min(args.count,args.seed,args.trials,args.delay_cycles,args.timeout_ms,args.observation_seconds) < 1:
        p.error('Counts, seed, delays and timeouts must be positive')
    if args.timeout_ms > 60000: p.error('timeout-ms must be <=60000')
    if args.output.exists(): p.error('Use a new output directory')
    args.output.mkdir(parents=True)
    manifest = {'scope':'real_board_requested', 'started_utc':datetime.now(timezone.utc).isoformat(),
                'host':platform.uname()._asdict(),
                'arguments':vars(args)|{'output':str(args.output)}, 'steps':[],
                'limitations':['E1 byte differences are CPU observations, not per-AXI-write trace counts.',
                               'P0/P1 use private synthetic scratch; no real cross-client confidentiality claim.',
                               'Observation timeout does not cancel DMA; do not unload/reuse the design.']}
    def run(command, name):
        result=capture(command,args.output/name,args.observation_seconds)
        manifest['steps'].append(result)
        (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        return result['returncode']
    if run([args.ctl,'info'],'device.json') != 0: raise SystemExit('Device not available; manifest retained')
    baseline=run([args.ctl,'verify',str(args.count),str(args.seed),'1000'],'normal.jsonl')
    if baseline != 0: raise SystemExit('Normal correctness gate failed; no fault experiments started')
    if args.e1:
        rng=random.Random(args.seed)
        for trial in range(args.trials):
            policies=[0,1,2]; rng.shuffle(policies)
            for policy in policies:
                rc=run([args.ctl,'e1',str(policy),str(args.delay_cycles),str(args.timeout_ms)],
                       f'e1_{trial}_P{policy}.jsonl')
                if rc not in (0,3): raise SystemExit('E1 failed/stalled; retained all records, stopping')
                if run([args.ctl,'verify','1',str(args.seed+trial+1),'1000'],
                       f'followup_{trial}_P{policy}.jsonl') != 0:
                    raise SystemExit('Follow-up correctness failed; stopping')
    manifest['files']={f.name:hashlib.sha256(f.read_bytes()).hexdigest()
                       for f in sorted(args.output.iterdir()) if f.name!='manifest.json'}
    manifest['completed_utc']=datetime.now(timezone.utc).isoformat()
    (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'Board records saved: {args.output}')

if __name__ == '__main__': main()
