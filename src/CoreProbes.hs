{-# LANGUAGE DataKinds, NoImplicitPrelude, TypeApplications, FlexibleContexts, NumericUnderscores, DeriveGeneric, DeriveAnyClass, ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
module CoreProbes where

import Clash.Prelude
import Data.Maybe (fromMaybe)
import GHC.Generics (Generic)
import qualified SimpleRisc as R

-- | Standalone timing probes of individual core structures, following the
-- Fast-Clash probe method: each circuit synthesizes once and routes at five
-- placement options of that frozen netlist, and the vendor's setup-derived
-- Fmax is the measured result. Each probe models one arc of the RV32IM canon
-- (8f83a6d) using the core's own functions, with feedback keeping every
-- output bit live. A probe measures one register-to-register arc, not the
-- whole pipeline: its number bounds what collapsing that arc into one cycle
-- could reach, and localizes which core structure sets a clock limit.

-- A 32-bit LFSR drives the control fields that vary in the real machine.
lfsrNext :: BitVector 32 -> BitVector 32
lfsrNext x = (x `shiftL` 1) .|. zeroExtend (slice d31 d31 x `xor` slice d21 d21 x `xor` slice d1 d1 x `xor` slice d0 d0 x)

lfsrS :: HiddenClockResetEnable d => Signal d (BitVector 32)
lfsrS = q where q = register 0x1 (lfsrNext <$> q)

-- | Fold a word and up to three flags into the 32-bit observable.
foldQ :: R.Word32 -> Bool -> Bool -> Bool -> BitVector 32
foldQ w a b c = bitCoerce w `xor` zeroExtend (pack (c, b, a))

-- | Synthetic legal R-type instructions: opcode OP, funct3 across all eight
-- values, funct7 alternating 0x00/0x20 (mul/div excluded: selectedAlu is
-- Nothing there and the result path would fold to a constant).
rTypeInstr :: BitVector 32 -> BitVector 32
rTypeInstr r =
  0x33
    .|. zeroExtend (pack (slice d14 d12 r)) `shiftL` 12
    .|. zeroExtend (pack (slice d19 d15 r)) `shiftL` 20
    .|. zeroExtend (pack (slice d24 d20 r)) `shiftL` 25
    .|. zeroExtend (pack (slice d31 d31 r)) `shiftL` 30

-- Probe 1: the execute arc. Registered operands and control feed the canon's
-- compareOperands (split 16-bit high/low) and aluCandidates/selectedAlu (the
-- two-level shift candidates, the funct3 result mux, the legal gate); the
-- result feeds back as the next A operand, closing the register-to-register
-- path exactly as the pipeline lives it.
aluProbeTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
aluProbeTop clk rst en = exposeClockResetEnable circuit clk rst en
 where
  circuit :: HiddenClockResetEnable d => Signal d (BitVector 32)
  circuit = foldQ <$> result <*> eqFlag <*> ltFlag <*> pure True
   where
    random = lfsrS
    instr = register (0x33 :: BitVector 32) (rTypeInstr <$> random)
    control = R.decodeExecuteControl . bitCoerce <$> instr
    a = register (0x13579BDF :: R.Word32) result
    b = register (0x02468ACE :: R.Word32) (bitCoerce <$> random)
    candidates = R.aluCandidates <$> control <*> a <*> b
    parts = R.compareOperands <$> a <*> b
    result = sel <$> control <*> candidates <*> parts
    sel ctl cands ps = fromMaybe 0 (R.selectedAlu ctl cands ps)
    eqFlag = f <$> parts
    ltFlag = g <$> parts
    f p = R.compareEqual p && R.compareHighEqual p
    g p = R.compareLowLess p || R.compareSignedHighLess p || R.compareUnsignedHighLess p

-- Probe 2: the full single-cycle barrel shifter, all three shift kinds with
-- a registered amount: what "shifts complete in E1" asks of one stage, five
-- mux levels deep.
shifterProbeTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
shifterProbeTop clk rst en = exposeClockResetEnable circuit clk rst en
 where
  circuit :: HiddenClockResetEnable d => Signal d (BitVector 32)
  circuit = foldQ <$> result <*> (kind .==. 1) <*> (kind .==. 2) <*> (kind .==. 3)
   where
    random = lfsrS
    a = register (0x0F0F0F0F :: R.Word32) result
    shamt = (\r -> fromIntegral (unpack (slice d4 d0 r) :: Unsigned 5)) <$> random
    kind = (\r -> slice d1 d0 r) <$> random
    left = shiftL <$> a <*> shamt
    logical = shiftR <$> a <*> shamt
    arith = bitCoerce <$> (shiftR <$> (R.signed32 <$> a) <*> shamt)
    result = mux (kind .==. 0) left (mux (kind .==. 1) logical arith)

-- | One BTB line: the canon's valid/tag/target without the compressed slot
-- bit (the probe runs the uncompressed 32-bit instruction set).
data BtbLine = BtbLine Bool (Unsigned 8) R.Word32
  deriving (Generic, NFDataX)

bLineValid :: BtbLine -> Bool
bLineValid (BtbLine v _ _) = v
bLineTag :: BtbLine -> Unsigned 8
bLineTag (BtbLine _ t _) = t
bLineTarget :: BtbLine -> R.Word32
bLineTarget (BtbLine _ _ t) = t

-- Probe 3: the fetch loop. The pc register indexes a 128-entry BTB with a
-- registered (block RAM) read; the tag compares, hit selects the stored
-- target or the pc+4 adder, a registered redirect steers, and the pc
-- register closes the loop. Training is registered and overrides one entry,
-- like the canon's deferred pBtbWrite. This is the arc that missed 87 MHz at
-- placement 0.
btbProbeTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
btbProbeTop clk rst en = exposeClockResetEnable circuit clk rst en
 where
  circuit :: HiddenClockResetEnable d => Signal d (BitVector 32)
  circuit = foldQ <$> pc <*> hit <*> steering <*> trainValid
   where
    random = lfsrS
    pc = register (0x8000_0000 :: R.Word32) nextPc
    index = R.btbIndex <$> pc
    tag = R.btbTag <$> pc
    table = blockRam (repeat (BtbLine False 0 0) :: Vec 128 BtbLine) index write
    -- registered training of the entry the resolved branch took
    trainValid = register False steerNext
    trainIdx = register (0 :: R.BtbIndex) (R.btbIndex <$> steerTarget)
    trainLine = register (BtbLine True 0 0) (BtbLine True <$> steerTag <*> steerTarget)
    steerTag = R.btbTag <$> steerTarget
    -- the read: the stored entry, overridden by last cycle's training when it
    -- hits this index
    override = f <$> trainValid <*> trainIdx <*> index
    f v i idx = v && (i == idx)
    entry = mux override trainLine table
    hit = g <$> entry <*> tag
    g e t = bLineValid e && bLineTag e == t
    -- a registered redirect, occasionally asserted, standing in for E2
    -- mispredict steering
    steerNext = (\r -> slice d17 d17 r == 1) <$> random
    steerTarget = register (0x8001_0000 :: R.Word32) targetWord
    targetWord = (\r -> zeroExtend (unpack (slice d31 d2 r) :: Unsigned 30) .|. 1) <$> random
    steering = h <$> steerReg <*> hit
    h s x = s && not x
    steerReg = register False steerNext
    nextPc = mux steering steerTarget (mux hit (bLineTarget <$> entry) (pc + 4))
    write = (\v i l -> if v then Just (i, l) else Nothing) <$> trainValid <*> trainIdx <*> trainLine

-- Probe 4: the decode/hazard arc. A consumer packet register (the rs1/rs2
-- fields and use bits decodeHazard reads) compares against three producer
-- slots (E1, E2 with its forwards gate, M with its final gate); the register
-- file is a dual-read RAM addressed from the entering packet with the canon's
-- forwarding muxes; the blocked decision holds the packet. This is the arc
-- that missed 87 MHz at placement 4.
hazardProbeTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
hazardProbeTop clk rst en = exposeClockResetEnable circuit clk rst en
 where
  circuit :: HiddenClockResetEnable d => Signal d (BitVector 32)
  circuit = foldQ <$> aVal <*> blocked <*> advance <*> hit2
   where
    random = lfsrS
    -- the entering packet: a synthetic instruction with rotating register
    -- fields, held while blocked
    nextWord = (\r -> 0x13
      .|. (fromIntegral (unpack (slice d11 d6 r) :: Unsigned 6) :: R.Word32) `shiftL` 20
      .|. ((fromIntegral (unpack (slice d5 d0 r) :: Unsigned 6) :: R.Word32) .|. 0xFFFFF800) `shiftL` 7) <$> random
    advance = not <$> blocked
    word = register (0x13 :: R.Word32) (mux advance nextWord word)
    entering = mux advance nextWord word
    rs1 = R.instructionRs1 <$> word
    rs2 = R.instructionRs2 <$> word
    uses1 = (\r -> (unpack (slice d19 d15 r) :: Unsigned 5) /= 0) <$> entering
    uses2 = (\r -> (unpack (slice d24 d20 r) :: Unsigned 5) /= 0) <$> entering
    -- three producer slots with rotating rd fields and the canon's qualifiers
    rd = register (1 :: Index 32) ((\r -> fromIntegral (unpack (slice d4 d0 r) :: Unsigned 5)) <$> random)
    writes = (\r -> slice d8 d8 r == 1) <$> random
    forwards = (\r -> slice d9 d9 r == 1) <$> random
    mFinal = (\r -> slice d10 d10 r == 1) <$> random
    notF = not <$> forwards
    notM = not <$> mFinal
    hit1 = rd .==. rs1
    hit2 = rd .==. rs2
    eitherHit = hit1 .&&. uses1 .||. hit2 .&&. uses2
    blockedE1 = writes .&&. eitherHit
    blockedE2 = writes .&&. notF .&&. eitherHit
    blockedM = writes .&&. notM .&&. eitherHit
    blocked = blockedE1 .||. blockedE2 .||. blockedM
    -- register file: read addresses registered from the entering packet
    rdA = register (0 :: Index 32) (R.instructionRs1 . bitCoerce <$> entering)
    rdB = register (0 :: Index 32) (R.instructionRs2 . bitCoerce <$> entering)
    write = (\w d v -> if w then Just (d, v) else Nothing) <$> writes <*> rd <*> aVal
    rfA = asyncRam (SNat @32) rdA write
    rfB = asyncRam (SNat @32) rdB write
    -- the canon's forwarding: a producing value replaces the RAM read
    aVal = mux (writes .&&. hit1) rfB rfA
    regB = mux (writes .&&. hit2) rfB rfA

-- | One cache tag: valid plus the compare field above the set index.
data TagLine = TagLine Bool (BitVector 19)
  deriving (Generic, NFDataX)

lineHit :: TagLine -> BitVector 19 -> Bool
lineHit (TagLine v t) w = v && (t == w)

-- Probe 5: the load/store port. A two-way set-indexed cache read (registered
-- tag and data RAMs), the hit and way select, the canon's loadValue sign
-- extension on the load side, and storeLanes/storeMask merged into a posted
-- write. This compresses the three-clock cache hit arc into one cycle: an
-- upper bound for restructuring, not the port's pipeline result.
loadProbeTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
loadProbeTop clk rst en = exposeClockResetEnable circuit clk rst en
 where
  circuit :: HiddenClockResetEnable d => Signal d (BitVector 32)
  circuit = foldQ <$> wb <*> hit <*> (wayBit .==. 0) <*> storeLive
   where
    random = lfsrS
    -- byte address: rotating set, jittered word and byte lanes, fixed tag region
    address = register (0x8000_4000 :: R.Word32) nextAddr
    nextAddr = bitCoerce <$> ((\r -> pack (slice d31 d13 r) ++# pack (slice d12 d2 r) ++# pack (slice d1 d0 r)) <$> random)
    setIndex = (\a -> unpack (slice d9 d2 a) :: Unsigned 8) <$> address
    wordIndex = (\a -> unpack (slice d9 d0 a) :: Unsigned 10) <$> address
    funct3 = (\a -> slice d14 d12 a) <$> address
    offset = (\a -> unpack (slice d1 d0 a) :: Unsigned 2) <$> address
    wantTag = (\a -> slice d31 d13 a) <$> address
    tag0 = blockRam (repeat (TagLine False 0) :: Vec 256 TagLine) setIndex (pure Nothing)
    tag1 = blockRam (repeat (TagLine True 0) :: Vec 256 TagLine) setIndex (pure Nothing)
    data0 = blockRam (repeat 0 :: Vec 1024 (BitVector 32)) wordIndex (pure Nothing)
    data1 = blockRam (repeat 0 :: Vec 1024 (BitVector 32)) wordIndex (pure Nothing)
    hit0 = lineHit <$> tag0 <*> wantTag
    hit1 = lineHit <$> tag1 <*> wantTag
    hit = hit0 .||. hit1
    wayBit = pure (\h -> if h then 1 else 0 :: Int) <*> hit0
    word = mux (wayBit .==. 1) data1 data0
    loaded = R.loadValue <$> funct3 <*> offset <*> (bitCoerce <$> word)
    storeValue = bitCoerce <$> random
    storeData = R.storeLanes <$> funct3 <*> offset <*> storeValue
    storeMask = R.storeMask <$> funct3 <*> offset
    merged = (\w m d -> (bitCoerce w .&. complement m) .|. d) <$> word <*> storeMask <*> storeData
    wb = mux hit loaded merged
    storeLive = (/= 0) <$> storeMask

-- Probe 6: the multiply. The canon's four 17x17 partial products registered
-- in M, then the wide sum and the half select completing in the next cycle:
-- four DSP blocks and the 66-bit adder network.
mulProbeTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
mulProbeTop clk rst en = exposeClockResetEnable circuit clk rst en
 where
  circuit :: HiddenClockResetEnable d => Signal d (BitVector 32)
  circuit = foldQ <$> result <*> (kind .==. 1) <*> (kind .==. 2) <*> (kind .==. 3)
   where
    random = lfsrS
    kind = (\r -> slice d1 d0 r) <$> random
    funct3 = (\r -> 2 + (if slice d1 d1 r == 1 then 1 else 0) + (if slice d2 d2 r == 1 then 1 else 0)) <$> random
    a = register (0x12345678 :: R.Word32) (bitCoerce <$> random)
    b = register (0x9ABCDEF0 :: R.Word32) result
    products = register (repeat 0 :: Vec 4 (Signed 34))
                        ((\f x y -> R.partialProducts f x y) <$> funct3 <*> a <*> b)
    funct3R = register 0 funct3
    result = R.productHalf <$> funct3R <*> products

-- Probe 7: branch resolution. compareOperands and branchTakenPrepared with
-- the target adder, the registered taken decision and its mispredict compare:
-- the E2 branch arc.
branchProbeTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
branchProbeTop clk rst en = exposeClockResetEnable circuit clk rst en
 where
  circuit :: HiddenClockResetEnable d => Signal d (BitVector 32)
  circuit = foldQ <$> result <*> taken <*> misp <*> branchZero
   where
    random = lfsrS
    a = register (0x2000 :: R.Word32) result
    b = register (0x0800 :: R.Word32) (bitCoerce <$> random)
    pc = register (0x8000_1000 :: R.Word32) ((+4) <$> pc)
    imm = register (8 :: R.Word32) ((\r -> fromIntegral (unpack (slice d12 d1 r) :: Unsigned 12)) <$> random)
    funct3 = (\r -> slice d2 d0 r) <$> random
    parts = R.compareOperands <$> a <*> b
    taken = (\f ps -> fromMaybe False (R.branchTakenPrepared f ps)) <$> funct3 <*> parts
    target = pc + imm
    misp = (\tk r -> tk && slice d0 d0 r == 1) <$> taken <*> random
    branchZero = (\r -> slice d2 d2 r == maxBound) <$> random
    result = mux misp target (a + b)

{-# ANN aluProbeTop (Synthesize {t_name="probe_alu",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
{-# ANN shifterProbeTop (Synthesize {t_name="probe_shift",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
{-# ANN btbProbeTop (Synthesize {t_name="probe_btb",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
{-# ANN hazardProbeTop (Synthesize {t_name="probe_hazard",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
{-# ANN loadProbeTop (Synthesize {t_name="probe_load",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
{-# ANN mulProbeTop (Synthesize {t_name="probe_mul",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
{-# ANN branchProbeTop (Synthesize {t_name="probe_branch",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}
