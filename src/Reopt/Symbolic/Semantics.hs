------------------------------------------------------------------------
-- |
-- Module           : Reopt.Symbolic.Semantics
-- Description      : Instance for Reopt.Semantics.Monad.Semantics that
--                    produces crucible app datatypes.
-- Copyright        : (c) Galois, Inc 2015
-- Maintainer       : Michael Hueschen <mhueschen@galois.com>
-- Stability        : provisional
--
------------------------------------------------------------------------
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-} -- MaybeF
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}

module Reopt.Symbolic.Semantics
       ( execSemantics
       , ppStmts
       , gimmeCFG
       , gen1
       , gen2
       , module Lang.Crucible.FunctionHandle
       , argTypes
       , retType
       ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<*>), pure, Applicative)
#endif
import           Control.Arrow ((***))
import           Control.Exception (assert)
import           Control.Lens
import           Control.Monad.Cont
import           Control.Monad.Reader
import           Control.Monad.State.Strict
import           Control.Monad.ST
import           Control.Monad.Writer
  (censor, execWriterT, listen, tell, MonadWriter, WriterT)
import           Data.Binary.IEEE754
import           Data.Bits
import           Data.BitVector (BV)
import qualified Data.BitVector as BV
import qualified Data.Foldable as Fold
import           Data.Functor
import           Data.IORef
import           Data.Maybe
import           Data.Monoid (mempty)
import           Data.Parameterized.Classes (OrderingF(..), OrdF, compareF, fromOrdering)
import           Data.Parameterized.Context
import           Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.NatRepr
import           Data.Parameterized.Some
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Text as Text
import qualified Data.Vector as V
import           Text.PrettyPrint.ANSI.Leijen
  ((<>), (<+>), colon, indent, line, parens, pretty, text, tupled, vsep, Doc, Pretty(..))

import           Data.Word
import           GHC.Float (float2Double, double2Float)
import           GHC.TypeLits
import           Numeric (showHex)

import qualified Flexdis86 as Flexdis
import qualified Lang.Crucible.Core as C
import           Lang.Crucible.FunctionHandle
import qualified Lang.Crucible.Generator as G
import           Lang.Crucible.ProgramLoc
import           Lang.Crucible.Simulator.Evaluation
import           Lang.Crucible.Simulator.RegMap
import           Lang.Crucible.Solver.Interface
import           Lang.Crucible.Solver.SimpleBuilder
import           Lang.Crucible.Solver.SimpleBackend
import           Lang.Crucible.SSAConversion (toSSA)
import           Reopt.Object.Memory
import           Reopt.Semantics.FlexdisMatcher (execInstruction)
import           Reopt.Semantics.Monad
  ( Type(..)
  , TypeRepr(..)
  , BoolType
  , bvLit
  )
import qualified Reopt.Semantics.Monad as S
import qualified Reopt.CFG.Representation as R
import qualified Reopt.Machine.StateNames as N
import           Reopt.Machine.Types ( FloatInfo(..), FloatInfoRepr, FloatType
                                     , TypeBits, floatInfoBits, n32, type_width
                                     )

------------------------------------------------------------------------
-- Expr
--
-- The 'Expr' data type and width related functions are copied from /
-- based on 'Reopt.Semantics.Implementation'. We need a different
-- 'IsValue' instance, so we duplicate these definitions here, and
-- extend them where the 'App' constructors are inadequate.
--
-- To reuse more 'Expr' code directly, an alternative approach would
-- be to add another type index to 'Expr' or the 'IsValue' class.  Of
-- course, we'll want the 'Expr' pretty printer down the road, so
-- maybe the indexing is inevitable? But then we need to make the
-- 'App' constructors more uniform, eliminating the need for extra
-- constructors below in our version 'Expr'.


-- | Variables and corresponding instances
data Variable tp = Variable !(TypeRepr tp) !Name
type Name = String

instance TestEquality Variable where
  (Variable tp1 n1) `testEquality` (Variable tp2 n2) = do
    Refl <- testEquality tp1 tp2
    return Refl

instance MapF.OrdF Variable where
  (Variable tp1 n1) `compareF` (Variable tp2 n2) =
    case (tp1 `compareF` tp2, n1 `compare` n2) of
      (LTF,_) -> LTF
      (GTF,_) -> GTF
      (EQF,o) -> fromOrdering o


