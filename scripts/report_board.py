#!/usr/bin/env python3
"""Summarize board records; keep failed/missed runs and do not invent AXI counts."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path

def percentile(values, fraction):
    return sorted(values)[max(0,math.ceil(fraction*len(values))-1)] if values else None

def summarize(directory):
    manifest=json.loads((directory/'manifest.json').read_text())
    info=json.loads((directory/'device.json').read_text())
    steps={s.get('record_file'):s for s in manifest['steps']}
    normal=[]; groups=defaultdict(list); failed=[]
    for path in sorted(directory.glob('*.jsonl')):
        for index,line in enumerate(path.read_text().splitlines(),1):
            if not line.strip(): continue
            try:
                row=json.loads(line)
                if row['status'] not in (0,-110) or row['guard_errors']:
                    failed.append({'file':path.name,'line':index,'record':row}); continue
                if not (row['submit_ns'] > 0 and row['release_ns'] >= max(row['tx_done_ns'],row['rx_done_ns']) >= row['submit_ns']):
                    raise ValueError('Invalid completion/release timeline')
                if row['kind']=='hardware_run':
                    if row['status']==0 and steps.get(path.name,{}).get('returncode')==0:
                        normal.append((row['release_ns']-row['submit_ns'])/1e6)
                    else: failed.append({'file':path.name,'line':index,'record':row})
                elif row['kind']=='hardware_E1_private_scratch' and row['policy'] in (0,1,2):
                    if row['policy']==2 and row['window_hit'] and row['handoff_ns'] < max(row['tx_done_ns'],row['rx_done_ns']):
                        raise ValueError('P2 released before DMA completion')
                    groups[row['policy']].append(row)
                else: raise ValueError('Unknown record kind/policy')
            except (ValueError,KeyError) as error:
                failed.append({'file':path.name,'line':index,'error':str(error)})
    summary={'scope':'board_records_summary','device':info,
        'collector_completed':'completed_utc' in manifest,
        'nonzero_or_incomplete_steps':[s for s in manifest['steps'] if s['returncode']!=0],
        'failed_or_invalid_records':failed,'successful_normal_records':len(normal),
        'normal_transfer_latency_ms':{f'p{int(f*100)}':percentile(normal,f) for f in (.5,.95,.99)},
        'policies':[],
        'limitations':['Latency is submit-to-release, excluding queueing and CPU reference; includes normal follow-ups.',
                       'No fixed-arrival-rate throughput, hardware AXI trace count or attack/confidentiality rate is inferred.']}
    for policy,records in sorted(groups.items()):
        usable=[r for r in records if r['window_hit'] and r['status']==-110]
        summary['policies'].append({'policy':policy,'records':len(records),'usable_windows':len(usable),
            'missed_windows':len(records)-len(usable),
            'observed_changed_bytes':sum(r['changed_bytes'] for r in usable),
            'observed_a_words':sum(r['late_a_words'] for r in usable),
            'mock_bad_responses':sum(r['mock_bad_response'] for r in usable)})
    return summary

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',type=Path); args=p.parse_args()
    summary=summarize(args.directory)
    (args.directory/'analysis.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))

if __name__=='__main__': main()
