"""Host-side gates: no fake execution is reported as board validation."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class BoardCollectorTests(unittest.TestCase):
    def run_fake(self, baseline_fail=False, miss=False):
        temp=tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        base=Path(temp.name)
        fake=base/'fake_ctl'
        fake.write_text('#!'+sys.executable+'\nimport json,sys\n'
                        'command=sys.argv[1]\n'
                        'print(json.dumps({"fixture": True,"command":command}))\n'
                        f'raise SystemExit(1 if command=="verify" and {baseline_fail!r} else '
                        f'3 if command=="e1" and {miss!r} else 0)\n')
        fake.chmod(0o755)
        output=base/'records'
        result=subprocess.run([sys.executable,str(ROOT/'scripts/run_board_suite.py'),
            '--ctl',str(fake),'--output',str(output),'--count','2','--trials','2','--e1'],
            capture_output=True,text=True)
        return result,output,json.loads((output/'manifest.json').read_text())

    def test_failed_clean_gate_never_starts_e1(self):
        result,output,manifest=self.run_fake(baseline_fail=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(len(manifest['steps']),2)
        self.assertFalse(list(output.glob('e1*')))

    def test_window_misses_are_retained_and_followups_run(self):
        result,output,manifest=self.run_fake(miss=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(sum(s['returncode']==3 for s in manifest['steps']),6)
        self.assertEqual(len(list(output.glob('followup*.jsonl'))),6)
        self.assertIn('completed_utc',manifest)

    def test_success_keeps_all_three_policies_and_hashes(self):
        result,output,manifest=self.run_fake()
        self.assertEqual(result.returncode,0,result.stderr)
        for trial in range(2):
            for policy in range(3):
                self.assertIn(f'e1_{trial}_P{policy}.jsonl',manifest['files'])
        self.assertEqual(len(manifest['steps']),14)

class BuildInputTests(unittest.TestCase):
    def test_board_report_retains_failed_batches_and_missed_windows(self):
        spec=importlib.util.spec_from_file_location('board_report',ROOT/'scripts/report_board.py')
        module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp)
            (base/'device.json').write_text('{"abi":1,"rows":64}')
            (base/'manifest.json').write_text(json.dumps({'steps':[
                {'record_file':'normal.jsonl','returncode':1},
                {'record_file':'e1.jsonl','returncode':3}]}))
            row={'kind':'hardware_run','status':0,'guard_errors':0,'submit_ns':1,
                 'tx_done_ns':2,'rx_done_ns':3,'release_ns':4}
            (base/'normal.jsonl').write_text(json.dumps(row)+'\n')
            row.update(kind='hardware_E1_private_scratch',policy=2,window_hit=0,
                       changed_bytes=0,late_a_words=0,mock_bad_response=0,handoff_ns=0)
            (base/'e1.jsonl').write_text(json.dumps(row)+'\n')
            result=module.summarize(base)
            self.assertEqual(result['successful_normal_records'],0)
            self.assertEqual(len(result['failed_or_invalid_records']),1)
            self.assertEqual(result['policies'][0]['missed_windows'],1)
            self.assertEqual(result['policies'][0]['usable_windows'],0)

    def test_missing_build_cannot_be_packaged(self):
        with tempfile.TemporaryDirectory() as temp:
            out=Path(temp)/'out'
            result=subprocess.run([sys.executable,str(ROOT/'scripts/package_firmware.py'),
                '--vivado-dir',temp,'--output',str(out)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(out.exists())

    def test_project_tcl_is_complete(self):
        # Syntax only; this intentionally makes no claim about Vivado IP APIs.
        script='set f [open {'+str(ROOT/'hw/create_project.tcl')+'}]; set s [read $f]; close $f; if {![info complete $s]} {exit 1}\n'
        subprocess.run(['tclsh'],input=script,text=True,check=True)

    def test_mmio_constants_match_rtl(self):
        text=(ROOT/'rtl/matvec_axil_ctrl.sv').read_text().lower()
        self.assertIn('4d565831',text)
        self.assertIn('00010001',text)
        contract=(ROOT/'sw/include/kv260_contract.h').read_text()
        self.assertIn('KV_REG_LAST_OUTCOME 0x094',contract)

if __name__=='__main__': unittest.main()
