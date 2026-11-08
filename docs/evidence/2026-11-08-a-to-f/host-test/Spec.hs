module Main (main) where

import Control.Monad (unless)
import Hedgehog (checkParallel)
import System.Exit (exitFailure)
import qualified TestPsramRegs as PsramRegsTests
import qualified TestSimpleRisc as SimpleRiscTests

main :: IO ()
main = do
  simpleRiscResult <- checkParallel SimpleRiscTests.simpleRiscGroup
  psramRegsResult <- checkParallel PsramRegsTests.psramRegsGroup
  unless (simpleRiscResult && psramRegsResult) exitFailure
