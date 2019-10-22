{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, TypeSynonymInstances #-}

module InferM
    (
      InferM,
      Context (Context, con, var),
      safeVar,
      safeCon,
      fresh,
      freshScheme,
      insertVar,
      insertMany
    ) where

import Errors
import Types
import Utils
import GenericConGraph
import Control.Monad.Except
import Control.Monad.RWS hiding (Sum)
import qualified Data.Map as M
import qualified GhcPlugins as Core
import Debug.Trace

type InferM = RWST Context () Int (Except Error)

data Context = Context {
    con :: M.Map Core.Var (Core.TyCon, [Sort]), -- k -> (d, args)
    var :: M.Map Core.Var TypeScheme
}

insertVar :: Core.Var -> TypeScheme -> Context ->  Context
insertVar x f ctx
  | isWild x  = ctx
  | otherwise = ctx{var = M.insert x f $ var ctx}

insertMany :: [Core.Var] -> [TypeScheme] -> Context -> Context
insertMany [] [] ctx = ctx
insertMany (x:xs) (t:ts) ctx = insertVar x t (insertMany xs ts ctx)

safeVar :: Core.Var -> InferM (TypeScheme)
safeVar v = do
  ctx <- ask
  case var ctx M.!? v of
    Just ts -> return ts
    Nothing -> trace (show v) $ error "Variable not in environment."

safeCon :: Core.Var -> InferM (Core.TyCon, [Sort])
safeCon k = do
  ctx <- ask
  case con ctx M.!? k of
    Just args -> return args
    Nothing   -> error "Constructor not in environment."

fresh :: Sort -> InferM Type
fresh t = do
    i <- get
    put (i + 1)
    return $ head $ upArrow (show i) [polarise True t]

freshScheme :: SortScheme -> InferM TypeScheme
freshScheme (SForall as (SVar a)) = return $ Forall as [] empty $ Con (TVar a) []
freshScheme (SForall as (SBase b)) = return $ Forall as [] empty $ Con (TBase b) []
freshScheme (SForall as s@(SData _)) = do
  t <- fresh s
  return $ Forall as [] empty t
freshScheme (SForall as (SArrow s1 s2)) = do
  Forall _ _ _ t1 <- freshScheme (SForall as s1)
  Forall _ _ _ t2 <- freshScheme (SForall as s2)
  return $ Forall as [] empty (t1 :=> t2)

delta :: Bool -> Core.TyCon -> Core.Var -> InferM [PType]
delta p d k = do
  ctx <- ask
  case con ctx M.!? k of
    Just (d', ts) -> if d == d'
      then return $ fmap (polarise p) ts
      else throwError DataTypeError
    otherwise -> throwError ConstructorError

instance Rewrite RVar UType InferM where
  toNorm t1@(K k ts) t2@(V x p d) = do
      args <- delta p d k
      let ts' = upArrow x args
      if ts' /= ts
        then return [(K k ts', V x p d), (K k ts, K k ts')]
        else return [(t1, t2)]
  toNorm t1@(V x p d) t2@(Sum cs) = do
      s <- mapM (refineCon x d) cs
      if cs /= s
        then return [(Sum s, Sum cs),(V x p d, Sum s)]
        else return [(t1, t2)]
      where
        refineCon x d (TCon k, ts) = do
          args <- delta p d k
          return (TCon k, upArrow x args)
