"""Evidence acceptance must reject incomplete and corrupted guest output."""
import unittest
from run_operating_envelope import parse_integrated
from summarize_envelope import classify, windows

class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.ref=[0,0,0x314aa865,0x314aa865,0x314aa865,0x63be2ac0]
        self.header='ENV1 START 80010000 807f0000 001f8000\n'
        self.rows=[f'ENV1 RESULT {p:08x} 001f8000 00000000 00000000 00000000 00000000 {d:08x}\n'
                   for p,d in enumerate(self.ref)]
        self.raw=(self.header+''.join(self.rows)+'ENV1 PASS\nDONE').encode()
    def test_complete(self):
        self.assertEqual(parse_integrated(self.raw,self.ref)['status'],'pass')
    def test_independent_digest(self):
        bad=self.raw.replace(b'314aa865',b'314aa864',1)
        self.assertEqual(parse_integrated(bad,self.ref)['status'],'digest_fail')
    def test_failure_evidence(self):
        raw=(self.header+'ENV1 RESULT 00000000 001f8000 00000001 80010000 00000000 ffffffff 00000000\nDONE').encode()
        r=parse_integrated(raw,self.ref)
        self.assertEqual(r['status'],'memory_fail')
        self.assertEqual(r['reports'][0]['actual'],0xffffffff)
    def test_refuse_bad_coverage_completion_and_order(self):
        for raw in (self.raw[:-4],self.raw.replace(b'001f8000',b'00000001'),
                    self.raw.replace(self.rows[2].encode(),b''),
                    self.raw.replace(b'ENV1 PASS',b'ENV1 FAIL')):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                parse_integrated(raw,self.ref)

class WindowTests(unittest.TestCase):
    def test_failure_cannot_be_erased_by_a_pass(self):
        self.assertEqual(classify([{'status':'memory_fail'},{'status':'pass'}]),'intermittent_fail')
    def test_unknown_is_not_a_failure(self):
        self.assertEqual(classify([{'status':'inconclusive'}]),'inconclusive')
    def test_margin_from_sampled_endpoints(self):
        w=windows([90,112.5,135],54)[0]
        self.assertEqual(w['central_sample_degrees'],112.5)
        self.assertEqual(w['distance_to_passing_endpoint_degrees'],22.5)
        self.assertEqual(w['lower_neighbor_degrees'],67.5)
        self.assertEqual(w['upper_neighbor_degrees'],157.5)
        self.assertAlmostEqual(w['distance_to_passing_endpoint_ns'],1.1574074074)
    def test_two_samples_have_no_tested_interior_step(self):
        self.assertEqual(windows([90,112.5],60)[0]['distance_to_passing_endpoint_degrees'],0)
    def test_wraparound_window(self):
        w=windows([337.5,0,22.5],48)[0]
        self.assertEqual(w['passing_samples_degrees'],[337.5,0,22.5])
        self.assertEqual(w['central_sample_degrees'],0)

if __name__=='__main__':unittest.main()
