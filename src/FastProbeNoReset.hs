{-# LANGUAGE DataKinds, NoImplicitPrelude, FlexibleContexts #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
module FastProbeNoReset where
import Clash.Prelude
import FastProbe (ramProbe)

-- Same added latency as FastProbePipeline, without resetting the payload.
-- There is deliberately no promise of cleared output on reset in this probe.
topEntity :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
topEntity clk rst en = exposeClockResetEnable circuit clk rst en
 where
  circuit :: HiddenClockResetEnable dom => Signal dom (BitVector 32)
  circuit = (+ 0x13579BDF) <$> delay 0 ramProbe
{-# ANN topEntity (Synthesize {t_name="probe_bram_pipe_norst",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
