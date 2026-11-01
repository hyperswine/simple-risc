import collections
import hashlib
import json
from pathlib import Path
import struct
import sys

sys.path.insert(0,str(Path.cwd()/'boards/tangnano20k/sdram'))
import run_operating_envelope as runner

base=Path(sys.argv[1]).resolve()
rows=json.loads((base/'measurements.json').read_text())['cases']
expected=json.loads((base/'reference.json').read_text())
meta=json.loads((base/'experiment.json').read_text())
assert {r['label'] for r in rows}=={runner.name(*c) for c in runner.matrix()}
parsed=0
for row in rows:
    dest=base/'hardware'/row['label']/f'run-{row["run"]}'
    assert json.loads((dest/'result.json').read_text())==row
    receipt=base/'builds'/row['label']/'receipt.json'
    assert hashlib.sha256(receipt.read_bytes()).hexdigest()==row['receipt_sha256']
    build=json.loads(receipt.read_text())
    assert build['status']=='built'
    assert '0 setup / 0 hold violating endpoints' in build['timing']
    assert (row['kind'],row['frequency_mhz'],row['phase_degrees'])==(build['kind'],build['frequency_mhz'],build['phase_degrees'])
    assert [v for k,v in build['sha256'].items() if k.endswith('/impl/pnr/sdram_test.fs')]==[row['image_sha256']]
    if row['status']=='inconclusive':continue
    raw=(dest/'uart.bin').read_bytes()
    if row['kind']=='integrated':
        assert row['receive_crc_verified']
        assert row['readback_crc']==row['expected_crc']
        result=runner.parse_integrated(raw,expected)
    else:
        assert len(raw)%25==0
        reports=[]
        for off in range(0,len(raw),25):
            magic,p,errors,count,addr,want,got=struct.unpack('<4sB5I',raw[off:off+25])
            assert magic==b'SDR1'
            if not reports:assert p==255 and count==errors==0
            else:assert p==len(reports)-1 and count==(p+1)*2097152 and errors<=count
            reports.append(dict(pattern=p,errors=errors,comparisons=count,first_address=addr,expected=want,actual=got))
        assert reports[-1]['errors'] or reports[-1]['pattern']==5
        result=dict(status='memory_fail' if reports[-1]['errors'] else 'pass',reports=reports)
    assert result['status']==row['status']
    assert result['reports']==row['reports']
    parsed+=1
recoveries=list(base.glob('recovery-*'))
for directory in recoveries:
    record=json.loads((directory/'result.json').read_text())
    assert record['passed'] and record['identity']==meta['starting_identity']
    assert record['image_sha256']==meta['restore_sha256']
    assert len(record['upload_probes'])==12
    assert all(p['passed'] for p in record['upload_probes'])
statuses=collections.Counter(r['status'] for r in rows)
record=dict(distinct_cases=96,runs=len(rows),statuses=dict(statuses),
    conclusive_uart_reports_reparsed=parsed,recoveries_verified=len(recoveries),
    recovery_crc_probes=12*len(recoveries),
    checks=['All 96 requested cases have board observations.',
        'Each journal row matches its saved result and hashed build receipt.',
        'Every programmed receipt passes internal setup and hold checks.',
        'All conclusive UART reports reparse and match the saved observations.',
        'Every recovery matches the pinned identity/image and passes twelve CRC probes.'])
(base/'validation.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,indent=2))
