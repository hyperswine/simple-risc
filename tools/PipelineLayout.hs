{-# LANGUAGE DataKinds, DefaultSignatures, FlexibleContexts, FlexibleInstances #-}
{-# LANGUAGE KindSignatures, ScopedTypeVariables, TypeApplications, TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- Host-only metadata for attributing a frozen generated register to source
-- fields. Functional tests use named ports, never this layout. The explicit
-- CommitKind rule follows its one-hot DataReprAnn; always verify the emitted
-- register width against this metadata before attributing a bit.
module Main (main) where

import Clash.Prelude (Vec, Unsigned, Signed, BitVector, Index)
import Data.Kind (Type)
import Data.List (intercalate, mapAccumL)
import Data.Proxy (Proxy(..))
import GHC.Generics
import GHC.TypeNats (KnownNat, natVal)
import qualified SimpleRisc.Types as R

class Width a where
  width :: Proxy a -> Int
  default width :: GWidth (Rep a) => Proxy a -> Int
  width _ = let (constructors, payload) = gwidth (Proxy @(Rep a))
             in ceilingLog2 constructors + payload

ceilingLog2 :: Int -> Int
ceilingLog2 n = length (takeWhile (< n) (iterate (* 2) 1))

class GWidth (f :: Type -> Type) where
  gwidth :: Proxy f -> (Int, Int)

instance GWidth f => GWidth (M1 i c f) where
  gwidth _ = gwidth (Proxy @f)
instance (GWidth a, GWidth b) => GWidth (a :+: b) where
  gwidth _ = let (ac, aw) = gwidth (Proxy @a); (bc, bw) = gwidth (Proxy @b)
             in (ac + bc, max aw bw)
instance (GWidth a, GWidth b) => GWidth (a :*: b) where
  gwidth _ = (1, snd (gwidth (Proxy @a)) + snd (gwidth (Proxy @b)))
instance Width a => GWidth (K1 i a) where
  gwidth _ = (1, width (Proxy @a))
instance GWidth U1 where
  gwidth _ = (1, 0)

instance Width Bool where width _ = 1
instance KnownNat n => Width (Unsigned n) where width _ = fromIntegral (natVal (Proxy @n))
instance KnownNat n => Width (Signed n) where width _ = fromIntegral (natVal (Proxy @n))
instance KnownNat n => Width (BitVector n) where width _ = fromIntegral (natVal (Proxy @n))
instance KnownNat n => Width (Index n) where width _ = ceilingLog2 (fromIntegral (natVal (Proxy @n)))
instance (KnownNat n, Width a) => Width (Vec n a) where width _ = fromIntegral (natVal (Proxy @n)) * width (Proxy @a)
instance Width a => Width (Maybe a) where width _ = 1 + width (Proxy @a)
instance (Width a, Width b) => Width (a, b)
instance Width R.CommitKind where width _ = fst (gwidth (Proxy @(Rep R.CommitKind)))
instance Width R.ExecuteControl
instance Width R.CompareResults
instance Width R.Computed
instance Width R.Fetched
instance Width R.ExecuteOne
instance Width R.ExecuteTwo
instance Width R.MemoryStage
instance Width R.Action
instance Width R.BtbEntry
instance Width a => Width (R.Slot a)
instance Width R.Pipe
instance Width R.StagePayloads

class GFields (f :: Type -> Type) where
  gfields :: Proxy f -> [(String, Int)]
instance GFields f => GFields (M1 D c f) where gfields _ = gfields (Proxy @f)
instance GFields f => GFields (M1 C c f) where gfields _ = gfields (Proxy @f)
instance (GFields a, GFields b) => GFields (a :*: b) where
  gfields _ = gfields (Proxy @a) ++ gfields (Proxy @b)
instance (Selector s, Width a) => GFields (M1 S s (K1 i a)) where
  gfields _ = [(selName (undefined :: M1 S s (K1 i a) ()), width (Proxy @a))]

record :: forall a. (Width a, GFields (Rep a)) => String -> Proxy a -> String
record name _ =
  let total = width (Proxy @a)
      field high (label, size) =
        (high - size, "{\"name\":" ++ show label ++ ",\"high\":" ++ show (high - 1) ++ ",\"low\":" ++ show (high - size) ++ "}")
      (remaining, fields) = mapAccumL field total (gfields (Proxy @(Rep a)))
   in if remaining /= 0 then error "record layout width mismatch"
      else "{\"type\":" ++ show name ++ ",\"bits\":" ++ show total ++ ",\"fields\":[" ++ intercalate "," fields ++ "]}"

main :: IO ()
main = putStrLn $ "[" ++ intercalate ","
  [record "Pipe" (Proxy @R.Pipe), record "StagePayloads" (Proxy @R.StagePayloads),
   record "Fetched" (Proxy @R.Fetched), record "ExecuteOne" (Proxy @R.ExecuteOne),
   record "ExecuteTwo" (Proxy @R.ExecuteTwo), record "MemoryStage" (Proxy @R.MemoryStage)] ++ "]"
