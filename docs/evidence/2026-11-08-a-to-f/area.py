from pathlib import Path
import re,json,hashlib
R=Path.cwd();B=R/'output/a-to-f-2026-11-08';out={}
for v,p in [('baseline',R/'output/refactor-2026-11-07/baseline-physical'),('candidate',B/'candidate-physical')]:
 rpt=p/'impl/gwsynthesis/sdram_test_syn.rpt.html';text=rpt.read_text();hier=(p/'impl/gwsynthesis/sdram_test_syn_resource.html').read_text();rows=[]
 for block in hier.split('</tr>'):
  vals=re.findall(r'<td align = "center">(\d+|-)</td>',block)
  if len(vals)==7:rows.append([0 if x=='-' else int(x) for x in vals])
 sums=[sum(r[i] for r in rows) for i in range(7)];out[v]=dict(zip(['registers','alu','lut_including_inverters','dsp_macros','bsram','ssram','rom16'],sums))
 out[v]['whole_design_logic']=int(re.search(r'<td class="label">Logic</td>\s*<td>(\d+)\(',text)[1]);out[v]['report_sha256']=hashlib.sha256(rpt.read_bytes()).hexdigest()
 out[v]['core_lut_equivalents']=json.loads((B/('baseline-area.json' if v=='baseline' else 'candidate-physical/area.json')).read_text())['total']
(B/'synthesis-area.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