-- | A pure expression for isValue.
data Expr tp where
  -- An expression obtained from some value.
  LitExpr :: !(NatRepr n) -> Integer -> Expr (BVType n)
  -- An expression that is computed from evaluating subexpressions.
  AppExpr :: !(R.App Expr tp) -> Expr tp

  -- Extra constructors where 'App' does not provide what we want.
  --
  -- Here 'App' has 'Trunc', but its type is different; see notes at
  -- bottom of file.
  TruncExpr :: (1 <= m, m <= n) =>
    !(NatRepr m) -> !(Expr (BVType n)) -> Expr (BVType m)
  -- Here 'app' has 'SExt', but its type is different as with 'Trunc'.
  -- But, strangely, the strict version of 'uext' is in the 'IsValue'
  -- class as 'uext'', so we can use 'App's 'UExt' there ... seems ad
  -- hoc.
  SExtExpr :: (1 <= m, m <= n) =>
    !(NatRepr n) -> !(Expr (BVType m)) -> Expr (BVType n)
  --
  -- A variable.
  -- Not doing anything fancy with names for now; can use 'unbound'
  -- later.
  VarExpr :: Variable tp -> Expr tp

mkLit :: NatRepr n -> Integer -> Expr (BVType n)
mkLit n v = LitExpr n (v .&. mask)
  where mask = maxUnsigned n

app :: R.App Expr tp -> Expr tp
app = AppExpr

exprType :: Expr tp -> S.TypeRepr tp
exprType (LitExpr r _) = S.BVTypeRepr r
exprType (AppExpr a) = R.appType a
exprType (TruncExpr r _) = S.BVTypeRepr r
exprType (SExtExpr r _) = S.BVTypeRepr r
exprType (VarExpr (Variable r _)) = r -- S.BVTypeRepr r

-- | Return width of expression.
exprWidth :: Expr (BVType n) -> NatRepr n
exprWidth e =
  case exprType e of
    S.BVTypeRepr n -> n

-- In this instance we don't override the default implementations. If
-- we wanted to, we'd have to extend the 'App' type with the
-- corresponding constructors, or add them to 'Expr' above.
instance S.IsValue Expr where
  bv_width = exprWidth
  mux c x y = app $ R.Mux (exprWidth x) c x y
  bvLit n v = mkLit n (toInteger v)
  bvAdd x y = app $ R.BVAdd (exprWidth x) x y
  bvSub x y = app $ R.BVSub (exprWidth x) x y
  bvMul x y = app $ R.BVMul (exprWidth x) x y
  complement x = app $ R.BVComplement (exprWidth x) x
  x .&. y = app $ R.BVAnd (exprWidth x) x y
  x .|. y = app $ R.BVOr (exprWidth x) x y
  bvXor x y = app $ R.BVXor (exprWidth x) x y
  x .=. y = app $ R.BVEq x y
  bvSplit :: forall n. (1 <= n)
          => Expr (BVType (n + n))
          -> (Expr (BVType n), Expr (BVType n))
  bvSplit v = withAddPrefixLeq hn hn ( app (R.UpperHalf hn v)
                                     , TruncExpr        hn v)
    where hn = halfNat (exprWidth v) :: NatRepr n
  bvShr x y = app $ R.BVShr (exprWidth x) x y
  bvSar x y = app $ R.BVSar (exprWidth x) x y
  bvShl x y = app $ R.BVShl (exprWidth x) x y
  bvTrunc w x = TruncExpr w x
  bvUlt x y = app $ R.BVUnsignedLt x y
  bvSlt x y = app $ R.BVSignedLt x y
  bvBit x y = app $ R.BVBit x y
  sext w x = SExtExpr w x
  uext' w x = app $ R.UExt x w
  even_parity x = app $ R.EvenParity x
  reverse_bytes x = app $ R.ReverseBytes (exprWidth x) x
  uadc_overflows x y c = app $ R.UadcOverflows (exprWidth x) x y c
  sadc_overflows x y c = app $ R.SadcOverflows (exprWidth x) x y c
  usbb_overflows x y c = app $ R.UsbbOverflows (exprWidth x) x y c
  ssbb_overflows x y c = app $ R.SsbbOverflows (exprWidth x) x y c
  bsf x = app $ R.Bsf (exprWidth x) x
  bsr x = app $ R.Bsr (exprWidth x) x
  isQNaN rep x = app $ R.FPIsQNaN rep x
  isSNaN rep x = app $ R.FPIsSNaN rep x
  fpAdd rep x y = app $ R.FPAdd rep x y
  fpAddRoundedUp rep x y = app $ R.FPAddRoundedUp rep x y
  fpSub rep x y = app $ R.FPSub rep x y
  fpSubRoundedUp rep x y = app $ R.FPSubRoundedUp rep x y
  fpMul rep x y = app $ R.FPMul rep x y
  fpMulRoundedUp rep x y = app $ R.FPMulRoundedUp rep x y
  fpDiv rep x y = app $ R.FPDiv rep x y
  fpLt rep x y = app $ R.FPLt rep x y
  fpEq rep x y = app $ R.FPEq rep x y
  fpCvt src tgt x = app $ R.FPCvt src x tgt
  fpCvtRoundsUp src tgt x = app $ R.FPCvtRoundsUp src x tgt
  fpFromBV tgt x = app $ R.FPFromBV x tgt
  truncFPToSignedBV tgt src x = app $ R.TruncFPToSignedBV src x tgt

