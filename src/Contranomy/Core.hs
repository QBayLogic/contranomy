{-|
Copyright  :  (C) 2020, Christiaan Baaij
License    :  BSD2 (see the file LICENSE)
Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TemplateHaskell #-}

module Contranomy.Core (core) where

import Data.Maybe

import Clash.Class.AutoReg as AutoReg
import qualified Clash.Explicit.Prelude as Explicit
import Clash.Prelude hiding (cycle, select)

import Contranomy.Clash.Extra
import Contranomy.Decode
import Contranomy.Encode
import Contranomy.RV32IM
import Contranomy.RVFI
import Contranomy.WishBone

data CoreStage
  = InstructionFetch
  | Execute
  deriving (Generic, NFDataX, AutoReg)

data MStatus
  = MStatus
  { mie :: Bool
  , mpie :: Bool
  }
  deriving (Generic, NFDataX)

deriveAutoReg ''MStatus

data MCause
  = MCause
  { interrupt :: Bool
  , code :: BitVector 4
  }
  deriving (Generic, NFDataX)

deriveAutoReg ''MCause

data CoreState
  = CoreState
  { stage :: CoreStage
  , pc :: Unsigned 32
  , instruction :: Instr
  , registers :: Vec 34 (BitVector 32)
  , mstatus :: MStatus
  , mieMtie :: Bool
  , mcause :: MCause
  , rvfiOrder :: BitVector 64
  }
  deriving (Generic, NFDataX)

pattern MTVEC_LOCATION, MSCRATCH_LOCATION, MEPC_LOCATION, MTVAL_LOCATION :: Index 34
pattern MTVEC_LOCATION = 31
pattern MSCRATCH_LOCATION = 32
pattern MEPC_LOCATION = 33
pattern MTVAL_LOCATION = 34

instance AutoReg CoreState where
  autoReg clk rst ena CoreState{stage,pc,instruction,registers,mstatus,mieMtie,mcause,rvfiOrder} = \inp ->
    let fld1 = (\CoreState{stage=f} -> f) <$> inp
        fld2 = (\CoreState{pc=f} -> f) <$> inp
        fld3 = (\CoreState{instruction=f} -> f) <$> inp
        fld4 = (\CoreState{registers=f} -> f) <$> inp
        fld5 = (\CoreState{mstatus=f} -> f) <$> inp
        fld6 = (\CoreState{mieMtie=f} -> f) <$> inp
        fld7 = (\CoreState{mcause=f} -> f) <$> inp
        fld8 = (\CoreState{rvfiOrder=f} -> f) <$> inp
    in  CoreState
           <$> setName @"stage" AutoReg.autoReg clk rst ena stage fld1
           <*> setName @"pc" AutoReg.autoReg clk rst ena pc fld2
           <*> setName @"instruction" AutoReg.autoReg clk rst ena instruction fld3
           <*> setName @"registers" Explicit.register clk rst ena registers fld4
           <*> setName @"mstatus" Explicit.register clk rst ena mstatus fld5
           <*> setName @"mie_mtie" Explicit.register clk rst ena mieMtie fld6
           <*> setName @"mcause" Explicit.register clk rst ena mcause fld7
           <*> setName @"rvfiOrder" AutoReg.autoReg clk rst ena rvfiOrder fld8
  {-# INLINE autoReg #-}

core ::
  HiddenClockResetEnable dom =>
  ( Signal dom (WishBoneS2M 4)
  , Signal dom (WishBoneS2M 4) ) ->
  ( Signal dom (WishBoneM2S 4 30)
  , Signal dom (WishBoneM2S 4 32)
  , Signal dom RVFI
  )
core = mealyAutoB transition cpuStart
 where
  cpuStart
    = CoreState
    { stage = InstructionFetch
    , pc = 0
    , instruction = noop
    , registers = deepErrorX "undefined"
    , mstatus = MStatus { mie = False, mpie = False}
    , mieMtie = False
    , mcause = MCause { interrupt = False, code = 0 }
    , rvfiOrder = 0
    }

transition ::
  CoreState ->
  ( WishBoneS2M 4, WishBoneS2M 4 ) ->
  ( CoreState
  , ( WishBoneM2S 4 30
    , WishBoneM2S 4 32
    , RVFI ))
transition s@(CoreState { stage = InstructionFetch, pc }) (iBus,_)
  = ( s { stage = if acknowledge iBus then
                    Execute
                  else
                    InstructionFetch
        , instruction = decodeInstruction (readData iBus)
        }
    , ( (defM2S @4 @30)
               { addr   = slice d31 d2 pc
               , cycle  = True
               , strobe = True
               }
      , defM2S
      , defRVFI ) )

transition s@(CoreState { stage = Execute, instruction, pc, registers, mstatus, mieMtie, mcause, rvfiOrder }) (_,dBusS2M)
  =
  let registers0 = 0 :> registers

      dstReg = case instruction of
        RRInstr (RInstr {dest}) -> Just dest
        RIInstr iinstr -> case iinstr of
          IInstr {dest} -> Just dest
          ShiftInstr {dest} -> Just dest
          LUI {dest} -> Just dest
          AUIPC {dest} -> Just dest
        CSRInstr csrInstr -> case csrInstr of
          CSRRInstr {dest} -> Just dest
          CSRIInstr {dest} -> Just dest
        MemoryInstr minstr -> case minstr of
          LOAD {dest} | acknowledge dBusS2M -> Just dest
          _ -> Nothing
        JumpInstr jinstr -> case jinstr of
          JAL {dest} -> Just dest
          JALR {dest} -> Just dest
        _ -> Nothing

      aluResult = case instruction of
        RRInstr (RInstr {opcode,src1,src2}) ->
          let arg1 = registers0 !! src1
              arg2 = registers0 !! src2
              shiftAmount = unpack (resize (slice d4 d0 arg2))
          in case opcode of
            ADD -> arg1 + arg2
            SUB -> arg1 - arg2
            SLT -> if (unpack arg1 :: Signed 32) < unpack arg2 then
                     1
                   else
                     0
            SLTU -> if arg1 < arg2 then
                      1
                    else
                      0
            AND -> arg1 .&. arg2
            OR -> arg1 .|. arg2
            XOR -> arg1 `xor` arg2
            SLL -> shiftL arg1 shiftAmount
            SRL -> shiftR arg1 shiftAmount
            SRA -> pack (shiftR (unpack arg1 :: Signed 32) shiftAmount)
#if !defined(RISCV_FORMAL_ALTOPS)
            MUL -> arg1 * arg2
            MULH -> slice d63 d32 (signExtend arg1 * signExtend arg2 :: BitVector 64)
            MULHSU -> slice d63 d32 (signExtend arg1 * zeroExtend arg2 :: BitVector 64)
            MULHU -> slice d63 d32 (zeroExtend arg1 * zeroExtend arg2 :: BitVector 64)
            DIV -> if arg2 == 0 then
                     (-1)
                   else if arg1 == pack (minBound :: Signed 32) && arg2 == (-1) then
                     pack (minBound :: Signed 32)
                   else
                     pack ((unpack arg1 :: Signed 32) `quot` unpack arg2)
            DIVU -> if arg2 == 0 then
                      (-1)
                    else
                      arg1 `quot` arg2
            REM -> if arg2 == 0 then
                     arg1
                   else if arg1 == pack (minBound :: Signed 32) && arg2 == (-1) then
                     0
                   else
                     pack ((unpack arg1 :: Signed 32) `rem` unpack arg2)
            REMU -> if arg2 == 0 then
                      arg1
                    else
                      arg1 `rem` arg2
#else
            MUL -> (arg1 + arg2) `xor` 0x2cdf52a55876063e
            MULH -> (arg1 + arg2) `xor` 0x15d01651f6583fb7
            MULHSU -> (arg1 - arg2) `xor` 0xea3969edecfbe137
            MULHU -> (arg1 + arg2) `xor` 0xd13db50d949ce5e8
            DIV -> (arg1 - arg2) `xor` 0x29bbf66f7f8529ec
            DIVU -> (arg1 - arg2) `xor` 0x8c629acb10e8fd70
            REM -> (arg1 - arg2) `xor` 0xf5b7d8538da68fa5
            REMU -> (arg1 - arg2) `xor` 0xbc4402413138d0e1
#endif
        RIInstr iinstr -> case iinstr of
          IInstr {iOpcode,src,imm12} ->
            let arg1 = registers0 !! src
                arg2 = signExtend imm12
            in case iOpcode of
              ADDI -> arg1 + arg2
              SLTI -> if (unpack arg1 :: Signed 32) < unpack arg2 then
                        1
                      else
                        0
              SLTIU -> if arg1 < arg2 then
                         1
                       else
                         0
              XORI -> arg1 `xor` arg2
              ORI -> arg1 .|. arg2
              ANDI -> arg1 .&. arg2
          ShiftInstr {sOpcode,src,shamt} ->
            let arg1 = registers0 !! src
                shiftAmount = unpack (resize shamt)
            in case sOpcode of
              SLLI -> shiftL arg1 shiftAmount
              SRLI -> shiftR arg1 shiftAmount
              SRAI -> pack (shiftR (unpack arg1 :: Signed 32) shiftAmount)
          LUI {imm20} ->
            imm20 ++# 0
          AUIPC {imm20} ->
            pack pc + (imm20 ++# 0)
        CSRInstr csrInstr -> case csr csrInstr of
          MSTATUS -> shiftL (boolToBitVector (mpie mstatus)) 7 .|.
                     shiftL (boolToBitVector (mie mstatus)) 3
          MIE -> shiftL (boolToBitVector mieMtie) 7
          MTVEC -> registers !! MTVEC_LOCATION
          MSCRATCH -> registers !! MSCRATCH_LOCATION
          MEPC -> registers !! MEPC_LOCATION
          MCAUSE -> pack (interrupt mcause) ++# 0 ++# code mcause
          MTVAL -> registers !! MTVAL_LOCATION
          _ -> 0

        MemoryInstr minstr -> case minstr of
          LOAD {loadWidth} -> case loadWidth of
            Width Byte -> signExtend (slice d7 d0 (readData dBusS2M))
            Width Half -> signExtend (slice d15 d0 (readData dBusS2M))
            HalfUnsigned -> zeroExtend (slice d15 d0 (readData dBusS2M))
            ByteUnsigned -> zeroExtend (slice d7 d0 (readData dBusS2M))
            _ -> readData dBusS2M
          _ -> 0
        JumpInstr {} -> pack (pc + 4)
        _ -> 0

      pcN0 = case instruction of
        BranchInstr (Branch {imm,cond,src1,src2}) ->
          let arg1 = registers0 !! src1
              arg2 = registers0 !! src2
              taken = case cond of
                BEQ -> arg1 == arg2
                BNE -> arg1 /= arg2
                BLT -> (unpack arg1 :: Signed 32) < unpack arg2
                BLTU -> arg1 < arg2
                BGE -> (unpack arg1 :: Signed 32) >= unpack arg2
                BGEU -> arg1 >= arg2
          in if taken then
               pc + unpack (signExtend imm `shiftL` 1)
             else
               pc + 4
        JumpInstr jinstr -> case jinstr of
          JAL {imm} ->
            pc + unpack (signExtend imm `shiftL` 1)
          JALR {offset,base} ->
            unpack (slice d31 d1 (registers0 !! base + signExtend offset) ++# 0)
        MemoryInstr {} | not (acknowledge dBusS2M) -> pc
        _ -> pc+4

      branchTrap = slice d1 d0 pcN0 /= 0
      pcN1 = if branchTrap then 0 else pcN0

      dBusM2S = case instruction of
        MemoryInstr minstr -> case minstr of
          LOAD {loadWidth,offset,base} ->
            (defM2S @4 @32)
              { addr   = registers0 !! base + signExtend offset
              , select = loadWidthSelect loadWidth
              , cycle  = True
              , strobe = True
              }
          STORE {width,offset,src,base} ->
            (defM2S @4 @32)
              { addr = registers0 !! base + signExtend offset
              , writeData = registers0 !! src
              , select = loadWidthSelect (Width width)
              , cycle = True
              , strobe = True
              , writeEnable = True
              }
        _ -> defM2S
  in
    ( s { stage = case instruction of
            MemoryInstr {}
              | not (acknowledge dBusS2M)
              -> Execute
            _ -> InstructionFetch
        , pc = pcN1
        , registers = case dstReg of
            Just dst -> tail (replace dst aluResult registers0)
            Nothing  -> registers
        , rvfiOrder = case instruction of
            MemoryInstr {}
              | not (acknowledge dBusS2M)
              -> rvfiOrder
            _ -> rvfiOrder + 1
        }
    , ( defM2S
      , dBusM2S
      , toRVFI rvfiOrder
               instruction
               (take d32 registers0)
               dstReg
               aluResult
               pc
               pcN1
               branchTrap
               dBusM2S
               dBusS2M
      ) )

loadWidthSelect :: LoadWidth -> BitVector 4
loadWidthSelect lw = case lw of
  Width Byte -> 0b0001
  Width Half -> 0b0011
  Width Word -> 0b1111
  HalfUnsigned -> 0b0011
  ByteUnsigned -> 0b0001
{-# INLINE loadWidthSelect #-}

toRVFI ::
  -- | Instruction index
  BitVector 64 ->
  -- | Current decoded instruction
  Instr ->
  -- | Registers
  Vec 32 (BitVector 32) ->
  -- | Destination register
  Maybe Register ->
  -- | Destination register write data
  BitVector 32 ->
  -- | Current PC
  Unsigned 32 ->
  -- | Next PC
  Unsigned 32 ->
  -- | Trap
  Bool ->
  -- | Data Bus M2S
  WishBoneM2S 4 32 ->
  -- | Data Bus S2M
  WishBoneS2M 4 ->
  RVFI
toRVFI rOrder instruction registers0 dstReg aluResult pc pcN branchTrap dBusM2S dBusS2M =
  let rs1AddrN = case instruction of
                   BranchInstr (Branch {src1}) -> src1
                   CSRInstr (CSRRInstr {src}) -> src
                   JumpInstr (JALR {base}) -> base
                   MemoryInstr (LOAD {base}) -> base
                   MemoryInstr (STORE {base}) -> base
                   RRInstr (RInstr {src1}) -> src1
                   RIInstr (IInstr {src}) -> src
                   RIInstr (ShiftInstr {src}) -> src
                   _ -> X0

      rs2AddrN = case instruction of
                   BranchInstr (Branch {src2}) -> src2
                   MemoryInstr (STORE {src}) -> src
                   RRInstr (RInstr {src2}) -> src2
                   _ -> X0
  in  defRVFI
        { valid = case instruction of
            MemoryInstr {} -> acknowledge dBusS2M
            _ -> True
        , order    = rOrder
        , insn     = encodeInstruction instruction
        , trap     = branchTrap
        , rs1Addr  = rs1AddrN
        , rs2Addr  = rs2AddrN
        , rs1RData = registers0 !! pack rs1AddrN
        , rs2RData = registers0 !! pack rs2AddrN
        , rdAddr   = fromMaybe X0 dstReg
          -- Since we take the tail for the written to registers, this is okay
        , rdWData  = case fromMaybe X0 dstReg of
                       X0 -> 0
                       _ -> aluResult
        , pcRData  = pc
        , pcWData  = pcN
        , memAddr  = addr dBusM2S
        , memRMask = if strobe dBusM2S && not (writeEnable dBusM2S) then
                       select dBusM2S
                     else
                       0
        , memWMask = if strobe dBusM2S && writeEnable dBusM2S then
                       select dBusM2S
                     else
                       0
        , memRData = if strobe dBusM2S && not (writeEnable dBusM2S) then
                       readData dBusS2M
                     else
                       0
        , memWData = if strobe dBusM2S && writeEnable dBusM2S then
                       writeData dBusM2S
                     else
                       0
        }
