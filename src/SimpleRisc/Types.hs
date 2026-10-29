{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- | The types 'SimpleRisc' is built from: the ISA-level control records, the
-- pipeline stages, the system bus, the devices and the machine state, with the
-- custom bit representations 'CpuPhase', 'MemoryTarget', 'BusPhase' and
-- 'CommitKind' use to keep their packed encodings small. Behaviour lives in the
-- other modules; this one depends on none of them.
module SimpleRisc.Types where

import Clash.Annotations.BitRepresentation (ConstrRepr (..), DataReprAnn (..), liftQ)
import Clash.Prelude


type Word32 = Unsigned 32

type Byte = Unsigned 8

-- | A physical word index: bit 14 selects the boot ROM (512 words), otherwise
-- the low 14 bits index the 64 KiB RAM.
type MemAddr = Unsigned 15

-- | CPU pipeline stage.  Every stage starts from flip-flops and does one kind
-- of work, so the clock can run fast (the design targets 100 MHz on a GW2A):
-- Fetch and register reads retain their existing registered stages.
-- OperandSelect registers ALU controls; ExecuteFinish selects registered results.
-- Ordinary instructions take nine cycles; shifts insert ShiftFinish for ten.
-- The BRAM and the UART transmitter are only ever driven from registers, in
-- stages of their own (Fetch, BusLoadIssue, BusRamWrite, BusTx...): on the GW2A
-- their input timing is worse than nextpnr models.  The
-- values passed between stages live in their own 'Machine' fields, each
-- written by a single stage, rather than in the phase: overlapping them in one
-- register put a many-way mux in front of every bit.
data CpuPhase
  = Fetch
  | FetchDelay
  | FetchCapture
  | FetchWait
  | Decode
  | OperandSelect
  | Execute
  | ExecuteFinish
  | ShiftFinish
  | MulDiv
  | Commit
  | Trap
  | CsrRead
  | CsrWrite
  | TrapReturn
  | BusWait
  | MemoryWait
  | MemoryCapture
  | FetchTargetWait
  | FetchCross
  | FetchCrossDelay
  | FetchCrossCapture
  | FetchCrossWait
  deriving (Generic, NFDataX, Show, Eq)

-- One dedicated state bit per CPU stage.
{-# ANN
  module
  ( DataReprAnn
      $(liftQ [t|CpuPhase|])
      23
      [ ConstrRepr 'Fetch 1 1 [],
        ConstrRepr 'FetchDelay 2 2 [],
        ConstrRepr 'FetchCapture 4 4 [],
        ConstrRepr 'FetchWait 8 8 [],
        ConstrRepr 'Decode 16 16 [],
        ConstrRepr 'OperandSelect 32 32 [],
        ConstrRepr 'Execute 64 64 [],
        ConstrRepr 'ShiftFinish 128 128 [],
        ConstrRepr 'MulDiv 256 256 [],
        ConstrRepr 'Commit 512 512 [],
        ConstrRepr 'Trap 1024 1024 [],
        ConstrRepr 'CsrRead 2048 2048 [],
        ConstrRepr 'CsrWrite 4096 4096 [],
        ConstrRepr 'TrapReturn 8192 8192 [],
        ConstrRepr 'BusWait 16384 16384 [],
        ConstrRepr 'ExecuteFinish 32768 32768 [],
        ConstrRepr 'MemoryWait 65536 65536 [],
        ConstrRepr 'MemoryCapture 131072 131072 [],
        ConstrRepr 'FetchTargetWait 262144 262144 [],
        ConstrRepr 'FetchCross 524288 524288 [],
        ConstrRepr 'FetchCrossDelay 1048576 1048576 [],
        ConstrRepr 'FetchCrossCapture 2097152 2097152 [],
        ConstrRepr 'FetchCrossWait 4194304 4194304 []
      ]
  )
  #-}

-- | Everything an instruction needs from the adders and the ALU, computed in
-- the Execute stage so the Commit stage only selects between registers.
data Computed = Computed
  { -- | Result for LUI, AUIPC, OP-IMM and OP; Nothing for an illegal encoding.
    cAlu :: Maybe Word32,
    -- | PC + 4: the fall-through PC and the JAL/JALR link value.
    cLink :: Word32,
    -- | Jump or taken-branch target.
    cTarget :: Word32,
    -- | Branch condition; Nothing for an illegal funct3.
    cTaken :: Maybe Bool,
    -- | Load/store effective address.
    cAddress :: Word32
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | Where the multiply/divide unit is in an instruction.
data MdStep
  = -- | Take the operands' magnitudes, or answer a division by zero.
    MdPrepare
  | -- | One of 32 shift-and-add (multiply) or restoring-division steps.
    MdLoop (Index 32)
  | -- | Commit the registered adder/subtractor result, separately from arithmetic.
    MdCommit (Index 32)
  | -- | Negate the low word if needed, recording the carry out of it.
    MdFixLo
  | -- | Negate the high word if needed, taking that carry.
    MdFixHi
  | -- | Pick the requested half.
    MdFinish
  deriving (Generic, NFDataX, Show, Eq)

-- | The multiply/divide unit's working registers.  A multiply keeps the
-- 64-bit product in 'mdHi' and 'mdLo' (the multiplier shifts out of 'mdLo' as
-- the product shifts in); a division keeps the remainder in 'mdHi' and the
-- quotient in 'mdLo' (the dividend shifts out as quotient bits shift in).
data MulDivUnit = MulDivUnit
  { mdStep :: MdStep,
    mdHi :: Word32,
    mdLo :: Word32,
    -- | The magnitude of the multiplicand or the divisor.
    mdOperand :: Word32,
    mdTotal :: Unsigned 33,
    -- | Negate the low word (product low half or quotient) at the end.
    mdNegLo :: Bool,
    -- | Negate the high word (product high half or remainder) at the end.
    mdNegHi :: Bool,
    -- | The low word was zero before negation: the carry into the high word.
    mdCarry :: Bool,
    -- | Registered at Prepare, so Finish's result mux does not decode the
    -- global instruction register on the way to register-file writeback.
    mdTakeLow :: Bool
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | Why the CPU last entered the boot ROM through a reset.  BOOTCAUSE reads

-- | Software-visible machine-mode trap registers. Only machine mode is used.
data TrapRegisters = TrapRegisters
  { trapVector :: Word32,
    trapEpc :: Word32,
    trapCause :: Word32,
    trapValue :: Word32,
    trapMie :: Bool,
    trapMpie :: Bool
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | The low word increments independently; its overflow is registered and
-- applied to the high word on the following clock. CSR reads wait out that
-- single carry cycle rather than adding another carry chain to the read mux.
data Counter64 = Counter64
  { counterLo :: Word32,
    counterHi :: Word32,
    counterCarry :: Bool
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | Where the next Fetch finds its word, decided by the instruction that
-- set the pc: the sequential prefetch (pc + 4), the branch-target read, or
-- the word decode-ahead already captured (FromNext), or neither (fetch from
-- memory). Fetch consumes it, so a trap, MRET, an interrupt or a reset
-- always fetches from memory. No address compare.
data FetchSource = FromMemory | FromPrefetch | FromTarget | FromNext
  deriving (Generic, NFDataX, Show, Eq)

-- | Interrupt-source state: the CLINT, the PLIC with its one source (the
-- UART, IRQ 10) and the UART's interrupt enables. Comparisons and the
-- pending bits are registered, so no wide compare or OR feeds the CPU.
data Devices = Devices
  { devMsip :: Bool,
    devMtimecmpLo :: Word32,
    devMtimecmpHi :: Word32,
    -- | Counts every core clock; a split counter like mcycle.
    devMtime :: Counter64,
    -- | mtime >= mtimecmp in two registered stages: the halves compared,
    -- then combined.
    devHiAbove :: Bool,
    devHiEqual :: Bool,
    devLoAtLeast :: Bool,
    devMtip :: Bool,
    devPlicPriority :: Unsigned 3,
    devPlicEnable :: Bool,
    devPlicThreshold :: Unsigned 3,
    -- | The gateway forwarded a request that has not been claimed yet.
    devPlicPending :: Bool,
    -- | Claimed and not yet completed: the gateway holds new requests.
    devPlicClaimed :: Bool,
    devMeip :: Bool,
    devUartRxInterrupt :: Bool,
    devUartTxInterrupt :: Bool,
    -- | The I/O complex's answer this cycle, injected by the circuit around
    -- the CPU (never stepped here).
    devIo :: Maybe Word32
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | An SPI master, mode 0 (SCK idle low, sample on the rising edge, shift
-- on the falling edge), for the microSD slot. Every pin is a register.
data Spi = Spi
  { spiSelect :: Bool,
    -- | Half an SCK period in clocks, minus one.
    spiDivider :: Unsigned 8,
    spiCount :: Unsigned 8,
    -- | Rising edges still to come in this byte; 0 when idle.
    spiBits :: Unsigned 4,
    spiSck :: Bool,
    -- | MSB first; ones shift in, so MOSI idles high.
    spiOut :: Byte,
    spiIn :: Byte,
    -- | MISO, already synchronised to the core clock.
    spiMiso :: Bit
  }
  deriving (Generic, NFDataX, Show, Eq)

-- Registered memory target; wide address comparisons stay out of Commit.
data MemoryTarget
  = RamTarget
  | RomTarget
  | UartTxTarget
  | UartStatusTarget
  | UartRxTarget
  | ExitTarget
  | BootCauseTarget
  | ClintMsipTarget
  | ClintCompareLoTarget
  | ClintCompareHiTarget
  | ClintTimeLoTarget
  | ClintTimeHiTarget
  | PlicPriorityTarget
  | PlicPendingTarget
  | PlicEnableTarget
  | PlicThresholdTarget
  | PlicClaimTarget
  | UartControlTarget
  | IoTarget
  | UnmappedTarget
  deriving (Generic, NFDataX, Show)

-- GHC's derived equality for an enumeration uses dataToTag#, which Clash
-- 1.8's Verilog backend cannot lower for a custom sum representation.
-- Constructor matches preserve the custom decode-bit representation.
instance Eq MemoryTarget where
  a == b = case a of
    RamTarget -> case b of RamTarget -> True; _ -> False
    RomTarget -> case b of RomTarget -> True; _ -> False
    UartTxTarget -> case b of UartTxTarget -> True; _ -> False
    UartStatusTarget -> case b of UartStatusTarget -> True; _ -> False
    UartRxTarget -> case b of UartRxTarget -> True; _ -> False
    ExitTarget -> case b of ExitTarget -> True; _ -> False
    BootCauseTarget -> case b of BootCauseTarget -> True; _ -> False
    ClintMsipTarget -> case b of ClintMsipTarget -> True; _ -> False
    ClintCompareLoTarget -> case b of ClintCompareLoTarget -> True; _ -> False
    ClintCompareHiTarget -> case b of ClintCompareHiTarget -> True; _ -> False
    ClintTimeLoTarget -> case b of ClintTimeLoTarget -> True; _ -> False
    ClintTimeHiTarget -> case b of ClintTimeHiTarget -> True; _ -> False
    PlicPriorityTarget -> case b of PlicPriorityTarget -> True; _ -> False
    PlicPendingTarget -> case b of PlicPendingTarget -> True; _ -> False
    PlicEnableTarget -> case b of PlicEnableTarget -> True; _ -> False
    PlicThresholdTarget -> case b of PlicThresholdTarget -> True; _ -> False
    PlicClaimTarget -> case b of PlicClaimTarget -> True; _ -> False
    UartControlTarget -> case b of UartControlTarget -> True; _ -> False
    IoTarget -> case b of IoTarget -> True; _ -> False
    UnmappedTarget -> case b of UnmappedTarget -> True; _ -> False

-- Each target retains its own decode bit. In particular testing RAM/ROM
-- must not encode every peripheral through a binary priority tree first.
{-# ANN
  module
  ( DataReprAnn
      $(liftQ [t|MemoryTarget|])
      20
      [ ConstrRepr 'RamTarget 1 1 [],
        ConstrRepr 'RomTarget 2 2 [],
        ConstrRepr 'UartTxTarget 4 4 [],
        ConstrRepr 'UartStatusTarget 8 8 [],
        ConstrRepr 'UartRxTarget 16 16 [],
        ConstrRepr 'ExitTarget 32 32 [],
        ConstrRepr 'BootCauseTarget 64 64 [],
        ConstrRepr 'ClintMsipTarget 128 128 [],
        ConstrRepr 'ClintCompareLoTarget 256 256 [],
        ConstrRepr 'ClintCompareHiTarget 512 512 [],
        ConstrRepr 'ClintTimeLoTarget 1024 1024 [],
        ConstrRepr 'ClintTimeHiTarget 2048 2048 [],
        ConstrRepr 'PlicPriorityTarget 4096 4096 [],
        ConstrRepr 'PlicPendingTarget 8192 8192 [],
        ConstrRepr 'PlicEnableTarget 16384 16384 [],
        ConstrRepr 'PlicThresholdTarget 32768 32768 [],
        ConstrRepr 'PlicClaimTarget 65536 65536 [],
        ConstrRepr 'UartControlTarget 131072 131072 [],
        ConstrRepr 'IoTarget 262144 262144 [],
        ConstrRepr 'UnmappedTarget 524288 524288 []
      ]
  )
  #-}

-- Single outstanding data transaction. The CPU registers the request and
-- waits for a registered response; the bus alone owns device side effects.
data BusRequest = BusRequest
  { busAddress :: Word32,
    busWidth :: BitVector 3,
    busWrite :: Bool,
    busData :: Word32
  }
  deriving (Generic, NFDataX, Show, Eq)

data BusResponse = BusResponse
  {responseValue :: Word32, responseFault :: Bool, responseExit :: Bool}
  deriving (Generic, NFDataX, Show, Eq)

data BusPhase
  = BusIdle
  | BusDecode
  | BusDispatch
  | BusLoadIssue
  | BusLoadDelay
  | BusLoadCapture
  | BusLoadWait
  | BusLoadAlign
  | BusReply
  | BusStoreIssue
  | BusStoreDelay
  | BusStoreCapture
  | BusStoreWait
  | BusStoreMerge
  | BusRamWrite
  | BusTx
  | BusIo
  deriving (Generic, NFDataX, Show, Eq)

{-# ANN
  module
  ( DataReprAnn
      $(liftQ [t|BusPhase|])
      17
      [ ConstrRepr 'BusIdle 1 1 [],
        ConstrRepr 'BusDecode 2 2 [],
        ConstrRepr 'BusDispatch 4 4 [],
        ConstrRepr 'BusLoadIssue 8 8 [],
        ConstrRepr 'BusLoadDelay 16 16 [],
        ConstrRepr 'BusLoadCapture 32 32 [],
        ConstrRepr 'BusLoadWait 64 64 [],
        ConstrRepr 'BusLoadAlign 128 128 [],
        ConstrRepr 'BusReply 256 256 [],
        ConstrRepr 'BusStoreIssue 512 512 [],
        ConstrRepr 'BusStoreDelay 1024 1024 [],
        ConstrRepr 'BusStoreCapture 2048 2048 [],
        ConstrRepr 'BusStoreWait 4096 4096 [],
        ConstrRepr 'BusStoreMerge 8192 8192 [],
        ConstrRepr 'BusRamWrite 16384 16384 [],
        ConstrRepr 'BusTx 32768 32768 [],
        ConstrRepr 'BusIo 65536 65536 []
      ]
  )
  #-}

data BusState = BusState
  { busPhase :: BusPhase,
    busRequest :: BusRequest,
    busTarget :: MemoryTarget,
    busWord :: Word32,
    busValue :: Word32
  }
  deriving (Generic, NFDataX)

-- | The side effect of a completed device read.
data BusEffect
  = NoEffect
  | ConsumeRx
  | ConsumeBootCause
  | -- | A word written to a device register.
    DeviceWrite MemoryTarget Word32
  | -- | A PLIC claim that granted the UART's interrupt.
    ClaimInterrupt
  deriving (Generic, NFDataX, Show, Eq)

-- | What Commit does with an instruction, decoded at OperandSelect and
-- carried in the stage register: later stages pick their action from one
-- flip-flop each rather than decoding the instruction word again. Encodings
-- with a reserved funct3 decode to 'KindInvalid' here.
data CommitKind
  = KindAlu
  | KindJump
  | KindBranch
  | KindLoad
  | KindStore
  | KindFence
  | KindFenceI
  | KindEcall
  | KindEbreak
  | KindMret
  | KindWfi
  | KindCsr
  | KindInvalid
  deriving (Generic, NFDataX, Show, Eq)

{-# ANN
  module
  ( DataReprAnn
      $(liftQ [t|CommitKind|])
      13
      [ ConstrRepr 'KindAlu 1 1 [],
        ConstrRepr 'KindJump 2 2 [],
        ConstrRepr 'KindBranch 4 4 [],
        ConstrRepr 'KindLoad 8 8 [],
        ConstrRepr 'KindStore 16 16 [],
        ConstrRepr 'KindFence 32 32 [],
        ConstrRepr 'KindFenceI 64 64 [],
        ConstrRepr 'KindEcall 128 128 [],
        ConstrRepr 'KindEbreak 256 256 [],
        ConstrRepr 'KindMret 512 512 [],
        ConstrRepr 'KindWfi 1024 1024 [],
        ConstrRepr 'KindCsr 2048 2048 [],
        ConstrRepr 'KindInvalid 4096 4096 []
      ]
  )
  #-}

-- Decode and operand selection are registered before the ALU carry chains;
-- the result mux runs in a separate stage after all candidates are registered.
-- This is the decoded half of the stage register between OperandSelect and
-- Execute; it stays with the instruction until it retires.
data ExecuteControl = ExecuteControl
  { execFunct3 :: BitVector 3,
    execLegal :: Bool,
    execSubtract :: Bool,
    execArithmeticShift :: Bool,
    execShift :: Bool,
    execMulDiv :: Bool,
    -- | A load or store; a branch or jump. Registered here so ExecuteFinish
    -- picks its memory read from flip-flops.
    execMemory :: Bool,
    execJump :: Bool,
    -- | ExecuteFinish's result: LUI's immediate, AUIPC's sum, or the ALU's
    -- (OP-IMM and OP); none of them for anything else.
    execLui :: Bool,
    execAuipc :: Bool,
    execAluOp :: Bool,
    execStore :: Bool,
    execKind :: CommitKind
  }
  deriving (Generic, NFDataX)

-- High and low comparisons run in parallel; their registered results are
-- combined in ExecuteFinish, avoiding a full 32-bit comparison carry chain.
data CompareResults = CompareResults
  { compareEqual :: Bool,
    compareHighEqual :: Bool,
    compareLowLess :: Bool,
    compareSignedHighLess :: Bool,
    compareUnsignedHighLess :: Bool
  }
  deriving (Generic, NFDataX)

data Machine = Machine
  { -- | The register file as values: the simulation's mirror. The BRAM
    -- circuit keeps the registers in distributed RAM instead (two read
    -- ports, see 'registerReads'), injects their outputs as cpuRfA/cpuRfB
    -- and leaves this constant, so synthesis removes it.
    cpuRegs :: Vec 32 Word32,
    -- | Which registers hold a value: a reset clears these instead of 32
    -- words, and a register whose bit is clear reads as 0 (x0 never set).
    cpuRegValid :: BitVector 32,
    -- | This cycle's register-file outputs at 'registerReads', injected.
    cpuRfA :: Word32,
    cpuRfB :: Word32,
    -- | Registered writeback request; consumed during the next fetch.
    cpuPendingWrite :: RegisterWrite,
    cpuPc :: Word32,
    cpuPhase :: CpuPhase,
    cpuInstruction :: Word32,
    -- | Explicit board variant: the default IM frontend remains unchanged.
    cpuCompressed :: Bool,
    cpuInstructionRaw :: Word32,
    cpuInstructionSize :: Unsigned 3,
    cpuFetchHalf :: Unsigned 16,
    -- | The PC being fetched is outside the ROM and RAM; registered at Fetch
    -- and raised as an instruction access fault at Decode.
    cpuFetchFault :: Bool,
    -- | The CPU drives a local block RAM directly (the BRAM image), which
    -- enables both overlaps below. Off on images whose memory is driven by
    -- the CPU's phase (the SDRAM wrapper).
    cpuLocalMemory :: Bool,
    -- | An external cache supplies the pipeline's fixed-latency word port.
    -- Preserve the full physical address beside the BRAM-sized legacy index.
    cpuExternalMemory :: Bool,
    cpuPortAddressFull :: Word32,
    cpuPortWriteAddressFull :: Word32,
    cpuPortByteEnable :: BitVector 4,
    -- | The pipeline: on the BRAM image, ordinary instructions run in
    -- 'cpuPipe' while the phases above run only the rest (see 'pipeStep').
    -- cpuFast: the pipeline holds the machine; otherwise a commit-stage
    -- action runs in the phases (Trap, CsrRead, CsrWrite, TrapReturn,
    -- BusWait, MulDiv, Commit for WFI) and the pipeline resumes at Fetch.
    cpuPipelined :: Bool,
    cpuFast :: Bool,
    cpuPipe :: Pipe,
    -- | An interrupt is due (registered: the pipeline hands over a cycle
    -- after it becomes due).
    cpuInterruptDue :: Maybe Word32,
    -- | The register file's read addresses this cycle, registered: the
    -- next state's 'registerReads'.
    cpuReadIndices :: (Index 32, Index 32),
    -- | Fast RAM access: ExecuteFinish found an aligned load or store to
    -- RAM and issued the word's read; Commit skips the bus.
    cpuFastMemory :: Bool,
    -- | The memory port's store, prepared at ExecuteFinish so the port's
    -- write register is fed from flip-flops: the RAM word index, the data
    -- already in its byte lanes and the lanes it replaces. A word store
    -- writes at Commit (cpuStoreNow); a byte or halfword store merges into
    -- the word read back, at MemoryCapture.
    cpuPortIndex :: MemAddr,
    cpuStoreData :: Word32,
    cpuStoreMask :: Word32,
    cpuStoreNow :: Bool,
    -- Fetch overlap: Decode reads the word at pc + 4 while the CPU's RAM
    -- port is otherwise idle; it arrives three cycles later. A Fetch whose
    -- pc matches a valid prefetch goes straight to Decode.
    cpuPrefetchAddress :: Word32,
    cpuPrefetchWord :: Word32,
    cpuPrefetchValid :: Bool,
    -- | Cycles until the prefetched word is on the memory bus; 0 when none.
    cpuPrefetchCount :: Unsigned 2,
    -- | Branch-target prefetch: ExecuteFinish of a branch or jump reads the
    -- target word (the port is free: no load or store is in flight). If
    -- the jump is taken, Fetch finds it buffered or one cycle away.
    cpuTargetAddress :: Word32,
    cpuTargetWord :: Word32,
    cpuTargetValid :: Bool,
    cpuTargetCount :: Unsigned 2,
    cpuFetchSource :: FetchSource,
    -- | Registered at ExecuteFinish: this store writes the prefetched word,
    -- or the branch-target word. Commit drops that buffer; every write path
    -- finishes before the next Fetch.
    cpuStoreHitsPrefetch :: Bool,
    cpuStoreHitsTarget :: Bool,
    -- | Decode-ahead: at ExecuteFinish of a plain ALU instruction the next
    -- word is on the memory bus or in the prefetch buffer; it is kept here.
    -- If it does not read this instruction's result (cpuAhead) and no
    -- interrupt is due, Commit does its Decode and it continues at
    -- OperandSelect, skipping Fetch. Otherwise Fetch takes it (FromNext).
    cpuNextInstruction :: Word32,
    cpuNextValid :: Bool,
    cpuAhead :: Bool,
    -- | A prefetch read was issued this cycle (Decode, or decode-ahead).
    cpuPrefetchIssue :: Bool,
    -- | Executing boot ROM code, registered at Fetch. Ctrl-C only breaks
    -- programs: in the ROM a 0x03 byte is data, such as part of an image.
    cpuInRom :: Bool,
    -- | Decode's register reads (rs1, rs2).
    cpuRegA :: Word32,
    cpuRegB :: Word32,
    cpuA :: Word32,
    cpuB :: Word32,
    -- | The instruction's immediate, whichever format it uses.
    cpuImm :: Word32,
    -- | OP (register-register) rather than OP-IMM: the ALU takes rs2, not the
    -- immediate. Selected in OperandSelect so Decode's register read feeds
    -- bank flip-flops directly; OperandSelect completes the read next cycle.
    cpuIsRegOp :: Bool,
    cpuOp2 :: Word32,
    cpuExecuteControl :: ExecuteControl,
    cpuAluCandidates :: Vec 8 Word32,
    cpuAluCompare :: CompareResults,
    cpuBranchCompare :: CompareResults,
    cpuComputed :: Computed,
    cpuTrapRegisters :: TrapRegisters,
    cpuExceptionCause :: Word32,
    cpuExceptionValue :: Word32,
    cpuScratch :: Word32,
    cpuInterruptEnable :: Word32,
    cpuCsrSelection :: Vec 14 Bool,
    -- | The CSR instruction writes (registered with the selection at Commit).
    cpuCsrWrite :: Bool,
    cpuCsrReadOnly :: Bool,
    cpuCsrValue :: Word32,
    cpuCsrSource :: Word32,
    cpuCycle :: Counter64,
    cpuInstret :: Counter64,
    -- | Registered pulse and CSR write request, applied on the next clock.
    cpuCountRetirement :: Bool,
    cpuCounterWrite :: Maybe (Unsigned 12, Word32),
    cpuMulDiv :: MulDivUnit,
    -- | The pipelined multiply's four partial products, injected each cycle
    -- like cpuRfA/cpuRfB. In hardware they come from two free-running
    -- registers outside 'Machine' ('multiplyOperands' -> operand register
    -- -> 'partialProductsOf' -> product register), so the DSP input and
    -- output registers have no clock enable or next-state mux and are not
    -- reached by stage-advance, hold or cancellation logic. The commit
    -- stage waits long enough ('mWait') that both registers have reloaded
    -- from its operands; holds only add edges, never remove them.
    cpuMulProducts :: Vec 4 (Signed 34),
    -- | The simulation's copy of those two registers (see
    -- 'withMultiplyMirror'); the circuits keep them constant (removed).
    cpuMulOperandsMirror :: (BitVector 3, Word32, Word32),
    cpuMulProductsMirror :: Vec 4 (Signed 34),
    systemBus :: BusState,
    cpuBusRequest :: Maybe BusRequest,
    cpuBusResponse :: Maybe BusResponse,
    rxHolding :: Maybe Byte,
    -- | BOOTCAUSE: why the CPU last reset into the boot ROM.
    bootCause :: Unsigned 2,
    cpuDevices :: Devices,
    -- | mie & mip is nonzero: WFI may finish.
    cpuWake :: Bool,
    -- | Zero all registers on the next cycle.  Commands and resets set this
    -- rather than clearing the 1024 register bits directly, so the clear is
    -- driven straight from one flip-flop.
    clearRegisters :: Bool
  }
  deriving (Generic, NFDataX)

-- | BRAM read address, optional BRAM write, and an optional UART TX byte.
type StepOutput = (MemAddr, Maybe (MemAddr, Word32), Maybe Byte)

-- | A register-file write requested by the instruction being executed.
type RegisterWrite = Maybe (Index 32, Word32)

-- UART -----------------------------------------------------------------------

-- 100 MHz / 115200 is 868 clocks per bit (0.007% baud-rate error).  At any
-- other clock f the UART runs at f / 868 baud.
type BaudCounter = Unsigned 10

data RxState
  = RxIdle
  | RxStart BaudCounter
  | RxData (Index 8) BaudCounter Byte
  | RxStop BaudCounter Byte
  deriving (Generic, NFDataX)

data TxState
  = TxIdle
  | TxStart BaudCounter Byte
  | TxData (Index 8) BaudCounter Byte
  | TxStop BaudCounter
  deriving (Generic, NFDataX)

-- I/O complex ---------------------------------------------------------------------

-- | A small FIFO in registers. Inputs: flush, push, pop (pop only when the
-- head is present); outputs: the head and the count. A push to a full FIFO
-- is dropped.
data Fifo n = Fifo {fifoData :: Vec n Byte, fifoRead :: Index n, fifoWrite :: Index n, fifoCount :: Index (n + 1)}
  deriving (Generic, NFDataX, Show, Eq)

-- | The SPI DMA engine: moves bytes between the SPI master and RAM through
-- the RAM's second port while the CPU runs.
data DmaPhase = DmaIdle | DmaToken | DmaReceive | DmaFetch | DmaFetchWait | DmaCapture | DmaSend
  deriving (Generic, NFDataX, Show, Eq)

data Dma = Dma
  { dmaPhase :: DmaPhase,
    dmaAddress :: Word32,
    dmaCount :: Unsigned 16,
    -- | The word being assembled (receive) or sent (send), little-endian.
    dmaWord :: Word32,
    dmaLane :: Unsigned 2,
    -- | A byte this engine started is still shifting.
    dmaInFlight :: Bool,
    -- | 0xff bytes still allowed before the start token.
    dmaPatience :: Unsigned 20,
    dmaToken :: Byte,
    dmaError :: Bool,
    -- | This cycle's command to the RAM's second port (registered).
    dmaRam :: Maybe (MemAddr, Maybe Word32)
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | Devices outside the CPU. A request is taken once (while no answer is
-- pending) and answered from a register the next cycle, so the CPU's bus
-- and the devices meet only at flip-flops.
data Io = Io {ioSpi :: Spi, ioDma :: Dma, ioAnswered :: Maybe Word32}
  deriving (Generic, NFDataX, Show, Eq)

-- | One cycle with a given CPU step: the circuit passes 'pipelinedCpuStep'
-- itself, so the phases it never uses are not part of it.
type CpuStep = (Word32 -> MemoryTarget) -> Machine -> Word32 -> Maybe Byte -> Bool -> Bool -> (Machine, RegisterWrite, StepOutput)

-- | A 'CpuStep' that also reports the stage payload group and its load
-- conditions, so a circuit can register each stage under its own enable.
type CpuStepStages = (Word32 -> MemoryTarget) -> Machine -> Word32 -> Maybe Byte -> Bool -> Bool -> (Machine, RegisterWrite, StepOutput, StagePayloads, StageLoad)

-- | The state that keeps running while an external memory holds the core.
data HeldState = HeldState
  { heldCycle :: Counter64,
    heldMtime :: Counter64,
    heldRx :: Maybe Byte
  }
  deriving (Generic, NFDataX)

-- Pipeline -------------------------------------------------------------------

-- | A fetched instruction and its pc, with which source registers it reads
-- (decoded as it arrives, so decode's hazard check is only compares).
data Fetched = Fetched
  { fPc :: Word32,
    fWord :: Word32,
    fUsesRs1 :: Bool,
    fUsesRs2 :: Bool,
    -- | The pc fetched after it (the branch target buffer's prediction).
    fPredicted :: Word32,
    fRaw :: Word32,
    fSize :: Unsigned 3
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | Decode/register read to the first execute stage: operands (forwarded),
-- the immediate and the decoded control.
data ExecuteOne = ExecuteOne
  { e1Pc :: Word32,
    e1Predicted :: Word32,
    e1Word :: Word32,
    e1Raw :: Word32,
    e1Size :: Unsigned 3,
    e1Control :: ExecuteControl,
    e1A :: Word32,
    e1B :: Word32,
    e1Imm :: Word32,
    e1Op2 :: Word32,
    e1Rd :: Index 32,
    e1Writes :: Bool,
    -- | The pc is outside the ROM and RAM: the word is not an instruction.
    e1FetchFault :: Bool,
    e1FaultValue :: Word32
  }
  deriving (Generic, NFDataX)

-- | The first execute stage's registered adders, comparisons and ALU
-- candidates (as in Execute), for the second to select from.
data ExecuteTwo = ExecuteTwo
  { e2Pc :: Word32,
    e2Predicted :: Word32,
    e2Control :: ExecuteControl,
    e2Computed :: Computed,
    e2Candidates :: Vec 8 Word32,
    e2AluCompare :: CompareResults,
    e2BranchCompare :: CompareResults,
    e2B :: Word32,
    e2Op2 :: Word32,
    e2Imm :: Word32,
    e2A :: Word32,
    e2Word :: Word32,
    e2Raw :: Word32,
    e2Rd :: Index 32,
    e2Writes :: Bool,
    e2FetchFault :: Bool,
    e2FaultValue :: Word32,
    -- | Its result is selected here (an ALU result other than a shift or a
    -- multiply, LUI, AUIPC, or a jump's link), so decode may take it.
    e2Forwards :: Bool,
    -- | E2's outcome, decided at the E1->E2 edge and registered here. The
    -- E2->M transition and decode's hazard check read these flip-flops
    -- instead of recomputing the exception/action priority encoder from
    -- E2's payload, keeping that encoder off the hazard critical path.
    e2Action :: Action,
    e2LoadFast :: Bool,
    e2StoreFast :: Bool,
    e2StoreWordFast :: Bool,
    e2ShiftFast :: Bool,
    e2MultFast :: Bool,
    e2WaitFast :: Unsigned 2,
    e2Slot :: Bool,
    e2Straddle :: Bool,
    e2Refetch :: Bool,
    e2PredictedTaken :: Bool
  }
  deriving (Generic, NFDataX)

-- | The commit stage: an instruction here is the oldest in the pipeline.
-- It writes RAM and the register file, or (slow) hands over to the phases.
data MemoryStage = MemoryStage
  { mPc :: Word32,
    -- | The pc after it: pc + 4 or the taken target.
    mNext :: Word32,
    mValue :: Word32,
    mRd :: Index 32,
    mWrites :: Bool,
    -- | mValue is the result (not a load, nor a shift still to finish), so
    -- a later instruction may take it.
    mFinal :: Bool,
    mLoad :: Bool,
    mStore :: Bool,
    -- | A word store: writes without reading.
    mStoreWord :: Bool,
    mFunct3 :: BitVector 3,
    mOffset :: Unsigned 2,
    mIndex :: MemAddr,
    mData :: Word32,
    mMask :: Word32,
    mShift :: Bool,
    mArith :: Bool,
    mAmount :: Word32,
    -- | A multiply: mA x mB, formed by the free-running DSP registers
    -- (see 'cpuMulProducts') and summed at commit.
    mMultiply :: Bool,
    -- | Cycles until the word read for a load or a sub-word store is on
    -- the memory bus.
    mWait :: Unsigned 2,
    -- | What the commit stage does besides committing a result.
    mAction :: Action,
    -- (for the actions: the instruction, its operands and its address)
    mWord :: Word32,
    mA :: Word32,
    mB :: Word32,
    mAddress :: Word32
  }
  deriving (Generic, NFDataX)

-- | A commit-stage action. Plain instructions commit in the pipeline, as
-- does FENCE.I (which then refetches); the rest flush it and run in the
-- phases from the commit stage's registers, in the order the phases check
-- them.
data Action
  = Plain
  | -- | an exception: mcause and mtval
    Raise Word32 Word32
  | CsrAccess
  | Mret
  | Wfi
  | FenceI
  | Divide
  | -- | a load or store outside RAM
    Bus
  deriving (Generic, NFDataX, Show, Eq)

-- | A branch target buffer entry: a taken branch or jump in the tagged
-- 32-bit word went to the target last time. bSlot records whether the
-- control instruction ends at the word's low halfword (False) or high
-- halfword (True). The tag is pc bits 12..5 only: an alias costs a
-- redirect, never correctness (execute checks every prediction).
data BtbEntry = BtbEntry {bValid :: Bool, bSlot :: Bool, bTag :: Unsigned 8, bTarget :: Word32}
  deriving (Generic, NFDataX, Show, Eq)

data Pipe = Pipe
  { -- | The next pc to fetch.
    pFetchPc :: Word32,
    -- | C-mode byte PC within the fetched-word FIFO.
    pInstructionPc :: Word32,
    -- | Reads in flight, newest first; one of these words is on the memory
    -- bus this cycle, 'inflightArrival' entries back.
    -- (each with the pc predicted to follow it)
    pInflight :: Vec 4 (Maybe (Word32, Word32)),
    -- | Fetched words waiting for decode: a ring, read at pQueueRead and
    -- written at pQueueWrite (each modulo 4; the difference is the count).
    pQueue :: Vec 4 Fetched,
    pQueueRead :: Unsigned 3,
    pQueueWrite :: Unsigned 3,
    -- | Words queued or in flight, kept as a register so fetch decides
    -- from it directly.
    pOutstanding :: Unsigned 3,
    -- | Raw aligned instruction. Assembly of a cross-word instruction
    -- ends here, before RV32C expansion. fWord/fRaw both hold the original
    -- bits; fSize and fPc preserve precise compressed traps and links.
    pA :: Maybe Fetched,
    -- | Expanded instructions and source-use bits, in a two-entry FIFO.
    -- A's readiness reads only its registered count; D's hazard/backpressure
    -- cannot feed back into the wide A/F payload enables. The registered
    -- head drives RF addresses and enters D on the same edge.
    pFQueue :: Vec 2 Fetched,
    pFRead :: Index 2,
    pFWrite :: Index 2,
    pFCount :: Unsigned 2,
    pDSlot :: Slot Fetched,
    -- | Decode's operands: on its first cycle (pDFresh) they come from the
    -- register file, read the cycle before at the entering word's sources;
    -- while it waits, from here, refreshed by forwarding.
    pDOperands :: (Word32, Word32),
    pDFresh :: Bool,
    -- | D's hazard against these registered producer stages, calculated
    -- from their next state on the preceding edge. Comparisons terminate
    -- here rather than driving the wide D payload enable in the same cycle.
    pDBlocked :: Bool,
    -- D, E1, E2 and M keep their validity token apart from their payload
    -- (see 'Slot'): cancellation (handover, FENCE.I, a redirect) clears the
    -- token only, and each payload is loaded under a local stage enable.
    pE1Slot :: Slot ExecuteOne,
    pE2Slot :: Slot ExecuteTwo,
    pMSlot :: Slot MemoryStage,
    -- | A taken branch or jump left the second execute stage last cycle:
    -- this cycle the younger stages are flushed and its target fetched.
    pRedirect :: Maybe Word32,
    -- | Eight entries, indexed by pc bits 4..2: fetch follows a hit's
    -- target; the second execute stage corrects a wrong guess.
    pBtb :: Vec 8 BtbEntry
  }
  deriving (Generic, NFDataX)

-- | A pipeline stage register split into a one-bit validity token and its
-- payload. Only 'slotValid' depends on cancellation (handover, FENCE.I,
-- redirects, resets); 'slotPayload' is loaded by the stage's own advance
-- decision, which reads registered stage state only. A Maybe-typed stage
-- made every payload bit's next-state mux depend on the whole-pipeline
-- cancellation logic (the 2026-10-28 reports trace pM.mAction and
-- cpuInterruptDue through 400-550-load selects into pD/E2 payload and the
-- DSP operand registers). A payload of an invalid slot is a don't-care and is
-- never observed: everything reads stages through 'pD', 'pE1', 'pE2', 'pM'.
data Slot a = Slot {slotValid :: Bool, slotPayload :: a}
  deriving (Generic, NFDataX)

-- | One payload per pipeline stage.
data StagePayloads = StagePayloads
  { spD :: Fetched,
    spE1 :: ExecuteOne,
    spE2 :: ExecuteTwo,
    spM :: MemoryStage
  }
  deriving (Generic, NFDataX)

-- | When each stage's payload register loads.
data StageLoad = StageLoad
  { slD :: Bool,
    slE1 :: Bool,
    slE2 :: Bool,
    slM :: Bool
  }
  deriving (Generic, NFDataX)