-- ??? Why do the 'App' constructors take a 'NatRepr' argument? It can
-- always be reconstructed by the user using 'bv_width' after
-- unpacking, no?

-- ??? Why do 'Trunc' and 'bvTrunc' have slightly different constraints?
-- 'Trunc   :: (1 <= n, n+1 <= m) => ...'
-- 'bvTrunc :: (1 <= n, n   <= m) => ...'
--
-- Answer: because 'Trunc' is only used for *strict* truncations. The
-- 'testStrictLeq' function in
-- reopt.git/deps/parameterized-utils/src/Data/Parameterized/NatRepr.hs
-- is used to turn a proof of 'm <= n' into a proof of 'm < n \/ m =
-- n' and 'Trunc' is only used in cases where 'm < n', i.e. 'm+1 <=
-- n'.

-- ??? Why does 'bvTrunc' take a 'NatRepr' argument?
--
-- Answer: because it specifies the return type. Same with 'sext' and
-- 'uext'.

-- ??? Why does 'Trunc' take it's 'NatRepr' argument second? (Nearly?)
-- all the other 'NatRepr' args come first in 'App' constructors.

-- TODO: rename for consistency:
--
-- - complement -> bvComplement
-- - Trunc -> BVTrunc

------------------------------------------------------------------------
-- Statements.

type MLocation = S.Location (Expr (BVType 64))

data NamedStmt where
  MakeUndefined :: TypeRepr tp -> NamedStmt
  Get :: MLocation tp -> NamedStmt
  BVDiv :: (1 <= n)
        => Expr (BVType (n+n))
        -> Expr (BVType n)
        -> NamedStmt
  BVSignedDiv :: (1 <= n)
              => Expr (BVType (n+n))
              -> Expr (BVType n)
              -> NamedStmt
  MemCmp :: Integer
         -> Expr (BVType 64)
         -> Expr (BVType 64)
         -> Expr (BVType 64)
         -> Expr BoolType
         -> NamedStmt

-- | Potentially side-effecting operations, corresponding the to the
-- 'S.Semantics' class.
data Stmt where
  -- | Bind the results of a statement to names.
  --
  -- Some statements, e.g. 'bvDiv', return multiple results, so we
  -- bind a list of 'Name's here.
  NamedStmt :: [Name] -> NamedStmt -> Stmt

  -- The remaining constructors correspond to the 'S.Semantics'
  -- operations; the arguments are documented there and in
  -- 'Reopt.CFG.Representation.Stmt'.
  (:=) :: MLocation tp -> Expr tp -> Stmt
  Ifte_ :: Expr BoolType -> [Stmt] -> [Stmt] -> Stmt
  MemCopy :: Integer
          -> Expr (BVType 64)
          -> Expr (BVType 64)
          -> Expr (BVType 64)
          -> Expr BoolType
          -> Stmt
  MemSet :: Expr (BVType 64) -> Expr (BVType n) -> Expr (BVType 64) -> Stmt
  Exception :: Expr BoolType
            -> Expr BoolType
            -> S.ExceptionClass
            -> Stmt
  X87Push :: Expr (S.FloatType X86_80Float) -> Stmt
  X87Pop  :: Stmt

------------------------------------------------------------------------
-- Semantics monad instance.

-- | An 'S.Semantics' monad.
--
-- We collect effects in a 'Writer' and use 'State' to generate fresh
-- names.
newtype Semantics a =
  Semantics { runSemantics :: WriterT [Stmt] (State Integer) a }
  deriving (Functor, Applicative, Monad, MonadState Integer, MonadWriter [Stmt])

