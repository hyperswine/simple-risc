module Main (main) where

import Control.Monad (unless)
import Hedgehog (checkParallel)
import System.Exit (exitFailure)
import qualified CoreMini as CoreMiniTests
import qualified Deflate as DeflateTests
import qualified PsramRegs as PsramRegsTests
import qualified SimpleRisc as SimpleRiscTests

main :: IO ()
main = do
  simpleRiscResult <- checkParallel SimpleRiscTests.simpleRiscGroup
  psramRegsResult <- checkParallel PsramRegsTests.psramRegsGroup
  deflateResult <- checkParallel DeflateTests.deflateGroup
  coreMiniResult <- checkParallel CoreMiniTests.coreMiniGroup
  unless (simpleRiscResult && psramRegsResult && deflateResult && coreMiniResult) exitFailure
