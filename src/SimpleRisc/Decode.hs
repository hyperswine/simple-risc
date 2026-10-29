{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- | Instruction decode, the ALU's registered candidates, the multiply/divide
-- step, the memory-map decode and the load/store lane helpers: everything that
-- works on instruction words and addresses without touching machine state.
module SimpleRisc.Decode where

import Clash.Prelude
import SimpleRisc.Types


{-# INLINE isRamTarget #-}
isRamTarget :: MemoryTarget -> Bool
isRamTarget target = case target of RamTarget -> True; _ -> False

{-# INLINE decodeCommitKind #-}
decodeCommitKind :: Word32 -> CommitKind
decodeCommitKind instruction = case instruction .&. 0x7f of
  0x37 -> KindAlu
  0x17 -> KindAlu
  0x13 -> KindAlu
  0x33 -> KindAlu
  0x6f -> KindJump
  0x67 | funct3 == 0 -> KindJump
  0x63 | funct3 /= 2 && funct3 /= 3 -> KindBranch
  0x03 | validLoad funct3 -> KindLoad
  0x23 | validStore funct3 -> KindStore
  0x0f
    | funct3 == 0 -> KindFence
    | funct3 == 1 -> KindFenceI
  0x73
    | instruction == 0x0000_0073 -> KindEcall
    | instruction == 0x0010_0073 -> KindEbreak
    | instruction == 0x3020_0073 -> KindMret
    | instruction == 0x1050_0073 -> KindWfi
    | funct3 /= 0 && funct3 /= 4 -> KindCsr
  _ -> KindInvalid
  where
    funct3 = instructionFunct3 instruction

{-# INLINE decodeExecuteControl #-}
decodeExecuteControl :: Word32 -> ExecuteControl
decodeExecuteControl instruction =
  let opcode = instruction .&. 0x7f
      funct3 = instructionFunct3 instruction
      funct7 = (instruction `shiftR` 25) .&. 0x7f
      regOperation = opcode == 0x33
      shiftOperation = funct3 == 1 || funct3 == 5
      alternate = funct7 == 0x20
      legal = if regOperation then funct7 == 0 || (alternate && (funct3 == 0 || funct3 == 5)) else not shiftOperation || funct7 == 0 || (alternate && funct3 == 5)
   in ExecuteControl funct3 legal (regOperation && alternate) alternate ((opcode == 0x13 || regOperation) && shiftOperation) (regOperation && funct7 == 1) (opcode == 0x03 || opcode == 0x23) (opcode == 0x63 || opcode == 0x6f || opcode == 0x67) (opcode == 0x37) (opcode == 0x17) (opcode == 0x13 || regOperation) (opcode == 0x23) (decodeCommitKind instruction)

{-# INLINE compareOperands #-}
compareOperands :: Word32 -> Word32 -> CompareResults
compareOperands a b =
  let highA = resize (a `shiftR` 16) :: Unsigned 16
      highB = resize (b `shiftR` 16) :: Unsigned 16
      lowA = resize a :: Unsigned 16
      lowB = resize b :: Unsigned 16
   in CompareResults
        (a == b)
        (highA == highB)
        (lowA < lowB)
        ((bitCoerce highA :: Signed 16) < (bitCoerce highB :: Signed 16))
        (highA < highB)

signedComparison, unsignedComparison :: CompareResults -> Bool
signedComparison parts = compareSignedHighLess parts || (compareHighEqual parts && compareLowLess parts)
unsignedComparison parts = compareUnsignedHighLess parts || (compareHighEqual parts && compareLowLess parts)

{-# INLINE branchTakenPrepared #-}
branchTakenPrepared :: BitVector 3 -> CompareResults -> Maybe Bool
branchTakenPrepared kind parts = case kind of
  0 -> Just (compareEqual parts)
  1 -> Just (not (compareEqual parts))
  4 -> Just (signedComparison parts)
  5 -> Just (not (signedComparison parts))
  6 -> Just (unsignedComparison parts)
  7 -> Just (not (unsignedComparison parts))
  _ -> Nothing

{-# INLINE aluCandidates #-}
aluCandidates :: ExecuteControl -> Word32 -> Word32 -> Vec 8 Word32
aluCandidates control a b =
  (if execSubtract control then a - b else a + b)
    :> (a `shiftL` fromIntegral (b .&. 3))
    :> 0
    :> 0
    :> (a `xor` b)
    :> (if execArithmeticShift control then unsigned32 (signed32 a `shiftR` fromIntegral (b .&. 3)) else a `shiftR` fromIntegral (b .&. 3))
    :> (a .|. b)
    :> (a .&. b)
    :> Nil

{-# INLINE selectedAlu #-}
selectedAlu :: ExecuteControl -> Vec 8 Word32 -> CompareResults -> Maybe Word32
selectedAlu control candidates parts = if execLegal control then Just value else Nothing
  where
    value = case execFunct3 control of
      2 -> boolWord (signedComparison parts)
      3 -> boolWord (unsignedComparison parts)
      _ -> candidates !! (fromIntegral (unpack (execFunct3 control) :: Unsigned 3) :: Index 8)

-- | The decode-stage dependency contract. E2 results wait until registered
-- in M, keeping its ALU result mux out of decode's operand forwarding path.
{-# INLINE decodeHazard #-}
decodeHazard :: Maybe Fetched -> Maybe ExecuteOne -> Maybe ExecuteTwo -> Maybe MemoryStage -> Bool
decodeHazard fetched one two memory = case fetched of
  Nothing -> False
  Just f ->
    let rs1 = instructionRs1 (fWord f)
        rs2 = instructionRs2 (fWord f)
        conflicts r writing = writing && ((fUsesRs1 f && rs1 == r) || (fUsesRs2 f && rs2 == r))
     in maybe False (\x -> conflicts (e1Rd x) (e1Writes x)) one
          || maybe False (\x -> conflicts (e2Rd x) (e2Writes x)) two
          || maybe False (\m -> not (mFinal m) && conflicts (mRd m) (mWrites m)) memory

-- | Execute stage: every adder and the ALU, in parallel, for whichever
-- instruction this turns out to be. Shifts compute their low two levels here
-- and ShiftFinish completes the high three levels.
-- The immediate has already been decoded for the instruction's format, so
-- each adder has fixed, registered inputs and nothing is muxed in front of it.
{-# INLINE compute #-}
compute :: Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> Computed
compute pc instruction a b imm op2 =
  Computed
    { cAlu = case opcode of
        0x37 -> Just imm -- LUI
        0x17 -> Just pcPlusImm -- AUIPC
        0x13 -> aluWithShiftMask 3 funct3 funct7 False a op2
        0x33 -> aluWithShiftMask 3 funct3 funct7 True a op2
        _ -> Nothing,
      cLink = pc + 4,
      cTarget = if opcode == 0x67 then aPlusImm .&. complement 1 else pcPlusImm, -- JALR; JAL and branches
      cTaken = branchTaken funct3 a b,
      cAddress = aPlusImm
    }
  where
    opcode = instruction .&. 0x7f
    funct3 = instructionFunct3 instruction
    funct7 = (instruction `shiftR` 25) .&. 0x7f
    pcPlusImm = pc + imm
    aPlusImm = a + imm

-- | The immediate in whichever format the opcode uses.
{-# INLINE decodeImmediate #-}
decodeImmediate :: Word32 -> Word32
decodeImmediate instruction = case instruction .&. 0x7f of
  0x37 -> immU instruction -- LUI
  0x17 -> immU instruction -- AUIPC
  0x6f -> immJ instruction -- JAL
  0x63 -> immB instruction -- branches
  0x23 -> immS instruction -- stores
  _ -> immI instruction -- OP-IMM, loads, JALR

instructionRd, instructionRs1, instructionRs2 :: Word32 -> Index 32
instructionRd instruction = regIndex ((instruction `shiftR` 7) .&. 0x1f)
instructionRs1 instruction = regIndex ((instruction `shiftR` 15) .&. 0x1f)
instructionRs2 instruction = regIndex ((instruction `shiftR` 20) .&. 0x1f)

{-# INLINE instructionFunct3 #-}
instructionFunct3 :: Word32 -> BitVector 3
instructionFunct3 instruction = pack (resize ((instruction `shiftR` 12) .&. 7) :: Unsigned 3)

-- | A halfword must be 2-aligned and a word 4-aligned; byte accesses are free.
{-# INLINE misalignedMemory #-}
misalignedMemory :: BitVector 3 -> Word32 -> Bool
misalignedMemory funct3 address
  | funct3 == 0b010 = address .&. 3 /= 0
  | funct3 == 0b001 || funct3 == 0b101 = testBit address 0
  | otherwise = False

-- | These CSRs have no read side effects, so CSRRW rd=x0 can share the same
-- read stage. Write suppression uses the encoded rs1/zimm, not its value.
csrWriteRequested :: Word32 -> Bool
csrWriteRequested instruction =
  let kind = instructionFunct3 instruction
   in kind == 1 || kind == 5 || instructionRs1 instruction /= 0

csrAddress :: Word32 -> Unsigned 12
csrAddress instruction = resize (instruction `shiftR` 20)

-- CSR address comparisons are registered at Commit, before the data mux.
decodeCsrSelection :: Unsigned 12 -> Vec 14 Bool
decodeCsrSelection address =
  (address == 0x300)
    :> (address == 0x301)
    :> (address == 0x304)
    :> (address == 0x305)
    :> (address == 0x340)
    :> (address == 0x341)
    :> (address == 0x342)
    :> (address == 0x343)
    :> (address == 0xb00 || address == 0xc00)
    :> (address == 0xb80 || address == 0xc80)
    :> (address == 0xb02 || address == 0xc02)
    :> (address == 0xb82 || address == 0xc82)
    :> ( address
           == 0x310
           || address
           == 0xf11
           || address
           == 0xf12
           || address
           == 0xf13
           || address
           == 0xf14
       )
    :> (address == 0x344)
    :> Nil

-- | The physical word index: bit 31 clear means the boot ROM (bit 14 set,
-- low nine bits the ROM word), set means RAM (the low 14 bits). Only
-- meaningful for addresses the decoder maps to ROM or RAM.
{-# INLINE memoryIndex #-}
memoryIndex :: Word32 -> MemAddr
memoryIndex address
  | testBit address 31 = resize (address `shiftR` 2) .&. 0x3fff
  | otherwise = 0x4000 .|. (resize (address `shiftR` 2) .&. 0x1ff)

ramBase :: Word32
ramBase = 0x8000_0000

-- | 64 KiB of RAM at 0x8000_0000, as a bit test.
{-# INLINE validMemoryAddress #-}
validMemoryAddress :: Word32 -> Bool
validMemoryAddress address = address .&. 0xffff_0000 == ramBase

-- | The 2 KiB boot ROM at address 0, as a bit test.
{-# INLINE romAddress #-}
romAddress :: Word32 -> Bool
romAddress address = address .&. 0xffff_f800 == 0

{-# INLINE fetchable #-}
fetchable :: MemoryTarget -> Bool
fetchable target = case target of RamTarget -> True; RomTarget -> True; _ -> False

-- SiFive/QEMU-style finisher command register. DONE carries no status payload.
exitDevice :: Word32
exitDevice = 0x0010_0000

-- | BOOTCAUSE, read-only beside the finisher.
bootCauseDevice :: Word32
bootCauseDevice = 0x0010_0004

-- | CLINT and PLIC registers (QEMU virt layout) and the UART control register.
clintMsip, clintCompareLo, clintCompareHi, clintTimeLo, clintTimeHi :: Word32

-- | The I/O complex's window and its registers' offsets within it.
ioBase :: Word32
ioBase = 0x1000_1000

ioSpiData, ioSpiStatus, ioSpiControl, ioDmaAddress, ioDmaCount, ioDmaControl, ioDmaStatus :: Word32

{-# INLINE decodeMemoryTarget #-}
decodeMemoryTarget :: Word32 -> MemoryTarget
decodeMemoryTarget address
  | validMemoryAddress address = RamTarget
  | romAddress address = RomTarget
  | address == bootCauseDevice = BootCauseTarget
  | address == clintMsip = ClintMsipTarget
  | address == clintCompareLo = ClintCompareLoTarget
  | address == clintCompareHi = ClintCompareHiTarget
  | address == clintTimeLo = ClintTimeLoTarget
  | address == clintTimeHi = ClintTimeHiTarget
  | address == plicPriorityUart = PlicPriorityTarget
  | address == plicPending = PlicPendingTarget
  | address == plicEnable = PlicEnableTarget
  | address == plicThreshold = PlicThresholdTarget
  | address == plicClaim = PlicClaimTarget
  | address == uartControl = UartControlTarget
  | address .&. 0xffff_f000 == ioBase = IoTarget
  | address == uartTxData = UartTxTarget
  | address == uartStatus = UartStatusTarget
  | address == uartRxData = UartRxTarget
  | address == exitDevice = ExitTarget
  | otherwise = UnmappedTarget

{-# INLINE validLoad #-}
validLoad :: BitVector 3 -> Bool
validLoad funct3 = funct3 == 0b000 || funct3 == 0b001 || funct3 == 0b010 || funct3 == 0b100 || funct3 == 0b101

{-# INLINE validStore #-}
validStore :: BitVector 3 -> Bool
validStore funct3 = funct3 == 0b000 || funct3 == 0b001 || funct3 == 0b010

{-# INLINE loadValue #-}
loadValue :: BitVector 3 -> Unsigned 2 -> Word32 -> Word32
loadValue funct3 byteOffset word = case funct3 of
  0b000 -> signExtend8 byte
  0b001 -> signExtend16 half
  0b010 -> word
  0b100 -> resize byte
  0b101 -> resize half
  _ -> 0
  where
    shiftAmount = fromIntegral byteOffset * 8
    byte = resize (word `shiftR` shiftAmount) :: Unsigned 8
    half = resize (word `shiftR` shiftAmount) :: Unsigned 16

-- | A store's data in its byte lanes, and the lanes it replaces.
{-# INLINE storeLanes #-}
storeLanes :: BitVector 3 -> Unsigned 2 -> Word32 -> Word32
storeLanes funct3 byteOffset value = case funct3 of
  0b000 -> (value .&. 0xff) `shiftL` (fromIntegral byteOffset * 8)
  0b001 -> (value .&. 0xffff) `shiftL` (fromIntegral byteOffset * 8)
  _ -> value

{-# INLINE storeMask #-}
storeMask :: BitVector 3 -> Unsigned 2 -> Word32
storeMask funct3 byteOffset = storeLanes funct3 byteOffset maxBound

-- | The RAM word index of a RAM address (bit 14 clear): 'memoryIndex'
-- without its ROM case.
{-# INLINE ramWordIndex #-}
ramWordIndex :: Word32 -> MemAddr
ramWordIndex address = resize (address `shiftR` 2) .&. 0x3fff

{-# INLINE storeValue #-}
storeValue :: BitVector 3 -> Unsigned 2 -> Word32 -> Word32 -> Word32
storeValue funct3 byteOffset value oldWord = case funct3 of
  0b000 -> (oldWord .&. complement (0xff `shiftL` shiftAmount)) .|. ((value .&. 0xff) `shiftL` shiftAmount)
  0b001 -> (oldWord .&. complement (0xffff `shiftL` shiftAmount)) .|. ((value .&. 0xffff) `shiftL` shiftAmount)
  _ -> value
  where
    shiftAmount = fromIntegral byteOffset * 8

-- Decode/execute helpers ------------------------------------------------------

-- | OP (register-register) and OP-IMM arithmetic on @a@ and @op2@; Nothing for
-- an illegal funct7.
{-# INLINE alu #-}
alu :: BitVector 3 -> Word32 -> Bool -> Word32 -> Word32 -> Maybe Word32
alu = aluWithShiftMask 0x1f

-- Only the shift distance is masked; adders retain their registered inputs.
{-# INLINE aluWithShiftMask #-}
aluWithShiftMask :: Word32 -> BitVector 3 -> Word32 -> Bool -> Word32 -> Word32 -> Maybe Word32
aluWithShiftMask mask funct3 funct7 isRegister a op2 = if legal then Just value else Nothing
  where
    alternate = funct7 == 0x20 -- SUB and SRA/SRAI
    isShift = funct3 == 0b001 || funct3 == 0b101
    legal
      | isRegister = funct7 == 0 || (alternate && (funct3 == 0b000 || funct3 == 0b101))
      | otherwise = not isShift || funct7 == 0 || (alternate && funct3 == 0b101)
    shamt = fromIntegral (op2 .&. mask)
    value = case funct3 of
      0b000 -> if isRegister && alternate then a - op2 else a + op2 -- ADD(I), SUB
      0b001 -> shiftResult funct3 funct7 a shamt -- SLL(I)
      0b010 -> boolWord (signed32 a < signed32 op2) -- SLT(I)
      0b011 -> boolWord (a < op2) -- SLT(I)U
      0b100 -> a `xor` op2 -- XOR(I)
      0b101 -> shiftResult funct3 funct7 a shamt -- SRL(I), SRA(I)
      0b110 -> a .|. op2 -- OR(I)
      _ -> a .&. op2 -- AND(I)

-- | One part of a shift; arithmetic shifts preserve the sign at both stages.
{-# INLINE shiftResult #-}
shiftResult :: BitVector 3 -> Word32 -> Word32 -> Int -> Word32
shiftResult funct3 funct7 value amount
  | funct3 == 0b001 = value `shiftL` amount
  | funct7 == 0x20 = unsigned32 (signed32 value `shiftR` amount)
  | otherwise = value `shiftR` amount

-- | One cycle of the multiply/divide unit for the M instruction @funct3@ on
-- operands @a@ (rs1) and @b@ (rs2): the next unit state, or the result.
mulDivStep :: BitVector 3 -> Word32 -> Word32 -> MulDivUnit -> Either MulDivUnit Word32
mulDivStep funct3 a b unit@MulDivUnit {..} = case mdStep of
  MdPrepare
    -- Division by zero: quotient all ones, remainder the dividend.
    | isDiv && b == 0 -> Left unit {mdStep = MdFinish, mdLo = maxBound, mdHi = a, mdTakeLow = takeLow}
    | otherwise ->
        let magnitude negative x = if negative then negate x else x
         in Left
              MulDivUnit
                { mdStep = MdLoop 0,
                  mdHi = 0,
                  mdLo = if isDiv then magnitude aNegative a else magnitude bNegative b,
                  mdOperand = if isDiv then magnitude bNegative b else magnitude aNegative a,
                  mdTotal = 0,
                  mdNegLo = aNegative /= bNegative,
                  mdNegHi = if isDiv then aNegative else aNegative /= bNegative,
                  mdCarry = False,
                  mdTakeLow = takeLow
                }
  MdLoop i ->
    Left unit {mdStep = MdCommit i, mdTotal = if isDiv then divideDifference else multiplyTotal}
  MdCommit i ->
    let (hi, lo) = if isDiv then divideStep else multiplyStep
     in Left unit {mdStep = if i == maxBound then MdFixLo else MdLoop (succ i), mdHi = hi, mdLo = lo}
  MdFixLo -> Left unit {mdStep = MdFixHi, mdLo = if mdNegLo then negate mdLo else mdLo, mdCarry = mdLo == 0}
  -- Negating the remainder is complement + 1; negating the product's high
  -- half is complement + the carry out of the low half.
  MdFixHi -> Left unit {mdStep = MdFinish, mdHi = if mdNegHi then complement mdHi + boolWord (isDiv || mdCarry) else mdHi}
  -- MUL, DIV and DIVU take the low word; MULH*, REM and REMU the high word.
  MdFinish -> Right (if mdTakeLow then mdLo else mdHi)
  where
    takeLow = funct3 == 0b000 || funct3 == 0b100 || funct3 == 0b101
    isDiv = testBit funct3 2
    -- MULH, MULHSU, DIV and REM treat rs1 as signed; MULH, DIV and REM rs2.
    aSigned = funct3 == 0b001 || funct3 == 0b010 || funct3 == 0b100 || funct3 == 0b110
    bSigned = funct3 == 0b001 || funct3 == 0b100 || funct3 == 0b110
    aNegative = aSigned && testBit a 31
    bNegative = bSigned && testBit b 31
    -- Add the multiplicand into the high half if the multiplier's low bit is
    -- set, then shift the 65-bit {carry, hi, lo} right by one.
    multiplyStep =
      let total = mdTotal
       in (resize (total `shiftR` 1), (mdLo `shiftR` 1) .|. (if testBit total 0 then 0x8000_0000 else 0))
    -- Shift the next dividend bit into the remainder; subtract the divisor if
    -- it fits, recording a quotient bit.
    divideStep =
      let fits = not (testBit mdTotal 32)
       in (resize (if fits then mdTotal else remainder), (mdLo `shiftL` 1) .|. boolWord fits)
    multiplyTotal = if testBit mdLo 0 then resize mdHi + resize mdOperand else resize mdHi
    remainder = (resize mdHi `shiftL` 1) .|. (if testBit mdLo 31 then 1 else 0) :: Unsigned 33
    -- During restoring division remainder < 2*divisor. A successful subtract
    -- is < divisor (fits in 32 bits); bit 32 therefore encodes the borrow.
    divideDifference = remainder - resize mdOperand

{-# INLINE branchTaken #-}
branchTaken :: BitVector 3 -> Word32 -> Word32 -> Maybe Bool
branchTaken funct3 a b = case funct3 of
  0b000 -> Just (a == b)
  0b001 -> Just (a /= b)
  0b100 -> Just (signed32 a < signed32 b)
  0b101 -> Just (signed32 a >= signed32 b)
  0b110 -> Just (a < b)
  0b111 -> Just (a >= b)
  _ -> Nothing

{-# INLINE boolWord #-}
boolWord :: Bool -> Word32
boolWord False = 0
boolWord True = 1

{-# INLINE signed32 #-}
signed32 :: Word32 -> Signed 32
signed32 = bitCoerce

{-# INLINE unsigned32 #-}
unsigned32 :: Signed 32 -> Word32
unsigned32 = bitCoerce

-- NEEDED FOR SIGN EXTENSION OF VALUES SINCE THE REGISTER SIZE IS 32 BITS

{-# INLINE signExtend8 #-}
signExtend8 :: Unsigned 8 -> Word32
signExtend8 value = if testBit value 7 then resize value .|. 0xffff_ff00 else resize value

{-# INLINE signExtend12 #-}
signExtend12 :: Unsigned 12 -> Word32
signExtend12 value = if testBit value 11 then resize value .|. 0xffff_f000 else resize value

{-# INLINE signExtend13 #-}
signExtend13 :: Unsigned 13 -> Word32
signExtend13 value = if testBit value 12 then resize value .|. 0xffff_e000 else resize value

{-# INLINE signExtend16 #-}
signExtend16 :: Unsigned 16 -> Word32
signExtend16 value = if testBit value 15 then resize value .|. 0xffff_0000 else resize value

{-# INLINE signExtend21 #-}
signExtend21 :: Unsigned 21 -> Word32
signExtend21 value = if testBit value 20 then resize value .|. 0xffe0_0000 else resize value

-- DIFFERENT FORMATS have different immediate extraction methods

{-# INLINE immI #-}
immI :: Word32 -> Word32
immI instruction = signExtend12 (resize (instruction `shiftR` 20))

{-# INLINE immS #-}
immS :: Word32 -> Word32
immS instruction =
  signExtend12
    ( resize ((instruction `shiftR` 25) `shiftL` 5)
        .|. resize ((instruction `shiftR` 7) .&. 0x1f)
    )

{-# INLINE immB #-}
immB :: Word32 -> Word32
immB instruction =
  signExtend13
    ( resize (((instruction `shiftR` 31) .&. 1) `shiftL` 12)
        .|. resize (((instruction `shiftR` 7) .&. 1) `shiftL` 11)
        .|. resize (((instruction `shiftR` 25) .&. 0x3f) `shiftL` 5)
        .|. resize (((instruction `shiftR` 8) .&. 0x0f) `shiftL` 1)
    )

{-# INLINE immU #-}
immU :: Word32 -> Word32
immU instruction = instruction .&. 0xffff_f000

{-# INLINE immJ #-}
immJ :: Word32 -> Word32
immJ instruction =
  signExtend21
    ( resize (((instruction `shiftR` 31) .&. 1) `shiftL` 20)
        .|. resize (((instruction `shiftR` 12) .&. 0xff) `shiftL` 12)
        .|. resize (((instruction `shiftR` 20) .&. 1) `shiftL` 11)
        .|. resize (((instruction `shiftR` 21) .&. 0x3ff) `shiftL` 1)
    )


-- | The UART's interrupt number on the PLIC, as on QEMU virt.
uartIrq :: Word32
uartIrq = 10
clintMsip = 0x0200_0000
clintCompareLo = 0x0200_4000
clintCompareHi = 0x0200_4004
clintTimeLo = 0x0200_bff8
clintTimeHi = 0x0200_bffc

plicPriorityUart, plicPending, plicEnable, plicThreshold, plicClaim, uartControl :: Word32
plicPriorityUart = 0x0c00_0000 + 4 * uartIrq
plicPending = 0x0c00_1000
plicEnable = 0x0c00_2000
plicThreshold = 0x0c20_0000
plicClaim = 0x0c20_0004
uartControl = 0x1000_000c
ioSpiData = 0x000
ioSpiStatus = 0x004
ioSpiControl = 0x008
ioDmaAddress = 0x100
ioDmaCount = 0x104
ioDmaControl = 0x108
ioDmaStatus = 0x10c

uartTxData, uartStatus, uartRxData :: Word32
uartTxData = 0x1000_0000
uartStatus = 0x1000_0004
uartRxData = 0x1000_0008


{-# INLINE regIndex #-}
regIndex :: Word32 -> Index 32
regIndex value = fromIntegral (resize value :: Unsigned 5)
