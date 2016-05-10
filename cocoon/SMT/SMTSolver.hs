-- Generic interface of an SMT solver

module SMT.SMTSolver where

import qualified Data.Map as M
import Data.Maybe
import Data.List
import GHC.Exts

import Ops
import Name

data Type = TBool
          | TUInt Int
          | TStruct String

instance Show Type where
    show TBool       = "bool"
    show (TUInt w)   = "uint<" ++ show w ++ ">"
    show (TStruct n) = n

data Struct = Struct { structName   :: String 
                     , structFields ::[(String,Type)]
                     }

instance WithName Struct where
    name (Struct n _) = n

data Var = Var { varName :: String
               , varType :: Type}

instance WithName Var where
    name (Var n _) = n

data Function = Function { funcName :: String
                         , funcArgs :: [(String, Type)]
                         , funcType :: Type
                         , funcDef  :: Expr
                         }

instance WithName Function where
    name = funcName

data Expr = EVar    String
          | EApply  String [Expr]
          | EField  Expr String
          | EBool   Bool
          | EInt    Int Integer
          | EStruct String [Expr]
          | EBinOp  BOp Expr Expr
          | EUnOp   UOp Expr 
          | ECond   [(Expr, Expr)] Expr
          deriving Show

-- Assigns values to variables.
type Assignment = M.Map String Expr

typ :: SMTQuery -> Expr -> Type
typ q (EVar n)      = varType $ fromJust $ find ((==n) . name) $ smtVars q
typ q (EField e f)  = fromJust $ lookup f fs
                      where TStruct n = typ q e
                            Struct _ fs = fromJust $ find ((== n) . name) $ smtStructs q
typ _ (EBool _)         = TBool
typ _ (EInt w _)        = TUInt w
typ _ (EStruct n _)     = TStruct n
typ q (EBinOp op e1 _)  | elem op [Eq, Lt, Gt, Lte, Gte, And, Or] = TBool
                        | elem op [Plus, Minus, Mod] = typ q e1
typ _ (EUnOp Not _)     = TBool 
typ q (ECond _ d)       = typ q d
typ q (EApply f _)      = funcType $ fromJust $ find ((==f) . name) $ smtFuncs q
typ _ e                 = error $ "SMTSolver.typ " ++ show e

data SMTQuery = SMTQuery { smtStructs :: [Struct]
                         , smtVars    :: [Var]
                         , smtFuncs   :: [Function]
                         , smtExprs   :: [Expr]
                         }

data SMTSolver = SMTSolver {
    -- Input:  list of formula
    -- Output: Nothing    - satisfiability of the formula could not be established
    --         Just Left  - unsat core of the conjunction of formula
    --         Just Right - satisfying assignment (unassigned variables are don't cares)
    smtGetModel       :: SMTQuery -> Maybe (Maybe Assignment),
    smtCheckSAT       :: SMTQuery -> Maybe Bool,
    smtGetCore        :: SMTQuery -> Maybe (Maybe [Int]),
    smtGetModelOrCore :: SMTQuery -> Maybe (Either [Int] Assignment)
}


allValues :: SMTQuery -> Type -> [Expr]
allValues _ TBool       = [EBool True, EBool False]
allValues _ (TUInt w)   = map (EInt w) [0..2^w-1]
allValues q (TStruct n) = map (EStruct n) $ allvals fs
    where Struct _ fs = fromJust $ find ((==n) . name) $ smtStructs q
          allvals []          = [[]]
          allvals ((_,t):fs') = concatMap (\v -> map (v:) $ allvals fs') $ allValues q t

allSolutions :: SMTSolver -> SMTQuery -> String -> [Expr]
allSolutions solver q var = sortWith solToArray $ allSolutions' solver q var

allSolutions' :: SMTSolver -> SMTQuery -> String -> [Expr]
allSolutions' solver q var = 
    -- Find one solution; block it, call allSolutions' recursively to find more
    case smtGetModel solver q of
         Nothing           -> error "SMTSolver.allSolutions: Failed to solve SMT query"
         Just Nothing      -> []
         Just (Just model) -> case M.lookup var model of
                                   Nothing  -> allValues q $ typ q $ EVar var
                                   Just val -> let q' = q{smtExprs = (EUnOp Not $ EBinOp Eq (EVar var) val) : (smtExprs q)}
                                               in val:(allSolutions' solver q' var)
                              


solToArray :: Expr -> [Integer]
solToArray (EBool True)   = [1]
solToArray (EBool False)  = [0]
solToArray (EInt _ i)     = [i]
solToArray (EStruct _ es) = concatMap solToArray es
solToArray e              = error $ "SMTSolver.solToArray " ++ show e