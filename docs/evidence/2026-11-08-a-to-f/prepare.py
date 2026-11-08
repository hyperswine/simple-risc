from pathlib import Path
import shutil,subprocess,json,hashlib,difflib
R=Path.cwd();B=R/'output/a-to-f-2026-11-08';S=B/'candidate-source';S.mkdir(exist_ok=True)
for name in ('src','boards/tangnano20k/bootrom'):shutil.copytree(R/name,S/name,dirs_exist_ok=True)
shutil.copyfile(R/'.ghc.environment.aarch64-darwin-9.8.2',S/'.ghc.environment.aarch64-darwin-9.8.2')
if not (S/'dist-newstyle').exists():(S/'dist-newstyle').symlink_to(R/'dist-newstyle',target_is_directory=True)
p=S/'src/SimpleRisc.hs';before=p.read_text();after=before
old='''      fQueue' = case pA pipe of
        Just f | fPush -> replace (pFWrite pipe) ((expand f) {fPredicted = aPredicted}) (pFQueue pipe)
        _ -> pFQueue pipe'''
new='''      -- Payload is meaningful only on fPush, which includes A validity.
      -- Do not put the validity-to-zero mux in front of the decompressor
      -- and prediction arithmetic; validity belongs at the write enable.
      fQueue'
        | fPush = replace (pFWrite pipe) ((expand aFetched) {fPredicted = aPredicted}) (pFQueue pipe)
        | otherwise = pFQueue pipe'''
assert old in after;after=after.replace(old,new)
old='      aFetched = fromMaybe (Fetched 0 0 False False 0 0 4) (pA pipe)'
assert old in after;after=after.replace(old,'''      -- Invalid A payload is a don't-care. Every architectural consumer
      -- is guarded by fPush; the unconditional target register is masked
      -- separately below to preserve its original invalid-A value.
      aFetched = fromJustX (pA pipe)''')
old='      aTarget = if rcReturn aClass then rasTop else fPc aFetched + rcJalOffset aClass'
assert old in after;after=after.replace(old,old+'''\n      aTargetStored = if isJust (pA pipe) then aTarget else 0''')
assert after.count('pFrontTarget = aTarget,')==2;after=after.replace('pFrontTarget = aTarget,','pFrontTarget = aTargetStored,')
p.write_text(after)
(B/'candidate.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='a/src/SimpleRisc.hs',tofile='b/src/SimpleRisc.hs')))
manifest={str(p.relative_to(S)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (S/'src').rglob('*') if p.is_file()}
(B/'source-manifest.json').write_text(json.dumps({'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'source_hashes':manifest},indent=2)+'\n')
print('Prepared isolated A-validity datapath refactor')
