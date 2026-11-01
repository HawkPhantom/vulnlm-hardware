"""Acceptance-runner workflow fixtures; never physical board evidence."""
import importlib.util
import errno
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from web.hardware import Info
from web.product import DEFAULT_A, reference_words
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('recovery_runner',ROOT/'scripts/run_recovery_suite.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)

class Fixture:
    corrupt_followup=False
    def __init__(self,path):
        self.count=0
        self.info=Info(abi=1,rows=64,cols=64,input_bytes=4160,output_bytes=256,lab_enabled=1,capabilities=7)
    def __enter__(self):return self
    def __exit__(self,*args):pass
    def run(self,frame,**kw):
        recovery=kw.get('recovery_test',False)
        if recovery:self.count+=1
        metadata={'status':-errno.ETIMEDOUT if recovery else 0,'recovery_flags':int(recovery),
                  'recovery_count':self.count,'guard_errors':0,'window_hit':0,'timed_out':int(recovery),
                  'submit_ns':100,'tx_done_ns':110,'rx_done_ns':120,'release_ns':130}
        words=reference_words(DEFAULT_A,64)
        if self.corrupt_followup and self.count and not recovery:words[0]+=1
        return {'fixture':True,'metadata':metadata,'words':words}

class AcceptanceTests(unittest.TestCase):
    def run_fixture(self,backend=Fixture):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        out=Path(temp.name)/'records'
        calls=[]
        def e2(request,*args):
            policy=request['policy'];calls.append(policy)
            return {'fixture':True,'window_observed':True,'wrong_product_decision':policy==0,
                    'wrong_request_association':policy==0,'delivered_b':{
                        'source':'late_a_dma' if policy==0 else 'own_b_dma'}}
        with patch.object(runner,'Hardware',backend),patch.object(runner,'execute',e2), \
             patch('sys.argv',['runner','--output',str(out),'--trials','2']):
            try:
                with contextlib.redirect_stdout(io.StringIO()):runner.main()
                error=None
            except SystemExit as exception:error=str(exception)
        return out,calls,error

    def test_acceptance_requires_reset_followups_and_all_e2_policies(self):
        out,calls,error=self.run_fixture()
        self.assertIsNone(error)
        self.assertEqual(calls,[0,1,2,0,1,2])
        manifest=json.loads((out/'manifest.json').read_text())
        self.assertTrue(manifest['completed'])
        self.assertIn('acceptance.json',manifest['files'])
        self.assertEqual(len(list(out.glob('reset_followup_*.json'))),2)

    def test_failed_followup_stops_before_e2_and_preserves_records(self):
        class Corrupt(Fixture):corrupt_followup=True
        out,calls,error=self.run_fixture(Corrupt)
        self.assertIn('CPU reference',error)
        self.assertEqual(calls,[])
        self.assertTrue((out/'reset_followup_0.json').exists())
        self.assertFalse((out/'acceptance.json').exists())
        self.assertFalse(json.loads((out/'manifest.json').read_text())['completed'])

    def test_missing_hardware_never_produces_acceptance(self):
        def absent(path):raise OSError('Missing real device')
        out,calls,error=self.run_fixture(absent)
        self.assertEqual(error,'Missing real device')
        self.assertFalse((out/'acceptance.json').exists())
        self.assertEqual(calls,[])

if __name__=='__main__':unittest.main()