-- | Execute a 'Semantics' computation, returning its effects.
execSemantics :: Semantics a -> [Stmt]
execSemantics = flip evalState 0 . execWriterT . runSemantics

type instance S.Value Semantics = Expr

-- | Generate a fresh variable with basename 'basename'.
fresh :: MonadState Integer m => String -> m String
fresh basename = do
  x <- get
  put (x + 1)
  return $ basename ++ show x


-- FIXME: Move
addIsLeqLeft1' :: forall f g n m. LeqProof (n + n) m ->
                  f (BVType n) -> g m
                  -> LeqProof n m
addIsLeqLeft1' prf _v _v' = addIsLeqLeft1 prf

-- | Interpret 'S.Semantics' operations into 'Stmt's.
--
-- Operations that return 'Value's return fresh variables; we track
-- the relation between variables and the 'Stmt's they bind to using
-- 'NamedStmt's.
instance S.Semantics Semantics where
  make_undefined t = do
    name <- fresh "undef"
    tell [NamedStmt [name] (MakeUndefined t)]
    return $ VarExpr (Variable t name)

  get l = do
    name <- fresh "get"
    tell [NamedStmt [name] (Get l)]
    return $ VarExpr (Variable (S.loc_type l) name)

  -- sjw: This is a huge hack, but then again, so is the fact that it
  -- happens at all.  According to the ISA, assigning a 32 bit value
  -- to a 64 bit register performs a zero extension so the upper 32
  -- bits are zero.  This may not be the best place for this, but I
  -- can't think of a nicer one ...
  (S.LowerHalf loc@(S.Register (N.GPReg _))) .= v =
    -- FIXME: doing this the obvious way breaks GHC
    --     case addIsLeqLeft1' LeqProof v S.n64 of ...
    --
    -- ghc: panic! (the 'impossible' happened)
    --     (GHC version 7.8.4 for x86_64-apple-darwin):
    --   	tcIfaceCoAxiomRule Sub0R
    --
    case testLeq (S.bv_width v) S.n64 of
     Just LeqProof -> tell [loc := S.uext knownNat v]
     Nothing -> error "impossible"

  l .= v = tell [l := v]

  ifte_ c trueBranch falseBranch = do
    trueStmts <- collectAndForget trueBranch
    falseStmts <- collectAndForget falseBranch
    tell [Ifte_ c trueStmts falseStmts]
    where
      -- | Run a subcomputation and collect and return the writes.
      --
      -- In the enclosing computation, the state changes persist and
      -- the writes are forgotten.
      collectAndForget :: MonadWriter w m => m a -> m w
      collectAndForget = liftM snd . censor (const mempty) . listen
      -- More obvious / less abstract version:
      {-
      collectAndForget :: Semantics a -> Semantics [Stmt]
      collectAndForget = Semantics . lift . execWriterT . runSemantics
      -}

  memcopy i v1 v2 v3 b = tell [MemCopy i v1 v2 v3 b]

  memset v1 v2 v3 = tell [MemSet v1 v2 v3]

  memcmp r v1 v2 v3 v4 = do
    name <- fresh "memcmp"
    tell [NamedStmt [name] (MemCmp r v1 v2 v3 v4)]
    return $ VarExpr (Variable S.knownType name)

  bvDiv v1 v2 = do
    nameQuot <- fresh "divQuot"
    nameRem <- fresh "divRem"
    tell [NamedStmt [nameQuot, nameRem] (BVDiv v1 v2)]
    return (VarExpr (Variable r nameQuot), VarExpr (Variable r nameRem))
    where
      r = exprType v2

  bvSignedDiv v1 v2 = do
    nameQuot <- fresh "sdivQuot"
    nameRem <- fresh "sdivRem"
    tell [NamedStmt [nameQuot, nameRem] (BVSignedDiv v1 v2)]
    return (VarExpr (Variable r nameQuot), VarExpr (Variable r nameRem))
    where
      r = exprType v2

  exception v1 v2 c = tell [Exception v1 v2 c]

  x87Push v = tell [X87Push v]

  x87Pop = tell [X87Pop]

------------------------------------------------------------------------
-- Pretty printing.

