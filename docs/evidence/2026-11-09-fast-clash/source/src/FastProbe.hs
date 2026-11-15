{-# LANGUAGE DataKinds, NoImplicitPrelude, TypeApplications, FlexibleContexts #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
module FastProbe where

import Clash.Prelude

-- Intentionally independent circuits: do not put a mode mux on the data path.
-- The external wrapper captures every output bit before folding it to a pin.
lfsrNext :: BitVector 32 -> BitVector 32
lfsrNext x = (x `shiftL` 1) .|. zeroExtend (slice d31 d31 x `xor` slice d21 d21 x `xor` slice d1 d1 x `xor` slice d0 d0 x)

lfsr :: HiddenClockResetEnable dom => Signal dom (BitVector 32)
lfsr = q where q = register 1 (lfsrNext <$> q)

counter :: HiddenClockResetEnable dom => Signal dom (Unsigned 32)
counter = q where q = register 0 ((+1) <$> q)

-- A true read/write memory, not a constant ROM that can collapse to LUTs.
-- The read follows the write by one address; read and write never collide.
ramProbe :: HiddenClockResetEnable dom => Signal dom (BitVector 32)
ramProbe = blockRam (repeat 0 :: Vec 1024 (BitVector 32)) rd wr
 where
  address = register (0 :: Unsigned 10) ((+1) <$> address)
  rd = (\a -> a - 1) <$> address
  wr = Just <$> bundle (address, lfsr)

lfsrTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
lfsrTop clk rst en = exposeClockResetEnable lfsr clk rst en
counterTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
counterTop clk rst en = pack <$> exposeClockResetEnable counter clk rst en
bramTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
bramTop clk rst en = exposeClockResetEnable ramProbe clk rst en
bramAddTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
bramAddTop clk rst en = exposeClockResetEnable circuit clk rst en
 where
  circuit :: HiddenClockResetEnable dom => Signal dom (BitVector 32)
  circuit = (+ 0x13579BDF) <$> ramProbe

{-# ANN lfsrTop (Synthesize {t_name="probe_lfsr",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
{-# ANN counterTop (Synthesize {t_name="probe_counter",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
{-# ANN bramTop (Synthesize {t_name="probe_bram",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
{-# ANN bramAddTop (Synthesize {t_name="probe_bram_add",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
