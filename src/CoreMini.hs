{-# LANGUAGE DataKinds, NoImplicitPrelude, TypeApplications, FlexibleContexts, NumericUnderscores, ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
module CoreMini where

import Clash.Prelude
import qualified Prelude as P
import qualified SimpleRisc.Types as R

type Instr = BitVector 32

-- | The architectural state the model and the hardware both land on.
type Regs = Vec 8 R.Word32

-- | Assemble one instruction. @b@ is the 6-bit low field (rs2:fn for R-type,
-- immediate for the rest).
enc :: Int -> Int -> Int -> Int -> Instr
enc op rd rs1 b = fromIntegral
  (op `shiftL` 12 .|. rd `shiftL` 9 .|. rs1 `shiftL` 6 .|. (b `P.mod` 64))

-- | Field extraction through shift and mask: synthesizable on the decode
-- paths for both constant and runtime fields.
bitsW :: Instr -> Int -> Int -> Int
bitsW w hi lo = fromIntegral ((w `shiftR` lo) .&. mask)
 where
  mask = shiftL 1 (hi P.- lo P.+ 1) - 1 :: BitVector 32

-- | R-type: rs2 lives in bits[5:3].
encR :: Int -> Int -> Int -> Int -> Instr
encR op rd rs1 rs2 = enc op rd rs1 ((rs2 `P.mod` 8) `shiftL` 3)

-- | Three demonstration programs, contract-respecting (two independent
-- instructions after every LD).
progSum :: [(Int, Instr)]
progSum =
  [ (0, enc 11 1 0 0)      -- LDI r1, 0          sum
  , (1, enc 11 2 0 5)      -- LDI r2, 5          i
  , (2, enc 11 3 0 1)      -- LDI r3, 1          one
  , (3, enc 11 4 0 0)      -- LDI r4, 0          base
  , (4, encR 0 1 1 2)      -- L: ADD r1, r1, r2
  , (5, encR 1 2 2 3)      --    SUB r2, r2, r3
  , (6, enc 9 0 2 3)       --    BEQZ r2, +3 -> 9
  , (7, enc 10 0 0 (-3))   --    JAL r0, -3  -> 4
  , (9, enc 8 0 4 9)       -- ST [r4 + 2], r1    mem[1] = sum
  , (10, enc 7 5 4 1)      -- LD r5, [r4 + 4]    r5 = mem[2] = sum
  , (11, enc 0 0 0 0)      -- NOP (contract filler)
  , (12, enc 0 0 0 0)      -- NOP (contract filler)
  , (13, encR 0 6 5 1)     -- ADD r6, r5, r1     r6 = 2 * sum
  , (14, enc 15 0 0 0)     -- HALT
  ]

progCall :: [(Int, Instr)]
progCall =
  [ (0, enc 11 1 0 7)      -- LDI r1, 7
  , (1, enc 11 2 0 3)      -- LDI r2, 3
  , (2, enc 10 7 0 3)      -- JAL r7, +3 -> 5    r7 = 3
  , (3, encR 0 3 1 2)      -- ADD r3, r1, r2     r3 = 17 + 1 = 18
  , (4, enc 15 0 0 0)      -- HALT
  , (5, encR 1 1 1 2)      -- SUB r1, r1, r2     r1 = 4
  , (6, enc 6 1 1 2)       -- SLL2 r1, r1, 2     r1 = 16
  , (7, encR 5 2 2 1)      -- SLT r2, r2, r1     r2 = (3 < 16) = 1
  , (8, encR 4 1 1 2)      -- XOR r1, r1, r2     r1 = 17
  , (9, enc 12 0 7 0)      -- JR r7 -> 3
  ]

progBranch :: [(Int, Instr)]
progBranch =
  [ (0, enc 11 1 0 0)      -- LDI r1, 0
  , (1, enc 11 2 0 0)      -- LDI r2, 0
  , (2, enc 11 3 0 1)      -- LDI r3, 1
  , (3, enc 9 0 2 2)       -- BEQZ r2, +2 -> 5   (taken, skips 4)
  , (4, encR 0 1 1 3)      -- ADD r1, r1, r3     (skipped)
  , (5, encR 0 2 2 3)      -- ADD r2, r2, r3     r2 = 1
  , (6, enc 9 0 2 2)       -- BEQZ r2, +2 -> 8   (not taken)
  , (7, encR 0 1 1 3)      -- ADD r1, r1, r3     r1 = 1
  , (8, enc 15 0 0 0)      -- HALT
  ]

-- | The default sweep program.
progDefault :: [(Int, Instr)]
progDefault = progSum

irom512 :: [(Int, Instr)] -> Vec 512 Instr
irom512 prog = go prog (repeat 0)
 where
  go [] v = v
  go ((i, w) : rest) v = go rest (replace (fromIntegral i :: Index 512) w v)

opOf :: Instr -> Int
opOf i = bitsW i 15 12

writesRd :: Int -> Bool
writesRd o = o <= 7 || o == 10 || o == 11

sext6I :: Int -> R.Word32
sext6I b = fromIntegral (unpack (fromIntegral b :: BitVector 6) :: Signed 6)

sext3I :: Int -> R.Word32
sext3I b = fromIntegral (unpack (fromIntegral b :: BitVector 3) :: Signed 3)

signedLt :: R.Word32 -> R.Word32 -> Bool
signedLt x y = sx < sy
 where
  sx = fromIntegral (unpack (slice d15 d0 x) :: Signed 16) :: Signed 32
  sy = fromIntegral (unpack (slice d15 d0 y) :: Signed 16) :: Signed 32

boolW :: Bool -> R.Word32
boolW c = if c then 1 else 0


-- | CoreMini: a deliberately tiny custom-ISA five-stage core built to answer
-- one question — how fast can a "typical stages" pipeline clock on this
-- fabric when every measured clock-killer is designed out?
--
-- ISA (16-bit fixed words, 8 x 16-bit registers, word-addressed 9-bit pc):
--
--   op[15:12] rd[11:9] rs1[8:6] b[5:0]
--   R-type: rs2 = b[5:3]
--   ST: data register rs2 = b[5:3], address offset = signed b[2:0]
--   LD/ST/BEQZ/JAL: offset = signed b[2:0] (word offset; x2 for LD/ST)
--   LDI: b = signed 6-bit immediate
--
--    0 ADD rd, rs1, rs2      1 SUB rd, rs1, rs2     2 AND   3 OR   4 XOR
--    5 SLT rd, rs1, rs2      (signed 16-bit less-than -> 1/0)
--    6 SLL2 rd, rs1, sh2     sh2 = b[1:0]; two shift levels by ISA contract
--    7 LD  rd, [rs1 + sext3(b)*2]
--    8 ST  [rs1 + sext3(b)*2], rs2
--    9 BEQZ rs1, sext3(b)    taken: pc += sext3(b); predict not-taken
--   10 JAL rd, sext3(b)      rd = pc + 1; pc += sext3(b)
--   11 LDI rd, sext(b)
--   12 JR  rs1                pc = rs1 (word address; JAL's link returns here)
--   15 HALT                   freezes the pc; the pipeline drains to NOPs
--   13/14 reserved            decode as NOP; the all-zero word is a NOP (ADD r0)
--
-- Deliberate simplifications, each tied to a measured result:
--
--   * No BTB/predictor: predict not-taken, redirect from E with a two-cycle
--     flush (the BTB feedback arc alone measured 114-123 MHz).
--   * No interlock: forwarding covers every ALU dependency at any distance;
--     a load's value forwards from distance 3 on, so the assembler contract
--     is two independent instructions after every LD.
--   * 8 registers as plain registers (not BRAM), read by mux in D: removes
--     the register-file read from every arc.
--   * r0 hardwired to zero: initialized, never written, so no read bypass.
--   * No CSRs, traps, interrupts, multiply, byte lanes or compression.
--
-- Pipeline: F (IROM registered read) -> D (decode + register mux) -> E
-- (forward + ALU/branch) -> M (DRAM registered read) -> W (writeback).
-- The register-file signal and the folded observable are returned together
-- so tests can observe per-register state through Clash's simulator.

-- | The full pipeline state for simulation and debugging: the fetch pc,
-- the E-stage instruction and the register file.
miniCoreAll :: forall d. HiddenClockResetEnable d => Vec 512 Instr
            -> (Signal d (Unsigned 9), Signal d Instr, Signal d R.Word32,
                Signal d R.Word32, Signal d (Vec 8 R.Word32))
miniCoreAll irom = (pc, iE, opA, opB, regVec)
 where
  nop :: Signal d Instr
  nop = pure 0x0000

  -- F: pc -> IROM (registered read)
  pc :: Signal d (Unsigned 9)
  pc = register 0 pcNext
  iFetch :: Signal d Instr
  iFetch = blockRam irom pc (pure Nothing)

  -- E-side decode
  eOp :: Signal d Int
  eOp = opOf <$> iE
  eIsLd = eOp .==. 7
  sext3U :: Signal d R.Word32
  sext3U = (\i -> fromIntegral (unpack (slice d2 d0 i) :: Signed 3) :: R.Word32) <$> iE
  writesRdI :: Signal d Int -> Signal d Bool
  writesRdI = fmap writesRd

  -- branch resolution (in E), registered one-shot; JR steers to opA
  aZero = (== 0) <$> opA
  redirectE = isRedirect <$> eOp <*> aZero
  isRedirect o z = (o == 9 && z) || o == 10 || o == 12
  brTargetPC :: Signal d R.Word32
  brTargetPC = addWrap <$> (fromIntegral <$> pcE) <*> sext3U
  addWrap p b = fromIntegral ((p + b) `P.mod` 512)
  brTargetJr :: Signal d R.Word32
  brTargetJr = opA
  isJr = eOp .==. 12
  brTargetW = mux isJr brTargetJr brTargetPC
  brValid = register False redirectE
  brValid2 = register False brValid
  brTarget = register 0 brTargetW
  redirectNow = brValid
  haltingNow = eOp .==. 15
  -- The D->E transfer dies on the fresh redirect or HALT (an instruction
  -- already in D must never execute, redirect or write past its elder); the
  -- two wrong-path fetches behind it die on the two registered redirect
  -- cycles, and everything fetched after HALT dies on frozen.
  killE = redirectE .||. brValid .||. haltingNow .||. frozen
  killD = brValid .||. brValid2 .||. haltingNow .||. frozen

  -- freeze: sticky once HALT reaches E
  frozen = register False (frozen .||. (eOp .==. 15))

  pcNext = mux frozen pc (mux redirectNow (truncateB <$> brTarget) (pc + 1))
  -- The pc of the E-stage instruction: three registers behind the fetch pc
  -- (pc -> IROM registered read -> iD -> iE).
  pcE1 :: Signal d (Unsigned 9)
  pcE1 = register 0 pc
  pcE2 :: Signal d (Unsigned 9)
  pcE2 = register 0 pcE1
  pcE :: Signal d (Unsigned 9)
  pcE = register 0 pcE2

  -- D: instruction register (killed on redirect)
  iD :: Signal d Instr
  iD = register 0x0000 (mux killD nop iFetch)
  rs1D :: Signal d (Index 8)
  rs1D = (\i -> fromIntegral (bitsW i 8 6) :: Index 8) <$> iD
  rs2D :: Signal d (Index 8)
  rs2D = (\i -> fromIntegral (bitsW i 5 3) :: Index 8) <$> iD
  aD = readReg regVec rs1D
  bD = readReg regVec rs2D

  -- D: register file (plain registers, written by W; r0 never written)
  regVec :: Signal d (Vec 8 R.Word32)
  regVec = register (repeat 0) nextVec
  wEn :: Signal d Bool
  wEn = (\w r -> w && r /= 0) <$> wWritesRd' <*> rdW
  wWritesRd' = wWritesRd
  nextVec :: Signal d (Vec 8 R.Word32)
  nextVec = (\v (en, r, val) -> if en then replace r val v else v)
              <$> regVec <*> bundle (wEn, rdW, wVal)

  -- E: instruction and operand registers (killed on redirect); operands
  -- captured with forwarding: E-now (ALU only), ER, MD, else regfile read
  iE :: Signal d Instr
  iE = register 0x0000 (mux killE nop iD)
  rdE :: Signal d (Index 8)
  rdE = (\i -> fromIntegral (bitsW i 11 9) :: Index 8) <$> iE
  -- Capture-time forwarding, youngest producer wins: distance 1 from E
  -- (ALU results only; a load has nothing yet), distance 2 from ER,
  -- distance 3 from the W value (including a load's data, which is the
  -- two-independent-instructions contract). r0 never forwards.
  eWritesRd' = writesRdI eOp
  notLdE' = not <$> eIsLd
  notLdM' = not <$> mIsLd
  rdENz = rdE ./=. pure 0
  rdMNz = rdM ./=. pure 0
  rdWNz = rdW ./=. pure 0
  fwd1A = eWritesRd' .&&. notLdE' .&&. (rdE .==. rs1D) .&&. rdENz
  fwd1B = eWritesRd' .&&. notLdE' .&&. (rdE .==. rs2D) .&&. rdENz
  fwd2A = mWritesRd .&&. notLdM' .&&. (rdM .==. rs1D) .&&. rdMNz
  fwd2B = mWritesRd .&&. notLdM' .&&. (rdM .==. rs2D) .&&. rdMNz
  fwd3A = wWritesRd .&&. (rdW .==. rs1D) .&&. rdWNz
  fwd3B = wWritesRd .&&. (rdW .==. rs2D) .&&. rdWNz
  opA = register 0 (mux fwd1A eResNow (mux fwd2A erReg (mux fwd3A wVal aD))) :: Signal d R.Word32
  opB = register 0 (mux fwd1B eResNow (mux fwd2B erReg (mux fwd3B wVal bD))) :: Signal d R.Word32

  -- M-side producer state
  iM :: Signal d Instr
  iM = register 0x0000 iE
  rdM :: Signal d (Index 8)
  rdM = (\i -> fromIntegral (bitsW i 11 9) :: Index 8) <$> iM
  mWritesRd = writesRdI (opOf <$> iM)
  mIsLd = (== 7) <$> mOpI
  mOpI = (\i -> bitsW i 15 12) <$> iM

  -- E: ALU and branch result (feeds the ER register and the D->E forward)
  eResNow = pickE <$> eOp <*> opA <*> opB <*> iE <*> (fromIntegral <$> pcE)
  erReg = register (0 :: R.Word32) eResNow :: Signal d R.Word32
  pickE :: Int -> R.Word32 -> R.Word32 -> Instr -> R.Word32 -> R.Word32
  pickE o a b i p = case o of
    0 -> a + b
    1 -> a - b
    2 -> a .&. b
    3 -> a .|. b
    4 -> a `xor` b
    5 -> boolW (signedLt a b)
    6 -> shiftL a (fromIntegral (unpack (slice d1 d0 i) :: Unsigned 2))
    10 -> p + 1                       -- JAL link
    11 -> sext6I (bitsW i 5 0)        -- LDI
    _ -> 0                            -- LD/ST/BEQZ/HALT: no result here

  -- W-side producer state
  wInstr :: Signal d Instr
  wInstr = register 0x0000 iM :: Signal d Instr
  rdW :: Signal d (Index 8)
  rdW = (\i -> fromIntegral (bitsW i 11 9) :: Index 8) <$> wInstr
  wWritesRd :: Signal d Bool
  wWritesRd = writesRdI (opOf <$> wInstr)

  -- M: data memory (registered read), the W value register
  eAddr :: Signal d R.Word32
  eAddr = (+) <$> opA <*> ((* 2) <$> sext3U)
  eAddrR = register (0 :: R.Word32) eAddr :: Signal d R.Word32
  mStoreData = register (0 :: R.Word32) opB :: Signal d R.Word32
  mIsSt = (== 8) <$> eOpAtM
  eOpAtM = (\i -> bitsW i 15 12) <$> iM
  mAddrW = (\a -> fromIntegral (bitsW (bitCoerce a) 8 1) :: Index 256) <$> eAddrR
  dramData = slice d15 d0 <$> mStoreData :: Signal d (BitVector 16)
  dram = blockRam (repeat 0 :: Vec 256 (BitVector 16)) mAddrW
                  ((\st a d -> if st then Just (a, d) else Nothing)
                     <$> mIsSt <*> mAddrW <*> dramData)
  dramOut = dram
  mRes = register (0 :: R.Word32) erReg :: Signal d R.Word32
  wIsLd = register False mIsLd
  wVal = mux wIsLd ((\d -> fromIntegral (unpack d :: Unsigned 16)) <$> dramOut) mRes
           :: Signal d R.Word32

  -- register-file read helper: 8-way mux
  readReg :: Signal d (Vec 8 R.Word32) -> Signal d (Index 8) -> Signal d R.Word32
  readReg v r = (\vec ix -> vec !! ix) <$> v <*> r

-- | The register file and folded observable.
miniCore' :: forall d. HiddenClockResetEnable d => Vec 512 Instr -> (Signal d (Vec 8 R.Word32), Signal d (BitVector 32))
miniCore' irom = (regVec, foldRegs <$> regVec)
 where
  (_, _, _, _, regVec) = miniCoreAll irom

-- | The fold wrapper.
miniFold :: Signal d (Vec 8 R.Word32) -> Signal d (BitVector 32)
miniFold = fmap foldRegs

foldRegs :: Vec 8 R.Word32 -> BitVector 32
foldRegs = go 0x13579BDF . toList
 where
  go acc [] = acc
  go acc (r : rs) = go (lfsrNext (acc + fromIntegral r)) rs

-- | The 32-bit LFSR step shared by the probe tops.
lfsrNext :: BitVector 32 -> BitVector 32
lfsrNext x = (x `shiftL` 1) .|. zeroExtend (slice d31 d31 x `xor` slice d21 d21 x `xor` slice d1 d1 x `xor` slice d0 d0 x)

-- | The pipeline observable.
miniCore :: HiddenClockResetEnable d => Vec 512 Instr -> Signal d (BitVector 32)
miniCore = snd . miniCore'

-- | The register-file observable.
miniRegs :: HiddenClockResetEnable d => Vec 512 Instr -> Signal d (Vec 8 R.Word32)
miniRegs = fst . miniCore'

-- | The synthesis observable: one parallel XOR tree over the registers.
-- The serial LFSR fold is for simulation only; an eight-step chain would
-- dominate the timing report with the probe wrapper's own path.
xorRegs :: Vec 8 R.Word32 -> BitVector 32
xorRegs v = if fold (/=) (map (\x -> odd (popCount x)) v) then 1 else 0

-- | The mini top for synthesis: the default program.
miniTop :: Clock XilinxSystem -> Reset XilinxSystem -> Enable XilinxSystem -> Signal XilinxSystem (BitVector 32)
miniTop clk rst en = exposeClockResetEnable (xorRegs <$> miniRegs (irom512 progDefault)) clk rst en
{-# ANN miniTop (Synthesize {t_name="mini_core",t_inputs=[PortName "clk",PortName "reset",PortName "enable"],t_output=PortName "q"}) #-}

-- | Sequential reference model: run the program with ideal state and return
-- the final registers. The hardware must land here after HALT drains.
-- Every semantic detail mirrors the hardware: 6-bit signed immediates,
-- signed 16-bit SLT, word addresses mod 512, DRAM words at (a + 2*simm)/2
-- mod 256, r0 never written, reserved words decode as NOP.
model :: [(Int, Instr)] -> Regs
model prog = go 0 (0 :: Int) (repeat 0 :: Regs) (repeat 0 :: Vec 256 R.Word32)
 where
  imem = irom512 prog
  go pc it regs dram
    | it >= 4096 = regs
    | op == 15 = regs                                   -- HALT
    | op == 12 = go (fromIntegral a `P.mod` 512) (it + 1) regs dram     -- JR
    | op == 9 = if a == 0                                 -- BEQZ
                  then go ((pc + sextB) `P.mod` 512) (it + 1) regs dram
                  else go nxt (it + 1) regs dram
    | op == 10 = go ((pc + sextB) `P.mod` 512) (it + 1) (wr (fromIntegral (pc + 1))) dram  -- JAL
    | op == 8 = go nxt (it + 1) regs dram'               -- ST (no register write)
    | op == 7 = go nxt (it + 1) (wr (dram !! dIdx)) dram'  -- LD
    | op == 11 = go nxt (it + 1) (wr (sext6I (bitsW w 5 0))) dram  -- LDI
    | op <= 6 = go nxt (it + 1) (wr (alu op)) dram       -- ALU
    | otherwise = go nxt (it + 1) regs dram              -- 13/14 reserved: NOP
   where
    nxt = (pc + 1) `P.mod` 512
    w = imem !! (fromIntegral pc :: Index 512)
    op = opOf w
    rd = bitsW w 11 9
    a = regs !! (fromIntegral (bitsW w 8 6) :: Index 8)
    bVal = regs !! (fromIntegral (bitsW w 5 3) :: Index 8)
    sextB = fromIntegral (sext3I (bitsW w 2 0)) :: Int
    dIdx = fromIntegral ((addrI `P.div` 2) `P.mod` 256) :: Index 256
    addrI = (fromIntegral a :: Int) + 2 P.* sextB
    dram' = replace dIdx bVal dram
    wr v = if rd /= 0 && writesRd op then replace (fromIntegral rd :: Index 8) v regs else regs
    alu o = case o of
      0 -> a + bVal
      1 -> a - bVal
      2 -> a .&. bVal
      3 -> a .|. bVal
      4 -> a `xor` bVal
      5 -> boolW (s16 a < s16 bVal)
      _ -> shiftL a (bitsW w 1 0)          -- 6: SLL2, shift = bits[1:0]
    s16 x = fromIntegral (unpack (slice d15 d0 x) :: Signed 16) :: Signed 32
