{-# LANGUAGE DataKinds, NoImplicitPrelude, FlexibleContexts #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
module FastProbePipeline where
import Clash.Prelude
import FastProbe (ramProbe)

-- Same RAM and same add as bramAddTop, with a register BEFORE the add.
-- Gowin can absorb this into the BSRAM's native output register.
topEntity :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
topEntity clk rst en = exposeClockResetEnable circuit clk rst en
 where
  circuit :: HiddenClockResetEnable dom => Signal dom (BitVector 32)
  circuit = (+ 0x13579BDF) <$> register 0 ramProbe
{-# ANN topEntity (Synthesize {t_name="probe_bram_pipe_add",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