ppExpr :: Expr a -> Doc
ppExpr e = case e of
  LitExpr n i -> parens $ R.ppLit n i
  AppExpr app -> R.ppApp ppExpr app
  TruncExpr n e -> R.sexpr "trunc" [ ppExpr e, R.ppNat n ]
  SExtExpr n e -> R.sexpr "sext" [ ppExpr e, R.ppNat n ]
  VarExpr (Variable _ x) -> text x

-- | Pretty print 'S.Location'.
--
-- Going back to pretty names for subregisters is pretty ad hoc;
-- see table at http://stackoverflow.com/a/1753627/470844. E.g.,
-- instead of @%ah@, we produce @(upper_half (lower_half (lower_half %rax)))@.
ppLocation :: forall addr tp. (addr -> Doc) -> S.Location addr tp -> Doc
ppLocation ppAddr l = case l of
  S.MemoryAddr addr _ -> ppAddr addr
  S.Register r -> text $ "%" ++ show r
  S.TruncLoc _ _ -> ppSubregister l
  S.LowerHalf _ -> ppSubregister l
  S.UpperHalf _ -> ppSubregister l
  S.X87StackRegister i -> text $ "x87_stack@" ++ show i
  where
    -- | Print subregister as Python-style slice @<reg>[<low>:<high>]@.
    --
    -- The low bit is inclusive and the high bit is exclusive, but I
    -- can't bring myself to generate @<reg>[<low>:<high>)@ :)
    ppSubregister :: forall tp. S.Location addr tp -> Doc
    ppSubregister l =
      r <> text ("[" ++ show low ++ ":" ++ show high ++ "]")
      where
        (r, low, high) = go l

    -- | Return pretty-printed register and subrange bounds.
    go :: forall tp. S.Location addr tp -> (Doc, Integer, Integer)
    go (S.TruncLoc l n) = truncLoc n $ go l
    go (S.LowerHalf l) = lowerHalf $ go l
    go (S.UpperHalf l) = upperHalf $ go l
    go (S.Register r) = (text $ "%" ++ show r, 0, natValue $ N.registerWidth r)
    go (S.MemoryAddr addr (BVTypeRepr nr)) = (ppAddr addr, 0, natValue nr)
    go (S.MemoryAddr _ _) = error "ppLocation.go: address of non 'BVType n' type!"


    -- Transformations on subranges.
    truncLoc :: NatRepr n -> (Doc, Integer, Integer) -> (Doc, Integer, Integer)
    truncLoc n (r, low, _high) = (r, low, low + natValue n)
    lowerHalf, upperHalf :: (Doc, Integer, Integer) -> (Doc, Integer, Integer)
    lowerHalf (r, low, high) = (r, low, (low + high) `div` 2)
    upperHalf (r, low, high) = (r, (low + high) `div` 2, high)

ppMLocation :: MLocation tp -> Doc
ppMLocation = ppLocation ppExpr

ppNamedStmt :: NamedStmt -> Doc
ppNamedStmt s = case s of
  MakeUndefined _ -> text "make_undefined"
  Get l -> R.sexpr "get" [ ppMLocation l ]
  BVDiv v1 v2 -> R.sexpr "bv_div" [ ppExpr v1, ppExpr v2 ]
  BVSignedDiv v1 v2 -> R.sexpr "bv_signed_div" [ ppExpr v1, ppExpr v2 ]
  MemCmp n v1 v2 v3 v4 ->
    R.sexpr "memcmp" [ pretty n, ppExpr v1, ppExpr v2, ppExpr v3, ppExpr v4 ]

ppStmts :: [Stmt] -> Doc
ppStmts = vsep . map ppStmt

ppStmt :: Stmt -> Doc
ppStmt s = case s of
  NamedStmt names s' ->
    text "let" <+> tupled (map text names) <+> text "=" <+> ppNamedStmt s'
  l := e -> ppMLocation l <+> text ":=" <+> ppExpr e
  Ifte_ v t f -> vsep
    [ text "if" <+> ppExpr v
    , text "then"
    ,   indent 2 (ppStmts t)
    , text "else"
    ,   indent 2 (ppStmts f)
    ]
  MemCopy i v1 v2 v3 b -> R.sexpr "memcopy" [ pretty i, ppExpr v1, ppExpr v2, ppExpr v3, ppExpr b ]
  MemSet v1 v2 v3 -> R.sexpr "memset" [ ppExpr v1, ppExpr v2, ppExpr v3 ]
  Exception v1 v2 e -> R.sexpr "exception" [ ppExpr v1, ppExpr v2, text $ show e ]
  X87Push v -> R.sexpr "x87_push" [ ppExpr v ]
  X87Pop -> text "x87_pop"

