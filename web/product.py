"""A transparent linear quality-gate scenario using the existing INT8 core.
This is an illustrative product workflow, not a trained industrial model.
Every hardware result must originate from an ioctl; CPU values are references.
"""
import errno
import hashlib
import secrets
import struct
from .hardware import Hardware, fields

FEATURES=('surface','dimension','temperature','vibration')
WEIGHTS=(4,3,2,1)
THRESHOLD=700
DEFAULT_A={'label':'Previous part A','surface':5,'dimension':4,'temperature':6,'vibration':8}

def validate_request(data):
    if not isinstance(data,dict): raise ValueError('The request must be a JSON object.')
    if set(data)-{'a','b','policy','delay_cycles','timeout_ms'}: raise ValueError('Unknown request field.')
    result={}
    for name in ('a','b'):
        item=data.get(name)
        if not isinstance(item,dict) or set(item)!={'label',*FEATURES}:
            raise ValueError(f'{name.upper()} requires a label and four deviation measurements.')
        if not isinstance(item['label'],str) or not 1<=len(item['label'].strip())<=60:
            raise ValueError('Part labels must contain 1–60 characters.')
        for key in FEATURES:
            if type(item[key]) is not int or not 0<=item[key]<=100:
                raise ValueError('Deviation measurements must be integers between 0 and 100.')
        result[name]=dict(item,label=item['label'].strip())
    policy=data.get('policy')
    if type(policy) is not int or policy not in (0,1,2): raise ValueError('Select a valid service policy.')
    result['policy']=policy
    for key,default,low,high in [('delay_cycles',50000000,1,200000000),('timeout_ms',20,1,5000)]:
        value=data.get(key,default)
        if type(value) is not int or not low<=value<=high: raise ValueError(f'{key} is out of range.')
        result[key]=value
    return result

def encode_frame(item,rows,cols):
    if rows<1 or cols<4: raise ValueError('Core shape too small')
    vector=bytes([100-item[key] for key in FEATURES])+bytes(cols-4)
    weights=bytes(WEIGHTS)+bytes(cols-4)
    # Row zero is the score; remaining rows are zero and independently checked.
    return vector+weights+bytes((rows-1)*cols)

def reference_words(item,rows):
    return [sum(w*(100-item[k]) for k,w in zip(FEATURES,WEIGHTS))]+[0]*(rows-1)

def decision(score): return 'accept' if score>=THRESHOLD else 'reject'

def verify_transfer(transfer,expected, *, allow_timeout=False):
    m=transfer['metadata']
    if m['status'] not in ((0,-errno.ETIMEDOUT) if allow_timeout else (0,)):
        raise RuntimeError(f"Hardware job failed: {m['status']}")
    if m['guard_errors']: raise RuntimeError('The buffer guard pattern was corrupted.')
    if transfer['words']!=expected:
        raise RuntimeError('The raw hardware output did not match the CPU reference; no product decision was produced.')
    if not (m['submit_ns']>0 and m['release_ns']>=max(m['tx_done_ns'],m['rx_done_ns'])>=m['submit_ns']):
        raise RuntimeError('The hardware completion record is invalid.')

def fingerprint(transfer):
    payload=b''.join(struct.pack('<i',word) for word in transfer['words'])
    transfer['dma_sha256']=hashlib.sha256(payload).hexdigest()
    return transfer

def execute(request, device_path, emit):
    """Called only in the isolated real-device worker, never the web thread."""
    with Hardware(device_path) as hw:
        info=fields(hw.info)
        if info['state']!=0 or not info['lab_enabled'] or not info['capabilities']&1:
            raise RuntimeError('The device is not ready or frame capture is not enabled.')
        rows,cols=info['rows'],info['cols']
        a,b=request['a'],request['b']; policy=request['policy']
        a_frame=encode_frame(a,rows,cols); b_frame=encode_frame(b,rows,cols)
        expected_a=reference_words(a,rows); expected_b=reference_words(b,rows)
        job=secrets.randbelow(0x7ffffffe)+1
        emit('baseline','B was submitted for an independent hardware control calculation.')
        control=hw.run(b_frame,job_id=job,generation=1)
        verify_transfer(control,expected_b); fingerprint(control)
        emit('capture','A is delayed on the core; the driver observes timeout and buffer ownership.')
        late=hw.run(a_frame,job_id=job+1,generation=2,policy=policy,
                    delay_cycles=request['delay_cycles'],timeout_ms=request['timeout_ms'],capture=True)
        verify_transfer(late,expected_a,allow_timeout=True); fingerprint(late)
        m=late['metadata']
        window=bool(m['timed_out'] and m['window_hit'] and m['status']==-errno.ETIMEDOUT)
        # The deadline might already have passed while the callback raced;
        # no handoff -> no claim of reproducing the product-level fault.
        if window and (not m['handoff_ns'] or
            (policy<2 and not m['handoff_ns']<m['rx_done_ns']) or
            (policy==2 and m['handoff_ns']<max(m['tx_done_ns'],m['rx_done_ns']))):
            window=False
        delivered=None; actual_b=None
        if window and policy==0:
            # Deliberately vulnerable SERVICE PATH: return real A DMA bytes as
            # B's product result. No score is changed or invented by the UI.
            delivered={'score':late['words'][0],'source_job_id':m['job_id'],
                       'source':'late_a_dma','decision':decision(late['words'][0])}
            emit('misdelivery','The vulnerable service delivered A’s late hardware output as B’s reply.')
        elif window:
            emit('protected','A was rejected as B’s reply; B is now executing on the core.')
            actual_b=hw.run(b_frame,job_id=job+2,generation=3)
            verify_transfer(actual_b,expected_b); fingerprint(actual_b)
            delivered={'score':actual_b['words'][0],'source_job_id':actual_b['metadata']['job_id'],
                       'source':'own_b_dma','decision':decision(actual_b['words'][0])}
        mismatch=delivered is not None and delivered['score']!=expected_b[0]
        flip=delivered is not None and delivered['decision']!=decision(expected_b[0])
        return {'evidence':'real_device_ioctl','request':request,'device':info,
            'threshold':THRESHOLD,'reference_b':{'score':expected_b[0],'decision':decision(expected_b[0])},
            'control_b':control,'capture_a':late,'actual_b':actual_b,'delivered_b':delivered,
            'window_observed':window,'wrong_output':mismatch,'wrong_product_decision':flip,
            'wrong_request_association':bool(window and policy==0),
            'a_frame_sha256':hashlib.sha256(a_frame).hexdigest(),
            'b_frame_sha256':hashlib.sha256(b_frame).hexdigest(),
            'scope':'controlled_fault_injection_on_custom_accelerator_and_service',
            'note':'This flow demonstrates a lifecycle bug in the custom test service; it is not a disclosed AMD product vulnerability.'}
