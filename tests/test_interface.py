"""Protocol/HTTP tests use explicit fixtures. They are not board evidence."""
import copy
import ctypes as C
import errno
from http.client import HTTPConnection
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from web import hardware, product, server

REQUEST={'a':dict(product.DEFAULT_A),'b':{'label':'B','surface':70,'dimension':55,'temperature':40,'vibration':30},
         'policy':0,'delay_cycles':50000000,'timeout_ms':20}

class FixtureHardware:
    """Only unit-test injection. No server option can select this backend."""
    calls=[]
    def __init__(self,path):
        self.info=hardware.Info(abi=1,rows=64,cols=64,input_bytes=4160,output_bytes=256,
                               state=0,lab_enabled=1,capabilities=1)
    def __enter__(self): return self
    def __exit__(self,*args): pass
    def run(self,frame,**kwargs):
        type(self).calls.append((frame,kwargs))
        is_capture=kwargs.get('capture',False)
        item=REQUEST['a'] if is_capture else REQUEST['b']
        metadata={'status':-errno.ETIMEDOUT if is_capture else 0,'guard_errors':0,'timed_out':int(is_capture),
                  'window_hit':int(is_capture),'job_id':kwargs['job_id'],'generation':kwargs['generation'],
                  'submit_ns':100,'timeout_ns':120 if is_capture else 0,'handoff_ns':121 if kwargs.get('policy',2)<2 else 160,
                  'tx_done_ns':110,'rx_done_ns':150,'release_ns':170,'changed_bytes':256,
                  'core_cycles':8192,'stall_cycles':0}
        return {'metadata':metadata,'words':product.reference_words(item,64)}

class ProductTests(unittest.TestCase):
    def setUp(self): FixtureHardware.calls=[]
    def run_policy(self,policy,backend=FixtureHardware):
        request=copy.deepcopy(REQUEST); request['policy']=policy
        with patch('web.product.Hardware',backend):
            return product.execute(product.validate_request(request),'/fixture',lambda *args:None)

    def test_actual_frame_encoding_matches_independent_score(self):
        frame=product.encode_frame(REQUEST['b'],64,64)
        self.assertEqual(len(frame),4160)
        self.assertEqual(frame[:4],bytes([30,45,60,70]))
        self.assertEqual(frame[64:68],bytes([4,3,2,1]))
        score=sum(int(frame[c])*int(frame[64+c]) for c in range(64))
        self.assertEqual(score,445)
        self.assertEqual(product.reference_words(REQUEST['a'],64)[0],948)
        self.assertEqual(frame[128:],bytes(4160-128))

    def test_p0_delivers_captured_a_bytes_not_reference_b(self):
        result=self.run_policy(0)
        self.assertEqual(result['delivered_b']['score'],948)
        self.assertEqual(result['reference_b']['score'],445)
        self.assertEqual(result['delivered_b']['source'],'late_a_dma')
        self.assertTrue(result['wrong_product_decision'])
        self.assertTrue(result['wrong_request_association'])
        self.assertIsNone(result['actual_b'])
        self.assertEqual(len(FixtureHardware.calls),2)
        self.assertEqual(FixtureHardware.calls[1][0],product.encode_frame(REQUEST['a'],64,64))

    def test_p1_and_p2_execute_real_b_path_after_capture(self):
        for policy in (1,2):
            with self.subTest(policy=policy):
                FixtureHardware.calls=[]
                result=self.run_policy(policy)
                self.assertEqual(result['delivered_b']['score'],445)
                self.assertEqual(result['delivered_b']['source'],'own_b_dma')
                self.assertFalse(result['wrong_product_decision'])
                self.assertEqual(len(FixtureHardware.calls),3)
                self.assertFalse(FixtureHardware.calls[-1][1].get('capture',False))

    def test_missed_window_never_delivers_an_artificial_bad_result(self):
        class Miss(FixtureHardware):
            def run(self,frame,**kwargs):
                value=super().run(frame,**kwargs)
                if kwargs.get('capture'): value['metadata'].update(window_hit=0,handoff_ns=0)
                return value
        result=self.run_policy(0,Miss)
        self.assertFalse(result['window_observed'])
        self.assertIsNone(result['delivered_b'])
        self.assertFalse(result['wrong_output'])

    def test_invalid_p2_handoff_is_not_success(self):
        class Early(FixtureHardware):
            def run(self,frame,**kwargs):
                value=super().run(frame,**kwargs)
                if kwargs.get('capture'): value['metadata']['handoff_ns']=121
                return value
        result=self.run_policy(2,Early)
        self.assertFalse(result['window_observed'])
        self.assertIsNone(result['delivered_b'])

    def test_corrupt_hardware_capture_prevents_product_reply(self):
        class Corrupt(FixtureHardware):
            def run(self,frame,**kwargs):
                value=super().run(frame,**kwargs)
                if kwargs.get('capture'): value['words'][0]+=1
                return value
        with self.assertRaisesRegex(RuntimeError,'CPU reference'):
            self.run_policy(0,Corrupt)

    def test_failed_control_prevents_fault_injection(self):
        class Failed(FixtureHardware):
            def run(self,frame,**kwargs):
                value=super().run(frame,**kwargs); value['metadata']['guard_errors']=1; return value
        with self.assertRaisesRegex(RuntimeError,'guard pattern'):
            self.run_policy(0,Failed)
        self.assertEqual(len(Failed.calls),1)

    def test_invalid_inputs_are_rejected(self):
        for key,value in [('surface',True),('dimension',-1),('temperature',101),('vibration',.5)]:
            request=copy.deepcopy(REQUEST); request['b'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError): product.validate_request(request)
        request=copy.deepcopy(REQUEST); request['policy']=True
        with self.assertRaises(ValueError): product.validate_request(request)

    def test_python_abi_offsets(self):
        self.assertEqual(C.sizeof(hardware.Info),32)
        self.assertEqual(C.sizeof(hardware.Run),160)
        self.assertEqual(hardware.Run.input_ptr.offset,32)
        self.assertEqual(hardware.Run.submit_ns.offset,96)

    def test_offline_device_has_no_result_fallback(self):
        with patch('web.hardware.sys.platform','darwin'):
            result=hardware.device_status()
        self.assertFalse(result['ready']); self.assertFalse(result['connected'])
        self.assertIsNone(result['device'])

class HttpTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.http=server.ThreadingHTTPServer(('127.0.0.1',0),server.Handler)
        self.http.app=server.Application('/nonexistent',Path(self.temp.name))
        self.thread=threading.Thread(target=self.http.serve_forever,daemon=True); self.thread.start()
        self.addCleanup(self.stop)
        self.port=self.http.server_address[1]
    def stop(self): self.http.shutdown(); self.http.server_close(); self.thread.join()
    def request(self,path='/',method='GET',body=None,headers=None):
        connection=HTTPConnection('127.0.0.1',self.port,timeout=3)
        connection.request(method,path,body=body,headers=headers or {})
        response=connection.getresponse(); data=response.read(); result=(response.status,dict(response.getheaders()),data)
        connection.close(); return result
    def test_page_and_real_device_offline_state(self):
        code,headers,data=self.request()
        self.assertEqual(code,200); self.assertIn(b'KV260',data)
        self.assertIn(b'<html lang="en-GB">',data)
        self.assertIn(b'VulnLM Hardware',data)
        self.assertIn("frame-ancestors 'none'",headers['Content-Security-Policy'])
        with patch('web.server.device_status',return_value={'connected':False,'ready':False,'reason':'offline','device':None}):
            code,_,data=self.request('/api/device')
        self.assertFalse(json.loads(data)['ready'])
    def test_supplied_logo_and_language_script_are_served(self):
        code,headers,data=self.request('/assets/cyberdes-logo.png')
        self.assertEqual(code,200)
        self.assertEqual(headers['Content-Type'],'image/png')
        self.assertEqual(data[:8],b'\x89PNG\r\n\x1a\n')
        code,_,data=self.request('/i18n.js')
        self.assertEqual(code,200); self.assertIn(b"let language = 'en-GB'",data)

    def test_nanosecond_timestamps_survive_javascript_json(self):
        original=10**18+123
        value=server.Application.public({'result':{'submit_ns':original,'score':948},'_secret':True})
        self.assertEqual(value['result']['submit_ns'],str(original))
        self.assertEqual(value['result']['score'],948)
        self.assertNotIn('_secret',value)
    def test_missing_hardware_rejects_job_without_starting_worker(self):
        headers={'Content-Type':'application/json','X-KV260-Session':self.http.app.token}
        with patch('web.server.device_status',return_value={'ready':False,'reason':'offline'}):
            code,_,data=self.request('/api/jobs','POST',json.dumps(REQUEST),headers)
        self.assertEqual(code,503); self.assertEqual(self.http.app.jobs,{})
        self.assertIsNone(self.http.app.process)
    def test_cross_origin_and_missing_token_are_rejected(self):
        for headers in ({'Content-Type':'application/json'},
            {'Content-Type':'application/json','X-KV260-Session':self.http.app.token,'Origin':'http://evil.invalid'}):
            code,_,_=self.request('/api/jobs','POST',json.dumps(REQUEST),headers)
            self.assertEqual(code,403)
    def test_rebinding_host_and_path_escape_are_rejected(self):
        code,_,_=self.request('/api/session',headers={'Host':'evil.invalid:8080'})
        self.assertEqual(code,403)
        code,_,_=self.request('/../sw/kernel/kv260_lab.c')
        self.assertEqual(code,404)

class WorkerTests(unittest.TestCase):
    def test_real_spawned_worker_reports_missing_device_without_result(self):
        with tempfile.TemporaryDirectory() as directory:
            app=server.Application('/this-device-does-not-exist',directory)
            # Readiness is a unit-test precondition only. The spawned worker
            # actually opens the missing path and must fail, never return data.
            with patch('web.server.device_status',return_value={'ready':True}):
                submitted=app.submit(REQUEST)
            deadline=time.monotonic()+8
            while time.monotonic()<deadline:
                job=app.get_job(submitted['id'])
                if app.process is None: break
                time.sleep(.02)
            self.assertIsNone(app.process)
            self.assertEqual(job['state'],'error')
            self.assertNotIn('result',job)
            self.assertTrue(job['record_saved'])
            persisted=json.loads((Path(directory)/(submitted['id']+'.json')).read_text())
            self.assertEqual(persisted['state'],'error')
            self.assertNotIn('result',persisted)

if __name__=='__main__': unittest.main()
