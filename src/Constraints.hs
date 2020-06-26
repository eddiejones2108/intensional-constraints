{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

module Constraints
  ( Guard,
    singleton,
    Atomic,
    Constraint (..),
    ConstraintSet,
    insert,
    guardWith,
    saturate,
  )
where

import Binary
import Constructors
import Control.Monad.RWS hiding (guard)
import Data.Bifunctor
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.Hashable
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import DataTypes
import GhcPlugins hiding ((<>), L, singleton)

-- A set of simple inclusion constraints, i.e. k in X, grouped by X
newtype Guard
  = Guard
      { groups :: HM.HashMap (DataType Name) (UniqSet Name)
      }
  deriving (Eq)

instance Binary Guard where
  put_ bh (Guard g) = put_ bh (HM.toList $ fmap nonDetEltsUniqSet g)
  get bh = Guard . HM.fromList . fmap (second mkUniqSet) <$> Binary.get bh

instance Monoid Guard where
  mempty = Guard mempty

instance Outputable Guard where
  ppr (Guard g) =
    pprWithCommas (\(d, k) -> hsep [ppr k, text "in", ppr d]) $
      second nonDetEltsUniqSet <$> HM.toList g

instance Refined Guard where
  domain (Guard g) = HM.foldrWithKey ((const . (<>)) . domain) mempty g

  rename x y (Guard g) =
    Guard
      ( HM.fromList $
          HM.foldrWithKey (\k a as -> (rename x y k, a) : as) [] g
      )

instance Semigroup Guard where
  Guard g <> Guard g' = Guard (HM.unionWith unionUniqSets g g')

-- A guard literal
singleton :: Name -> DataType Name -> Guard
singleton k d = Guard (HM.singleton d (unitUniqSet k))

-- Remove a constraint from a guard
remove :: Name -> DataType Name -> Guard -> Guard
remove k d (Guard g) = Guard (HM.adjust (`delOneFromUniqSet` k) d g)

type Atomic = Constraint 'L 'R

-- A pair of constructor sets
data Constraint l r
  = Constraint
      { left :: K l,
        right :: K r,
        guard :: Guard,
        srcSpan :: SrcSpan
      }

instance (Binary (K l), Binary (K r)) => Binary (Constraint l r) where
  put_ bh c = put_ bh (left c) >> put_ bh (right c) >> put_ bh (guard c) >> put_ bh (Constraints.srcSpan c)
  get bh = Constraint <$> Binary.get bh <*> Binary.get bh <*> Binary.get bh <*> Binary.get bh

-- Disregard location in comparison
instance Eq (Constraint l r) where
  Constraint l r g _ == Constraint l' r' g' _ = l == l' && r == r' && g == g'

instance Hashable (Constraint l r) where
  hashWithSalt s c = hashWithSalt s (left c, right c, second nonDetEltsUniqSet <$> HM.toList (groups (guard c)))

instance Outputable (Constraint l r) where
  ppr a = ppr (guard a) <+> char '?' <+> ppr (left a) <+> arrowt <+> ppr (right a)

instance Refined (Constraint l r) where
  domain c = domain (left c) <> domain (right c) <> domain (guard c)

  rename x y c =
    c
      { left = rename x y (left c),
        right = rename x y (right c),
        guard = rename x y (guard c)
      }

-- A constraint is trivially satisfied
tautology :: Atomic -> Bool
tautology a =
  case left a of
    Dom d ->
      case right a of
        Dom d' -> d == d'
        _ -> False
    Con k _ ->
      case right a of
        Dom d ->
          case HM.lookup d (groups (guard a)) of
            Just ks -> elementOfUniqSet k ks
            Nothing -> False
        Set ks _ -> elementOfUniqSet k ks

-- A constraint that defines a variable which also appears in the guard
recursive :: Atomic -> Bool
recursive a =
  case right a of
    Dom d ->
      case HM.lookup d (groups (guard a)) of
        Nothing -> False
        Just ks -> not (isEmptyUniqSet ks)
    Set _ _ -> False

