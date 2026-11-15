{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module Deflate where

import Clash.Prelude
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe (fromMaybe)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Hedgehog
import "simple-risc" Deflate as D
import qualified Prelude as P

-- Registered-read RAM model: reads observe the old memory contents.
-- Input stalls and output backpressure are independent deterministic schedules.
runScheduled :: Int -> Int -> Int -> [BitVector 8] -> ([BitVector 8], Int, Bool, Bool, Bool)
runScheduled bound inputSeed outputSeed stream = go D.initState IntMap.empty 0 [] 0 stream False Nothing False
 where
  allowed seed cycle = seed == 0 || ((cycle * 17 + seed * 13) `P.mod` 23 >= 8 && (cycle + seed) `P.mod` 101 >= 11)
  go s ram rdata acc cycle bytes offered held broken
    | cycle >= bound || D.done s || D.bad s = (P.reverse acc, cycle, D.done s, D.bad s, broken)
    | otherwise =
      let valid = not (P.null bytes) && (offered || allowed inputSeed cycle)
          byte = case bytes of b:_ -> b; [] -> 0
          readyOut = allowed outputSeed cycle
          (s', (addr, wr, readyIn, validOut, byteOut, _, _)) = D.step s (valid, byte, P.null bytes, readyOut, rdata)
          broken' = broken || case held of Just b -> not validOut || byteOut /= b; Nothing -> False
          held' = if validOut && not readyOut then Just byteOut else Nothing
          ram' = case wr of Just (a,b) -> IntMap.insert (fromIntegral a) b ram; Nothing -> ram
          rdata' = fromMaybe 0 (IntMap.lookup (fromIntegral addr) ram)
          acc' = if validOut && readyOut then byteOut : acc else acc
          bytes' = if valid && readyIn then P.tail bytes else bytes
       in go s' ram' rdata' acc' (cycle + 1) bytes' (valid && not readyIn) held' broken'

runStream :: Int -> [BitVector 8] -> ([BitVector 8], Int, Bool, Bool, Bool)
runStream bound = runScheduled bound 0 0

strBytes :: P.String -> [BitVector 8]
strBytes = P.map (fromIntegral . fromEnum)

hexBytes :: P.String -> [BitVector 8]
hexBytes = hexDigits
 where
  hexDigits [] = []
  hexDigits (a : b : rest) = fromDigit a * 16 + fromDigit b : hexDigits rest
  hexDigits [_] = P.error "odd hex length"
  fromDigit :: Char -> BitVector 8
  fromDigit c
    | c P.>= '0' && c P.<= '9' = fromIntegral (fromEnum c - fromEnum '0')
    | c P.>= 'a' && c P.<= 'f' = fromIntegral (fromEnum c - fromEnum 'a' + 10)
    | otherwise = P.error "bad hex digit"

loremText :: P.String
loremText =
  "the quick brown fox jumps over the lazy dog. "
    P.++ "packing arbitrary prose tests literals and short copies; "
    P.++ "the window keeps every byte so distances reach back through it. "

loremBytes :: Int -> [BitVector 8]
loremBytes n = P.take n (strBytes (P.cycle loremText))

storedPayload :: [BitVector 8]
storedPayload =
  P.map fromIntegral [0 .. 63] P.++ P.replicate 32 255 P.++ strBytes "tail bytes here"

-- | The vectors of boards/tangnano20k/deflate/make_vectors.py, with the
-- streams as generated and the expected outputs rebuilt from their patterns.
vectors :: [(P.String, [BitVector 8], [BitVector 8], Bool)]
vectors =
  [ ("hello", hexBytes helloStream, strBytes (P.take 111 (P.cycle "Hello, DEFLATE on the Tang Nano 20K! ")), False),
    ("abc", hexBytes abcStream, strBytes (P.concat (P.replicate 2000 "abc")), False),
    ("lorem", hexBytes loremStream, loremBytes 2560, False),
    ("big", hexBytes bigStream, loremBytes 16384, False),
    ("empty", hexBytes "0300", [], False),
    ("stored", hexBytes storedStream, storedPayload, False),
    ("hand-far-distance", hexBytes "73045eff0f00", strBytes "A", True),
    ("hand-bad-nlen", hexBytes "010300fdff414243", [], True),
    ("zlib-stored", hexBytes zlibStoredStream, P.map (\i -> fromIntegral ((i * 137 + 11) `P.mod` 251 :: Int)) [0 .. 299], False),
    ("dynamic", hexBytes dynamicStream, [], True)
  ]
 where
  helloStream :: P.String
  helloStream = "f348cdc9c9d751707175f3710c7155c8cf5328c948550849cc4b57f04bcccb573032f05654f0a09a2200"
  abcStream :: P.String
  abcStream = "4b4c4a4e1c45a368148da251348a46d1281a45a368148da251348a46d1281a45a368148da251348a4611650800"
  loremStream :: P.String
  loremStream = "2bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb291424266767e6a52b2416256596142516552a1414e517a72a94a41697142be46496a41625e6142b24e6a5281467e417952824e71764a6165b838d29cfcc4bc92f57c84e4d051a9e0a34bc5221a9b22455a1385f2125b3b824312f39b558a128353139432109680f504f517e697a864266891e58ffa82b475d39eaca51578eba72d495a3ae1c75e5a82ba9e14a00"
  bigStream :: P.String
  bigStream =
    "2bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb291424266767e6a52b2416256596142516552a1414e517a72a94a41697142be46496a41625e6142b24e6a5281467e417952824e71764a6165b838d29cfcc4bc92f57c84e4d051a9e0a34bc5221a9b22455a1385f2125b3b824312f39b558a128353139432109680f504f517e697a864266891e58ffa82b475d39eaca51578eba72d495a3ae1c75e5a82b475d39eaca51578eba72d495a3ae1c75e5a82b475d39eaca51578eba72d495a3ae1c75e5a82b475d39eaca51578eba72d495a3ae1c75e5a82b475d39eaca51578eba72d495a3ae1c75e5a82b475d39eaca51578eba72d495a3ae1c75e5a82b475d39eaca51578eba72d495a3ae1c75e5a82b475d39eaca51578eba72d495c3d79500"
  storedStream :: P.String
  storedStream = "016f0090ff000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7461696c2062797465732068657265"
  zlibStoredStream :: P.String
  zlibStoredStream = "e39ea2b4daf250c0cdf40f753c5395d7581d0ebc95f1b19e779aca5aeb2341b7333f35f04d575d677334f84ed6e746fe196aeb6d8f85dccdfed22430537d83ddf1d07b395f9b0567696cb43f11763ff75b8bd06ccd4d0e27c31fe47d6f159ea3b5d9f154c4c3fc1f6d2273b5b7389d8e7c54f0b35d749ece56e733518f0b7f7588cdd7dde67236fa491143a7f802bdedaee7629e163376492cd4dfe1763ef6590953b7e422839dee17e29e9732f7482d36dce57131fe45194baff412a3dd9e97125e96b3f6c92c35dee37539f155055bbfec3293bdde57925e57b24f905b6ebacfe76af29b2a8e89f22bccf6fb5e4b795bcd394961a5f901bfeba9ef6ab8262baeb238e87f23ed7d2d37a95e0700"
  dynamicStream :: P.String
  dynamicStream = "edcecb15c2300c44d156a682344035fe88d82458465208a67a7c52034bad75e6e95a21bc8e9a3644e1b3e1ce1f3c8e6757f09b0436cf7bf80e645e17f490b6da560489d524c840175682919a62af4612764568195a580c897b25bd5d99b3b6cc2736a219a7191f88c308cac8552db4440aa1900ae2fc3337c2c75a506db9f6ae74a52b5de94a57bad295aefc87f207"

prop_vector :: P.String -> ([BitVector 8], [BitVector 8], Bool) -> PropertyT IO ()
prop_vector name (stream, expected, reject) = do
  let bound = 400_000
      (got, cycles, done, bad, handshakeViolation) = runStream bound stream
  if reject
    then do
      bad === True
      done === False
      got === expected
    else do
      done === True
      bad === False
      handshakeViolation === False
      got === expected

prop_deflate_vectors :: Property
prop_deflate_vectors = withTests 1 . property $ do
  mapM_ (\(name, stream, expected, reject) -> prop_vector name (stream, expected, reject)) vectors

prop_decodeFixed_spot_values :: Property
prop_decodeFixed_spot_values = withTests 1 . property $ do
  -- Each case feeds the LSB-first peek of a canonical fixed-tree code (its
  -- bits transmitted MSB first, padded with two zero bits) and expects the
  -- symbol back. Values computed from the RFC 1951 section 3.2.6 table.
  -- canonical 0000000 -> 256;  canonical 0010111 -> 279;
  -- canonical 00110000 -> literal 0; canonical 10111111 -> 143;
  -- canonical 11000000 -> 280; canonical 11000111 -> 287;
  -- canonical 110010000 -> 144; canonical 111111111 -> 255.
  fst (D.decodeFixed 0x000) === 256
  fst (D.decodeFixed 0x074) === 279
  fst (D.decodeFixed 0x00C) === 0
  fst (D.decodeFixed 0x1FD) === 143
  fst (D.decodeFixed 0x003) === 280
  fst (D.decodeFixed 0x0E3) === 287
  fst (D.decodeFixed 0x013) === 144
  fst (D.decodeFixed 0x1FF) === 255

prop_stored_block_byte_alignment :: Property
prop_stored_block_byte_alignment = withTests 1 . property $ do
  -- A stored block whose header ends mid-byte: BFINAL=1, BTYPE=00 and five
  -- padding bits before the byte boundary, so the align step must drop
  -- exactly those five bits before LEN.
  let stream = hexBytes "d1" P.++ hexBytes "0200" P.++ hexBytes "fdff" P.++ hexBytes "6f6b"
      (got, _, done, bad, _) = runStream 10_000 stream
  done === True
  bad === False
  got === strBytes "ok"

prop_copy_heavy_stream_throughput :: Property
prop_copy_heavy_stream_throughput = withTests 1 . property $ do
  -- 'abc' emits 6000 bytes almost entirely through copies at two cycles per
  -- byte; refills must keep the decoder inside four cycles per output byte.
  let (_, cycles, done, _, _) = runStream 2_000_000 (hexBytes "4b4c4a4e1c45a368148da251348a46d1281a45a368148da251348a46d1281a45a368148da251348a4611650800")
  done === True
  assert (cycles < 4 * 6000 + 1000)

-- The same generated corpus is consumed by the RTL bench; accepted streams
-- are independently inflated by Python zlib when the fixtures are generated.
prop_edge_corpus :: Property
prop_edge_corpus = withTests 1 . property $ do
  rows <- evalIO (P.readFile "boards/tangnano20k/deflate/vectors/cases.txt")
  mapM_ checkCase (P.lines rows)
 where
  checkCase row = case P.words row of
    [name, rejectFlag] -> do
      let prefix = "boards/tangnano20k/deflate/vectors/" P.++ name
      stream <- evalIO (P.readFile (prefix P.++ ".deflate.hex"))
      expected <- evalIO (P.readFile (prefix P.++ ".expected.hex"))
      annotate name
      mapM_ (checkSchedule (rejectFlag == "1") (hexBytes (P.concat (P.words stream))) (hexBytes (P.concat (P.words expected)))) [(0,0),(1,0),(0,3),(7,11)]
    _ -> failure
  checkSchedule reject stream expected (i,o) = do
    let (got, _, done, bad, broken) = runScheduled 3_000_000 i o stream
    got === expected
    bad === reject
    done === not reject
    broken === False

prop_random_stalls :: Property
prop_random_stalls = withTests 50 . property $ do
  i <- forAll (Gen.int (Range.linear 1 10000))
  o <- forAll (Gen.int (Range.linear 1 10000))
  mapM_ (check i o) vectors
 where
  check i o (name, stream, expected, reject) = do
    annotate name
    let (got, _, done, bad, broken) = runScheduled 400_000 i o stream
    got === expected
    bad === reject
    done === not reject
    broken === False

deflateGroup :: Group
deflateGroup =
  Group "Deflate"
    [ ("vectors decode to zlib's own inflation", prop_deflate_vectors),
      ("decodeFixed spot values across the four code lengths", prop_decodeFixed_spot_values),
      ("stored block after a mid-byte header", prop_stored_block_byte_alignment),
      ("copy-heavy stream finishes within four cycles per byte", prop_copy_heavy_stream_throughput),
      ("edge corpus with input stalls and output backpressure", prop_edge_corpus),
      ("random input stalls and output backpressure", prop_random_stalls)
    ]
