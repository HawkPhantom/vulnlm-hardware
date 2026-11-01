#!/usr/bin/env python3
"""Real KV260 automatic-reset and E2 acceptance run. No fixture backend."""
import argparse
from datetime import datetime, timezone
import errno
import hashlib
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from web.hardware import Hardware, fields, CAP_RECOVERY, CAP_E2
from web.product import DEFAULT_A, encode_frame, reference_words, verify_transfer, validate_request, execute

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device',default='/dev/kv260-lab')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--trials',type=int,default=3)
    args=parser.parse_args()
    if not 1<=args.trials<=10000: parser.error('trials must be 1..10000')
    if args.output.exists(): parser.error('Use a new output directory')
    args.output.mkdir(parents=True,mode=0o700)
    manifest={'scope':'real_device_recovery_and_e2','started_utc':datetime.now(timezone.utc).isoformat(),
              'completed':False,'steps':[]}
    def save(name,value):
        path=args.output/name;path.write_text(json.dumps(value,indent=2)+'\n');path.chmod(0o600)
        manifest['steps'].append(name)
        mp=args.output/'manifest.json';mp.write_text(json.dumps(manifest,indent=2)+'\n');mp.chmod(0o600)
    try:
        with Hardware(args.device) as hw:
            info=fields(hw.info);save('device.json',info)
            if info['state'] or not info['lab_enabled'] or (info['capabilities']&6) != (CAP_RECOVERY|CAP_E2):
                raise RuntimeError('Matching FPGA, lab mode, recovery and E2 capabilities required')
            frame=encode_frame(DEFAULT_A,info['rows'],info['cols'])
            expected=reference_words(DEFAULT_A,info['rows'])
            baseline=hw.run(frame,job_id=0x1000,generation=1)
            save('baseline.json',baseline);verify_transfer(baseline,expected)
            previous_count=baseline['metadata']['recovery_count']
            for trial in range(args.trials):
                # >42 s programmed delay at 100 MHz, aborted after 20 ms.
                aborted=hw.run(frame,job_id=0x2000+trial,generation=2,
                               delay_cycles=0xffffffff,timeout_ms=20,recovery_test=True)
                save(f'reset_{trial}.json',aborted)
                m=aborted['metadata']
                if (m['status']!=-errno.ETIMEDOUT or m['recovery_flags']!=1 or m['guard_errors'] or
                    m['window_hit'] or not m['timed_out'] or
                    not m['release_ns']>=max(m['tx_done_ns'],m['rx_done_ns'])>=m['submit_ns']>0 or
                    m['recovery_count']!=((previous_count+1)&0xffffffff)):
                    raise RuntimeError('Automatic reset/drain evidence failed')
                previous_count=m['recovery_count']
                followup=hw.run(frame,job_id=0x3000+trial,generation=3)
                save(f'reset_followup_{trial}.json',followup);verify_transfer(followup,expected)
        for trial in range(args.trials):
            for policy in (0,1,2):
                request=validate_request({'a':DEFAULT_A,'b':{'label':'Part B','surface':70,
                    'dimension':55,'temperature':40,'vibration':30},'scenario':'e2',
                    'policy':policy,'delay_cycles':5000000,'timeout_ms':20})
                result=execute(request,args.device,lambda *event:None)
                save(f'e2_{trial}_P{policy}.json',result)
                if not result['window_observed']: raise RuntimeError('E2 window missed; retain evidence and retune')
                if (result['wrong_product_decision']!=(policy==0) or
                    result['wrong_request_association']!=(policy==0) or
                    result['delivered_b']['source']!=('late_a_dma' if policy==0 else 'own_b_dma')):
                    raise RuntimeError('E2 product association check failed')
        manifest['completed']=True;manifest['completed_utc']=datetime.now(timezone.utc).isoformat()
        save('acceptance.json',{'passed':True,'reset_trials':args.trials,'e2_trials':3*args.trials})
        manifest['files']={p.name:hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in sorted(args.output.glob('*.json')) if p.name!='manifest.json'}
        (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print(f'PASS real-device recovery/E2 evidence saved: {args.output}')
    except (OSError,ValueError,RuntimeError) as error:
        manifest['error']=str(error);save('failure.json',{'error':str(error)})
        raise SystemExit(str(error))

if __name__=='__main__': main()
