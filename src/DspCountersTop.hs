{-# LANGUAGE DataKinds, NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- | The SDRAM pipeline with its three 64-bit counters (mcycle, mtime,
-- minstret) outside the core, in Verilog dsp_counter instances that
-- package_dsp_counters.py wraps around this entity. Experimental: the
-- aggregate area candidate of 2026-11-08.
module DspCountersTop where

import Clash.Prelude
import qualified SimpleRisc as R
import qualified SdramPipeline as P

type CounterInputs dom = (Signal dom R.Word32, Signal dom R.Word32, Signal dom Bool,
                          Signal dom R.Word32, Signal dom R.Word32, Signal dom Bool,
                          Signal dom R.Word32, Signal dom R.Word32, Signal dom Bool)
type CommandOutputs dom = (Signal dom Bool, Signal dom Bool, Signal dom R.Word32,
                           Signal dom Bool, Signal dom Bool, Signal dom R.Word32,
                           Signal dom Bool, Signal dom Bool, Signal dom R.Word32,
                           Signal dom Bool, Signal dom Bool)

counters :: CounterInputs dom -> P.ExternalCounters dom
counters (clo,chi,cc,tlo,thi,tc,ilo,ihi,ic) =
  (R.Counter64 <$> clo <*> chi <*> cc, R.Counter64 <$> tlo <*> thi <*> tc, R.Counter64 <$> ilo <*> ihi <*> ic)

commands :: Signal dom P.CounterCommands -> CommandOutputs dom
commands c = (valid cycleW, high cycleW, value cycleW, valid timeW, high timeW, value timeW,
              valid instretW, high instretW, value instretW, P.ccInstretIncrement <$> c, P.ccInstretEnable <$> c)
  where
    cycleW = P.ccCycleWrite <$> c
    timeW = P.ccTimeWrite <$> c
    instretW = P.ccInstretWrite <$> c
    valid = fmap (maybe False (const True))
    high = fmap (maybe False fst)
    value = fmap (maybe 0 snd)

{-# ANN topEntity (Synthesize {t_name="sdram_pipeline_core",
 t_inputs=[PortName "clk",PortName "reset",PortName "enable",PortName "uart_rx",PortName "memory_data",PortName "memory_hold",PortName "sd_miso",
   PortProduct "" [PortName "cycle_lo",PortName "cycle_hi",PortName "cycle_carry",PortName "time_lo",PortName "time_hi",PortName "time_carry",PortName "instret_lo",PortName "instret_hi",PortName "instret_carry"]],
 t_output=PortProduct "" [
   PortProduct "" [PortName "uart_tx",PortName "memory_address",PortName "memory_write",PortName "memory_wdata",PortName "memory_mask",PortName "sd_sck",PortName "sd_mosi",PortName "sd_cs"],
   PortProduct "" [PortName "cycle_write_valid",PortName "cycle_write_high",PortName "cycle_write_value",PortName "time_write_valid",PortName "time_write_high",PortName "time_write_value",PortName "instret_write_valid",PortName "instret_write_high",PortName "instret_write_value",PortName "instret_increment",PortName "instret_enable"]]}) #-}
topEntity :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem ->
 Signal XilinxSystem Bit -> Signal XilinxSystem R.Word32 -> Signal XilinxSystem Bool -> Signal XilinxSystem Bit -> CounterInputs XilinxSystem ->
 (P.BoardOutput XilinxSystem, CommandOutputs XilinxSystem)
topEntity clk rst en rx dat held miso ins = withClockResetEnable clk rst en $
  let (output, _, c) = P.circuitWithExternalCounters rx dat held miso (counters ins)
   in (output, commands c)

{-# ANN observedTop (Synthesize {t_name="sdram_pipeline_core",
 t_inputs=[PortName "clk",PortName "reset",PortName "enable",PortName "uart_rx",PortName "memory_data",PortName "memory_hold",PortName "sd_miso",
   PortProduct "" [PortName "cycle_lo",PortName "cycle_hi",PortName "cycle_carry",PortName "time_lo",PortName "time_hi",PortName "time_carry",PortName "instret_lo",PortName "instret_hi",PortName "instret_carry"]],
 t_output=PortProduct "" [
   PortProduct "" [PortName "uart_tx",PortName "memory_address",PortName "memory_write",PortName "memory_wdata",PortName "memory_mask",PortName "sd_sck",PortName "sd_mosi",PortName "sd_cs"],
   PortProduct "" [PortName "observe_commit",PortName "observe_word",PortName "observe_pc",PortName "observe_next_pc",PortName "observe_issue",PortName "observe_fetch_pc",PortName "observe_empty",PortName "observe_redirect"],
   PortProduct "" [PortName "cycle_write_valid",PortName "cycle_write_high",PortName "cycle_write_value",PortName "time_write_valid",PortName "time_write_high",PortName "time_write_value",PortName "instret_write_valid",PortName "instret_write_high",PortName "instret_write_value",PortName "instret_increment",PortName "instret_enable"]]}) #-}
observedTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem ->
 Signal XilinxSystem Bit -> Signal XilinxSystem R.Word32 -> Signal XilinxSystem Bool -> Signal XilinxSystem Bit -> CounterInputs XilinxSystem ->
 (P.BoardOutput XilinxSystem,
  (Signal XilinxSystem Bool, Signal XilinxSystem R.Word32, Signal XilinxSystem R.Word32, Signal XilinxSystem R.Word32,
   Signal XilinxSystem Bool, Signal XilinxSystem R.Word32, Signal XilinxSystem Bool, Signal XilinxSystem Bool),
  CommandOutputs XilinxSystem)
observedTop clk rst en rx dat held miso ins = withClockResetEnable clk rst en $
  let (output, trace, c) = P.circuitWithExternalCounters rx dat held miso (counters ins)
   in (output, (R.ptCommit <$> trace, R.ptWord <$> trace, R.ptPc <$> trace, R.ptNextPc <$> trace,
                R.ptIssue <$> trace, R.ptFetchPc <$> trace, R.ptEmpty <$> trace, R.ptRedirect <$> trace), commands c)
