{-# LANGUAGE DataKinds, NoImplicitPrelude, CPP #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- | Simulation-only top. The named ports are the observation ABI, independent
-- of Machine/Pipe packing and of generated internal wire names. Decisions are
-- exported from the real step function; there is no duplicate pipeline model.
module SdramPipelineObserved where

import Clash.Prelude
import qualified SimpleRisc as R
import qualified SdramPipeline as P

type Observations dom =
  (Signal dom Bool, Signal dom R.Word32, Signal dom R.Word32, Signal dom R.Word32,
   Signal dom Bool, Signal dom R.Word32, Signal dom Bool, Signal dom Bool
#ifdef PIPELINE_SLOT_OBSERVATIONS
   -- Stall breakdown (named-v2): generate with -DPIPELINE_SLOT_OBSERVATIONS.
   , Signal dom (Unsigned 4), Signal dom Bool, Signal dom (Unsigned 4), Signal dom (Unsigned 3)
#endif
   )

#ifdef PIPELINE_SLOT_OBSERVATIONS
{-# ANN topEntity (Synthesize {t_name="sdram_pipeline_risc",
 t_inputs=[PortName "clk",PortName "reset",PortName "enable",PortName "uart_rx",PortName "memory_data",PortName "memory_hold",PortName "sd_miso"],
 t_output=PortProduct "" [
   PortProduct "" [PortName "uart_tx",PortName "memory_address",PortName "memory_write",PortName "memory_wdata",PortName "memory_mask",PortName "sd_sck",PortName "sd_mosi",PortName "sd_cs"],
   PortProduct "" [PortName "observe_commit",PortName "observe_word",PortName "observe_pc",PortName "observe_next_pc",PortName "observe_issue",PortName "observe_fetch_pc",PortName "observe_empty",PortName "observe_redirect",PortName "observe_slot",PortName "observe_fetch_port_blocked",PortName "observe_hazard",PortName "observe_redirect_kind"]]}) #-}
#else
{-# ANN topEntity (Synthesize {t_name="sdram_pipeline_risc",
 t_inputs=[PortName "clk",PortName "reset",PortName "enable",PortName "uart_rx",PortName "memory_data",PortName "memory_hold",PortName "sd_miso"],
 t_output=PortProduct "" [
   PortProduct "" [PortName "uart_tx",PortName "memory_address",PortName "memory_write",PortName "memory_wdata",PortName "memory_mask",PortName "sd_sck",PortName "sd_mosi",PortName "sd_cs"],
   PortProduct "" [PortName "observe_commit",PortName "observe_word",PortName "observe_pc",PortName "observe_next_pc",PortName "observe_issue",PortName "observe_fetch_pc",PortName "observe_empty",PortName "observe_redirect"]]}) #-}
#endif
topEntity :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem ->
 Signal XilinxSystem Bit -> Signal XilinxSystem R.Word32 -> Signal XilinxSystem Bool -> Signal XilinxSystem Bit ->
 (P.BoardOutput XilinxSystem, Observations XilinxSystem)
topEntity clk rst en rx dat held miso = withClockResetEnable clk rst en $
  let (output, trace) = P.circuitWithObservations rx dat held miso
   in (output, (R.ptCommit <$> trace, R.ptWord <$> trace, R.ptPc <$> trace, R.ptNextPc <$> trace,
                R.ptIssue <$> trace, R.ptFetchPc <$> trace, R.ptEmpty <$> trace, R.ptRedirect <$> trace
#ifdef PIPELINE_SLOT_OBSERVATIONS
               , R.ptSlot <$> trace, R.ptFetchPortBlocked <$> trace, R.ptHazard <$> trace, R.ptRedirectKind <$> trace
#endif
               ))
