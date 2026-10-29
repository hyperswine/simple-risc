{-# LANGUAGE DataKinds, TypeApplications, NoImplicitPrelude, FlexibleContexts, PackageImports #-}
-- Experimental implementation retained after its routed timing regression.
-- The production top does not instantiate this module. The ownership property
-- exercises real Clash banks here so a rejected optimization still leaves a
-- reproducible executable contract, alongside its archived generated RTL.
module FQueueVariant (expandedQueueWrite, fQueueStorage) where
import Clash.Prelude
import Data.Maybe (fromMaybe)
import qualified "simple-risc" SimpleRisc as R
import qualified "simple-risc" RiscVCompressed as C

expandFetched :: R.Fetched -> R.Fetched
expandFetched f =
  let word = if R.fSize f == 2 then fromMaybe 0 (C.decompress32 (resize (R.fRaw f))) else R.fRaw f
   in (R.fetchedWord (R.fPc f, R.fPredicted f) word) {R.fRaw = R.fRaw f, R.fSize = R.fSize f}

expandedQueueWrite :: R.Pipe -> Maybe (Index 2, R.Fetched)
expandedQueueWrite pipe
  | R.pFCount pipe < 2 = (\f -> (R.pFWrite pipe,expandFetched f)) <$> R.pA pipe
  | otherwise = Nothing

fQueueStorage :: HiddenClockResetEnable dom => Signal dom (Maybe (Index 2, R.Fetched)) -> Signal dom (Vec 2 R.Fetched)
fQueueStorage pending = bundle (imap bank (repeat ()))
 where
 empty = R.Fetched 0 0 False False 0 0 4
 bank index _ = regEn empty
   ((\write -> maybe False ((==index) . fst) write) <$> pending)
   ((\write -> maybe empty snd write) <$> pending)

