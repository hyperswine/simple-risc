{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Replace case with maybe" #-}

-- | A small RV32IM computer with an optional compressed frontend. Board
-- images use the pipeline; the multi-cycle reference remains for testing.
--
-- Memory map:
--
--   * 0x0000_0000 - 0x0000_07ff: 2 KiB boot ROM (the reset vector)
--   * 0x0010_0000: finisher (QEMU virt style: 0x5555 = exit 0,
--     code << 16 | 0x3333 = exit code)
--   * 0x0010_0004: BOOTCAUSE, read-only; a read clears it (0 none, 1 power-on,
--     2 Ctrl-C, 3 finisher exit)
--   * 0x0200_0000: CLINT (QEMU virt layout): msip +0x0, mtimecmp +0x4000/4,
--     mtime +0xbff8/c; mtime counts core clocks
--   * 0x0c00_0000: PLIC (QEMU virt layout, one source: the UART, IRQ 10):
--     priority +0x28, pending +0x1000, enable +0x2000, threshold +0x20_0000,
--     claim/complete +0x20_0004
--   * 0x1000_0000: UART TXDATA (write the low byte)
--   * 0x1000_0004: UART STATUS (bit 0 = TX ready, bit 1 = RX byte ready)
--   * 0x1000_0008: UART RXDATA (read low byte, consuming it)
--   * 0x1000_000c: UART CTRL (bit 0 = interrupt while a byte is waiting,
--     bit 1 = interrupt while the transmitter is ready)
--   * 0x1000_1000-0x1000_1fff: the I/O complex, outside the CPU (word
--     accesses only, one handshake per access):
--     - 0x1000_1000 SPI DATA (write: send the low byte while receiving one;
--       read: the last byte received)
--     - 0x1000_1004 SPI STATUS (bit 0 = a transfer is in progress)
--     - 0x1000_1008 SPI CTRL (bit 0 = chip select asserted; bits 8-15 = half
--       an SCK period in clocks, minus one)
--     - 0x1000_1100 DMA ADDR (RAM byte address, word aligned)
--     - 0x1000_1104 DMA COUNT (bytes, a multiple of 4; reads what is left)
--     - 0x1000_1108 DMA CTRL (write starts: bit 0 = send RAM to SPI, else
--       receive SPI to RAM; bit 1 = before receiving, clock 0xff until a
--       start token, which must be 0xfe)
--     - 0x1000_110c DMA STATUS (bit 0 busy, bit 1 error, bits 8-15 token)
--   * 0x8000_0000 - 0x8000_ffff: 64 KiB RAM
--
-- Everything else raises an access fault.  The physical UART is 8-N-1 at
-- clock / 868 baud: 115200 at 100 MHz.
--
-- The CPU is only a CPU: it runs from reset at address 0, in the boot ROM
-- (boards/tangnano20k/bootrom), which implements the host protocol in
-- software -- 'P' to load words at 0x8000_0000, 'R' to run them, 'M' to clear
-- RAM -- and sends "DONE" when a program ends.  A program ends by writing the
-- finisher, which resets the CPU into the ROM with cause EXIT, or by taking a
-- trap while mtvec is 0, which lands in the ROM directly.  While a program
-- runs, received byte 0x03 (Ctrl-C) never reaches it: it resets the CPU into
-- the ROM with cause BREAK.  In the ROM 0x03 is an ordinary byte, so images
-- containing it load intact.  Resets keep RAM.
--
-- ECALL, EBREAK, illegal instructions, misaligned and faulting accesses enter
-- the machine trap handler.  CSR instructions and MRET support direct-mode
-- handlers and split 64-bit cycle/retirement counters.  Machine software
-- (msip), timer (CLINT) and external (PLIC) interrupts are taken between
-- instructions, in that priority order external > software > timer, and WFI
-- waits for one.
--
-- The M extension (MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU) runs on an
-- iterative unit: 68 unit cycles per nonzero-divisor instruction, with each
-- 33-bit add/subtract followed by a separate registered commit.  Division by zero and overflow give the results the RISC-V spec
-- requires.
module SimpleRisc (module SimpleRisc, module SimpleRisc.Types, module SimpleRisc.Uart, module SimpleRisc.Decode) where

import Clash.Prelude
import Data.Maybe (fromMaybe, isJust, isNothing)
import Language.Haskell.TH.Syntax (addDependentFile, runIO)
import qualified RiscVCompressed as C
import qualified Prelude as P
import SimpleRisc.Types
import SimpleRisc.Uart
import SimpleRisc.Decode

-- | The boot ROM image, embedded at compile time from the output of
-- boards/tangnano20k/bootrom/build.sh.
bootRomContents :: Vec 512 Word32
bootRomContents =
  $( do
       let path = "boards/tangnano20k/bootrom/bootrom.hex"
       addDependentFile path
       text <- runIO (P.readFile path)
       let romWords = P.map (\line -> P.read ("0x" P.++ line) :: P.Integer) (P.lines text)
       if P.length romWords P./= 512
         then P.fail (path P.++ ": expected 512 words")
         else listToVecTH (P.map P.fromInteger romWords :: [Unsigned 32])
   )

-- | BOOTCAUSE values: why the CPU last reset into the boot ROM.
causeNone, causePowerOn, causeBreak, causeExit :: Unsigned 2
causeNone = 0
causePowerOn = 1
causeBreak = 2
causeExit = 3

initialTrapRegisters :: TrapRegisters
initialTrapRegisters = TrapRegisters 0 0 0 0 False False

initialCounter :: Counter64
initialCounter = Counter64 0 0 False

-- Explicit writes suppress the increment and change only the selected half.
-- A low-half write still drains an overflow from the preceding clock; a
-- high-half write replaces that high half, including any preceding carry.
tickCounter :: Bool -> Maybe (Bool, Word32) -> Counter64 -> Counter64
tickCounter increment write counter =
  let lo = counterLo counter
      hi = counterHi counter
      carriedHi = if counterCarry counter then hi + 1 else hi
   in case write of
        Just (False, value) -> Counter64 value carriedHi False
        Just (True, value) -> Counter64 lo value False
        Nothing -> Counter64 (if increment then lo + 1 else lo) carriedHi (increment && lo == maxBound)

-- | Deselected, idle, and slow enough (about 190 kHz at 96 MHz) for a card's
-- identification phase.
initialSpi :: Spi
initialSpi = Spi False 255 0 0 False 0xff 0xff high

spiBusy :: Spi -> Bool
spiBusy spi = spiBits spi /= 0 || spiSck spi

-- | (SCK, MOSI, chip select active low).
spiPins :: Spi -> (Bit, Bit, Bit)
spiPins spi = (boolToBit (spiSck spi), msb (spiOut spi), boolToBit (not (spiSelect spi)))

-- | One clock of the SPI master; @start@ is a byte written to DATA.
stepSpi :: Maybe Byte -> Maybe Word32 -> Spi -> Spi
stepSpi start control spi
  | Just c <- control, not (spiBusy spi) = spi {spiSelect = testBit c 0, spiDivider = resize (c `shiftR` 8)}
  | Just byte <- start, not (spiBusy spi) = spi {spiOut = byte, spiBits = 8, spiCount = spiDivider spi, spiSck = False}
  | not (spiBusy spi) = spi
  | spiCount spi /= 0 = spi {spiCount = spiCount spi - 1}
  | not (spiSck spi) = spi {spiSck = True, spiCount = spiDivider spi, spiBits = spiBits spi - 1, spiIn = (spiIn spi `shiftL` 1) .|. (if spiMiso spi == high then 1 else 0)}
  | otherwise = spi {spiSck = False, spiCount = spiDivider spi, spiOut = (spiOut spi `shiftL` 1) .|. 1}

initialDevices :: Devices
initialDevices =
  Devices
    False
    maxBound
    maxBound
    initialCounter
    False
    False
    False
    False
    0
    False
    0
    False
    False
    False
    False
    False
    Nothing

-- | The PLIC would grant a claim now.
plicClaimable :: Devices -> Bool
plicClaimable devices = devPlicPending devices && devPlicEnable devices && devPlicPriority devices > devPlicThreshold devices

-- | mip as software reads it.
pendingInterrupts :: Devices -> Word32
pendingInterrupts devices = (if devMeip devices then 0x800 else 0) .|. (if devMtip devices then 0x80 else 0) .|. (if devMsip devices then 0x8 else 0)

initialBus :: BusState
initialBus = BusState BusIdle (BusRequest 0 0 False 0) UnmappedTarget 0 0

-- Response and effects are pulses. A stalled TX emits neither; a completed
-- transfer emits exactly one response and, where appropriate, one side effect.
busStep :: BusState -> Maybe BusRequest -> Word32 -> Bool -> Maybe Byte -> Unsigned 2 -> Devices -> (BusState, Maybe BusResponse, StepOutput, BusEffect)
busStep = busStepWith decodeMemoryTarget

busStepWith :: (Word32 -> MemoryTarget) -> BusState -> Maybe BusRequest -> Word32 -> Bool -> Maybe Byte -> Unsigned 2 -> Devices -> (BusState, Maybe BusResponse, StepOutput, BusEffect)
busStepWith decodeTarget state request memoryWord txReady rx bootCause devices =
  let q = busRequest state
      width = busWidth q
      address = busAddress q
      advance phase = (state {busPhase = phase}, Nothing, (0, Nothing, Nothing), NoEffect)
      respond value fault exiting effect = (state {busPhase = BusIdle}, Just (BusResponse value fault exiting), (0, Nothing, Nothing), effect)
      valid = (if busWrite q then validStore width else validLoad width) && not (misalignedMemory width address)
   in case busPhase state of
        BusIdle -> case request of
          Nothing -> advance BusIdle
          Just new -> (state {busPhase = BusDecode, busRequest = new}, Nothing, (0, Nothing, Nothing), NoEffect)
        BusDecode -> (state {busPhase = BusDispatch, busTarget = decodeTarget address}, Nothing, (0, Nothing, Nothing), NoEffect)
        BusDispatch
          | not valid -> respond 0 True False NoEffect
          | otherwise -> case busTarget state of
              RamTarget
                | not (busWrite q) -> advance BusLoadIssue
                | width == 2 -> (state {busPhase = BusRamWrite, busValue = busData q}, Nothing, (0, Nothing, Nothing), NoEffect)
                | otherwise -> advance BusStoreIssue
              RomTarget
                | busWrite q -> respond 0 True False NoEffect
                | otherwise -> advance BusLoadIssue
              UartTxTarget
                | busWrite q -> advance BusTx
                | otherwise -> respond 0 False False NoEffect
              UartStatusTarget
                | busWrite q -> respond 0 True False NoEffect
                | otherwise -> respond (loadValue width 0 ((if txReady then 1 else 0) .|. (case rx of Nothing -> 0; Just _ -> 2))) False False NoEffect
              UartRxTarget
                | busWrite q -> respond 0 True False NoEffect
                | otherwise -> respond (loadValue width 0 (maybe 0 resize rx)) False False (case rx of Nothing -> NoEffect; Just _ -> ConsumeRx)
              ExitTarget
                | width == 0 || width == 4 -> respond 0 True False NoEffect
                | not (busWrite q) -> respond 0 False False NoEffect
                | otherwise -> let status = busData q .&. 0xffff in respond 0 False (status == 0x5555 || status == 0x3333) NoEffect
              BootCauseTarget
                | busWrite q -> respond 0 True False NoEffect
                | otherwise -> respond (loadValue width 0 (resize bootCause)) False False ConsumeBootCause
              UnmappedTarget -> respond 0 True False NoEffect
              -- The I/O complex: word accesses, answered by a handshake.
              IoTarget
                | width /= 2 -> respond 0 True False NoEffect
                | otherwise -> advance BusIo
              -- CLINT, PLIC and UART control registers are word-only.
              target
                | width /= 2 -> respond 0 True False NoEffect
                | busWrite q -> respond 0 False False (deviceWrite target (busData q))
                | target == PlicClaimTarget -> if plicClaimable devices then respond uartIrq False False ClaimInterrupt else respond 0 False False NoEffect
                | otherwise -> respond (deviceRead target devices) False False NoEffect
        BusLoadIssue -> (state {busPhase = BusLoadDelay}, Nothing, (memoryIndex address, Nothing, Nothing), NoEffect)
        BusLoadDelay -> advance BusLoadCapture
        BusLoadCapture -> advance BusLoadWait
        BusLoadWait -> (state {busPhase = BusLoadAlign, busWord = memoryWord}, Nothing, (0, Nothing, Nothing), NoEffect)
        BusLoadAlign -> (state {busPhase = BusReply, busValue = loadValue width (resize address) (busWord state)}, Nothing, (0, Nothing, Nothing), NoEffect)
        BusReply -> respond (busValue state) False False NoEffect
        BusStoreIssue -> (state {busPhase = BusStoreDelay}, Nothing, (memoryIndex address, Nothing, Nothing), NoEffect)
        BusStoreDelay -> advance BusStoreCapture
        BusStoreCapture -> advance BusStoreWait
        BusStoreWait -> (state {busPhase = BusStoreMerge, busWord = memoryWord}, Nothing, (0, Nothing, Nothing), NoEffect)
        BusStoreMerge -> (state {busPhase = BusRamWrite, busValue = storeValue width (resize address) (busData q) (busWord state)}, Nothing, (0, Nothing, Nothing), NoEffect)
        BusRamWrite -> (state {busPhase = BusIdle}, Just (BusResponse 0 False False), (0, Just (memoryIndex address, busValue state), Nothing), NoEffect)
        BusTx
          | txReady -> (state {busPhase = BusIdle}, Just (BusResponse 0 False False), (0, Nothing, Just (resize (busData q))), NoEffect)
          | otherwise -> advance BusTx
        BusIo -> case devIo devices of
          Just value -> respond (if busWrite q then 0 else value) False False NoEffect
          Nothing -> advance BusIo

-- | A device register's value; only for the CLINT/PLIC/UART-control targets.
deviceRead :: MemoryTarget -> Devices -> Word32
deviceRead target devices = case target of
  ClintMsipTarget -> boolWord (devMsip devices)
  ClintCompareLoTarget -> devMtimecmpLo devices
  ClintCompareHiTarget -> devMtimecmpHi devices
  ClintTimeLoTarget -> counterLo (devMtime devices)
  ClintTimeHiTarget -> counterHi (devMtime devices)
  PlicPriorityTarget -> resize (devPlicPriority devices)
  PlicPendingTarget -> if devPlicPending devices then 1 `shiftL` 10 else 0
  PlicEnableTarget -> if devPlicEnable devices then 1 `shiftL` 10 else 0
  PlicThresholdTarget -> resize (devPlicThreshold devices)
  UartControlTarget -> (if devUartRxInterrupt devices then 1 else 0) .|. (if devUartTxInterrupt devices then 2 else 0)
  _ -> 0

-- | Writes to read-only device registers (PLIC pending) are ignored.
deviceWrite :: MemoryTarget -> Word32 -> BusEffect
deviceWrite PlicPendingTarget _ = NoEffect
deviceWrite target value = DeviceWrite target value

-- | One clock of the interrupt sources. @rxWaiting@ and @txReady@ are the
-- UART's levels; @effect@ is this clock's completed bus access.
stepDevices :: Bool -> Bool -> BusEffect -> Devices -> Devices
stepDevices rxWaiting txReady effect devices =
  let Devices {..} = devices
      write target = case effect of
        DeviceWrite t value | t == target -> Just value
        _ -> Nothing
      timeWrite = case effect of
        DeviceWrite ClintTimeLoTarget value -> Just (False, value)
        DeviceWrite ClintTimeHiTarget value -> Just (True, value)
        _ -> Nothing
      claimed = effect == ClaimInterrupt
      completed = write PlicClaimTarget == Just uartIrq
      level = (devUartRxInterrupt && rxWaiting) || (devUartTxInterrupt && txReady)
      timeLo = counterLo devMtime
      timeHi = counterHi devMtime
   in devices
        { devMsip = maybe devMsip (`testBit` 0) (write ClintMsipTarget),
          devMtimecmpLo = maybe devMtimecmpLo P.id (write ClintCompareLoTarget),
          devMtimecmpHi = maybe devMtimecmpHi P.id (write ClintCompareHiTarget),
          devMtime = tickCounter True timeWrite devMtime,
          devHiAbove = timeHi > devMtimecmpHi,
          devHiEqual = timeHi == devMtimecmpHi,
          devLoAtLeast = timeLo >= devMtimecmpLo,
          devMtip = devHiAbove || (devHiEqual && devLoAtLeast),
          devPlicPriority = maybe devPlicPriority resize (write PlicPriorityTarget),
          devPlicEnable = maybe devPlicEnable (`testBit` 10) (write PlicEnableTarget),
          devPlicThreshold = maybe devPlicThreshold resize (write PlicThresholdTarget),
          devPlicPending = (devPlicPending || (level && not devPlicClaimed)) && not claimed,
          devPlicClaimed = (devPlicClaimed || claimed) && not completed,
          devMeip = plicClaimable devices,
          devUartRxInterrupt = maybe devUartRxInterrupt (`testBit` 0) (write UartControlTarget),
          devUartTxInterrupt = maybe devUartTxInterrupt (`testBit` 1) (write UartControlTarget),
          devIo = Nothing
        }

-- | The interrupt to take, highest priority first (external, software,
-- timer), if any is pending, enabled in mie and MIE is set.
interruptCause :: Machine -> Maybe Word32
interruptCause machine
  | not (trapMie (cpuTrapRegisters machine)) = Nothing
  | testBit ready 11 = Just 0x8000_000b
  | testBit ready 3 = Just 0x8000_0003
  | testBit ready 7 = Just 0x8000_0007
  | otherwise = Nothing
  where
    ready = cpuInterruptEnable machine .&. pendingInterrupts (cpuDevices machine)

initialExecuteControl :: ExecuteControl
initialExecuteControl = ExecuteControl 0 False False False False False False False False False False False KindInvalid

initialCompareResults :: CompareResults
initialCompareResults = CompareResults False False False False False

initialMachine :: Machine
initialMachine =
  Machine
    { cpuRegs = repeat 0,
      cpuRegValid = 0,
      cpuRfA = 0,
      cpuRfB = 0,
      cpuPendingWrite = Nothing,
      cpuPc = 0,
      cpuPhase = Fetch,
      cpuInstruction = 0,
      cpuCompressed = False,
      cpuInstructionRaw = 0,
      cpuInstructionSize = 4,
      cpuFetchHalf = 0,
      cpuFetchFault = False,
      cpuLocalMemory = True,
      cpuExternalMemory = False,
      cpuPortAddressFull = 0,
      cpuPortWriteAddressFull = 0,
      cpuPortByteEnable = 0xf,
      cpuPipelined = False,
      cpuFast = False,
      cpuPipe = emptyPipe,
      cpuInterruptDue = Nothing,
      cpuReadIndices = (0, 0),
      cpuFastMemory = False,
      cpuPortIndex = 0,
      cpuStoreData = 0,
      cpuStoreMask = 0,
      cpuStoreNow = False,
      cpuPrefetchAddress = 0,
      cpuPrefetchWord = 0,
      cpuPrefetchValid = False,
      cpuPrefetchCount = 0,
      cpuTargetAddress = 0,
      cpuTargetWord = 0,
      cpuTargetValid = False,
      cpuTargetCount = 0,
      cpuFetchSource = FromMemory,
      cpuStoreHitsPrefetch = False,
      cpuStoreHitsTarget = False,
      cpuNextInstruction = 0,
      cpuNextValid = False,
      cpuAhead = False,
      cpuPrefetchIssue = False,
      cpuInRom = True,
      cpuRegA = 0,
      cpuRegB = 0,
      cpuA = 0,
      cpuB = 0,
      cpuImm = 0,
      cpuIsRegOp = False,
      cpuOp2 = 0,
      cpuExecuteControl = initialExecuteControl,
      cpuAluCandidates = repeat 0,
      cpuAluCompare = initialCompareResults,
      cpuBranchCompare = initialCompareResults,
      cpuComputed = Computed Nothing 0 0 Nothing 0,
      cpuTrapRegisters = initialTrapRegisters,
      cpuExceptionCause = 0,
      cpuExceptionValue = 0,
      cpuScratch = 0,
      cpuInterruptEnable = 0,
      cpuCsrSelection = repeat False,
      cpuCsrWrite = False,
      cpuCsrReadOnly = False,
      cpuCsrValue = 0,
      cpuCsrSource = 0,
      cpuCycle = initialCounter,
      cpuInstret = initialCounter,
      cpuCountRetirement = False,
      cpuCounterWrite = Nothing,
      cpuMulDiv = MulDivUnit MdPrepare 0 0 0 0 False False False False,
      cpuMulProducts = repeat 0,
      cpuMulOperandsMirror = (0, 0, 0),
      cpuMulProductsMirror = repeat 0,
      systemBus = initialBus,
      cpuBusRequest = Nothing,
      cpuBusResponse = Nothing,
      rxHolding = Nothing,
      bootCause = causePowerOn,
      cpuDevices = initialDevices,
      cpuWake = False,
      clearRegisters = False
    }

{-# ANN
  topEntity
  ( Synthesize
      { t_name = "simple_risc",
        t_inputs = [PortName "clk", PortName "reset", PortName "enable", PortName "uart_rx", PortName "sd_miso"],
        t_output = PortProduct "" [PortName "uart_tx", PortName "sd_sck", PortName "sd_mosi", PortName "sd_cs"]
      }
  )
  #-}

-- XilinxSystem is System with a synchronous reset.  Gowin flip-flops have a
-- synchronous-reset pin, and it keeps nextpnr from timing paths through
-- every flip-flop's asynchronous clear.
topEntity ::
  "CLK" ::: Clock XilinxSystem ->
  "RESET" ::: Reset XilinxSystem ->
  "ENABLE" ::: Enable XilinxSystem ->
  "UART_RX" ::: Signal XilinxSystem Bit ->
  "SD_MISO" ::: Signal XilinxSystem Bit ->
  Signal XilinxSystem (Bit, Bit, Bit, Bit)
topEntity clk rst en serialRx sdMiso = withClockResetEnable clk rst en (simpleRiscSd serialRx sdMiso)

-- | The core without the SD slot (tests and the iverilog testbenches).
simpleRisc :: forall dom. (HiddenClockResetEnable dom) => Signal dom Bit -> Signal dom Bit
simpleRisc serialRx = (\(tx, _, _, _) -> tx) <$> simpleRiscSd serialRx (pure high)

-- | The core with the SPI master's pins: (UART TX, SCK, MOSI, CS active low).
simpleRiscSd :: forall dom. (HiddenClockResetEnable dom) => Signal dom Bit -> Signal dom Bit -> Signal dom (Bit, Bit, Bit, Bit)
simpleRiscSd serialRx sdMiso = bundle (serialTx, sck, mosi, cs)
  where
    -- Two flip-flops resynchronise the asynchronous RX pin before sampling, and
    -- the received byte is registered before it reaches the CPU: a Ctrl-C
    -- resets the whole CPU, so that compare fans out to every state bit.
    receivedNow = uartRx (register high (register high serialRx))
    emergencyReset = register False ((== Just 0x03) <$> receivedNow)
    -- Receive FIFO between the UART and the CPU's one-byte holding
    -- register: a byte is offered only while the holding register is empty
    -- and no offer is in flight. A Ctrl-C that breaks a program discards
    -- everything unread, as the reset itself does to the holding register.
    breaking = breakRequested <$> runningState <*> emergencyReset
    rxWanted =
      (\m offered headByte -> isNothing (rxHolding m) && isNothing offered && isJust headByte)
        <$> runningState
        <*> received
        <*> rxHead
    rxPop = (&&) <$> rxWanted <*> (not <$> breaking)
    received = register Nothing (mux rxPop rxHead (pure Nothing))
    (rxHead, _rxCount) = unbundle (mealy fifoStep (initialFifo :: Fifo 32) (bundle (breaking, receivedNow, rxPop)))
    -- Transmit FIFO: a TX store completes as soon as there is room, and the
    -- transmitter drains the FIFO by itself. The push is registered, so
    -- "ready" keeps one slot in reserve for a byte still on its way in.
    (serialTx, uartReady) = uartTx txOffer
    txPush = register Nothing txRequestNow
    txPop = (\ready headByte -> ready && isJust headByte) <$> uartReady <*> txHead
    txOffer = mux txPop txHead (pure Nothing)
    (txHead, txCount) = unbundle (mealy fifoStep (initialFifo :: Fifo 16) (bundle (pure False, txPush, txPop)))
    txReady = register False ((< 15) <$> txCount)

    machineInput = bundle (memoryOut, received, txReady, emergencyReset)
    -- MISO is asynchronous: two flip-flops, then into the I/O complex.
    miso = register high (register high sdMiso)
    machineState = register boardMachine ((\(m, _, _, _) -> m) <$> stepped)
    -- One clock-enabled register per pipeline stage (see 'StageLoad'): each
    -- loads only when its own stage advances, so the machine register no
    -- longer carries the payloads or their advance decision.
    stageRegisters = StagePayloads <$> stageD <*> stageE1 <*> stageE2 <*> stageM
    stageD = regEn (spD initialStagePayloads) ((\(_, _, _, l) -> slD l) <$> stepped) ((\(_, _, ps, _) -> spD ps) <$> stepped)
    stageE1 = regEn (spE1 initialStagePayloads) ((\(_, _, _, l) -> slE1 l) <$> stepped) ((\(_, _, ps, _) -> spE1 ps) <$> stepped)
    stageE2 = regEn (spE2 initialStagePayloads) ((\(_, _, _, l) -> slE2 l) <$> stepped) ((\(_, _, ps, _) -> spE2 ps) <$> stepped)
    stageM = regEn (spM initialStagePayloads) ((\(_, _, _, l) -> slM l) <$> stepped) ((\(_, _, ps, _) -> spM ps) <$> stepped)
    runningState = withStagePayloads <$> stageRegisters <*> machineState
    stepped = withIo <$> runningState <*> machineInput <*> ioAnswer <*> rfA <*> rfB <*> mulProducts
    -- Free-running DSP operand and product registers (see 'cpuMulProducts').
    mulOperands = register (0, 0, 0) (multiplyOperands <$> runningState)
    mulProducts = register (repeat 0) (partialProductsOf <$> mulOperands)
    -- The register file is distributed RAM: two copies, one per read port,
    -- written together. The mirror in the machine stays constant (removed).
    withIo m input answer a b products =
      let (m', output, stages, loads) =
            machineStepCoreStagesBy
              pipelinedCpuStepStages
              decodeMemoryTarget
              m {cpuDevices = (cpuDevices m) {devIo = answer}, cpuRfA = a, cpuRfB = b, cpuMulProducts = products}
              input
       in (m' {cpuRegs = repeat 0, cpuMulOperandsMirror = (0, 0, 0), cpuMulProductsMirror = repeat 0}, output, stages, loads)
    rfWrite = (\m cancel -> if cancel then Nothing else cpuPendingWrite m) <$> runningState <*> breaking
    rfA = asyncRam (SNat @32) (fst . cpuReadIndices <$> runningState) rfWrite
    rfB = asyncRam (SNat @32) (snd . cpuReadIndices <$> runningState) rfWrite
    machineOutput = (\(_, output, _, _) -> output) <$> stepped
    -- The I/O complex sees the CPU's request as registered bus state and
    -- answers a cycle later; a system reset returns it to idle.
    (ioAnswer, ioPins, ioRam) =
      unbundle
        ( mealy
            ioStep
            initialIo
            (bundle (ioRequest <$> runningState, clearRegisters <$> runningState, miso, ramOutB))
        )
    (sck, mosi, cs) = unbundle ioPins
    (memoryAddressNow, memoryWriteNow, txRequestNow) = unbundle machineOutput
    -- Real BRAM setup time is worse than the Gowin timing model. Register all
    -- commands at its boundary; issue/delay/wait stages account for latency.
    memoryAddress = register (0 :: MemAddr) memoryAddressNow
    memoryWrite = register Nothing memoryWriteNow

    -- A synchronous 16384 x 32-bit RAM and the 512-word boot ROM, each with an
    -- output register. Reads take two cycles after the registered command;
    -- writes (RAM only: the bus refuses ROM stores) are visible on a later
    -- read. Bit 14 of the physical index selects the ROM; the select is
    -- delayed to line up with the registered outputs, so the final mux sits
    -- between flip-flops rather than after a block RAM.
    -- Port A is the CPU's; port B the I/O complex's DMA.
    (ramOutA, ramOutB) =
      trueDualPortBlockRam
        (portOp <$> memoryAddress <*> memoryWrite)
        (dmaOp <$> ioRam)
    ramIndex :: MemAddr -> Index 16384
    ramIndex a = fromIntegral (resize a :: Unsigned 14)
    portOp address write = case write of
      Just (a, v) -> RamWrite (ramIndex a) v
      Nothing -> RamRead (ramIndex address)
    dmaOp command = case command of
      Just (a, Just v) -> RamWrite (ramIndex a) v
      Just (a, Nothing) -> RamRead (ramIndex a)
      Nothing -> RamRead 0
    ramOut = register 0 ramOutA
    romOut = register 0 (rom bootRomContents (resize <$> memoryAddress :: Signal dom (Unsigned 9)))
    romSelected = register False (register False ((`testBit` 14) <$> memoryAddress))
    memoryOut = mux romSelected romOut ramOut

-- | The BRAM image's CPU: the pipeline runs ordinary instructions and the
-- phases (without their own overlaps) the rest.
boardMachine :: Machine
boardMachine = initialMachine {cpuPipelined = True, cpuLocalMemory = False, cpuCompressed = boardCompressed}

boardCompressed :: Bool
boardCompressed = False

initialFifo :: (KnownNat n, KnownNat (n + 1), 1 <= n) => Fifo n
initialFifo = Fifo (repeat 0) 0 0 0

fifoStep :: forall n. (KnownNat n, KnownNat (n + 1), 1 <= n) => Fifo n -> (Bool, Maybe Byte, Bool) -> (Fifo n, (Maybe Byte, Index (n + 1)))
fifoStep fifo (flush, push, pop) = (next, (headByte, fifoCount fifo))
  where
    headByte = if fifoCount fifo == 0 then Nothing else Just (fifoData fifo !! fifoRead fifo)
    popped = pop && isJust headByte
    full = fifoCount fifo == maxBound
    pushed = case push of Just _ -> not full || popped; Nothing -> False
    bump i = if i == maxBound then 0 else i + 1
    next
      | flush = initialFifo
      | otherwise =
          fifo
            { fifoData = case push of Just byte | pushed -> replace (fifoWrite fifo) byte (fifoData fifo); _ -> fifoData fifo,
              fifoWrite = if pushed then bump (fifoWrite fifo) else fifoWrite fifo,
              fifoRead = if popped then bump (fifoRead fifo) else fifoRead fifo,
              fifoCount = case (pushed, popped) of
                (True, False) -> fifoCount fifo + 1
                (False, True) -> fifoCount fifo - 1
                _ -> fifoCount fifo
            }

-- | The CPU's request to the I/O complex: its registered bus state while
-- the bus waits in 'BusIo'.
ioRequest :: Machine -> Maybe BusRequest
ioRequest machine = case busPhase (systemBus machine) of
  BusIo -> Just (busRequest (systemBus machine))
  _ -> Nothing

initialDma :: Dma
initialDma = Dma DmaIdle 0 0 0 0 False 0 0 False Nothing

-- | Running, or its last RAM write has not left yet.
dmaBusy :: Dma -> Bool
dmaBusy dma = dmaPhase dma /= DmaIdle || isJust (dmaRam dma)

-- | One clock of the DMA engine. @spi@ is the SPI master's state this
-- cycle and @ramWord@ the second RAM port's output. Returns the next state
-- and the byte to start shifting, if any.
stepDma :: Dma -> Spi -> Word32 -> (Dma, Maybe Byte)
stepDma dma spi ramWord = case dmaPhase dma of
  DmaIdle -> (cleared, Nothing)
  -- The read leaves the state register next cycle; the block RAM answers
  -- the cycle after.
  DmaFetch -> (cleared {dmaPhase = DmaFetchWait, dmaRam = Just (memoryIndex (dmaAddress dma), Nothing)}, Nothing)
  DmaFetchWait -> (cleared {dmaPhase = DmaCapture}, Nothing)
  DmaCapture -> (cleared {dmaPhase = DmaSend, dmaWord = ramWord, dmaLane = 0}, Nothing)
  _
    | spiBusy spi -> (cleared, Nothing)
    | not (dmaInFlight dma) -> (cleared {dmaInFlight = True}, Just outgoing)
    | otherwise -> (finished, Nothing)
  where
    cleared = dma {dmaRam = Nothing}
    outgoing = case dmaPhase dma of
      DmaSend -> resize (dmaWord dma `shiftR` (8 * fromIntegral (dmaLane dma)))
      _ -> 0xff
    byte = spiIn spi
    lastByte = dmaCount dma == 1
    afterByte = cleared {dmaInFlight = False, dmaCount = dmaCount dma - 1, dmaLane = dmaLane dma + 1}
    finished = case dmaPhase dma of
      DmaToken
        | byte == 0xff && dmaPatience dma /= 0 -> cleared {dmaInFlight = False, dmaPatience = dmaPatience dma - 1}
        | byte == 0xfe -> cleared {dmaInFlight = False, dmaToken = byte, dmaPhase = DmaReceive}
        | otherwise -> cleared {dmaInFlight = False, dmaToken = byte, dmaError = True, dmaPhase = DmaIdle}
      DmaReceive ->
        let word = (dmaWord dma .&. complement (0xff `shiftL` lane)) .|. (resize byte `shiftL` lane)
            lane = 8 * fromIntegral (dmaLane dma)
            complete = dmaLane dma == 3 || lastByte
         in afterByte
              { dmaWord = word,
                dmaRam = if complete then Just (memoryIndex (dmaAddress dma), Just word) else Nothing,
                dmaAddress = if complete then dmaAddress dma + 4 else dmaAddress dma,
                dmaPhase = if lastByte then DmaIdle else DmaReceive
              }
      _ -- DmaSend
        | lastByte -> afterByte {dmaPhase = DmaIdle}
        | dmaLane dma == 3 -> afterByte {dmaPhase = DmaFetch, dmaAddress = dmaAddress dma + 4}
        | otherwise -> afterByte

initialIo :: Io
initialIo = Io initialSpi initialDma Nothing

-- | Inputs: the CPU's request, a system reset, MISO, the second RAM port's
-- output. Outputs: the answer, the SPI pins (SCK, MOSI, CS active low) and
-- the command to the second RAM port.
ioStep :: Io -> (Maybe BusRequest, Bool, Bit, Word32) -> (Io, (Maybe Word32, (Bit, Bit, Bit), Maybe (MemAddr, Maybe Word32)))
ioStep io (request, reset, miso, ramWord) = (next, (ioAnswered io, spiPins (ioSpi io), dmaRam (ioDma io)))
  where
    spi = (ioSpi io) {spiMiso = miso}
    dma = ioDma io
    (dmaStepped, dmaByte) = stepDma dma spi ramWord
    -- A DMA is started by a CTRL write while idle; its first step is the
    -- next cycle's.
    dma' = case writing ioDmaControl of
      Just c
        | not (dmaBusy dma) ->
            dma
              { dmaPhase = if testBit c 0 then DmaFetch else if testBit c 1 then DmaToken else DmaReceive,
                dmaLane = 0,
                dmaWord = 0,
                dmaInFlight = False,
                dmaError = False,
                dmaToken = 0,
                dmaPatience = maxBound,
                dmaRam = Nothing
              }
      _
        | dmaBusy dma -> dmaStepped
        | otherwise ->
            dmaStepped
              { dmaAddress = maybe (dmaAddress dma) P.id (writing ioDmaAddress),
                dmaCount = maybe (dmaCount dma) resize (writing ioDmaCount)
              }
    taken = case ioAnswered io of Nothing -> request; Just _ -> Nothing
    offset = maybe 0 (\q -> busAddress q .&. 0xfff) taken
    writing at = case taken of
      Just q | busWrite q && offset == at -> Just (busData q)
      _ -> Nothing
    value
      | offset == ioSpiData = resize (spiIn spi)
      | offset == ioSpiStatus = boolWord (spiBusy spi)
      | offset == ioSpiControl = boolWord (spiSelect spi) .|. (resize (spiDivider spi) `shiftL` 8)
      | offset == ioDmaAddress = dmaAddress dma
      | offset == ioDmaCount = resize (dmaCount dma)
      | offset == ioDmaStatus =
          boolWord (dmaBusy dma) .|. (if dmaError dma then 2 else 0) .|. (resize (dmaToken dma) `shiftL` 8)
      | otherwise = 0
    -- While a DMA runs it owns the SPI master's data register.
    spiStart = if dmaBusy dma then dmaByte else resize <$> writing ioSpiData
    next
      | reset = initialIo
      | otherwise =
          Io
            { ioSpi = stepSpi spiStart (writing ioSpiControl) spi,
              ioDma = dma',
              ioAnswered = (\q -> if busWrite q then 0 else value) <$> taken
            }

-- | Result wires from the machine controller: BRAM read address, optional BRAM
-- write, and an optional byte offered to the UART transmitter.
machineStep ::
  Machine ->
  (Word32, Maybe Byte, Bool) ->
  (Machine, (MemAddr, Maybe (MemAddr, Word32), Maybe Byte))
machineStep machine (memoryWord, received, txReady) =
  machineStepDecoded machine (memoryWord, received, txReady, received == Just 0x03)

-- The physical circuit supplies a registered Ctrl-C decode, preventing the
-- 8-bit byte comparison from preceding the controller's high-fanout reset mux.
machineStepDecoded :: Machine -> (Word32, Maybe Byte, Bool, Bool) -> (Machine, StepOutput)
machineStepDecoded = machineStepDecodedWith decodeMemoryTarget

-- | One cycle with the register file as values in the machine ('cpuRegs'):
-- the simulation and the SDRAM image.
machineStepDecodedWith :: (Word32 -> MemoryTarget) -> Machine -> (Word32, Maybe Byte, Bool, Bool) -> (Machine, StepOutput)
machineStepDecodedWith decodeTarget machine input = withMultiplyMirror (\m -> machineStepCoreWith decodeTarget (withMirrorReads m) input) machine

-- | One cycle; the register file's outputs at 'registerReads' are already in
-- cpuRfA/cpuRfB, and its write this cycle is the state's cpuPendingWrite
-- (unless a break cancels it).
machineStepCoreWith :: (Word32 -> MemoryTarget) -> Machine -> (Word32, Maybe Byte, Bool, Bool) -> (Machine, StepOutput)
machineStepCoreWith = machineStepCoreBy cpuStepDecodedWith

machineStepCoreBy :: CpuStep -> (Word32 -> MemoryTarget) -> Machine -> (Word32, Maybe Byte, Bool, Bool) -> (Machine, StepOutput)
machineStepCoreBy cpuStepWith decodeTarget machine input =
  let (next, output, _, _) = machineStepCoreStagesBy (dropStages cpuStepWith) decodeTarget machine input
   in (next, output)

dropStages :: CpuStep -> CpuStepStages
dropStages cpuStepWith decodeTarget machine memoryWord received txReady emergencyReset =
  let (next, write, output) = cpuStepWith decodeTarget machine memoryWord received txReady emergencyReset
   in (next, write, output, initialStagePayloads, noStageLoad)

machineStepCoreStagesBy :: CpuStepStages -> (Word32 -> MemoryTarget) -> Machine -> (Word32, Maybe Byte, Bool, Bool) -> (Machine, StepOutput, StagePayloads, StageLoad)
machineStepCoreStagesBy cpuStepWith decodeTarget machine (memoryWord, received, txReady, emergencyRequest) =
  let emergencyReset = breakRequested machine emergencyRequest
      receivedMachine = case (not emergencyReset, received, rxHolding machine) of
        (True, Just byte, Nothing) -> machine {rxHolding = Just byte}
        _ -> machine
      (machine', coreOutput, stages, loads) = runningStepStagesBy cpuStepWith decodeTarget receivedMachine {clearRegisters = False, cpuCountRetirement = False, cpuCounterWrite = Nothing, cpuBusRequest = Nothing, cpuPrefetchIssue = False} memoryWord received txReady emergencyReset
      cancelled = emergencyReset
      (busStepped, busResponse, busOutput, busEffect) = busStepWith decodeTarget (systemBus machine) (cpuBusRequest machine) memoryWord txReady (rxHolding machine) (bootCause machine) (cpuDevices machine)
      (bus', response, effect) = if cancelled then ((systemBus machine) {busPhase = BusIdle}, Nothing, NoEffect) else (busStepped, busResponse, busEffect)
      busActive = case busPhase (systemBus machine) of
        BusIdle -> case cpuBusRequest machine of Nothing -> False; Just _ -> True
        _ -> True
      -- A break cancels writes and UART bytes; the read address is a
      -- don't-care then, so it does not wait on the break.
      (busAddress', busWrite', busTx) = busOutput
      (coreAddress, coreWrite, coreTx) = coreOutput
      output = (if busActive then busAddress' else coreAddress, if busActive then (if cancelled then Nothing else busWrite') else coreWrite, if busActive then (if cancelled then Nothing else busTx) else coreTx)
      counterWrite lowAddress highAddress = case cpuCounterWrite machine of
        Just (address, value)
          | address == lowAddress -> Just (False, value)
          | address == highAddress -> Just (True, value)
        _ -> Nothing
      counted =
        machine'
          { systemBus = bus',
            cpuBusResponse = response,
            rxHolding = if effect == ConsumeRx then Nothing else rxHolding machine',
            bootCause = if effect == ConsumeBootCause then causeNone else bootCause machine',
            cpuCycle = tickCounter True (counterWrite 0xb00 0xb80) (cpuCycle machine),
            cpuInstret = tickCounter (cpuCountRetirement machine) (counterWrite 0xb02 0xb82) (cpuInstret machine),
            -- Devices step from their registers; a reset this cycle quietens
            -- them after the time and compare logic, keeping time.
            cpuDevices = if clearRegisters machine' then initialDevices {devMtime = devMtime devices'} else devices',
            -- From registers, a cycle behind: WFI may finish a cycle late.
            cpuWake = cpuInterruptEnable machine .&. pendingInterrupts (cpuDevices machine) /= 0
          }
      devices' = stepDevices (case rxHolding machine of Nothing -> False; Just _ -> True) txReady effect (cpuDevices machine)
      -- The prefetch arrives three cycles after Decode issued it, the
      -- branch target three after ExecuteFinish. (Stores into a buffered
      -- word drop it at Commit.)
      -- The word is taken whenever its read arrives (a register decides);
      -- only the valid bit and the count wait on this cycle's phase.
      arriving = cpuPrefetchCount machine == 1
      prefetchedWord = if arriving then counted {cpuPrefetchWord = memoryWord} else counted
      prefetched
        | clearRegisters counted = prefetchedWord {cpuPrefetchValid = False, cpuPrefetchCount = 0}
        | cpuPrefetchIssue counted = prefetchedWord -- a read issued this cycle
        | arriving = prefetchedWord {cpuPrefetchCount = 0, cpuPrefetchValid = True}
        | cpuPrefetchCount machine /= 0 = prefetchedWord {cpuPrefetchCount = cpuPrefetchCount machine - 1}
        | otherwise = prefetchedWord
      -- the same for the branch target (issued at ExecuteFinish)
      targeted
        | clearRegisters prefetched = prefetched {cpuTargetValid = False, cpuTargetCount = 0}
        | cpuTargetCount machine == 1 = prefetched {cpuTargetCount = 0, cpuTargetWord = memoryWord, cpuTargetValid = True}
        | cpuTargetCount machine /= 0 = prefetched {cpuTargetCount = cpuTargetCount machine - 1}
        | otherwise = prefetched
      final = (if clearRegisters machine then targeted {cpuRegs = repeat 0, cpuRegValid = 0} else targeted) {cpuInterruptDue = interruptCause machine}
   in -- The register file's next read: a pipelined machine's is the
      -- pipeline's choice (its phases read no registers); otherwise
      -- Decode's sources.
      ( if cpuPipelined machine then final else final {cpuReadIndices = registerReads final},
        output,
        stages,
        loads
      )

-- | Keep time while an external memory holds the core (the SDRAM wrapper).
tickHeld :: Machine -> Machine
tickHeld machine = machine {cpuCycle = tickCounter True Nothing (cpuCycle machine), cpuDevices = (cpuDevices machine) {devMtime = tickCounter True Nothing (devMtime (cpuDevices machine))}}

initialHeldState :: HeldState
initialHeldState = HeldState initialCounter initialCounter Nothing

heldStateOf :: Machine -> HeldState
heldStateOf machine = HeldState (cpuCycle machine) (devMtime (cpuDevices machine)) (rxHolding machine)

applyHeldState :: HeldState -> Machine -> Machine
applyHeldState HeldState {..} machine =
  machine
    { cpuCycle = heldCycle,
      cpuDevices = (cpuDevices machine) {devMtime = heldMtime},
      rxHolding = heldRx
    }

-- | Ctrl-C: reset the CPU into the boot ROM with cause BREAK.
resetCpu :: Machine -> Machine
resetCpu = systemReset causeBreak

-- | A received Ctrl-C breaks a running program; in the boot ROM it is data.
-- Both inputs are registers, so the reset fan-out starts from one gate.
breakRequested :: Machine -> Bool -> Bool
breakRequested machine requested = requested && not (cpuInRom machine)

-- | Reset architectural state and cancellation tokens and restart at the boot
-- ROM, recording why; RAM is kept. Pipeline temporaries remain held: each is
-- overwritten before its next valid use, avoiding wide reset muxes.
systemReset :: Unsigned 2 -> Machine -> Machine
systemReset cause machine =
  machine
    { clearRegisters = True,
      cpuPendingWrite = Nothing,
      bootCause = cause,
      cpuInRom = True,
      cpuPc = 0,
      cpuPhase = Fetch,
      cpuTrapRegisters = initialTrapRegisters,
      cpuScratch = 0,
      cpuInterruptEnable = 0,
      cpuCountRetirement = False,
      cpuCounterWrite = Nothing,
      systemBus = (systemBus machine) {busPhase = BusIdle},
      cpuBusRequest = Nothing,
      cpuBusResponse = Nothing,
      rxHolding = Nothing,
      cpuDevices = initialDevices {devMtime = devMtime (cpuDevices machine)},
      cpuPrefetchValid = False,
      cpuPrefetchCount = 0,
      cpuTargetValid = False,
      cpuTargetCount = 0,
      cpuFetchSource = FromMemory,
      cpuStoreHitsPrefetch = False,
      cpuStoreHitsTarget = False,
      cpuNextInstruction = 0,
      cpuNextValid = False,
      cpuAhead = False,
      cpuPrefetchIssue = False,
      cpuWake = False,
      cpuFast = False,
      cpuPipe = restartPipe 0 (cpuPipe machine)
    }

fetchedWord :: (Word32, Word32) -> Word32 -> Fetched
fetchedWord (pc, predicted) word =
  let opcode = word .&. 0x7f
   in Fetched pc word (opcode /= 0x37 && opcode /= 0x17 && opcode /= 0x6f) (opcode == 0x33 || opcode == 0x23 || opcode == 0x63) predicted word 4

btbIndex :: Word32 -> Index 8
btbIndex pc = fromIntegral (resize (pc `shiftR` 2) :: Unsigned 3)

btbTag :: Word32 -> Unsigned 8
btbTag pc = resize (pc `shiftR` 5)

slotView :: Slot a -> Maybe a
slotView (Slot valid payload) = if valid then Just payload else Nothing

-- | Invalidate, keeping the (now don't-care) payload: no payload mux.
slotCancel :: Slot a -> Slot a
slotCancel slot = slot {slotValid = False}

-- | The token from a Maybe-valued next state, keeping the old payload; the
-- payload is overwritten separately in 'pipeStepDecodedWith'.
slotToken :: Slot a -> Maybe b -> Slot a
slotToken slot next = slot {slotValid = isJust next}

pD :: Pipe -> Maybe Fetched
pD = slotView . pDSlot

pE1 :: Pipe -> Maybe ExecuteOne
pE1 = slotView . pE1Slot

pE2 :: Pipe -> Maybe ExecuteTwo
pE2 = slotView . pE2Slot

pM :: Pipe -> Maybe MemoryStage
pM = slotView . pMSlot

emptyExecuteOne :: ExecuteOne
emptyExecuteOne = ExecuteOne 0 0 0 0 0 initialExecuteControl 0 0 0 0 0 False False 0

emptyExecuteTwo :: ExecuteTwo
emptyExecuteTwo =
  ExecuteTwo 0 0 initialExecuteControl (Computed Nothing 0 0 Nothing 0) (repeat 0) initialCompareResults initialCompareResults
    0 0 0 0 0 0 0 False False 0 False Plain False False False False False 0 False False False False

emptyMemoryStage :: MemoryStage
emptyMemoryStage = MemoryStage 0 0 0 0 False False False False False 0 0 0 0 0 False False 0 False 0 Plain 0 0 0 0

initialStagePayloads :: StagePayloads
initialStagePayloads =
  StagePayloads (Fetched 0 0 False False 0 0 4) emptyExecuteOne emptyExecuteTwo emptyMemoryStage

-- | Replace the pipeline state, for a circuit that keeps it in its own
-- clock-enabled register: 'cpuPipe' is the largest single field, so taking it
-- off the machine register's enable keeps that enable's fanout small.
withPipe :: Pipe -> Machine -> Machine
withPipe pipe machine = machine {cpuPipe = pipe}

stagePayloadsOf :: Machine -> StagePayloads
stagePayloadsOf machine =
  let pipe = cpuPipe machine
   in StagePayloads
        (slotPayload (pDSlot pipe))
        (slotPayload (pE1Slot pipe))
        (slotPayload (pE2Slot pipe))
        (slotPayload (pMSlot pipe))

withStagePayloads :: StagePayloads -> Machine -> Machine
withStagePayloads StagePayloads {..} machine =
  let pipe = cpuPipe machine
   in machine
        { cpuPipe =
            pipe
              { pDSlot = (pDSlot pipe) {slotPayload = spD},
                pE1Slot = (pE1Slot pipe) {slotPayload = spE1},
                pE2Slot = (pE2Slot pipe) {slotPayload = spE2},
                pMSlot = (pMSlot pipe) {slotPayload = spM}
              }
        }

noStageLoad :: StageLoad
noStageLoad = StageLoad False False False False

emptyPipe :: Pipe
emptyPipe =
  Pipe
    0
    0
    (repeat Nothing)
    (repeat (Fetched 0 0 False False 0 0 4))
    0
    0
    0
    Nothing
    (repeat (Fetched 0 0 False False 0 0 4))
    0
    0
    0
    (Slot False (Fetched 0 0 False False 0 0 4))
    (0, 0)
    False
    False
    (Slot False emptyExecuteOne)
    (Slot False emptyExecuteTwo)
    (Slot False emptyMemoryStage)
    Nothing
    (repeat (BtbEntry False False 0 0))

-- | Expanded FIFO head, stable while D stalls. Data words are only written
-- by A, so popping this head changes pointers rather than a wide shift mux.
pF :: Pipe -> Maybe Fetched
pF pipe = if pFCount pipe == 0 then Nothing else Just (pFQueue pipe !! pFRead pipe)

-- | Empty every stage and fetch from @pc@. Only valid bits, pointers and
-- the pc change: the stages' contents are don't-cares once empty.
restartPipe :: Word32 -> Pipe -> Pipe
restartPipe pc pipe =
  pipe
    { pFetchPc = pc,
      pInstructionPc = pc,
      pInflight = repeat Nothing,
      pQueueRead = 0,
      pQueueWrite = 0,
      pOutstanding = 0,
      pA = Nothing,
      pFRead = 0,
      pFWrite = 0,
      pFCount = 0,
      pDSlot = slotCancel (pDSlot pipe),
      pDFresh = False,
      pDBlocked = False,
      pE1Slot = slotCancel (pE1Slot pipe),
      pE2Slot = slotCancel (pE2Slot pipe),
      pMSlot = slotCancel (pMSlot pipe),
      pRedirect = Nothing
    }

-- | A multiply's operands as 33-bit signed values (sign- or zero-extended
-- as MUL, MULH, MULHSU or MULHU needs), split into a signed high 17 bits
-- and an unsigned low 16, multiplied pairwise: four 17 x 17 products, each
-- one DSP block.
partialProducts :: BitVector 3 -> Word32 -> Word32 -> Vec 4 (Signed 34)
partialProducts funct3 a b =
  let widen signed value
        | signed = resize (bitCoerce value :: Signed 32) :: Signed 33
        | otherwise = bitCoerce (resize value :: Unsigned 33)
      a33 = widen (funct3 == 1 || funct3 == 2) a
      b33 = widen (funct3 == 1) b
      upper v = resize (v `shiftR` 16) :: Signed 17
      lower v = resize (v .&. 0xffff) :: Signed 17
   in (upper a33 `mul` upper b33) :> (upper a33 `mul` lower b33) :> (lower a33 `mul` upper b33) :> (lower a33 `mul` lower b33) :> Nil

-- | The partial products summed: MUL's low word, else the high word.
productHalf :: BitVector 3 -> Vec 4 (Signed 34) -> Word32
productHalf funct3 products =
  let wide v = resize v :: Signed 66
      total =
        (wide (products !! (0 :: Index 4)) `shiftL` 32)
          + ((wide (products !! (1 :: Index 4)) + wide (products !! (2 :: Index 4))) `shiftL` 16)
          + wide (products !! (3 :: Index 4))
      bits = bitCoerce total :: BitVector 66
   in if funct3 == 0 then unpack (slice d31 d0 bits) else unpack (slice d63 d32 bits)

-- | One cycle of the pipeline: fetch (up to four words outstanding), raw
-- instruction assembly, compressed expansion/source predecode, decode and
-- register read with forwarding, two execute stages, and the commit stage.
-- The explicit C variant uses the same queue as a raw word FIFO:
-- two compressed instructions can share one word, and a full-width instruction
-- can combine the upper half with the next word's lower half. The BTB tags
-- which halfword of the fetched 32-bit word ends a predicted branch or jump.
-- Straight-line decode still advances one instruction per cycle.
-- ALU instructions, jumps, branches, and aligned RAM loads and
-- stores run here. Anything else (CSRs, ECALL, EBREAK, MRET, WFI,
-- FENCE.I, multiply and divide, device or misaligned accesses, illegal
-- encodings, misaligned targets, fetch faults) and any interrupt hands
-- over: when it reaches the commit stage the pipeline is flushed and the
-- phases run it from Fetch.
-- | Which 'pInflight' entry this cycle's memory word belongs to. The internal
-- block RAM's port answers two edges after its read address; an external
-- cache registers its own BSRAM read return, so it answers one edge later and
-- the word on the bus is the older of the two.
inflightArrival :: Machine -> Index 4
inflightArrival machine = if cpuExternalMemory machine then 3 else 2

-- | The commit stage's multiply operands, read every cycle by the
-- free-running DSP operand register (a don't-care unless M multiplies).
multiplyOperands :: Machine -> (BitVector 3, Word32, Word32)
multiplyOperands machine = let m = slotPayload (pMSlot (cpuPipe machine)) in (mFunct3 m, mA m, mB m)

partialProductsOf :: (BitVector 3, Word32, Word32) -> Vec 4 (Signed 34)
partialProductsOf (funct3, a, b) = partialProducts funct3 a b

-- | Simulation: inject the mirrored product register, then advance both
-- mirrored registers by one edge, as the circuits' free-running registers do.
withMultiplyMirror :: (Machine -> (Machine, o)) -> Machine -> (Machine, o)
withMultiplyMirror stepWith machine =
  let (next, output) = stepWith machine {cpuMulProducts = cpuMulProductsMirror machine}
   in (next {cpuMulOperandsMirror = multiplyOperands machine, cpuMulProductsMirror = partialProductsOf (cpuMulOperandsMirror machine)}, output)

pipeStep :: Machine -> Word32 -> (Machine, RegisterWrite, StepOutput)
pipeStep = pipeStepDecodedWith decodeMemoryTarget

pipeStepDecodedWith :: (Word32 -> MemoryTarget) -> Machine -> Word32 -> (Machine, RegisterWrite, StepOutput)
pipeStepDecodedWith decodeTarget machine memoryWord =
  let (next, write, output, _, _) = pipeStepStagesWith decodeTarget machine memoryWord
   in (next, write, output)

pipeStepStagesWith :: (Word32 -> MemoryTarget) -> Machine -> Word32 -> (Machine, RegisterWrite, StepOutput, StagePayloads, StageLoad)
pipeStepStagesWith decodeTarget machine memoryWord =
  let pipe = cpuPipe machine
      -- Every stall and port decision below reads registers (stage valid
      -- bits, kinds, wait counts, queue pointers), never another stage's
      -- decision, so no long chain runs from the commit stage to fetch.
      -- Commit --------------------------------------------------------------
      -- An interrupt is taken before the oldest instruction; any action but
      -- Plain and FENCE.I leaves the pipeline for the phases.
      leavesFor m = case cpuInterruptDue machine of
        Just _ -> True
        Nothing -> case mAction m of Plain -> False; FenceI -> False; _ -> True
      handover = case pM pipe of
        Just m -> leavesFor m
        Nothing -> False
      -- FENCE.I commits, then the pipeline refetches after it
      fencing = case pM pipe of
        Just m -> not handover && mAction m == FenceI
        Nothing -> False
      -- waiting for a load's (or a sub-word store's) word
      mHold = case pM pipe of
        Just m -> mWait m /= 0
        Nothing -> False
      mCommits = case pM pipe of
        Just m -> not handover && mWait m == 0
        Nothing -> False
      -- the port writes this cycle (from registers; a handover makes it moot)
      mWriting = case pM pipe of
        Just m -> mStore m && mWait m == 0
        Nothing -> False
      committedValue m
        | mLoad m = loadValue (mFunct3 m) (mOffset m) memoryWord
        | mShift m = shiftResult (mFunct3 m) (if mArith m then 0x20 else 0) (mValue m) (fromIntegral (mAmount m .&. 0x1c))
        | otherwise = mValue m
      -- Multiplication's wide carry chains end at a dedicated register,
      -- before the common load/shift/ordinary writeback mux. A multiply
      -- spends one extra M cycle here; its result then forwards as mValue.
      -- mWait counts 3, 2, 1: the operand register reloads from mA/mB by the
      -- first edge, the product register by the second, and the third sums.
      heldMemory m
        | mMultiply m && mWait m == 1 = m {mWait = 0, mValue = productHalf (mFunct3 m) (cpuMulProducts machine), mMultiply = False, mFinal = True}
        | otherwise = m {mWait = mWait m - 1}
      registerWriteNow = case pM pipe of
        Just m | mCommits && mWrites m -> Just (mRd m, committedValue m)
        _ -> Nothing
      memoryWrite = case pM pipe of
        Just m
          | mCommits && mStore m ->
              Just (mIndex m, if mStoreWord m || cpuExternalMemory machine then mData m else (memoryWord .&. complement (mMask m)) .|. mData m)
        _ -> Nothing
      -- Execute two: select, resolve branches, read memory -----------------
      -- A load or sub-word store reads its word whenever it is here (a read
      -- nobody waits for is harmless), and moves on the cycle it can.
      e2Reads x = case execKind (e2Control x) of
        KindLoad -> True
        KindStore -> not (cpuExternalMemory machine) && execFunct3 (e2Control x) /= 2
        _ -> False
      e2Advance = case pE2 pipe of
        Just x -> not mHold && not (e2Reads x && mWriting)
        Nothing -> True
      e2Out x =
        let control = e2Control x
            comp = e2Computed x
            kind = execKind control
            funct3 = execFunct3 control
            aluResult
              -- (a multiply's product is summed at commit)
              | execMulDiv control = Just 0
              | execLui control = Just (e2Imm x)
              | execAuipc control = Just (cTarget comp)
              | execAluOp control = selectedAlu control (e2Candidates x) (e2AluCompare x)
              | otherwise = Nothing
            taken = case kind of
              KindJump -> True
              KindBranch -> branchTakenPrepared funct3 (e2BranchCompare x) == Just True
              _ -> False
            target = cTarget comp
            address = cAddress comp
            -- The outcome was decided at the E1->E2 edge and registered in
            -- E2: read the flip-flops here instead of recomputing the
            -- exception/action priority encoder on the hazard path.
            action = e2Action x
            slow = case action of Plain -> False; FenceI -> False; _ -> True
            load = e2LoadFast x
            store = e2StoreFast x
            storeWord = e2StoreWordFast x
            value = case kind of KindJump -> cLink comp; _ -> fromMaybe 0 aluResult
            shifting = e2ShiftFast x
            multiplying = e2MultFast x
            stage =
              MemoryStage
                { mPc = e2Pc x,
                  mNext = if taken then target else cLink comp,
                  mValue = value,
                  mRd = e2Rd x,
                  mWrites = e2Writes x && not slow,
                  mFinal = not load && not shifting && not multiplying,
                  mLoad = load,
                  mStore = store,
                  mStoreWord = storeWord,
                  mFunct3 = funct3,
                  mOffset = resize address,
                  mIndex = ramWordIndex address,
                  mData = storeLanes funct3 (resize address) (e2B x),
                  mMask = storeMask funct3 (resize address),
                  mShift = shifting,
                  mArith = execArithmeticShift control,
                  mAmount = e2Op2 x,
                  mMultiply = multiplying,
                  mWait = e2WaitFast x,
                  mAction = action,
                  mWord = e2Word x,
                  mA = e2A x,
                  mB = e2B x,
                  mAddress = address
                }
            actual = if e2Refetch x then e2Pc x else if taken then target else cLink comp
            control' = case kind of KindBranch -> True; KindJump -> True; _ -> False
            mispredicted = e2Refetch x || actual /= e2Predicted x
            trainTaken = control' && not (e2Refetch x) && not (e2Straddle x) && taken && target /= cLink comp
            -- A taken non-straddling branch or jump teaches the buffer; any
            -- mispredicted BTB hit clears its entry, while a correctly
            -- predicted not-taken branch leaves the other halfword's entry
            -- intact.
            trainBtb = trainTaken || (e2PredictedTaken x && mispredicted)
            training = if trainBtb then Just (e2Pc x, trainTaken, e2Slot x, target) else Nothing
         in (stage, if mispredicted then Just actual else Nothing, training, e2Refetch x)
      -- (in a redirect cycle the stage holds a wrong-path instruction)
      flushing = pRedirect pipe
      e2Moved = case pE2 pipe of
        Just x | e2Advance && isNothing flushing -> Just (e2Out x)
        _ -> Nothing
      redirect = e2Moved >>= (\(_, r, _, _) -> r)
      btb = pBtb pipe
      btb' = case e2Moved >>= (\(_, _, t, _) -> t) of
        Just (pc, taken, slotBit, target) -> replace (btbIndex pc) (BtbEntry taken slotBit (btbTag pc) target) btb
        Nothing -> btb
      e2Reading = case pE2 pipe of
        Just x -> e2Reads x && isNothing flushing
        Nothing -> False
      e2Index = maybe 0 (ramWordIndex . cAddress . e2Computed) (pE2 pipe)
      -- Execute one ------------------------------------------------------------
      e1Out x =
        let a = e1A x
            b = e1B x
            imm = e1Imm x
            op2 = e1Op2 x
            control = e1Control x
            link1 = e1Pc x + resize (e1Size x)
            computed = (compute (e1Pc x) (e1Word x) a b imm op2) {cLink = link1, cAlu = Nothing, cTaken = Nothing}
            -- The E2 outcome, decided here at the E1->E2 edge: the same
            -- priority order the E2->M transition used to recompute (fetch
            -- fault, illegal encoding, system instructions, misaligned
            -- target, misaligned access, then access outside RAM).
            kind1 = execKind control
            funct31 = execFunct3 control
            target1 = cTarget computed
            address1 = cAddress computed
            taken1 = case kind1 of
              KindJump -> True
              KindBranch -> branchTakenPrepared funct31 (compareOperands a b) == Just True
              _ -> False
            memory1 = case kind1 of KindLoad -> True; KindStore -> True; _ -> False
            storing1 = case kind1 of KindStore -> True; _ -> False
            misaligned1 = misalignedMemory funct31 address1
            dividing1 = execMulDiv control && testBit funct31 2
            -- selectedAlu is Just for multiply/divide (a dummy zero), LUI,
            -- AUIPC, and legal ALU operations, so only those flag bits (not
            -- the result mux) are needed here.
            illegal1 = case kind1 of
              KindAlu ->
                not
                  ( execMulDiv control
                      || execLui control
                      || execAuipc control
                      || (execAluOp control && execLegal control)
                  )
                  && not dividing1
              KindInvalid -> True
              _ -> False
            action1
              | e1Pc x .&. instructionAlignmentMask machine /= 0 = Raise 0 (e1Pc x)
              | e1FetchFault x = Raise 1 (e1FaultValue x)
              | dividing1 = Divide
              | illegal1 = Raise 2 (e1Raw x)
              | otherwise = case kind1 of
                  KindEcall -> Raise 11 0
                  KindEbreak -> Raise 3 (e1Pc x)
                  KindMret -> Mret
                  KindWfi -> Wfi
                  KindCsr -> CsrAccess
                  KindFenceI -> FenceI
                  _
                    | taken1 && target1 .&. instructionAlignmentMask machine /= 0 -> Raise 0 target1
                    | memory1 && misaligned1 -> Raise (if storing1 then 6 else 4) address1
                    | memory1 && not (isRamTarget (decodeTarget address1)) -> Bus
                    | otherwise -> Plain
            plainMemory1 =
              e1Pc x
                .&. instructionAlignmentMask machine
                == 0
                && not (e1FetchFault x)
                && not misaligned1
                && isRamTarget (decodeTarget address1)
            load1 = plainMemory1 && case kind1 of KindLoad -> True; _ -> False
            store1 = plainMemory1 && storing1
            storeWord1 = store1 && funct31 == 2
            shifting1 = execShift control && not (execMulDiv control)
            multiplying1 = execMulDiv control && not (testBit funct31 2)
            -- An external cache answers one edge later (see 'inflightArrival')
            wait1 = if load1 then (if cpuExternalMemory machine then 3 else 2) else if store1 && not storeWord1 && not (cpuExternalMemory machine) then 2 else if multiplying1 then 3 else 0
            refetch1 = e1Size x == 0
         in ExecuteTwo
              { e2Pc = e1Pc x,
                e2Predicted = e1Predicted x,
                e2Control = control,
                e2Computed = computed,
                e2Candidates = aluCandidates control a op2,
                e2AluCompare = compareOperands a op2,
                e2BranchCompare = compareOperands a b,
                e2B = b,
                e2Op2 = op2,
                e2Imm = imm,
                e2A = a,
                e2Word = e1Word x,
                e2Raw = e1Raw x,
                e2Rd = e1Rd x,
                e2Writes = e1Writes x,
                e2FetchFault = e1FetchFault x,
                e2FaultValue = e1FaultValue x,
                e2Forwards = False,
                e2Action = action1,
                e2LoadFast = load1,
                e2StoreFast = store1,
                e2StoreWordFast = storeWord1,
                e2ShiftFast = shifting1,
                e2MultFast = multiplying1,
                e2WaitFast = wait1,
                e2Slot = testBit (e1Pc x) 1 || e1Size x == 4,
                e2Straddle = testBit (e1Pc x) 1 && e1Size x == 4,
                e2Refetch = refetch1,
                e2PredictedTaken = refetch1 || e1Predicted x /= link1
              }
      e1Advance = isNothing (pE2 pipe) || e2Advance
      -- Decode and register read ---------------------------------------------
      d = pD pipe
      e1Free = isNothing (pE1 pipe) || e1Advance
      decodeOut f =
        let word = fWord f
            pc = fPc f
            opcode = word .&. 0x7f
            control = decodeExecuteControl word
            kind = execKind control
            firstFault = fSize f /= 0 && not (fetchable (decodeTarget pc))
            crossFault = cpuCompressed machine && fSize f == 4 && testBit pc 1 && not (fetchable (decodeTarget (pc + 2)))
            fetchFault = firstFault || crossFault
            faultValue = if firstFault then pc else pc + 2
            -- (division and the system instructions write rd in the phases)
            phasesWrite =
              fetchFault || (execMulDiv control && testBit (execFunct3 control) 2) || case kind of
                KindAlu -> False
                KindJump -> False
                KindLoad -> False
                _ -> True
            rs1 = instructionRs1 word
            rs2 = instructionRs2 word
            rd = instructionRd word
            hazard = pDBlocked pipe
            operand r current = case pM pipe of
              Just m | mWrites m && mRd m == r -> mValue m
              _ -> case cpuPendingWrite machine of
                Just (w, v) | w /= 0 && w == r -> v
                _ -> current
            (heldA, heldB) = pDOperands pipe
            a = operand rs1 (if pDFresh pipe then registerValue (cpuRegValid machine) rs1 (cpuRfA machine) else heldA)
            b = operand rs2 (if pDFresh pipe then registerValue (cpuRegValid machine) rs2 (cpuRfB machine) else heldB)
            imm = decodeImmediate word
            writes = not phasesWrite && rd /= 0
         in ( ExecuteOne
                { e1Pc = pc,
                  e1Predicted = fPredicted f,
                  e1Word = word,
                  e1Raw = fRaw f,
                  e1Size = fSize f,
                  e1Control = control,
                  e1A = a,
                  e1B = b,
                  e1Imm = imm,
                  e1Op2 = if opcode == 0x33 then b else imm,
                  e1Rd = rd,
                  e1Writes = writes,
                  e1FetchFault = fetchFault,
                  e1FaultValue = faultValue
                },
              hazard,
              (a, b)
            )
      dAdvance = case d of
        Just f -> e1Free && not (let (_, hazard, _) = decodeOut f in hazard)
        Nothing -> False
      dFree = isNothing d || dAdvance
      -- These two elastic stages separate FIFO word/halfword selection,
      -- RV32C expansion, and the registered register-file address. Source
      -- addresses depend only on the registered F FIFO head, never on
      -- raw fetch pointers, the decompressor or ready/stall decisions.
      fFree = pFCount pipe < 2
      aFree = isNothing (pA pipe) || fFree
      fPush = fFree && isJust (pA pipe)
      fPop = dFree && pFCount pipe /= 0
      expand f =
        let word = if fSize f == 2 then fromMaybe 0 (C.decompress32 (resize (fRaw f))) else fRaw f
         in (fetchedWord (fPc f, fPredicted f) word) {fRaw = fRaw f, fSize = fSize f}
      -- Fetch ------------------------------------------------------------------
      inflight = pInflight pipe
      -- The word issued 'inflightArrival' cycles ago is on the bus now. The
      -- internal block RAM's port answers two edges after its read address;
      -- an external cache (SdramPipeline) registers its BSRAM read return as
      -- well, so it answers one edge later.
      arrival = (`fetchedWord` memoryWord) <$> (inflight !! inflightArrival machine)
      readPointer = pQueueRead pipe
      writePointer = pQueueWrite pipe
      waiting = writePointer /= readPointer
      slot i = fromIntegral (i .&. 3) :: Index 4
      -- The arriving word is written at the write pointer regardless; it
      -- counts as queued unless it went straight to raw assembly.
      bypass = aFree && not waiting
      queue' = case arrival of
        Just a -> replace (slot writePointer) a (pQueue pipe)
        Nothing -> pQueue pipe
      instructionPc = pInstructionPc pipe
      atHalf1 = testBit instructionPc 1
      headWord = if waiting then Just (pQueue pipe !! slot readPointer) else arrival
      secondWord
        | writePointer - readPointer >= 2 = Just (pQueue pipe !! slot (readPointer + 1))
        | waiting = arrival
        | otherwise = Nothing
      (assembled, headDone) = case headWord of
        Nothing -> (Nothing, False)
        Just h ->
          let slot0Hit = testBit (fPc h) 0
              slot1Hit = testBit (fPc h) 1
              half = resize (fWord h `shiftR` (if atHalf1 then 16 else 0)) :: Unsigned 16
              short = half .&. 3 /= 3
              straddle = atHalf1 && not short
              -- If fetch followed a BTB hit on this word, the next queued word
              -- is the predicted target rather than the sequential upper half
              -- of a straddling 32-bit instruction; emit a zero-size refetch
              -- bubble so E2 clears the aliased BTB entry and refetches.
              refetch = straddle && (slot0Hit || slot1Hit)
              wordDone = atHalf1 || not short || slot0Hit
              nextPc = if wordDone then fPredicted h else instructionPc + 2
              raw
                | refetch = 0x00000013
                | short = resize half
                | not atHalf1 = fWord h
                | otherwise = ((maybe 0 fWord secondWord .&. 0xffff) `shiftL` 16) .|. resize half
              size
                | refetch = 0
                | short = 2
                | otherwise = 4
              predictedPc
                | straddle && not refetch = instructionPc + 4
                | otherwise = nextPc
           in -- Fetch always supplies a word, including a harmless dummy
              -- outside the memory map. Wait for it before assembly; D
              -- raises the precise second-half access fault. This keeps a
              -- full address-map decode out of FIFO consumption/accounting.
              if straddle && not refetch && isNothing secondWord
                then (Nothing, False)
                else (Just (Fetched instructionPc raw False False predictedPc raw size), wordDone)
      cConsume = aFree && headDone
      writePointer'
        | cpuCompressed machine = if isJust arrival then writePointer + 1 else writePointer
        | otherwise = if isJust arrival && not bypass then writePointer + 1 else writePointer
      readPointer'
        | cpuCompressed machine = if cConsume then readPointer + 1 else readPointer
        | otherwise = if aFree && waiting then readPointer + 1 else readPointer
      nextA
        | not aFree = pA pipe
        | cpuCompressed machine = assembled
        | waiting = Just (pQueue pipe !! slot readPointer)
        | otherwise = arrival
      fQueue' = case pA pipe of
        Just f | fFree -> replace (pFWrite pipe) (expand f) (pFQueue pipe)
        _ -> pFQueue pipe
      nextD = if dFree then pF pipe else d
      -- Compare each registered consumer before selecting the next D.
      -- Selecting the wide instruction first puts dFree's backpressure
      -- chain in front of both register-index comparators. Only the final
      -- one-bit choice should depend on dFree.
      nextBlocked =
        if dFree
          then decodeHazard (pF pipe) nextE1 nextE2 nextM
          else decodeHazard d nextE1 nextE2 nextM
      -- Read for the registered word that would enter D next, whether or
      -- not it does: no stall decision reaches the read address.
      entering = maybe 0 fWord (pF pipe)
      enteringReads = (instructionRs1 entering, instructionRs2 entering)
      leaving = if cpuCompressed machine then (if cConsume then 1 else 0) else (if aFree && waiting then 1 else 0) + (if bypass && isJust arrival then 1 else 0) :: Unsigned 3
      -- Words queued or in flight never exceed the queue (decided from
      -- registers); the port is free unless a store writes or a read waits.
      -- A redirect fetches its target from the next cycle.
      portBusy = mWriting || e2Reading
      fetchPc = fromMaybe (pFetchPc pipe) flushing
      issue = not portBusy && pOutstanding pipe < 4
      -- The lookup reads the fetch pc register only: a redirect's target
      -- is followed by target + 4.
      entry = btb !! btbIndex (pFetchPc pipe)
      hit =
        isNothing flushing
          && bValid entry
          && bTag entry == btbTag (pFetchPc pipe)
          && (not (cpuCompressed machine) || not (testBit (pFetchPc pipe) 1) || bSlot entry)
      predicted = if hit then bTarget entry else (if cpuCompressed machine then fetchPc .&. complement 3 else fetchPc) + 4
      fetchMeta =
        if cpuCompressed machine
          then (if hit && not (bSlot entry) then 1 else 0) .|. (if hit && bSlot entry then 2 else 0)
          else fetchPc
      issued = if issue then Just (fetchMeta, predicted) else Nothing
      nextE1 = case pE1 pipe of
        Just x | not e1Advance -> Just x
        _ -> if dAdvance then (\f -> let (stage, _, _) = decodeOut f in stage) <$> d else Nothing
      nextE2 = case pE2 pipe of
        Just x | not e2Advance -> Just x
        _ -> if e1Advance then e1Out <$> pE1 pipe else Nothing
      nextM = case pM pipe of
        Just m | mHold -> Just (heldMemory m)
        _ -> case e2Moved of
          Just (stage, _, _, False) -> Just stage
          _ -> Nothing
      pipe'
        | handover = restartPipe 0 pipe
        | fencing = restartPipe (maybe 0 mNext (pM pipe)) pipe
        | isJust flushing =
            (restartPipe (if issue then predicted else fetchPc) pipe)
              { pInstructionPc = fetchPc,
                pInflight = issued :> Nothing :> Nothing :> Nothing :> Nil,
                pOutstanding = if issue then 1 else 0,
                pMSlot = slotToken (pMSlot pipe) (if mHold then pM pipe else Nothing)
              }
        | otherwise =
            Pipe
              { pFetchPc = if issue then predicted else fetchPc,
                pInstructionPc = if cpuCompressed machine && aFree && isJust assembled then maybe (pInstructionPc pipe) fPredicted assembled else pInstructionPc pipe,
                pInflight = issued :> init inflight,
                pQueue = queue',
                pQueueRead = readPointer',
                pQueueWrite = writePointer',
                pOutstanding = pOutstanding pipe + (if issue then 1 else 0) - leaving,
                pA = nextA,
                pFQueue = fQueue',
                pFRead = if fPop then (if pFRead pipe == 0 then 1 else 0) else pFRead pipe,
                pFWrite = if fPush then (if pFWrite pipe == 0 then 1 else 0) else pFWrite pipe,
                pFCount = pFCount pipe + (if fPush then 1 else 0) - (if fPop then 1 else 0),
                pDSlot = slotToken (pDSlot pipe) nextD,
                pDOperands = case d of
                  Just f -> let (_, _, operands) = decodeOut f in operands
                  Nothing -> pDOperands pipe,
                pDFresh = dFree,
                pDBlocked = nextBlocked,
                pE1Slot = slotToken (pE1Slot pipe) nextE1,
                pE2Slot = slotToken (pE2Slot pipe) nextE2,
                pMSlot = slotToken (pMSlot pipe) nextM,
                pRedirect = redirect,
                pBtb = btb'
              }
      readAddress = if e2Reading then e2Index else memoryIndex fetchPc
      committed = case pM pipe of
        Just m | mCommits -> machine {cpuPc = mNext m, cpuInRom = romAddress (mNext m), cpuCountRetirement = True}
        _ -> machine
      handed = case pM pipe of
        Just m ->
          commitAction
            (cpuInterruptDue machine)
            m
            machine {cpuFast = False, cpuPipe = restartPipe 0 pipe, cpuPc = mPc m, cpuInRom = romAddress (mPc m)}
        Nothing -> machine
      portState m =
        m
          { cpuPortAddressFull = if e2Reading then maybe 0 (cAddress . e2Computed) (pE2 pipe) else (if cpuCompressed machine then fetchPc .&. complement 3 else fetchPc),
            cpuPortWriteAddressFull = maybe 0 mAddress (pM pipe),
            cpuPortByteEnable = maybe 0xf (\x -> pack (map (\n -> if testBit (mMask x) (n * 8) then high else low) (3 :> 2 :> 1 :> 0 :> Nil))) (pM pipe)
          }
      -- Stage payloads, independent of handover, FENCE.I and redirects:
      -- each loads from the stage before it under that stage's own advance
      -- decision (registered state only), and otherwise holds, so synthesis
      -- can use the flip-flops' clock enables. Wherever the selected
      -- next pipe (any branch above) has a valid stage, its contents equal
      -- the payload here; where the stage is cancelled the payload is unused.
      payloadD
        | dFree && pFCount pipe /= 0 = pFQueue pipe !! pFRead pipe
        | otherwise = slotPayload (pDSlot pipe)
      payloadE1
        | isJust (pE1 pipe) && not e1Advance = slotPayload (pE1Slot pipe)
        | dAdvance = let (stage, _, _) = decodeOut (slotPayload (pDSlot pipe)) in stage
        | otherwise = slotPayload (pE1Slot pipe)
      payloadE2
        | isJust (pE2 pipe) && not e2Advance = slotPayload (pE2Slot pipe)
        | isJust (pE1 pipe) && e1Advance = e1Out (slotPayload (pE1Slot pipe))
        | otherwise = slotPayload (pE2Slot pipe)
      payloadM
        | mHold = heldMemory (slotPayload (pMSlot pipe))
        | isJust (pE2 pipe) && e2Advance = let (stage, _, _, _) = e2Out (slotPayload (pE2Slot pipe)) in stage
        | otherwise = slotPayload (pMSlot pipe)
      withPayloads m =
        let p = cpuPipe m
         in m
              { cpuPipe =
                  p
                    { pDSlot = (pDSlot p) {slotPayload = payloadD},
                      pE1Slot = (pE1Slot p) {slotPayload = payloadE1},
                      pE2Slot = (pE2Slot p) {slotPayload = payloadE2},
                      pMSlot = (pMSlot p) {slotPayload = payloadM}
                    }
              }
      stages = StagePayloads payloadD payloadE1 payloadE2 payloadM
      -- Each enable admits every cycle in which the payload above may differ
      -- from the stage's current one (see 'StageLoad'). It is a superset: an
      -- empty stage can take a new instruction even when it cannot advance
      -- because the stage after it is stalled, so those cycles must load too.
      -- Where the two agree the register reloads its own value.
      loads = StageLoad (dFree && pFCount pipe /= 0) (e1Advance || dAdvance) (e2Advance || e1Advance) (mHold || e2Advance)
   in if handover
        then (withPayloads handed {cpuReadIndices = enteringReads}, Nothing, (0, Nothing, Nothing), stages, loads)
        else
          ( withPayloads (portState committed {cpuPipe = pipe', cpuReadIndices = enteringReads}),
            registerWriteNow,
            (readAddress, memoryWrite, Nothing),
            stages,
            loads
          )

-- | Leave the pipeline for the phases at the commit stage: an interrupt
-- (before the instruction), an exception, or an action the phases run from
-- the stage's registers. @machine@ is already flushed, at the
-- instruction's pc.
commitAction :: Maybe Word32 -> MemoryStage -> Machine -> Machine
commitAction interrupt m machine =
  let link = mNext m
      computed = (cpuComputed machine) {cLink = link, cAddress = mAddress m}
      word = mWord m
      funct3 = instructionFunct3 word
      raise cause value = machine {cpuPhase = Trap, cpuExceptionCause = cause, cpuExceptionValue = value}
   in case interrupt of
        Just cause -> raise cause 0
        Nothing -> case mAction m of
          Raise cause value -> raise cause value
          CsrAccess ->
            machine
              { cpuPhase = CsrRead,
                cpuInstruction = word,
                cpuComputed = computed,
                cpuCsrSelection = decodeCsrSelection (csrAddress word),
                cpuCsrReadOnly = csrAddress word == 0x301 || csrAddress word .&. 0xc00 == 0xc00,
                cpuCsrWrite = csrWriteRequested word,
                cpuCsrSource = if testBit funct3 2 then resize ((word `shiftR` 15) .&. 0x1f) else mA m
              }
          Mret -> machine {cpuPhase = TrapReturn}
          Wfi -> machine {cpuPhase = Commit, cpuComputed = computed}
          Divide ->
            machine
              { cpuPhase = MulDiv,
                cpuInstruction = word,
                cpuComputed = computed,
                cpuA = mA m,
                cpuB = mB m,
                cpuMulDiv = (cpuMulDiv machine) {mdStep = MdPrepare}
              }
          Bus ->
            machine
              { cpuPhase = BusWait,
                cpuInstruction = word,
                cpuComputed = computed,
                cpuBusRequest = Just (BusRequest (mAddress m) funct3 (testBit word 5) (mB m))
              }
          _ -> machine

-- | Wait for the bus to answer a load or store, then retire it, or raise
-- its access fault, or (the finisher) reset into the boot ROM.
busWaitStep :: Machine -> (Machine, RegisterWrite, StepOutput)
busWaitStep machine =
  let instruction = cpuInstruction machine
      address = cAddress (cpuComputed machine)
      retire = finishInstruction machine {cpuPc = cLink (cpuComputed machine), cpuFetchSource = FromPrefetch} Nothing
   in case cpuBusResponse machine of
        Nothing -> withoutRegister (machine, (0, Nothing, Nothing))
        Just response
          | responseFault response ->
              withoutRegister
                ( raiseException
                    machine
                    (if testBit instruction 5 then 7 else 5)
                    address
                )
          -- The finisher ends the program: reset into the boot ROM.
          | responseExit response ->
              withoutRegister
                ((systemReset causeExit machine) {cpuCountRetirement = True}, (0, Nothing, Nothing))
          | testBit instruction 5 -> withoutRegister retire
          | otherwise -> withRegister (instructionRd instruction) (responseValue response) retire

-- | The machine with the pipeline as its only datapath (the BRAM image):
-- the pipeline runs every instruction to its commit stage, and the phases
-- only the commit-stage actions. The phases' fetch, decode and execute
-- stages are not part of it.
pipelinedCpuStep :: (Word32 -> MemoryTarget) -> Machine -> Word32 -> Maybe Byte -> Bool -> Bool -> (Machine, RegisterWrite, StepOutput)
pipelinedCpuStep decodeTarget machine memoryWord received txReady emergencyReset =
  let (next, write, output, _, _) = pipelinedCpuStepStages decodeTarget machine memoryWord received txReady emergencyReset
   in (next, write, output)

pipelinedCpuStepStages :: (Word32 -> MemoryTarget) -> Machine -> Word32 -> Maybe Byte -> Bool -> Bool -> (Machine, RegisterWrite, StepOutput, StagePayloads, StageLoad)
pipelinedCpuStepStages decodeTarget machine memoryWord _received _txReady emergencyReset
  | cpuFast machine =
      let (machine', write, (address, memoryWrite, tx), stages, loads) = pipeStepStagesWith decodeTarget machine memoryWord
       in if emergencyReset
            then ((resetCpu machine) {cpuReadIndices = cpuReadIndices machine'}, Nothing, (address, Nothing, Nothing), stages, loads)
            else (machine', write, (address, memoryWrite, tx), stages, loads)
  | otherwise =
      let (next, write, output) = phases
       in (next, write, output, stagePayloadsOf next, noStageLoad)
  where
    phases
      | emergencyReset = (resetCpu machine, Nothing, idle)
      | otherwise = case cpuPhase machine of
      -- an action has finished (or a trap, MRET or reset set the pc)
      Fetch ->
        ( machine {cpuFast = True, cpuPipe = restartPipe (cpuPc machine) (cpuPipe machine), cpuInRom = romAddress (cpuPc machine)},
          Nothing,
          idle
        )
      Trap -> withoutRegister (enterTrap machine)
      CsrRead -> csrReadStep machine
      CsrWrite -> csrWriteStep machine
      TrapReturn -> withoutRegister (returnFromTrap machine)
      BusWait -> busWaitStep machine
      MulDiv ->
        let instruction = cpuInstruction machine
         in case mulDivStep (instructionFunct3 instruction) (cpuA machine) (cpuB machine) (cpuMulDiv machine) of
              Left unit -> (machine {cpuMulDiv = unit}, Nothing, idle)
              Right result ->
                withRegister
                  (instructionRd instruction)
                  result
                  (finishInstruction machine {cpuPc = cLink (cpuComputed machine)} Nothing)
      -- WFI waits until an interrupt is pending and enabled in mie
      Commit
        | cpuWake machine -> withoutRegister (finishInstruction machine {cpuPc = cLink (cpuComputed machine)} Nothing)
        | otherwise -> (machine, Nothing, idle)
      _ -> (machine {cpuPhase = Fetch}, Nothing, idle)
    idle = (0, Nothing, Nothing)

-- CPU ------------------------------------------------------------------------

runningStep ::
  Machine ->
  Word32 ->
  Maybe Byte ->
  Bool ->
  (Machine, (MemAddr, Maybe (MemAddr, Word32), Maybe Byte))
runningStep machine memoryWord received txReady =
  runningStepDecodedWith decodeMemoryTarget machine memoryWord received txReady (received == Just 0x03)

runningStepDecodedWith :: (Word32 -> MemoryTarget) -> Machine -> Word32 -> Maybe Byte -> Bool -> Bool -> (Machine, StepOutput)
runningStepDecodedWith = runningStepBy cpuStepDecodedWith

runningStepBy :: CpuStep -> (Word32 -> MemoryTarget) -> Machine -> Word32 -> Maybe Byte -> Bool -> Bool -> (Machine, StepOutput)
runningStepBy cpuStepWith decodeTarget machine memoryWord received txReady emergencyReset =
  let (next, output, _, _) = runningStepStagesBy (dropStages cpuStepWith) decodeTarget machine memoryWord received txReady emergencyReset
   in (next, output)

runningStepStagesBy :: CpuStepStages -> (Word32 -> MemoryTarget) -> Machine -> Word32 -> Maybe Byte -> Bool -> Bool -> (Machine, StepOutput, StagePayloads, StageLoad)
runningStepStagesBy cpuStepWith decodeTarget machine memoryWord received txReady emergencyReset =
  let (machine', registerWrite, output, stages, loads) = cpuStepWith decodeTarget machine memoryWord received txReady emergencyReset
      pending = if emergencyReset then Nothing else cpuPendingWrite machine
      written = maybe machine' (\(index, value) -> writeRegister index value machine') pending
   in (written {cpuPendingWrite = registerWrite}, output, stages, loads)

-- | One CPU cycle.  Register writes are returned rather than applied in each
-- branch, so the generated hardware has a single register-file write port
-- instead of a full copy of all 32 registers per instruction kind.
cpuStep :: Machine -> Word32 -> Maybe Byte -> Bool -> (Machine, RegisterWrite, StepOutput)
cpuStep machine memoryWord received txReady =
  cpuStepDecodedWith decodeMemoryTarget machine memoryWord received txReady (received == Just 0x03)

cpuStepDecodedWith :: (Word32 -> MemoryTarget) -> Machine -> Word32 -> Maybe Byte -> Bool -> Bool -> (Machine, RegisterWrite, StepOutput)
cpuStepDecodedWith decodeTarget machine
  | cpuPipelined machine = pipelinedCpuStep decodeTarget machine
  | otherwise = phasesCpuStep decodeTarget machine

-- | The machine with only the phases (the SDRAM image, and most tests).
phasesCpuStep :: (Word32 -> MemoryTarget) -> Machine -> Word32 -> Maybe Byte -> Bool -> Bool -> (Machine, RegisterWrite, StepOutput)
phasesCpuStep decodeTarget machine memoryWord received txReady emergencyReset =
  let (machine', write, (_, _, tx)) = cpuStepPhases decodeTarget machine memoryWord received txReady emergencyReset
   in (machine', write, (portAddress machine, if emergencyReset then Nothing else portWrite machine memoryWord, tx))

-- | IALIGN changes only in the explicit C board variant.
instructionAlignmentMask :: Machine -> Word32
instructionAlignmentMask machine = if cpuCompressed machine then 1 else 3

originalInstruction :: Machine -> Word32
originalInstruction machine =
  if cpuCompressed machine && cpuInstructionSize machine == 2
    then cpuInstructionRaw machine
    else cpuInstruction machine

-- | Turn a word read into one instruction, or request the second word of
-- a 32-bit instruction beginning at the upper halfword. No memory beyond
-- the instruction is required for a compressed instruction at a map boundary.
captureInstruction :: (Word32 -> MemoryTarget) -> Machine -> Word32 -> Machine
captureInstruction decodeTarget machine word
  | cpuFetchFault machine = machine {cpuPhase = Decode, cpuInstruction = 0, cpuInstructionRaw = 0, cpuInstructionSize = 4}
  | not (cpuCompressed machine) = machine {cpuPhase = Decode, cpuInstruction = word, cpuInstructionRaw = word, cpuInstructionSize = 4}
  | half .&. 3 /= 3 = machine {cpuPhase = Decode, cpuInstruction = fromMaybe 0 (C.decompress32 half), cpuInstructionRaw = resize half, cpuInstructionSize = 2}
  | not (testBit (cpuPc machine) 1) = machine {cpuPhase = Decode, cpuInstruction = word, cpuInstructionRaw = word, cpuInstructionSize = 4}
  | not (fetchable (decodeTarget (cpuPc machine + 2))) =
      machine
        { cpuPhase = Decode,
          cpuInstruction = 0,
          cpuInstructionRaw = resize half,
          cpuInstructionSize = 4,
          cpuFetchFault = True,
          cpuExceptionCause = 1,
          cpuExceptionValue = cpuPc machine + 2
        }
  | otherwise = machine {cpuPhase = FetchCross, cpuFetchHalf = half, cpuInstructionSize = 4}
  where
    half = resize (word `shiftR` (if testBit (cpuPc machine) 1 then 16 else 0)) :: Unsigned 16

-- | The CPU's read address this cycle, from registers: Fetch reads the pc,
-- Decode the next word (the prefetch), ExecuteFinish a load or store's word,
-- a branch or jump's target, or (decode-ahead) the word after next. A read
-- nobody waits for is harmless, so every other phase reads the pc too and
-- no phase needs its own "no read" case.
portAddress :: Machine -> MemAddr
portAddress machine = case cpuPhase machine of
  FetchCross -> memoryIndex (cpuPc machine + 2)
  FetchCrossDelay -> memoryIndex (cpuPc machine + 2)
  FetchCrossCapture -> memoryIndex (cpuPc machine + 2)
  FetchCrossWait -> memoryIndex (cpuPc machine + 2)
  ExecuteFinish
    | execMemory control -> memoryIndex (cAddress (cpuComputed machine))
    | execJump control -> memoryIndex (cTarget (cpuComputed machine))
    | otherwise -> memoryIndex (cpuPc machine + 8)
  Decode -> memoryIndex (cpuPc machine + 4)
  _ -> memoryIndex (cpuPc machine)
  where
    control = cpuExecuteControl machine

-- | The CPU's write to its memory port this cycle, from registers prepared
-- at ExecuteFinish: a word store at Commit, a byte or halfword store merged
-- into the word read back at MemoryCapture.
portWrite :: Machine -> Word32 -> Maybe (MemAddr, Word32)
portWrite machine word = case cpuPhase machine of
  Commit | cpuStoreNow machine -> Just (cpuPortIndex machine, cpuStoreData machine)
  MemoryCapture
    | execStore (cpuExecuteControl machine) ->
        Just (cpuPortIndex machine, (word .&. complement (cpuStoreMask machine)) .|. cpuStoreData machine)
  _ -> Nothing

-- | The phases' next state; their memory writes are 'portWrite''s.
cpuStepPhases :: (Word32 -> MemoryTarget) -> Machine -> Word32 -> Maybe Byte -> Bool -> Bool -> (Machine, RegisterWrite, StepOutput)
cpuStepPhases decodeTarget machine memoryWord _received txReady emergencyReset
  | emergencyReset = (resetCpu machine, Nothing, (0, Nothing, Nothing))
  | otherwise =
      let machineRx = machine
          next m = withoutRegister (m, (0, Nothing, Nothing))
       in let Machine {..} = machineRx
              instruction = cpuInstruction
              address = cAddress cpuComputed
              -- One register-bank read, shared by Decode and decode-ahead (at
              -- Commit, from the captured next word). Both sources are core
              -- registers, picked by one one-hot phase bit.
              decoding = case cpuPhase of Commit -> cpuNextInstruction; _ -> instruction
              -- (the register file is read at 'registerReads', which picks
              -- the same instruction)
              sharedRegA = registerValue cpuRegValid (instructionRs1 decoding) cpuRfA
              sharedRegB = registerValue cpuRegValid (instructionRs2 decoding) cpuRfB
           in case cpuPhase of
                -- Only the ROM and RAM hold instructions. The check is
                -- registered here and raised as an access fault at Decode.
                -- Interrupts are taken between instructions: mepc is the
                -- instruction about to be fetched.
                -- Every input is a register (the pending bits, mie and MIE),
                -- so a change to MIE or mie applies at the next boundary.
                -- The pc's read always goes out (a hit makes it harmless), so
                -- the memory address never waits on the hit decision.
                Fetch -> case interruptCause machineRx of
                  Just cause -> withoutRegister (raiseException machineRx {cpuFetchSource = FromMemory} cause 0)
                  Nothing | cpuPc .&. instructionAlignmentMask machineRx /= 0 -> withoutRegister (raiseException machineRx 0 cpuPc)
                  Nothing ->
                    -- The cause and value of an instruction access fault are
                    -- written here whether or not it faults (nothing reads
                    -- them before another exception would overwrite them),
                    -- so Decode only chooses the phase.
                    let fetched =
                          machineRx
                            { cpuFetchSource = FromMemory,
                              cpuFetchFault = not (fetchable (decodeTarget cpuPc)),
                              cpuInRom = romAddress cpuPc,
                              cpuExceptionCause = 1,
                              cpuExceptionValue = cpuPc
                            }
                        phase =
                          if cpuCompressed
                            then FetchDelay
                            else case cpuFetchSource of
                              FromPrefetch | cpuPrefetchValid -> Decode
                              FromTarget | cpuTargetValid -> Decode
                              FromTarget | cpuTargetCount /= 0 -> FetchTargetWait
                              FromNext | cpuNextValid -> Decode
                              _ -> FetchDelay
                        word = case cpuFetchSource of
                          FromTarget -> cpuTargetWord
                          FromNext -> cpuNextInstruction
                          _ -> cpuPrefetchWord
                     in withoutRegister
                          ( fetched {cpuPhase = phase, cpuInstruction = word, cpuInstructionRaw = word, cpuInstructionSize = 4},
                            (0, Nothing, Nothing) -- the read: 'portAddress'
                          )
                FetchDelay -> next machineRx {cpuPhase = FetchCapture}
                -- (cpuTargetCount is 1 exactly when its word is on the bus)
                FetchTargetWait
                  | cpuTargetCount == 1 -> next machineRx {cpuPhase = Decode, cpuInstruction = memoryWord}
                  | cpuTargetValid -> next machineRx {cpuPhase = Decode, cpuInstruction = cpuTargetWord}
                  | cpuTargetCount /= 0 -> next machineRx
                  -- a store into the target dropped it: fetch it again
                  | otherwise -> next machineRx {cpuPhase = Fetch}
                FetchCapture -> next machineRx {cpuPhase = FetchWait}
                FetchWait -> next (captureInstruction decodeTarget machineRx memoryWord)
                FetchCross -> next machineRx {cpuPhase = FetchCrossDelay}
                FetchCrossDelay -> next machineRx {cpuPhase = FetchCrossCapture}
                FetchCrossCapture -> next machineRx {cpuPhase = FetchCrossWait}
                FetchCrossWait ->
                  let joined = ((memoryWord .&. 0xffff) `shiftL` 16) .|. resize cpuFetchHalf
                   in next machineRx {cpuPhase = Decode, cpuInstruction = joined, cpuInstructionRaw = joined, cpuInstructionSize = 4}
                -- A fetch fault only changes the phase (its cause and value
                -- were written at Fetch); the rest is harmless for a trap.
                Decode ->
                  withoutRegister
                    ( machineRx
                        { cpuPhase = if cpuFetchFault then Trap else OperandSelect,
                          cpuRegA = sharedRegA,
                          cpuRegB = sharedRegB,
                          cpuImm = decodeImmediate instruction,
                          cpuIsRegOp = instruction .&. 0x7f == 0x33,
                          cpuPrefetchAddress = cpuPc + 4,
                          cpuPrefetchValid = False,
                          cpuPrefetchCount = if cpuLocalMemory && not cpuCompressed then 3 else 0,
                          cpuPrefetchIssue = cpuLocalMemory && not cpuCompressed,
                          cpuNextValid = False
                        },
                      (0, Nothing, Nothing) -- the read of pc + 4: 'portAddress'
                    )
                OperandSelect ->
                  next
                    machineRx
                      { cpuPhase = Execute,
                        cpuA = cpuRegA,
                        cpuB = cpuRegB,
                        cpuOp2 = if cpuIsRegOp then cpuRegB else cpuImm,
                        cpuExecuteControl = decodeExecuteControl instruction
                      }
                Execute ->
                  next
                    machineRx
                      { cpuPhase = if execMulDiv cpuExecuteControl then MulDiv else ExecuteFinish,
                        cpuComputed = (compute cpuPc instruction cpuA cpuB cpuImm cpuOp2) {cLink = cpuPc + resize cpuInstructionSize, cAlu = Nothing, cTaken = Nothing},
                        cpuAluCompare = compareOperands cpuA cpuOp2,
                        cpuBranchCompare = compareOperands cpuA cpuB,
                        cpuAluCandidates = aluCandidates cpuExecuteControl cpuA cpuOp2,
                        cpuMulDiv = cpuMulDiv {mdStep = MdPrepare},
                        cpuStoreNow = False
                      }
                ExecuteFinish ->
                  let control = cpuExecuteControl
                      result
                        | execLui control = Just cpuImm
                        | execAuipc control = Just (cTarget cpuComputed)
                        | execAluOp control = selectedAlu control cpuAluCandidates cpuAluCompare
                        | otherwise = Nothing
                      -- The RAM port is free here (the prefetch read went out at
                      -- Decode). Loads and stores read their word; branches and
                      -- jumps read their target in case it is taken. The choice
                      -- comes from registered kind bits; whether the access is
                      -- really RAM (and may skip the bus) only gates Commit.
                      memoryOp = cpuLocalMemory && execMemory control
                      jump = cpuLocalMemory && not cpuCompressed && execJump control
                      fast = memoryOp && validMemoryAddress (cAddress cpuComputed)
                      store = execStore control
                      -- word addresses of two registers (a store that writes is
                      -- to RAM, so this is exact; memoryIndex would share the
                      -- memory-address output's mux)
                      sameWord a b = (a `xor` b) .&. complement 3 == 0
                      -- Decode-ahead for a plain ALU instruction whose next word
                      -- is on the bus now and in the same 2 KiB block (so just
                      -- as fetchable). All registered conditions: the read of
                      -- pc + 8 goes out whether or not the next one may start
                      -- early; the hazard check only sets cpuAhead.
                      plainAlu =
                        (execAluOp control || execLui control || execAuipc control)
                          && not (execShift control)
                          && not (execMulDiv control)
                      -- the next word is on the bus now (after a Decode), or
                      -- already in the prefetch buffer (in a chain of these)
                      onBus = cpuPrefetchCount == 1
                      ahead =
                        cpuLocalMemory
                          && not cpuCompressed
                          && plainAlu
                          && cpuPc
                          .&. 0x7fc
                          /= 0x7fc
                          && (onBus || (cpuPrefetchCount == 0 && cpuPrefetchValid))
                      nextWord = if onBus then memoryWord else cpuPrefetchWord
                      nextOpcode = nextWord .&. 0x7f
                      rd = instructionRd instruction
                      readsRs1 = nextOpcode /= 0x37 && nextOpcode /= 0x17 && nextOpcode /= 0x6f
                      readsRs2 = nextOpcode == 0x33 || nextOpcode == 0x23 || nextOpcode == 0x63
                      hazard =
                        rd
                          /= 0
                          && ((readsRs1 && instructionRs1 nextWord == rd) || (readsRs2 && instructionRs2 nextWord == rd))
                      decodedAhead m
                        | ahead =
                            m
                              { cpuNextInstruction = nextWord,
                                cpuNextValid = True,
                                cpuAhead = not hazard,
                                cpuPrefetchAddress = cpuPc + 8,
                                cpuPrefetchValid = False,
                                cpuPrefetchCount = 3,
                                cpuPrefetchIssue = True
                              }
                        | otherwise = m {cpuAhead = False}
                   in withoutRegister
                        ( decodedAhead
                            machineRx
                              { cpuPhase = if execShift control then ShiftFinish else Commit,
                                cpuComputed =
                                  cpuComputed
                                    { cAlu = result,
                                      cTaken = branchTakenPrepared (execFunct3 control) cpuBranchCompare
                                    },
                                cpuFastMemory = fast,
                                cpuPortIndex = ramWordIndex (cAddress cpuComputed),
                                cpuStoreData = storeLanes (execFunct3 control) (resize (cAddress cpuComputed)) cpuB,
                                cpuStoreMask = storeMask (execFunct3 control) (resize (cAddress cpuComputed)),
                                cpuStoreNow = fast && store && execFunct3 control == 2 && cAddress cpuComputed .&. 3 == 0,
                                cpuStoreHitsPrefetch = store && sameWord (cAddress cpuComputed) cpuPrefetchAddress,
                                cpuStoreHitsTarget = store && sameWord (cAddress cpuComputed) cpuTargetAddress,
                                cpuTargetAddress = if jump then cTarget cpuComputed else cpuTargetAddress,
                                cpuTargetValid = cpuTargetValid && not jump,
                                cpuTargetCount = if jump then 3 else cpuTargetCount
                              },
                          (0, Nothing, Nothing) -- the read: 'portAddress'
                        )
                ShiftFinish ->
                  let control = cpuExecuteControl
                      result =
                        fmap
                          ( \value ->
                              shiftResult
                                (execFunct3 control)
                                (if execArithmeticShift control then 0x20 else 0)
                                value
                                (fromIntegral (cpuOp2 .&. 0x1c))
                          )
                          (cAlu cpuComputed)
                   in next machineRx {cpuPhase = Commit, cpuComputed = cpuComputed {cAlu = result}}
                MulDiv ->
                  case mulDivStep (instructionFunct3 instruction) cpuA cpuB cpuMulDiv of
                    Left unit -> next machineRx {cpuMulDiv = unit}
                    Right result -> next machineRx {cpuPhase = Commit, cpuComputed = cpuComputed {cAlu = Just result}}
                Commit ->
                  let (committed, write, output) = commitInstruction machineRx txReady
                      retired = case committed of Machine {cpuPhase = Fetch} -> True; _ -> False
                      next' = cpuNextInstruction
                      early = cpuAhead && retired && case interruptCause machineRx of Nothing -> True; Just _ -> False
                      handed
                        -- the next instruction's Decode, here, and OperandSelect next
                        | early =
                            committed
                              { cpuPhase = OperandSelect,
                                cpuInstruction = next',
                                cpuRegA = sharedRegA,
                                cpuRegB = sharedRegB,
                                cpuImm = decodeImmediate next',
                                cpuIsRegOp = next' .&. 0x7f == 0x33,
                                cpuFetchFault = False,
                                cpuFetchSource = FromMemory,
                                cpuAhead = False,
                                cpuNextValid = False
                              }
                        -- the prefetch now holds pc + 8; Fetch takes the next word
                        | cpuNextValid && retired = committed {cpuFetchSource = FromNext, cpuAhead = False}
                        | otherwise = committed {cpuAhead = False}
                   in (handed, write, output)
                -- The fast path's word arrives three cycles after ExecuteFinish
                -- issued it: a load aligns it, a sub-word store merges into it.
                MemoryWait -> next machineRx {cpuPhase = MemoryCapture}
                MemoryCapture
                  | testBit instruction 5 ->
                      withoutRegister (finishInstruction machineRx {cpuPc = cLink cpuComputed, cpuFetchSource = FromPrefetch} Nothing)
                  | otherwise ->
                      withRegister
                        (instructionRd instruction)
                        (loadValue (instructionFunct3 instruction) (resize address) memoryWord)
                        (finishInstruction machineRx {cpuPc = cLink cpuComputed, cpuFetchSource = FromPrefetch} Nothing)
                Trap -> withoutRegister (enterTrap machineRx)
                CsrRead -> csrReadStep machineRx
                CsrWrite -> csrWriteStep machineRx
                TrapReturn -> withoutRegister (returnFromTrap machineRx)
                BusWait -> busWaitStep machineRx

withRegister :: Index 32 -> Word32 -> (Machine, StepOutput) -> (Machine, RegisterWrite, StepOutput)
withRegister index value (machine, output) = (machine, Just (index, value), output)

withoutRegister :: (Machine, StepOutput) -> (Machine, RegisterWrite, StepOutput)
withoutRegister (machine, output) = (machine, Nothing, output)

-- | Commit stage: act on the values the Execute stage computed.
commitInstruction :: Machine -> Bool -> (Machine, RegisterWrite, StepOutput)
commitInstruction committing _txReady =
  let -- a store into a buffered word drops that buffer before it writes
      machine =
        committing
          { cpuPrefetchValid = cpuPrefetchValid committing && not (cpuStoreHitsPrefetch committing),
            cpuTargetValid = cpuTargetValid committing && not (cpuStoreHitsTarget committing)
          }
      instruction = cpuInstruction machine
      Computed {..} = cpuComputed machine
      rd = instructionRd instruction
      funct3 = instructionFunct3 instruction
      nextPc = cLink
      normal = case cAlu of
        Just value -> withRegister rd value (finishInstruction machine {cpuPc = nextPc, cpuFetchSource = FromPrefetch} Nothing)
        Nothing -> invalid
      -- (FENCE, WFI: the next instruction is the prefetched one)
      noWrite newPc = withoutRegister (finishInstruction machine {cpuPc = newPc, cpuFetchSource = FromPrefetch} Nothing)
      jumpAndLink newPc
        | newPc .&. instructionAlignmentMask machine /= 0 = fault 0 newPc
        | otherwise = withRegister rd nextPc (finishInstruction machine {cpuPc = newPc, cpuFetchSource = FromTarget} Nothing)
      fault cause value = withoutRegister (raiseException machine cause value)
      invalid = fault 2 (originalInstruction machine)
      address = cAddress
      requestBus write =
        withoutRegister
          ( machine
              { cpuPhase = BusWait,
                cpuBusRequest = Just (BusRequest address funct3 write (cpuB machine))
              },
            (0, Nothing, Nothing)
          )
   in case execKind (cpuExecuteControl machine) of
        -- LUI, AUIPC, OP-IMM, OP (an illegal OP encoding has no result)
        KindAlu -> normal
        -- JAL, JALR
        KindJump -> jumpAndLink cTarget
        KindBranch ->
          case cTaken of
            Just True | cTarget .&. instructionAlignmentMask machine /= 0 -> fault 0 cTarget
            Just takeBranch ->
              withoutRegister
                ( finishInstruction
                    machine
                      { cpuPc = if takeBranch then cTarget else nextPc,
                        cpuFetchSource = if takeBranch then FromTarget else FromPrefetch
                      }
                    Nothing
                )
            Nothing -> invalid
        -- Validate the alignment before touching RAM or a device. Address
        -- misalignment takes priority over an out-of-map address.
        KindLoad
          | misalignedMemory funct3 address -> fault 4 address
          | cpuFastMemory machine -> withoutRegister (machine {cpuPhase = MemoryWait}, (0, Nothing, Nothing))
          | otherwise -> requestBus False
        KindStore
          | misalignedMemory funct3 address -> fault 6 address
          -- a word store writes at once; a byte or halfword waits for the word
          | cpuFastMemory machine && funct3 == 2 ->
              -- (the port writes from cpuStoreNow; see 'portWrite')
              withoutRegister (finishInstruction machine {cpuPc = nextPc, cpuFetchSource = FromPrefetch} Nothing)
          | cpuFastMemory machine -> withoutRegister (machine {cpuPhase = MemoryWait}, (0, Nothing, Nothing))
          | otherwise -> requestBus True
        -- FENCE is a no-op in this single-master core. FENCE.I fetches the
        -- next instruction from memory, not from a prefetch buffer. The
        -- other MISC-MEM encodings are reserved.
        KindFence -> noWrite nextPc
        KindFenceI -> withoutRegister (finishInstruction machine {cpuPc = nextPc, cpuFetchSource = FromMemory} Nothing)
        KindEcall -> fault 11 0 -- from M mode
        KindEbreak -> fault 3 (cpuPc machine)
        KindMret -> withoutRegister (machine {cpuPhase = TrapReturn}, (0, Nothing, Nothing))
        -- WFI waits in Commit until an interrupt is pending and enabled in
        -- mie (whether or not MIE is set).
        KindWfi -> if cpuWake machine then noWrite nextPc else withoutRegister (machine, (0, Nothing, Nothing))
        KindCsr ->
          withoutRegister
            ( machine
                { cpuPhase = CsrRead,
                  cpuCsrSelection = decodeCsrSelection (csrAddress instruction),
                  cpuCsrWrite = csrWriteRequested instruction,
                  cpuCsrReadOnly = csrAddress instruction == 0x301 || csrAddress instruction .&. 0xc00 == 0xc00,
                  cpuCsrSource =
                    if testBit funct3 2
                      then resize ((instruction `shiftR` 15) .&. 0x1f)
                      else cpuA machine
                },
              (0, Nothing, Nothing)
            )
        KindInvalid -> invalid

-- | Capture the exception without retiring, advancing PC, writing rd or issuing
-- a memory/UART request. The next stage owns the trap register write muxes.
raiseException :: Machine -> Word32 -> Word32 -> (Machine, StepOutput)
raiseException machine cause value =
  ( machine
      { cpuPhase = Trap,
        cpuExceptionCause = cause,
        cpuExceptionValue = value,
        cpuFetchSource = FromMemory,
        cpuAhead = False
      },
    (0, Nothing, Nothing)
  )

enterTrap :: Machine -> (Machine, StepOutput)
enterTrap machine =
  let regs = cpuTrapRegisters machine
      updated =
        regs
          { trapEpc = cpuPc machine .&. complement (instructionAlignmentMask machine),
            trapCause = cpuExceptionCause machine,
            trapValue = cpuExceptionValue machine,
            trapMpie = trapMie regs,
            trapMie = False
          }
      -- With mtvec still 0 this is the boot ROM, which reports the end of
      -- the program.
      trapped = machine {cpuTrapRegisters = updated, cpuPc = trapVector regs .&. complement 3, cpuPhase = Fetch}
   in (trapped, (0, Nothing, Nothing))

readCsr :: Unsigned 12 -> Machine -> Maybe (Word32, Bool)
readCsr address machine = case address of
  0x300 -> Just (0x1800 .|. (if trapMie regs then 8 else 0) .|. (if trapMpie regs then 0x80 else 0), False)
  0x301 -> Just (if cpuCompressed machine then 0x4000_1104 else 0x4000_1100, True) -- read-only RV32IM(C)
  0x304 -> Just (cpuInterruptEnable machine, False)
  0x305 -> Just (trapVector regs, False)
  0x310 -> Just (0, False) -- mstatush, all fields WARL zero
  0x340 -> Just (cpuScratch machine, False)
  0x341 -> Just (trapEpc regs, False)
  0x342 -> Just (trapCause regs, False)
  0x343 -> Just (trapValue regs, False)
  0x344 -> Just (pendingInterrupts (cpuDevices machine), False) -- mip; writes ignored
  0xb00 -> Just (counterLo (cpuCycle machine), False)
  0xb80 -> Just (counterHi (cpuCycle machine), False)
  0xb02 -> Just (counterLo (cpuInstret machine), False)
  0xb82 -> Just (counterHi (cpuInstret machine), False)
  0xc00 -> Just (counterLo (cpuCycle machine), True)
  0xc80 -> Just (counterHi (cpuCycle machine), True)
  0xc02 -> Just (counterLo (cpuInstret machine), True)
  0xc82 -> Just (counterHi (cpuInstret machine), True)
  0xf11 -> Just (0, True)
  0xf12 -> Just (0, True)
  0xf13 -> Just (0, True)
  0xf14 -> Just (0, True)
  _ -> Nothing
  where
    regs = cpuTrapRegisters machine

writeCsr :: Unsigned 12 -> Word32 -> Machine -> Machine
writeCsr address value machine = case address of
  0x300 -> machine {cpuTrapRegisters = regs {trapMie = testBit value 3, trapMpie = testBit value 7}}
  0x304 -> machine {cpuInterruptEnable = value .&. 0x888}
  0x305 -> machine {cpuTrapRegisters = regs {trapVector = value .&. complement 3}}
  0x340 -> machine {cpuScratch = value}
  0x341 -> machine {cpuTrapRegisters = regs {trapEpc = value .&. complement (instructionAlignmentMask machine)}}
  0x342 -> machine {cpuTrapRegisters = regs {trapCause = value}}
  0x343 -> machine {cpuTrapRegisters = regs {trapValue = value}}
  0xb00 -> counterWrite
  0xb80 -> counterWrite
  0xb02 -> counterWrite
  0xb82 -> counterWrite
  _ -> machine -- mstatush/mip writes are ignored; invalid access checked in CsrRead
  where
    regs = cpuTrapRegisters machine
    counterWrite = machine {cpuCounterWrite = Just (address, value)}

counterReadBusy :: Unsigned 12 -> Machine -> Bool
counterReadBusy address machine = case address of
  0xb00 -> cycleCarry
  0xb80 -> cycleCarry
  0xc00 -> cycleCarry
  0xc80 -> cycleCarry
  0xb02 -> instretCarry
  0xb82 -> instretCarry
  0xc02 -> instretCarry
  0xc82 -> instretCarry
  _ -> False
  where
    cycleCarry = counterCarry (cpuCycle machine)
    instretCarry = counterCarry (cpuInstret machine)

csrReadStep :: Machine -> (Machine, RegisterWrite, StepOutput)
csrReadStep machine =
  let instruction = cpuInstruction machine
      selection = cpuCsrSelection machine
      -- Even a refused/busy read may latch a temporary value. It is used only
      -- after successful completion, avoiding validity gates on the data mux.
      captured = machine {cpuCsrValue = readSelectedCsr selection machine}
      invalid = withoutRegister (raiseException captured 2 (originalInstruction machine))
      busy =
        ( (selection !! (8 :: Index 14) || selection !! (9 :: Index 14))
            && counterCarry (cpuCycle machine)
        )
          || ( (selection !! (10 :: Index 14) || selection !! (11 :: Index 14))
                 && counterCarry (cpuInstret machine)
             )
   in if not (or selection) || (cpuCsrReadOnly machine && cpuCsrWrite machine)
        then invalid
        else
          withoutRegister
            (captured {cpuPhase = if busy then CsrRead else CsrWrite}, (0, Nothing, Nothing))

readSelectedCsr :: Vec 14 Bool -> Machine -> Word32
readSelectedCsr selection machine =
  let regs = cpuTrapRegisters machine
      values =
        (0x1800 .|. (if trapMie regs then 8 else 0) .|. (if trapMpie regs then 0x80 else 0))
          :> (if cpuCompressed machine then 0x4000_1104 else 0x4000_1100)
          :> cpuInterruptEnable machine
          :> trapVector regs
          :> cpuScratch machine
          :> trapEpc regs
          :> trapCause regs
          :> trapValue regs
          :> counterLo (cpuCycle machine)
          :> counterHi (cpuCycle machine)
          :> counterLo (cpuInstret machine)
          :> counterHi (cpuInstret machine)
          :> 0
          :> pendingInterrupts (cpuDevices machine)
          :> Nil
   in fold (.|.) (zipWith (\selected value -> if selected then value else 0) selection values)

csrWriteStep :: Machine -> (Machine, RegisterWrite, StepOutput)
csrWriteStep machine =
  let instruction = cpuInstruction machine
      old = cpuCsrValue machine
      source = cpuCsrSource machine
      value = case instructionFunct3 instruction .&. 3 of
        1 -> source
        2 -> old .|. source
        _ -> old .&. complement source
      updated = if cpuCsrWrite machine then writeSelectedCsr (cpuCsrSelection machine) value machine else machine
   in withRegister
        (instructionRd instruction)
        old
        (finishInstruction updated {cpuPc = cLink (cpuComputed machine), cpuFetchSource = FromPrefetch} Nothing)

-- | 'writeCsr' by the registered one-hot selection rather than the address:
-- the read stage has already refused read-only and unknown CSRs, so a
-- counter selected here is the machine-mode (0xb..) one.
writeSelectedCsr :: Vec 14 Bool -> Word32 -> Machine -> Machine
writeSelectedCsr selection value machine =
  let regs = cpuTrapRegisters machine
      chosen i = selection !! (i :: Index 14)
      counter
        | chosen 8 = Just (0xb00, value)
        | chosen 9 = Just (0xb80, value)
        | chosen 10 = Just (0xb02, value)
        | chosen 11 = Just (0xb82, value)
        | otherwise = Nothing
   in machine
        { cpuTrapRegisters =
            regs
              { trapMie = if chosen 0 then testBit value 3 else trapMie regs,
                trapMpie = if chosen 0 then testBit value 7 else trapMpie regs,
                trapVector = if chosen 3 then value .&. complement 3 else trapVector regs,
                trapEpc = if chosen 5 then value .&. complement (instructionAlignmentMask machine) else trapEpc regs,
                trapCause = if chosen 6 then value else trapCause regs,
                trapValue = if chosen 7 then value else trapValue regs
              },
          cpuInterruptEnable = if chosen 2 then value .&. 0x888 else cpuInterruptEnable machine,
          cpuScratch = if chosen 4 then value else cpuScratch machine,
          cpuCounterWrite = counter
        }

returnFromTrap :: Machine -> (Machine, StepOutput)
returnFromTrap machine =
  let regs = cpuTrapRegisters machine
   in finishInstruction
        machine
          { cpuPc = trapEpc regs,
            cpuTrapRegisters = regs {trapMie = trapMpie regs, trapMpie = True}
          }
        Nothing

finishInstruction :: Machine -> Maybe (MemAddr, Word32) -> (Machine, StepOutput)
finishInstruction machine write = finishWith machine write Nothing

finishInstructionWithTx :: Machine -> Maybe Byte -> (Machine, StepOutput)
finishInstructionWithTx machine request = finishWith machine Nothing request

-- | Retire an instruction.  The next fetch starts in the Fetch stage from the
-- PC register, a cycle after any write here, so it always sees the new word.
-- Whether that PC has left the program is checked in 'cpuStep'.
finishWith :: Machine -> Maybe (MemAddr, Word32) -> Maybe Byte -> (Machine, StepOutput)
finishWith machine write request = (machine {cpuPhase = Fetch, cpuCountRetirement = True}, (0, write, request))

-- Split the physical 32-way mux across two clock edges. Each first-stage
-- register sees eight candidates; the operand register then sees four banks.

-- | Where the register file is read this cycle: rs1 and rs2 of the
-- instruction being decoded, the instruction register's (Decode) or, at
-- Commit, the captured next word's (decode-ahead).
registerReads :: Machine -> (Index 32, Index 32)
registerReads machine =
  let word
        | cpuFast machine = maybe 0 fWord (pD (cpuPipe machine))
        | cpuLocalMemory machine = case cpuPhase machine of Commit -> cpuNextInstruction machine; _ -> cpuInstruction machine
        | otherwise = cpuInstruction machine
   in (instructionRs1 word, instructionRs2 word)

-- | A register file output, or 0 for a register not written since reset.
registerValue :: BitVector 32 -> Index 32 -> Word32 -> Word32
registerValue valid index value = if testBit valid (fromIntegral index) then value else 0

-- | The simulation's register file: inject the mirror's values at
-- 'registerReads'.
withMirrorReads :: Machine -> Machine
withMirrorReads machine =
  let (a, b) = if cpuPipelined machine then cpuReadIndices machine else registerReads machine
   in machine {cpuRfA = cpuRegs machine !! a, cpuRfB = cpuRegs machine !! b}

readRegisterBanks :: Index 32 -> Vec 32 Word32 -> Vec 4 Word32
readRegisterBanks index regs = map (!! bankOffset) (unconcat (SNat @8) regs)
  where
    bankOffset = fromIntegral (fromIntegral index .&. 7 :: Unsigned 5) :: Index 8

selectRegisterBank :: Index 32 -> Vec 4 Word32 -> Word32
selectRegisterBank 0 _ = 0
selectRegisterBank index banks = banks !! (fromIntegral (fromIntegral index `shiftR` 3 :: Unsigned 5) :: Index 4)

readRegister :: Index 32 -> Machine -> Word32
readRegister 0 _ = 0
readRegister index Machine {..} = cpuRegs !! index

writeRegister :: Index 32 -> Word32 -> Machine -> Machine
writeRegister 0 _ machine = machine
writeRegister index value machine@Machine {..} =
  machine {cpuRegs = replace index value cpuRegs, cpuRegValid = setBit cpuRegValid (fromIntegral index)}
