{-# LANGUAGE DataKinds, NoImplicitPrelude, TypeApplications, PackageImports, ScopedTypeVariables, OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
module CoreMini where

import Clash.Prelude
import Hedgehog
import qualified Prelude as P
import qualified "simple-risc" CoreMini as M

-- | The hardware fold (registered pipeline state through Clash's simulator,
-- including the IROM/DRAM registered reads, forwarding and redirect flush)
-- must land on the sequential ISA model's fold after each program halts,
-- and stay there.
checkProgram :: (String, [(Int, M.Instr)], M.Regs) -> Property
checkProgram (name, prog, wantRegs) = withTests 1 . property $ do
  let cycles = 2048 :: Int
      trace = sampleN cycles (M.miniCore (M.irom512 prog) :: Signal XilinxSystem (BitVector 32))
      final = P.last trace
      want = M.foldRegs wantRegs
  footnote (name P.++ ": hw fold " P.++ P.show final P.++ " model fold " P.++ P.show want)
  -- stable after halt: the last ten samples agree
  (P.take 10 (P.drop 2038 trace)) === (P.replicate 10 final)
  final === want

expectedSum, expectedCall, expectedBranch :: M.Regs
expectedSum = M.model M.progSum
expectedCall = M.model M.progCall
expectedBranch = M.model M.progBranch

coreMiniGroup :: Group
coreMiniGroup =
  Group
    "CoreMini"
    [ ("sum loop: model vs hardware fold", checkProgram ("sum", M.progSum, expectedSum)),
      ("call/return: model vs hardware fold", checkProgram ("call", M.progCall, expectedCall)),
      ("branch both ways + flush: model vs hardware fold", checkProgram ("branch", M.progBranch, expectedBranch))
    ]
