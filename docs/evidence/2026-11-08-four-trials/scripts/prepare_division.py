from pathlib import Path
import shutil
root=Path.cwd();b=root/'output/refactor-four-2026-11-08';s=b/'division-source';s.mkdir(exist_ok=True)
for name in ('src','boards/tangnano20k/bootrom'):shutil.copytree(root/name,s/name,dirs_exist_ok=True)
shutil.copyfile(root/'.ghc.environment.aarch64-darwin-9.8.2',s/'.ghc.environment.aarch64-darwin-9.8.2')
if not (s/'dist-newstyle').exists():(s/'dist-newstyle').symlink_to(root/'dist-newstyle',target_is_directory=True)
(s/'src/DivisionService.hs').write_text('''{-# LANGUAGE DataKinds, DeriveGeneric, DeriveAnyClass, NoImplicitPrelude #-}
module DivisionService where
import Clash.Prelude
import SimpleRisc.Types
import SimpleRisc.Decode (mulDivStep)

type Command = (BitVector 3, Word32, Word32)
data Service = Idle | Running (BitVector 3) Word32 Word32 MulDivUnit | Complete Word32
 deriving (Generic,NFDataX,Show,Eq)
initialUnit :: MulDivUnit
initialUnit = MulDivUnit MdPrepare 0 0 0 0 False False False False
-- A request is accepted only in Idle. Completion holds until consume.
-- Cancellation wins over both transfers and suppresses any old completion.
serviceStep :: Service -> (Bool,Maybe Command,Bool) -> (Service,Maybe Word32)
serviceStep state (cancel,command,consume) = (next,answer)
 where
 answer | cancel = Nothing
        | Complete value <- state = Just value
        | otherwise = Nothing
 next | cancel = Idle
      | otherwise = case state of
       Idle -> maybe Idle (\\(op,a,b) -> Running op a b initialUnit) command
       Running op a b unit -> case mulDivStep op a b unit of
        Left unit' -> Running op a b unit'
        Right value -> Complete value
       Complete value -> if consume then Idle else Complete value
''')
p=s/'src/SimpleRisc.hs';t=p.read_text();start=t.index('pipelinedCpuStepStages ::');end=t.index('-- CPU ----',start);body=t[start:end]
body=body.replace('pipelinedCpuStepStages','pipelinedCpuStepDivisionStages').replace(':: (Word32 -> MemoryTarget)', ':: Maybe Word32 -> (Word32 -> MemoryTarget)').replace('pipelinedCpuStepDivisionStages decodeTarget','pipelinedCpuStepDivisionStages divisionAnswer decodeTarget')
a=body.index('         in case mulDivStep');z=body.index('              Right result ->',a)
body=body[:a]+'''         in case divisionAnswer of
              Nothing -> (machine, Nothing, idle)
              Just result ->'''+body[z+len('              Right result ->'):]
p.write_text(t[:end]+body+t[end:])
p=s/'src/SdramPipeline.hs';t=p.read_text().replace('import qualified SimpleRisc as R','import qualified SimpleRisc as R\nimport qualified DivisionService as DS')
t=t.replace('Maybe R.Word32,Vec 4 (Signed 34))','Maybe R.Word32,Vec 4 (Signed 34),Maybe R.Word32)')
t=t.replace('ioAnswer,products) =','ioAnswer,products,divisionAnswer) =')
t=t.replace('R.machineStepCoreStagesBy R.pipelinedCpuStepStages','R.machineStepCoreStagesBy (R.pipelinedCpuStepDivisionStages divisionAnswer)')
t=t.replace('ioAnswer,mulProducts)','ioAnswer,mulProducts,divisionAnswer)')
t=t.replace('machineNext=(\\(m,_,_,_) -> m) <$> stepped','machineNext=(\\(m,_,_,_) -> m {R.cpuMulDiv=DS.initialUnit}) <$> stepped')
t=t.replace(' breaking=emergency',''' divisionActive=(\\m -> case R.cpuPhase m of R.MulDiv -> not (R.cpuFast m); _ -> False) <$> running
 divisionCommand=(\\m active -> if active then Just (R.instructionFunct3 (R.cpuInstruction m),R.cpuA m,R.cpuB m) else Nothing) <$> running <*> divisionActive
 divisionConsume=(&&) <$> divisionActive <*> (not <$> holding)
 divisionAnswer=mealy DS.serviceStep DS.Idle (bundle (emergency,divisionCommand,divisionConsume))
 breaking=emergency''')
p.write_text(t)
