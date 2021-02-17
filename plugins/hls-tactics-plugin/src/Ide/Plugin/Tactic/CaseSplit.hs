{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE ViewPatterns        #-}

module Ide.Plugin.Tactic.CaseSplit
  ( mkFirstAgda
  , iterateSplit
  , splitToDecl
  ) where

import           Control.Lens
import           Data.Bool (bool)
import           Data.Data
import           Data.Generics
import           Data.Set (Set)
import qualified Data.Set as S
import           Development.IDE.GHC.Compat
import           GHC.Exts (IsString(fromString))
import           GHC.SourceGen (funBinds, match, wildP)
import           Ide.Plugin.Tactic.GHC
import           Ide.Plugin.Tactic.Types
import           OccName



------------------------------------------------------------------------------
-- | Construct an 'AgdaMatch' from patterns in scope (should be the LHS of the
-- match) and a body.
mkFirstAgda :: [Pat GhcPs] -> HsExpr GhcPs -> AgdaMatch
mkFirstAgda pats (Lambda pats' body) = mkFirstAgda (pats <> pats') body
mkFirstAgda pats body = AgdaMatch pats body


------------------------------------------------------------------------------
-- | Transform an 'AgdaMatch' whose body is a case over a bound pattern, by
-- splitting it into multiple matches: one for each alternative of the case.
agdaSplit :: AgdaMatch -> [AgdaMatch]
agdaSplit (AgdaMatch pats (Case (HsVar _ (L _ var)) matches)) = do
  (i, pat) <- zip [id @Int 0 ..] pats
  case pat of
    VarPat _ (L _ patname) | eqRdrName patname var -> do
      (case_pat, body) <- matches
      -- TODO(sandy): use an at pattern if necessary
      pure $ AgdaMatch (pats & ix i .~ case_pat) body
    _ -> []
agdaSplit x = [x]


------------------------------------------------------------------------------
-- | Replace unused bound patterns with wild patterns.
wildify :: AgdaMatch -> AgdaMatch
wildify (AgdaMatch pats body) =
  let make_wild = bool id (wildifyT (allOccNames body)) $ not $ containsHole body
   in AgdaMatch (make_wild pats) body


------------------------------------------------------------------------------
-- | Helper function for 'wildify'.
wildifyT :: Data a => Set OccName -> a -> a
wildifyT (S.map occNameString -> used) = everywhere $ mkT $ \case
  VarPat _ (L _ var) | S.notMember (occNameString $ occName var) used -> wildP
  (x :: Pat GhcPs) -> x


------------------------------------------------------------------------------
-- | Construct an 'HsDecl' from a set of 'AgdaMatch'es.
splitToDecl
    :: OccName  -- ^ The name of the function
    -> [AgdaMatch]
    -> LHsDecl GhcPs
splitToDecl name ams = noLoc $ funBinds (fromString . occNameString . occName $ name) $ do
  AgdaMatch pats body <- ams
  pure $ match pats body


------------------------------------------------------------------------------
-- | Sometimes 'agdaSplit' exposes another opportunity to do 'agdaSplit'. This
-- function runs it a few times, hoping it will find a fixpoint.
iterateSplit :: AgdaMatch -> [AgdaMatch]
iterateSplit am =
  let iterated = iterate (agdaSplit =<<) $ pure am
   in fmap wildify . head . drop 5 $ iterated
