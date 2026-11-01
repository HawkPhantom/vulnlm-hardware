"""Linux ioctl bridge to this repository's real DMAengine driver."""
import ctypes as C
import fcntl
import os
import stat
import struct
import sys

ABI = 1
OP_RUN, OP_CAPTURE = 0, 2
CAP_CAPTURE = 1

class Info(C.Structure):
    _fields_ = [(key, C.c_uint32) for key in (
        'abi','rows','cols','input_bytes','output_bytes','state','lab_enabled','capabilities')]

class Run(C.Structure):
    _fields_ = ([(key,C.c_uint32) for key in (
        'abi','op','policy','job_id','generation','delay_cycles','timeout_ms','reserved')]
        + [('input_ptr',C.c_uint64),('output_ptr',C.c_uint64),
           ('input_bytes',C.c_uint32),('output_bytes',C.c_uint32),('status',C.c_int32)]
        + [(key,C.c_uint32) for key in (
            'timed_out','window_hit','changed_bytes','late_a_words','mock_bad_response',
            'old_completion_rejected','guard_errors')]
        + [('reserved_out',C.c_uint32*2)]
        + [(key,C.c_uint64) for key in (
            'submit_ns','timeout_ns','handoff_ns','tx_done_ns','rx_done_ns','release_ns',
            'core_cycles','stall_cycles')])

assert C.sizeof(Info)==32 and C.sizeof(Run)==160 and Run.status.offset==56
GET_INFO = (2 << 30) | (C.sizeof(Info) << 16) | (ord('K') << 8)
RUN = (3 << 30) | (C.sizeof(Run) << 16) | (ord('K') << 8) | 1

def fields(value):
    return {name:getattr(value,name) for name,_ in value._fields_ if name!='reserved_out'}

def ioctl_struct(fd, command, value):
    buffer=bytearray(bytes(value))
    fcntl.ioctl(fd,command,buffer,True)
    C.memmove(C.addressof(value),bytes(buffer),len(buffer))

class Hardware:
    def __init__(self, path='/dev/kv260-lab'):
        if sys.platform!='linux':
            raise OSError('Run the hardware service on the KV260 Linux system.')
        self.fd=os.open(path,os.O_RDWR|os.O_CLOEXEC)
        try:
            if not stat.S_ISCHR(os.fstat(self.fd).st_mode):
                raise OSError('The selected path is not a kernel character device.')
            self.info=Info(); ioctl_struct(self.fd,GET_INFO,self.info)
            d=self.info
            if (d.abi!=ABI or not 1<=d.rows<=4096 or not 4<=d.cols<=4096 or d.cols%4
                or d.input_bytes!=(d.rows+1)*d.cols or d.output_bytes!=d.rows*4
                or d.input_bytes>1024*1024):
                raise OSError('The device ABI or dimensions do not match this interface.')
        except BaseException:
            os.close(self.fd); raise

    def close(self): os.close(self.fd)
    def __enter__(self): return self
    def __exit__(self,*_): self.close()

    def run(self, frame, *, job_id, generation, policy=2, delay_cycles=0,
            timeout_ms=1000, capture=False):
        if len(frame)!=self.info.input_bytes: raise ValueError('Frame length mismatch')
        if capture and not self.info.capabilities & CAP_CAPTURE:
            raise OSError('The driver lacks frame capture; rebuild the module.')
        source=C.create_string_buffer(frame,len(frame))
        output=C.create_string_buffer(self.info.output_bytes)
        run=Run(abi=ABI,op=OP_CAPTURE if capture else OP_RUN,policy=policy,
                job_id=job_id,generation=generation,delay_cycles=delay_cycles,
                timeout_ms=timeout_ms,input_ptr=C.addressof(source),output_ptr=C.addressof(output),
                input_bytes=len(frame),output_bytes=len(output))
        # Buffers stay alive through the entire blocking ioctl, including drain.
        ioctl_struct(self.fd,RUN,run)
        data=fields(run)
        for key in ('input_ptr','output_ptr','reserved'): data.pop(key,None)
        words=list(struct.unpack('<'+'i'*self.info.rows,output.raw))
        return {'metadata':data,'words':words}

def device_status(path='/dev/kv260-lab'):
    try:
        with Hardware(path) as hw:
            info=fields(hw.info)
            ready=(info['state']==0 and bool(info['lab_enabled']) and
                   bool(info['capabilities'] & CAP_CAPTURE))
            if info['state']!=0: code,reason='not_ready','The device is busy, quarantined or faulted.'
            elif not info['capabilities'] & CAP_CAPTURE: code,reason='capture_required','Rebuild the driver with frame capture.'
            elif not info['lab_enabled']: code,reason='lab_disabled','Load the driver with allow_lab=1.'
            else: code,reason='ready','Real KV260 device ready.'
            return {'connected':True,'ready':ready,'reason':reason,'reason_code':code,'device':info}
    except (OSError,ValueError) as error:
        code='linux_required' if sys.platform!='linux' else 'device_unavailable'
        return {'connected':False,'ready':False,'reason':str(error),'reason_code':code,'device':None}
