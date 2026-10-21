module Main (main) where

import Control.Monad (unless)
import Hedgehog (checkParallel)
import System.Exit (exitFailure)
import qualified PsramRegs as PsramRegsTests
import qualified SimpleRisc as SimpleRiscTests

main :: IO ()
main = do
  simpleRiscResult <- checkParallel SimpleRiscTests.simpleRiscGroup
  psramRegsResult <- checkParallel PsramRegsTests.psramRegsGroup
  unless (simpleRiscResult && psramRegsResult) exitFailure