-- Apply the saturation rules
resolve :: Atomic -> Atomic -> [Atomic]
resolve l r =
  case right l of
    Dom d ->
      -- The combined guards
      let guards = guard l <> guard r
          trans =
            case left r of
              Dom d' | d == d' -> [r {left = left l, guard = guards}] -- Trans
              _ -> []
          weak =
            case left l of
              Dom d' ->
                case nonDetEltsUniqSet <$> HM.lookup d (groups (guard r)) of
                  Nothing -> []
                  Just ks -> [r {guard = singleton k d' <> remove k d guards} | k <- ks] -- Substitute
              Con k _ -> [r {guard = remove k d guards}] -- Weakening
       in filter (not . tautology) (trans ++ weak) -- Remove redundant constriants
    Set _ _ -> []

type ConstraintSet = ConstraintSetGen Atomic

data ConstraintSetGen a
  = ConstraintSet
      { definite :: IM.IntMap (HS.HashSet a),
        goal :: HS.HashSet a
      }
  deriving (Eq, Foldable)

instance (Binary a, Hashable a, Eq a) => Binary (ConstraintSetGen a) where
  put_ bh cs = put_ bh (second HS.toList <$> IM.toList (definite cs)) >> put_ bh (HS.toList (goal cs))
  get bh = ConstraintSet . IM.fromList . fmap (second HS.fromList) <$> Binary.get bh <*> (HS.fromList <$> Binary.get bh)

instance (Hashable a, Eq a) => Monoid (ConstraintSetGen a) where
  mempty = ConstraintSet {definite = mempty, goal = mempty}

instance Outputable a => Outputable (ConstraintSetGen a) where
  ppr cs = vcat ((ppr . HS.toList . snd <$> IM.toList (definite cs)) ++ (ppr <$> HS.toList (goal cs)))

instance (Refined a, Hashable a, Eq a) => Refined (ConstraintSetGen a) where
  domain cs = foldMap (foldMap domain) (definite cs) <> foldMap domain (goal cs)
  rename x y cs =
    ConstraintSet
      { definite = IM.fromListWith HS.union $ bimap (\z -> if z == x then y else z) (HS.map $ rename x y) <$> IM.toList (definite cs),
        goal = HS.map (rename x y) (goal cs)
      }

instance (Hashable a, Eq a) => Semigroup (ConstraintSetGen a) where
  cs <> cs' =
    ConstraintSet
      { definite = IM.unionWith HS.union (definite cs) (definite cs'),
        goal = HS.union (goal cs) (goal cs')
      }

-- Add an atomic constriant to the set
insert :: Atomic -> ConstraintSet -> ConstraintSet
insert a cs =
  case right a of
    Dom (Base _) -> cs -- Ignore constraints concerning base types
    Dom (Inj x _) -> cs {definite = IM.insertWith HS.union x (HS.singleton a) (definite cs)}
    Set _ _ -> cs {goal = HS.insert a (goal cs)}

-- Add a guard to every constraint
guardWith :: Guard -> ConstraintSet -> ConstraintSet
guardWith g cs =
  ConstraintSet
    { definite = IM.map (HS.map go) (definite cs),
      goal = HS.map go (goal cs)
    }
  where
    go a = a {guard = g <> guard a}

-- Is an atomic constraint already in the set
member :: Atomic -> ConstraintSet -> Bool
member a cs =
  case right a of
    Dom (Inj x _)
      | Just as <- IM.lookup x (definite cs) -> HS.member a as
    Set _ _ -> HS.member a (goal cs)
    _ -> False

-- Apply the saturation rules and remove intermediate variables until a fixedpoint is reached
saturate :: IS.IntSet -> ConstraintSet -> ConstraintSet
saturate is cs
  | IS.null is = cs
  | otherwise = do
    let i = IS.findMin is
    case runRWS (saturateF i) () cs of
      ((), cs', Any True) -> saturate is cs'
      ((), cs', Any False) -> saturate (IS.deleteMin is) (eliminate i cs') -- i has been saturated

-- Remove constraints concerning a particular refinement variable
eliminate :: Int -> ConstraintSet -> ConstraintSet
eliminate i cs =
  ConstraintSet
    { definite =
        IM.mapMaybeWithKey
          ( \x s ->
              if i == x
                then Nothing
                else Just $ HS.filter (IS.notMember i . domain) s
          )
          (definite cs),
      goal = HS.filter (IS.notMember i . domain) (goal cs)
    }

-- One step consequence operator for saturation rules concerning a particular refinement variable
saturateF :: Int -> RWS () Any ConstraintSet ()
saturateF x =
  -- Lookup constraints with x in the head
  gets (IM.lookup x . definite) >>= \case
    Just cs
      -- If there are only recursive clauses the minimum model is empty
      | not (all recursive cs) ->
        mapM_
          ( \c ->
              Control.Monad.RWS.get
                >>= mapM_
                  ( mapM_
                      ( \resolvant ->
                          gets (member resolvant) >>= \case
                            True -> return ()
                            False -> do
                              modify (insert resolvant) -- Add every resolvant
                              tell (Any True)
                      )
                      . resolve c
                  )
          )
          cs
    _ -> return ()
