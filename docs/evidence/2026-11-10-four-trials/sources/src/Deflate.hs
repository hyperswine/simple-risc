{-# LANGUAGE DataKinds, TypeApplications, FlexibleContexts, RecordWildCards, NoImplicitPrelude, NumericUnderscores, DeriveGeneric, DeriveAnyClass #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
module Deflate where

import Clash.Prelude
import GHC.Generics (Generic)

-- | A timing probe: a serial-input DEFLATE (RFC 1951) inflate for streams
-- made of stored (BTYPE=00) and fixed-Huffman (BTYPE=01) blocks, with the
-- full 32 KiB LZ77 window in block RAM. Dynamic blocks (BTYPE=10) and
-- malformed streams set 'bad'. This exists to measure what the same Clash
-- and Gowin flow reports for a deliberately small, shallow design, so every
-- path is kept short by construction:
--
--   * A cycle either refills the bit buffer or consumes bits, never both,
--     so no path crosses two variable shifts.
--   * Every variable shift amount is at most 15, applied through an explicit
--     case of constant shifts ('shiftBuf' and 'insBuf'): four mux levels, no
--     40-deep barrel.
--   * The fixed-Huffman decode compares bit-reversed (canonical) peeked
--     ranges; the reversal is wiring. Length and distance tables are case
--     functions of five bits.
--   * The window block RAM read is registered, so copy bytes take two cycles
--     and the BRAM clock-to-out is a full cycle budget.
--
-- Contract: input and output use ready/valid handshakes. Hold a valid byte
-- until accepted. Assert in_end with no input valid after the last byte;
-- it is sticky until reset and enables explicit truncation detection. No
-- padding bytes are required. out_valid may remain high under backpressure
-- or for consecutive stored bytes. done/bad are sticky; reset starts a new
-- stream. Dynamic Huffman blocks are intentionally unsupported.

data Phase
  = PhHead
  | -- | stored block: drop to the byte boundary
    PhStoredAlign
  | -- | stored block: LEN and NLEN, one byte at a time
    PhStoredLen
  | -- | stored block: pass bytes through
    PhStoredByte
  | -- | register one literal/length symbol before the consume/extra-bit cycle
    PhSym
  | PhDecoded
  | -- | write and emit the decoded literal
    PhLitEmit
  | -- | decode the 5-bit distance code
    PhDistSym
  | -- | distance extra bits
    PhDistExtra
  | -- | issue the window read at wAddr - dist
    PhCopyRead
  | -- | write and emit the copied byte
    PhCopyWrite
  | PhDone
  | PhBad
  deriving (Generic, NFDataX, Eq, Show)

data S = S
  { phase :: Phase
  , -- | LSB-first bits; bit 0 is next. All bits at or above nBits are zero.
    buf :: BitVector 40
  , nBits :: Unsigned 6
  , decodedSym :: Unsigned 9
  , decodedLen :: Unsigned 4
  , finalBlk :: Bool
  , -- | decoded literal waiting for its emit cycle
    lit :: BitVector 8
  , -- | distance base scratch, set in PhDistSym
    base :: Unsigned 16
  , extra :: Unsigned 4
  , dist :: Unsigned 16
  , -- | decoded copy length, waiting in PhDistSym/PhDistExtra
    copyLen :: Unsigned 16
  , -- | collected byte while LEN/NLEN
    acc :: BitVector 8
  , accCnt :: Unsigned 2
  , lenCtr :: Unsigned 16
  , produced :: Unsigned 15
  , available :: Unsigned 16
  , inputEnded :: Bool
  , -- | the one-cycle output pulse; explicit registers rather than a Maybe,
    -- so every reset value is concrete
    oValid :: Bool
  , oByte :: BitVector 8
  , done :: Bool
  , bad :: Bool
  }
  deriving (Generic, NFDataX, Show)

initState :: S
initState =
  S
    { phase = PhHead,
      buf = 0,
      nBits = 0,
      decodedSym = 0,
      decodedLen = 0,
      finalBlk = False,
      lit = 0,
      base = 0,
      extra = 0,
      dist = 0,
      copyLen = 0,
      acc = 0,
      accCnt = 0,
      lenCtr = 0,
      produced = 0,
      available = 0,
      inputEnded = False,
      oValid = False,
      oByte = 0,
      done = False,
      bad = False
    }

-- | Shift right by 0..15 through a case of constant shifts: each arm is
-- wiring, the case is a four-level mux. This is the only variable shift the
-- design has (besides 'insBuf'), and its amount is bounded because a cycle
-- never consumes more than 15 bits.
shiftBuf :: BitVector 40 -> Unsigned 4 -> BitVector 40
shiftBuf b k = case k of
  0 -> shR b 0
  1 -> shR b 1
  2 -> shR b 2
  3 -> shR b 3
  4 -> shR b 4
  5 -> shR b 5
  6 -> shR b 6
  7 -> shR b 7
  8 -> shR b 8
  9 -> shR b 9
  10 -> shR b 10
  11 -> shR b 11
  12 -> shR b 12
  13 -> shR b 13
  14 -> shR b 14
  _ -> shR b 15
 where
  shR :: BitVector 40 -> Int -> BitVector 40
  shR = shiftR

-- | The refill counterpart: a byte into bits [k .. k+7], same shape.
insBuf :: BitVector 8 -> Unsigned 4 -> BitVector 40
insBuf byte k = case k of
  0 -> shL b 0
  1 -> shL b 1
  2 -> shL b 2
  3 -> shL b 3
  4 -> shL b 4
  5 -> shL b 5
  6 -> shL b 6
  7 -> shL b 7
  8 -> shL b 8
  9 -> shL b 9
  10 -> shL b 10
  11 -> shL b 11
  12 -> shL b 12
  13 -> shL b 13
  14 -> shL b 14
  _ -> shL b 15
 where
  b = zeroExtend byte :: BitVector 40
  shL :: BitVector 40 -> Int -> BitVector 40
  shL = shiftL

dropBits :: S -> Unsigned 4 -> S
dropBits s k = s {buf = shiftBuf (buf s) k, nBits = nBits s - fromIntegral k}

noOut :: S -> S
noOut s = s {oValid = False}

-- | Emit a byte: output pulse and the LZ77 window write at the current
-- write address (the pre-increment 'produced', truncated to the window).
emit :: S -> BitVector 8 -> S
emit s b = s {oValid = True, oByte = b, produced = produced s + 1, available = if available s < 32768 then available s + 1 else 32768}

endBlock :: S -> S
endBlock s = if finalBlk s then s {phase = PhDone, done = True} else s {phase = PhHead}

-- | Bit-reverse nine peeked bits (wiring) into the canonical MSB-first
-- code value.
rev9 :: BitVector 9 -> BitVector 9
rev9 p = z (z (z (z (z (z (z (z (z 0 (t 0)) (t 1)) (t 2)) (t 3)) (t 4)) (t 5)) (t 6)) (t 7)) (t 8)
 where
  t i = if testBit p i then 1 else 0 :: BitVector 9
  z acc bit = (acc `shiftL` 1) .|. bit

rev5 :: BitVector 5 -> BitVector 5
rev5 p = z (z (z (z (z 0 (t 0)) (t 1)) (t 2)) (t 3)) (t 4)
 where
  t i = if testBit p i then 1 else 0 :: BitVector 5
  z acc bit = (acc `shiftL` 1) .|. bit

-- | The fixed literal/length tree, decoded from the canonical value of the
-- next (at most) nine bits: RFC 1951 section 3.2.6. Returns the symbol and
-- its code length, with symbol 511 for an impossible code.
decodeFixed :: BitVector 9 -> (Unsigned 9, Unsigned 4)
decodeFixed p =
  let c = unpack (rev9 p) :: Unsigned 9
      c7 = shiftR c 2
      c8 = shiftR c 1
   in if c7 <= 23
        then (256 + c7, 7)
        else
          if 0x30 <= c8 && c8 <= 0xBF
            then (c8 - 0x30, 8)
            else
              if c8 <= 0xC7
                then (c8 + 88, 8)
                else
                  if c >= 0x190
                    then (c - 0x190 + 144, 9)
                    else (511, 0)

-- | Length bases and extra-bit counts for length codes 257..285.
lenBase :: Unsigned 5 -> Unsigned 16
lenBase i = case i of
  0 -> 3
  1 -> 4
  2 -> 5
  3 -> 6
  4 -> 7
  5 -> 8
  6 -> 9
  7 -> 10
  8 -> 11
  9 -> 13
  10 -> 15
  11 -> 17
  12 -> 19
  13 -> 23
  14 -> 27
  15 -> 31
  16 -> 35
  17 -> 43
  18 -> 51
  19 -> 59
  20 -> 67
  21 -> 83
  22 -> 99
  23 -> 115
  24 -> 131
  25 -> 163
  26 -> 195
  27 -> 227
  28 -> 258
  _ -> 0

lenExtra :: Unsigned 5 -> Unsigned 4
lenExtra i = case i of
  8 -> 1
  9 -> 1
  10 -> 1
  11 -> 1
  12 -> 2
  13 -> 2
  14 -> 2
  15 -> 2
  16 -> 3
  17 -> 3
  18 -> 3
  19 -> 3
  20 -> 4
  21 -> 4
  22 -> 4
  23 -> 4
  24 -> 5
  25 -> 5
  26 -> 5
  27 -> 5
  _ -> 0

distBase :: Unsigned 5 -> Unsigned 16
distBase i = case i of
  0 -> 1
  1 -> 2
  2 -> 3
  3 -> 4
  4 -> 5
  5 -> 7
  6 -> 9
  7 -> 13
  8 -> 17
  9 -> 25
  10 -> 33
  11 -> 49
  12 -> 65
  13 -> 97
  14 -> 129
  15 -> 193
  16 -> 257
  17 -> 385
  18 -> 513
  19 -> 769
  20 -> 1025
  21 -> 1537
  22 -> 2049
  23 -> 3073
  24 -> 4097
  25 -> 6145
  26 -> 8193
  27 -> 12289
  28 -> 16385
  29 -> 24577
  _ -> 0

distExtra :: Unsigned 5 -> Unsigned 4
distExtra i = case i of
  4 -> 1
  5 -> 1
  6 -> 2
  7 -> 2
  8 -> 3
  9 -> 3
  10 -> 4
  11 -> 4
  12 -> 5
  13 -> 5
  14 -> 6
  15 -> 6
  16 -> 7
  17 -> 7
  18 -> 8
  19 -> 8
  20 -> 9
  21 -> 9
  22 -> 10
  23 -> 10
  24 -> 11
  25 -> 11
  26 -> 12
  27 -> 12
  28 -> 13
  29 -> 13
  _ -> 0

type Input = (Bool, BitVector 8, Bool, Bool, BitVector 8) -- valid, byte, end, out_ready, RAM data

type Output =
  ( Unsigned 15 -- window read address for the next cycle
  , Maybe (Unsigned 15, BitVector 8) -- window write this cycle
  , Bool -- in_ready
  , Bool -- out_valid
  , BitVector 8 -- out_byte
  , Bool -- done (sticky)
  , Bool -- bad (sticky)
  )

-- | Refill never interrupts an emission or the registered RAM read/write
-- pair. Keeping the copy address selected also preserves RAM data while the
-- output consumer stalls. Writes and counters advance only on acceptance.
step :: S -> Input -> (S, Output)
step s0 (inValid, inByte, inEnd, outReady, rData) =
  (s1, (rAddr, wReq, inReady, outValid, outByte, done s1, bad s1))
 where
  s = s0 {inputEnded = inputEnded s0 || (inEnd && not inValid)}
  active = phase s /= PhDone && phase s /= PhBad
  canRefill = phase s /= PhLitEmit && phase s /= PhCopyRead && phase s /= PhCopyWrite
    && (phase s /= PhStoredByte || nBits s < 8)
  inReady = active && canRefill && not (inputEnded s) && nBits s <= 15
  refillCycle = inReady && inValid
  refill = noOut s {buf = buf s .|. insBuf inByte (truncateB (nBits s)), nBits = nBits s + 8}
  (candidate, writeCandidate) = if refillCycle then (refill, Nothing) else advance s rData
  outValid = oValid candidate
  outByte = oByte candidate
  stalled = outValid && not outReady
  s1 = if stalled then noOut s else candidate
  wReq = if stalled then Nothing else writeCandidate
  rAddr = case phase s of
    PhCopyRead -> produced s - truncateB (dist s)
    PhCopyWrite -> produced s - truncateB (dist s)
    _ -> 0

-- No more input can arrive once EOF is latched: insufficient bits is an error.
needInput :: S -> S
needInput s = if inputEnded s then noOut s {phase = PhBad, bad = True} else noOut s

-- | The consume path (taken only when not refilling). Every branch needs at
-- most 15 bits, and a branch that cannot run yet returns the state
-- unchanged with the output pulse cleared.
advance :: S -> BitVector 8 -> (S, Maybe (Unsigned 15, BitVector 8))
advance s0 rData = case phase s0 of
  PhDone -> (noOut s0, Nothing)
  PhBad -> (noOut s0, Nothing)
  PhHead
    | nBits s0 < 3 -> (needInput s0, Nothing)
    | otherwise ->
        let h = truncateB (buf s0) :: BitVector 3
            bfinal = testBit h 0
            t1 = testBit h 1
            t2 = testBit h 2
            dropped = (dropBits (noOut s0) 3) {finalBlk = bfinal}
         in ( case (t2, t1) of
                (False, False) -> dropped {phase = PhStoredAlign, accCnt = 0, acc = 0}
                (False, True) -> dropped {phase = PhSym}
                _ -> dropped {phase = PhBad, bad = True}
            , Nothing
            )
  PhStoredAlign ->
    let k = truncateB (nBits s0 .&. 7)
     in ((dropBits (noOut s0) k) {phase = PhStoredLen, base = 0, accCnt = 0}, Nothing)
  PhStoredLen
    | nBits s0 < 8 -> (needInput s0, Nothing)
    | otherwise ->
        let b = truncateB (buf s0) :: BitVector 8
            s = dropBits (noOut s0) 8
            word hi lo = unpack (zeroExtend (lo :: BitVector 8) .|. shiftL (zeroExtend hi) 8) :: Unsigned 16
         in ( case accCnt s0 of
                0 -> s {acc = b, accCnt = 1}
                1 -> s {base = word b (acc s0), accCnt = 2}
                2 -> s {acc = b, accCnt = 3}
                _ ->
                  if word b (acc s0) == complement (base s0)
                    then if base s0 == 0 then endBlock s else s {phase = PhStoredByte, lenCtr = base s0}
                    else s {phase = PhBad, bad = True}
            , Nothing
            )
  PhStoredByte
    | nBits s0 < 8 -> (needInput s0, Nothing)
    | otherwise ->
        let b = truncateB (buf s0) :: BitVector 8
            s = dropBits s0 8
            written = truncateB (produced s0)
            emitted = emit s b
         in ( if lenCtr s0 == 1
                then endBlock emitted
                else emitted {lenCtr = lenCtr s0 - 1}
            , Just (written, b)
            )
  PhSym
    -- Do not latch a partial peek while more input may arrive. EOF permits
    -- the shorter seven/eight-bit codes, checked in PhDecoded.
    | nBits s0 < 7 || (nBits s0 < 9 && not (inputEnded s0)) -> (needInput s0, Nothing)
    | otherwise ->
        let (sym, codeLen) = decodeFixed (truncateB (buf s0))
         in (noOut s0 {phase = PhDecoded, decodedSym = sym, decodedLen = codeLen}, Nothing)
  PhDecoded ->
        let sym = decodedSym s0
            codeLen = decodedLen s0
            isLen = sym >= 257 && sym <= 285
            idx = truncateB (sym - 257) :: Unsigned 5
            e = if isLen then lenExtra idx else 0
            total = fromIntegral codeLen + fromIntegral e :: Unsigned 6
         in if sym == 511
              then (noOut s0 {phase = PhBad, bad = True}, Nothing)
              else
                if nBits s0 < total
                  then (needInput s0, Nothing)
                  else
                    if sym <= 255
                      then ((dropBits (noOut s0) codeLen) {phase = PhLitEmit, lit = truncateB (pack sym)}, Nothing)
                      else
                        if sym == 256
                          then (endBlock (dropBits (noOut s0) codeLen), Nothing)
                          else
                            if sym >= 286
                              then (noOut s0 {phase = PhBad, bad = True}, Nothing)
                              else
                                let evFull = unpack (truncateB (shiftBuf (buf s0) codeLen) :: BitVector 5) :: Unsigned 5
                                    mask = shiftL 1 (fromIntegral e) - 1 :: Unsigned 16
                                    extraVal = resize evFull .&. mask
                                 in ( (dropBits (noOut s0) (truncateB total)) {phase = PhDistSym, copyLen = lenBase idx + extraVal}
                                    , Nothing
                                    )
  PhLitEmit ->
    let written = truncateB (produced s0)
     in (emit (noOut s0 {phase = PhSym}) (lit s0), Just (written, lit s0))
  PhDistSym
    | nBits s0 < 5 -> (needInput s0, Nothing)
    | otherwise ->
        let p5 = truncateB (buf s0) :: BitVector 5
            idx = unpack (rev5 p5) :: Unsigned 5
         in if idx >= 30
              then (noOut s0 {phase = PhBad, bad = True}, Nothing)
              else
                ( (dropBits (noOut s0) 5) {phase = PhDistExtra, extra = distExtra idx, base = distBase idx}
                , Nothing
                )
  PhDistExtra
    | nBits s0 < fromIntegral (extra s0) -> (needInput s0, Nothing)
    | otherwise ->
        let e = extra s0
            -- the distance code was consumed in PhDistSym: the extra bits
            -- start at bit 0, so no shift here (unlike the length extra,
            -- which skips the not-yet-consumed length code)
            ev = unpack (zeroExtend (truncateB (buf s0) :: BitVector 13)) :: Unsigned 16
            mask = shiftL 1 (fromIntegral e) - 1 :: Unsigned 16
            d = base s0 + (ev .&. mask)
         in if d > available s0
              then (noOut s0 {phase = PhBad, bad = True}, Nothing)
              else ((dropBits (noOut s0) e) {phase = PhCopyRead, dist = d, lenCtr = copyLen s0}, Nothing)
  PhCopyRead -> (noOut s0 {phase = PhCopyWrite}, Nothing)
  PhCopyWrite ->
    let written = truncateB (produced s0)
        emitted = emit (noOut s0) rData
     in ( if lenCtr s0 == 1
            then emitted {phase = PhSym}
            else emitted {lenCtr = lenCtr s0 - 1, phase = PhCopyRead}
        , Just (written, rData)
        )

topEntity ::
  Clock XilinxSystem ->
  Reset XilinxSystem ->
  Enable XilinxSystem ->
  Signal XilinxSystem Bool ->
  Signal XilinxSystem (BitVector 8) ->
  Signal XilinxSystem Bool ->
  Signal XilinxSystem Bool ->
  ( Signal XilinxSystem Bool,
    Signal XilinxSystem Bool,
    Signal XilinxSystem (BitVector 8),
    Signal XilinxSystem Bool,
    Signal XilinxSystem Bool
  )
topEntity clk rst en = withClockResetEnable clk rst en circuit

circuit ::
  HiddenClockResetEnable XilinxSystem =>
  Signal XilinxSystem Bool ->
  Signal XilinxSystem (BitVector 8) ->
  Signal XilinxSystem Bool ->
  Signal XilinxSystem Bool ->
  ( Signal XilinxSystem Bool,
    Signal XilinxSystem Bool,
    Signal XilinxSystem (BitVector 8),
    Signal XilinxSystem Bool,
    Signal XilinxSystem Bool
  )
circuit inValid inByte inEnd outReady = (inReady, outValid, outByte, doneFlag, badFlag)
 where
  rData = blockRam (repeat 0 :: Vec 32768 (BitVector 8)) rAddr wReq
  (rAddr, wReq, inReady, outValid, outByte, doneFlag, badFlag) =
    mealyB step initState (inValid, inByte, inEnd, outReady, rData) ::
      ( Signal XilinxSystem (Unsigned 15)
      , Signal XilinxSystem (Maybe (Unsigned 15, BitVector 8))
      , Signal XilinxSystem Bool
      , Signal XilinxSystem Bool
      , Signal XilinxSystem (BitVector 8)
      , Signal XilinxSystem Bool
      , Signal XilinxSystem Bool
      )

{-# ANN topEntity
  ( Synthesize
      { t_name = "deflate_inflate",
        t_inputs =
          [ PortName "clk",
            PortName "reset",
            PortName "enable",
            PortName "in_valid",
            PortName "in_byte",
            PortName "in_end",
            PortName "out_ready"
          ],
        t_output =
          PortProduct
            ""
            [ PortName "in_ready",
              PortName "out_valid",
              PortName "out_byte",
              PortName "done",
              PortName "bad"
            ]
      }
  ) #-}
