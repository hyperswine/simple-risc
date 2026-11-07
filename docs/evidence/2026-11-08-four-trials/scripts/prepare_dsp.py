from pathlib import Path
import shutil
root=Path.cwd();b=root/'output/refactor-four-2026-11-08';s=b/'dsp-source';s.mkdir(exist_ok=True)
for name in ('src','boards/tangnano20k/bootrom'):shutil.copytree(root/name,s/name,dirs_exist_ok=True)
shutil.copyfile(root/'.ghc.environment.aarch64-darwin-9.8.2',s/'.ghc.environment.aarch64-darwin-9.8.2')
if not (s/'dist-newstyle').exists():(s/'dist-newstyle').symlink_to(root/'dist-newstyle',target_is_directory=True)
p=s/'src/SdramPipeline.hs';t=p.read_text();start=t.index('circuitWithObservations ::');body=t[start:]
body=body.replace('circuitWithObservations','circuitWithExternalCycle')
body=body.replace('Signal dom Bit ->\n (BoardOutput dom, Signal dom R.PipelineTrace)','Signal dom Bit -> Signal dom R.Counter64 ->\n (BoardOutput dom, Signal dom R.PipelineTrace, Signal dom (Bool,Bool,R.Word32))')
body=body.replace('serialRx memoryData memoryHeld sdMiso = ((serialTx,address,write,wdata,mask,sck,mosi,cs),trace)','serialRx memoryData memoryHeld sdMiso externalCycle = ((serialTx,address,write,wdata,mask,sck,mosi,cs),trace,cycleWrite)')
body=body.replace('machineNext=(\\(m,_,_,_) -> m) <$> stepped','machineNext=(\\(m,_,_,_) -> m {R.cpuCycle=R.initialCounter}) <$> stepped')
body=body.replace(' running=R.withStagePayloads', ' running=(\\m c -> m {R.cpuCycle=c}) <$> internalRunning <*> externalCycle\n cycleWrite=cycleCommand <$> running\n cycleCommand m=case R.cpuCounterWrite m of\n  Just (address,value) | address==0xb00 || address==0xb80 -> (True,address==0xb80,value)\n  _ -> (False,False,0)\n internalRunning=R.withStagePayloads')
assert 'externalCycle = ' in body and 'Signal dom R.Counter64' in body
p.write_text(t+'\n-- Experimental external physical mcycle owner.\n'+body)
ports=['uart_tx','memory_address','memory_write','memory_wdata','memory_mask','sd_sck','sd_mosi','sd_cs']
obs=['observe_commit','observe_word','observe_pc','observe_next_pc','observe_issue','observe_fetch_pc','observe_empty','observe_redirect']
cmd=['cycle_write_valid','cycle_write_high','cycle_write_value']
def product(names):return 'PortProduct "" ['+','.join('PortName "'+n+'"' for n in names)+']'
inputs=['clk','reset','enable','uart_rx','memory_data','memory_hold','sd_miso','cycle_lo','cycle_hi','cycle_carry']
header='''{-# LANGUAGE DataKinds, NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
module DspCycleTop where
import Clash.Prelude
import qualified SimpleRisc as R
import qualified SdramPipeline as P
'''
for fun,observed in [('topEntity',False),('observedTop',True)]:
 out=[product(ports)]+([product(obs)] if observed else [])+[product(cmd)]
 header+='\n{-# ANN '+fun+' (Synthesize {t_name="sdram_pipeline_core", t_inputs=['+','.join('PortName "'+n+'"' for n in inputs)+'], t_output=PortProduct "" ['+','.join(out)+']}) #-}\n'
 header+=fun+' clk rst en rx dat held miso lo hi carry = withClockResetEnable clk rst en $\n let (o,t,w)=P.circuitWithExternalCycle rx dat held miso (R.Counter64 <$> lo <*> hi <*> carry)\n     (v,h,d)=unbundle w\n in '
 header+='(o,'+('(R.ptCommit <$> t,R.ptWord <$> t,R.ptPc <$> t,R.ptNextPc <$> t,R.ptIssue <$> t,R.ptFetchPc <$> t,R.ptEmpty <$> t,R.ptRedirect <$> t),' if observed else '')+'(v,h,d))\n'
 # Explicit signature fixes the clock domain and all tuple widths.
 sig=fun+' :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem Bit -> Signal XilinxSystem R.Word32 -> Signal XilinxSystem Bool -> Signal XilinxSystem Bit -> Signal XilinxSystem R.Word32 -> Signal XilinxSystem R.Word32 -> Signal XilinxSystem Bool -> (P.BoardOutput XilinxSystem, '
 if observed:sig+='(Signal XilinxSystem Bool,Signal XilinxSystem R.Word32,Signal XilinxSystem R.Word32,Signal XilinxSystem R.Word32,Signal XilinxSystem Bool,Signal XilinxSystem R.Word32,Signal XilinxSystem Bool,Signal XilinxSystem Bool), '
 sig+='(Signal XilinxSystem Bool,Signal XilinxSystem Bool,Signal XilinxSystem R.Word32))\n'
 header=header.replace(fun+' clk rst en',sig+fun+' clk rst en',1)
(s/'src/DspCycleTop.hs').write_text(header)
