#!/usr/bin/env python3
"""Run on KV260: python3 -m web.server. Hardware-only, loopback-only API."""
import argparse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import multiprocessing as mp
import os
from pathlib import Path
from queue import Empty
import secrets
import threading
import time
from urllib.parse import urlsplit
import uuid
from .hardware import device_status
from .product import execute, validate_request

STATIC=Path(__file__).resolve().parent/'static'
ROOT=STATIC.parents[1]

def worker(request,device,channel):
    def emit(phase,message):
        channel.put({'type':'event','phase':phase,'message':message,
                     'utc':datetime.now(timezone.utc).isoformat()})
    try:
        result=execute(request,device,emit)
        channel.put({'type':'result','result':result})
    except BaseException as error:
        channel.put({'type':'error','message':f'{type(error).__name__}: {error}'})

class BusyError(Exception): pass

class Application:
    def __init__(self, device='/dev/kv260-lab', records=None):
        self.device=device
        self.records=Path(records) if records else ROOT/'results/board-ui'
        self.token=secrets.token_urlsafe(32)
        self.lock=threading.Lock(); self.jobs={}; self.process=None; self.channel=None
        self.active=None

    def drain(self):
        if self.channel is None: return
        job=self.jobs[self.active]
        def accept(event):
            if event['type']=='event':
                job['events'].append(event); job['phase']=event['phase']
            elif event['type']=='result':
                job.update(state='done',phase='done',result=event['result'])
            else: job.update(state='error',phase='error',error=event['message'])
        while True:
            try: event=self.channel.get_nowait()
            except Empty: break
            accept(event)
        if job['state']=='running' and time.monotonic()-job['_start']>10:
            job['waiting_for_hardware']=True
        if not self.process.is_alive():
            self.process.join(timeout=0)
            # Consume all queued events before deciding that a worker exited
            # without a result; a final progress event can precede the result.
            while True:
                try:
                    event=self.channel.get(timeout=.1)
                    accept(event)
                except Empty: break
            if job['state']=='running':
                job.update(state='error',phase='error',error='The hardware worker exited without returning a result.')
            if not job.get('_saved'):
                target=self.records/(self.active+'.json')
                try:
                    self.records.mkdir(parents=True,exist_ok=True,mode=0o700)
                    fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
                    with os.fdopen(fd,'w') as output:
                        json.dump(self.public(job),output,ensure_ascii=False,indent=2)
                    job['record_saved']=True
                except OSError as error:
                    job['record_saved']=False; job['record_error']=str(error)
                job['_saved']=True
            self.channel.close(); self.channel=None; self.process.close(); self.process=None

    @staticmethod
    def public(job):
        # Preserve 64-bit monotonic timestamps through JavaScript JSON parsing.
        def clean(value):
            if isinstance(value,dict):
                return {key:str(item) if key.endswith('_ns') and type(item) is int else clean(item)
                        for key,item in value.items() if not key.startswith('_')}
            if isinstance(value,list): return [clean(item) for item in value]
            return value
        return clean(job)

    def status(self):
        with self.lock:
            self.drain()
            result=device_status(self.device)
            result['busy']=self.process is not None
            if result['busy']: result['ready']=False
            result['active_job']=self.active if result['busy'] else None
            return result

    def submit(self,data):
        request=validate_request(data)
        with self.lock:
            self.drain()
            if self.process is not None: raise BusyError('The previous hardware job is still active; no new job was admitted.')
            status=device_status(self.device)
            if not status['ready']: raise OSError(status['reason'])
            context=mp.get_context('spawn')
            channel=context.Queue()
            job_id=str(uuid.uuid4())
            process=context.Process(target=worker,args=(request,self.device,channel),daemon=False)
            process.start()
            self.active=job_id; self.channel=channel; self.process=process
            self.jobs[job_id]={'id':job_id,'state':'running','phase':'starting','events':[],
                               'created_utc':datetime.now(timezone.utc).isoformat(),
                               'request':request,'_start':time.monotonic()}
            # Retain the newest requests, never discard an active one.
            while len(self.jobs)>40: self.jobs.pop(next(iter(self.jobs)))
            return self.public(self.jobs[job_id])

    def get_job(self,job_id):
        with self.lock:
            self.drain()
            if job_id not in self.jobs: raise KeyError(job_id)
            return self.public(self.jobs[job_id])

class Handler(BaseHTTPRequestHandler):
    server_version='VulnLMHardware/1.0'
    def trusted(self):
        host=self.headers.get('Host','')
        try:
            parsed=urlsplit('http://'+host)
            valid=(parsed.hostname in ('127.0.0.1','localhost') and parsed.port is not None
                   and parsed.username is None and not parsed.path and not parsed.query and not parsed.fragment)
        except ValueError: valid=False
        origin=self.headers.get('Origin')
        return valid and (origin is None or origin=='http://'+host)

    def send(self,code,content,kind='application/json; charset=utf-8'):
        if kind.startswith('application/json'): content=json.dumps(content,ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type',kind); self.send_header('Content-Length',str(len(content)))
        self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Referrer-Policy','no-referrer')
        self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.end_headers(); self.wfile.write(content)

    def do_GET(self):
        if not self.trusted(): return self.send(403,{'error':'Local same-origin access is required.'})
        path=urlsplit(self.path).path; app=self.server.app
        if path=='/api/session': return self.send(200,{'token':app.token})
        if path=='/api/device': return self.send(200,app.status())
        if path.startswith('/api/jobs/'):
            try: return self.send(200,app.get_job(path.rsplit('/',1)[-1]))
            except KeyError: return self.send(404,{'error':'Request not found.'})
        files={'/':('index.html','text/html; charset=utf-8'),
               '/i18n.js':('i18n.js','text/javascript; charset=utf-8'),
               '/assets/cyberdes-logo.png':('assets/cyberdes-logo.png','image/png'),
               '/app.js':('app.js','text/javascript; charset=utf-8'),
               '/style.css':('style.css','text/css; charset=utf-8')}
        if path not in files: return self.send(404,{'error':'Not found.'})
        name,kind=files[path]
        return self.send(200,(STATIC/name).read_bytes(),kind)

    def do_POST(self):
        if (not self.trusted() or not secrets.compare_digest(
            self.headers.get('X-KV260-Session',''),self.server.app.token)):
            return self.send(403,{'error':'Invalid session or origin.'})
        if self.path!='/api/jobs': return self.send(404,{'error':'Not found.'})
        try:
            size=int(self.headers.get('Content-Length','0'))
            if not 0<size<=16384: raise ValueError('Invalid request size.')
            if self.headers.get('Content-Type','').split(';')[0]!='application/json':
                raise ValueError('A JSON request is required.')
            data=json.loads(self.rfile.read(size))
            return self.send(202,self.server.app.submit(data))
        except (ValueError,UnicodeError) as error: return self.send(400,{'error':str(error)})
        except BusyError as error: return self.send(409,{'error':str(error)})
        except OSError as error: return self.send(503,{'error':str(error)})

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',type=int,default=8080)
    parser.add_argument('--device',default='/dev/kv260-lab')
    parser.add_argument('--records',type=Path)
    args=parser.parse_args()
    if not 1<=args.port<=65535: parser.error('Port is out of range.')
    server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    server.app=Application(args.device,args.records)
    print(f'VulnLM Hardware: http://127.0.0.1:{args.port}',flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally:
        server.server_close()
        if server.app.process is not None:
            print('A hardware job is active; DMA was not cancelled. The process is retained until drain.',flush=True)
            server.app.process.join()  # Never kill a process owning an active DMA ioctl.

if __name__=='__main__': main()