instance Pretty Stmt where
  pretty = ppStmt




------------------------------------------------------------------------
-- Scratch
------------------------------------------------------------------------

-- data X86State s
--    = X86State
--    { -- | Map from identifiers to associated register shape
--      _identMap :: !(IdentMap s)
--    , _blockInfoMap :: !(Map L.BlockLabel (X86BlockInfo s))
--    , x86Context :: X86Context
--    }

-- type X86Generator s ret = Generator s X86State ret

-- addAssert :: IO ()
-- addAssert = return ()
-- addAssert = do
--   sym <- theSym
--   addAssertionM sym (evalExpr sym emptyRegMap testExpr) "testing that True is True!"

type ArgTys = EmptyCtx ::> C.BVType 32
type RetTy = C.BVType 32

argTypes = C.ctxRepr :: C.CtxRepr ArgTys
retType  = C.BVRepr n32 :: C.TypeRepr RetTy

gen1 :: Assignment (G.Atom s) ArgTys -> G.Generator s t RetTy a
gen1 assn = do
  reg <- G.newReg $ G.AtomExpr $ assn^._1 -- assn ! base
  val <- G.readReg reg
  let foo = G.App (C.BVLit n32 11)
  G.assignReg reg (G.App $ C.BVMul n32 val foo)
  G.returnFromFunction =<< G.readReg reg

gen2 :: Assignment (G.Atom s) ArgTys -> G.Generator s t RetTy a
gen2 assn = do
  reg <- G.newReg $ G.AtomExpr $ assn^._1 -- assn ! base
  val <- G.readReg reg
  let foo1 = G.App (C.BVLit n32 6)
      foo2 = G.App (C.BVLit n32 5)
      bar = G.App (C.BVMul n32 val foo1)
      baz = G.App (C.BVMul n32 val foo2)
  G.assignReg reg (G.App $ C.BVAdd n32 bar baz)
  G.returnFromFunction =<< G.readReg reg


gimmeCFG :: HandleAllocator s
         -> (forall s. Assignment (G.Atom s) ArgTys -> G.Generator s [] RetTy (G.Expr s RetTy))
         -- -> ST s (G.CFG s EmptyCtx RetTy, [C.AnyCFG])
         -> ST s C.AnyCFG
gimmeCFG halloc gen = do
  fnH <- mkHandle' halloc "testFun" argTypes retType
  let fnDef :: G.FunctionDef [] ArgTys RetTy
      fnDef inputs = (s, f)
        where s = []
              f = gen inputs
  (g,[]) <- G.defineFunction halloc InternalPos fnH fnDef
  case toSSA g of
    C.SomeCFG g_ssa -> return (C.AnyCFG g_ssa)



-- logger :: Int -> String -> IO ()
-- logger i msg = putStrLn $ show i ++ ": " ++ msg

-- testExpr :: C.Expr ctx C.BoolType
-- testExpr = C.App (C.BoolLit True)

-- -- | Evaluate a register.
-- evalReg :: RegMap sym ctx
--         -> C.Reg ctx tp
--         -> RegValue sym tp
-- evalReg rMap r = rMap `regVal` r

-- -- | Evaluate an expression.
-- evalExpr :: forall sym ctx tp rtp blocks r
--           . IsSymInterface sym
--          => sym
--          -> RegMap sym ctx
--          -> C.Expr ctx tp
--          -> IO (RegValue sym tp)
-- evalExpr sym rMap (C.App a) = do
--   r <- evalApp sym logger (return . evalReg rMap) a
--   return $! r

-- theSym :: IO (SimpleBuilder SimpleBackendState)
-- theSym = do
--   backendState <- newIORef initialSimpleBackendState
--   newSimpleBuilder backendState

-- testApp :: C.App (C.Expr ctx) C.BoolType
-- testApp = C.BoolLit True

-- processApp :: IsSymInterface sym
--            => sym
--            -> RegMap sym ctx
--            -> C.App (C.Expr ctx) tp
--            -> IO (RegValue sym tp)
-- processApp sym rMap a0 = evalApp sym logger (evalExpr sym rMap) a0

-- testAppResult :: IO (Pred (SimpleBuilder SimpleBackendState))
-- testAppResult = do
--   sym <- theSym
--   processApp sym emptyRegMap testApp