{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Type.Solve (solve) where

import Control.Monad
import Control.Monad.Except (ExceptT, liftIO, throwError)
import qualified Data.Foldable as F
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import qualified Data.Vector.Mutable as MVector

import qualified AST.Module.Name as ModuleName
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Type as Error
import qualified Type.Occurs as Occurs
import qualified Type.State as TS
import Type.Type as Type
import Type.Unify
import qualified Type.UnionFind as UF



{-| Every variable has rank less than or equal to the maxRank of the pool.
This sorts variables into the young and old pools accordingly.
-}
generalize :: TS.Pool -> TS.Solver ()
generalize pool@(TS.Pool youngRank _) =
  {-# SCC elm_compiler_type_generalize #-}
  do  youngMark <- TS.uniqueMark

      rankTable <- liftIO $ poolToRankTable youngMark pool

      -- get the ranks right for each entry.
      -- start at low ranks so that we only have to pass
      -- over the information once.
      visitedMark <- TS.uniqueMark
      let adjust poolRank vars =
            F.traverse_ (adjustRank youngMark visitedMark poolRank) vars
      liftIO $ Vector.imapM_ adjust rankTable

      -- For variables that have rank lowerer than youngRank, register them in
      -- the old pool if they are not redundant.
      Vector.forM_ (Vector.unsafeInit rankTable) $ \vars ->
        forM_ vars $ \var ->
          do  isRedundant <- liftIO $ UF.redundant var
              if isRedundant then return var else TS.register var

      -- For variables with rank youngRank
      --   If rank < youngRank: register in oldPool
      --   otherwise generalize
      forM_ (Vector.unsafeLast rankTable) $ \var ->
        {-# SCC elm_compiler_type_register #-}
        do  isRedundant <- liftIO $ UF.redundant var
            if isRedundant
              then return ()
              else do
                (Descriptor content rank mark copy) <- liftIO $ UF.descriptor var
                if rank < youngRank
                  then
                    TS.register var >> return ()
                  else
                    liftIO $ UF.setDescriptor var $ Descriptor (rigidify content) noRank mark copy


poolToRankTable :: Int -> TS.Pool -> IO (Vector.Vector [Variable])
poolToRankTable youngMark (TS.Pool youngRank youngInhabitants) =
  do  mutableTable <- MVector.replicate (youngRank + 1) []

      -- Sort the youngPool variables by rank.
      forM_ youngInhabitants $ \var ->
        do  (Descriptor content rank _ copy) <- UF.descriptor var
            UF.setDescriptor var (Descriptor content rank youngMark copy)
            MVector.modify mutableTable (var:) rank

      Vector.unsafeFreeze mutableTable


rigidify :: Content -> Content
rigidify content =
  case content of
    Var Flex maybeSuper maybeName ->
        Var Rigid maybeSuper maybeName

    _ ->
        content


-- adjust the ranks of variables such that ranks never increase as you
-- move deeper into a variable.
adjustRank :: Int -> Int -> Int -> Variable -> IO Int
adjustRank youngMark visitedMark groupRank var =
  {-# SCC elm_compiler_type_adjust #-}
  do  descriptor <- UF.descriptor var
      adjustRankHelp youngMark visitedMark groupRank var descriptor


adjustRankHelp :: Int -> Int -> Int -> Variable -> Descriptor -> IO Int
adjustRankHelp youngMark visitedMark groupRank var descriptor@(Descriptor content rank mark _) =
  if mark == youngMark then

      do  -- Set the variable as marked first because it may be cyclic.
          UF.modifyDescriptor var $ \desc -> desc { _mark = visitedMark }
          maxRank <- adjustRankContent youngMark visitedMark groupRank content
          UF.modifyDescriptor var $ \desc -> desc { _rank = maxRank }
          return maxRank

  else if mark /= visitedMark then

      do  let minRank = min groupRank rank
          UF.setDescriptor var (descriptor { _mark = visitedMark, _rank = minRank })
          return minRank

  else

      return rank


adjustRankContent :: Int -> Int -> Int -> Content -> IO Int
adjustRankContent youngMark visitedMark groupRank content =
  let
    go = adjustRank youngMark visitedMark groupRank
  in
    case content of
      Error _ ->
          return groupRank

      Var _ _ _ ->
          return groupRank

      Alias _ args realVar ->
          -- TODO do you have to crawl the args?
          do  realRank <- go realVar
              foldM (\rank (_, argVar) -> max rank <$> go argVar) realRank args

      Structure (App1 _ []) ->
          return groupRank

      Structure (App1 _ (first:rest)) ->
        do  firstRank <- go first
            foldM (\rank arg -> max rank <$> go arg) firstRank rest

      Structure (Fun1 arg result) ->
          max <$> go arg <*> go result

      Structure EmptyRecord1 ->
          return outermostRank

      Structure (Record1 fields extension) ->
          do  extRank <- go extension
              foldM (\rank field -> max rank <$> go field) extRank fields



-- SOLVER


solve :: Constraint -> ExceptT [A.Located Error.Error] IO TS.State
solve constraint =
  {-# SCC elm_compiler_type_solve #-}
  do  state <- liftIO (TS.run (actuallySolve constraint))
      case TS.sError state of
        [] ->
            return state
        errors ->
            throwError errors


actuallySolve :: Constraint -> TS.Solver ()
actuallySolve constraint =
  case constraint of
    CTrue ->
        return ()

    CSaveEnv ->
        TS.saveLocalEnv

    CEqual hint region term1 term2 ->
        do  t1 <- TS.flatten term1
            t2 <- TS.flatten term2
            unify hint region t1 t2

    CAnd cs ->
        mapM_ actuallySolve cs

    CLet [Scheme [] fqs constraint' _] CTrue ->
        do  oldEnv <- TS.getEnv
            mapM_ TS.introduce fqs
            actuallySolve constraint'
            TS.modifyEnv (\_ -> oldEnv)

    CLet schemes constraint' ->
        do  oldEnv <- TS.getEnv
            headers <- Map.unions <$> mapM solveScheme schemes
            TS.modifyEnv $ \env -> Map.union headers env
            actuallySolve constraint'
            mapM_ occurs $ Map.toList headers
            TS.modifyEnv (\_ -> oldEnv)

    CInstance region name term ->
        do  env <- TS.getEnv
            freshCopy <-
                case Map.lookup name env of
                  Just (A.A _ tipe) ->
                      TS.makeInstance tipe

                  Nothing ->
                      if ModuleName.isKernel name then
                          liftIO (mkVar Nothing)

                      else
                          error ("Could not find `" ++ Text.unpack name ++ "` when solving type constraints.")

            t <- TS.flatten term
            unify (Error.Instance name) region freshCopy t


solveScheme :: Scheme -> TS.Solver TS.Env
solveScheme scheme =
  let
    flatten (A.A region term) =
      A.A region <$> TS.flatten term
  in
  case scheme of
    Scheme [] [] constraint header ->
        do  actuallySolve constraint
            traverse flatten header

    Scheme rigidQuantifiers flexibleQuantifiers constraint header ->
        do  let quantifiers = rigidQuantifiers ++ flexibleQuantifiers
            oldPool <- TS.getPool

            -- fill in a new pool when working on this scheme's constraints
            freshPool <- TS.nextRankPool
            TS.switchToPool freshPool
            mapM_ TS.introduce quantifiers
            header' <- traverse flatten header
            actuallySolve constraint

            youngPool <- TS.getPool
            TS.switchToPool oldPool
            generalize youngPool
            mapM_ isGeneric rigidQuantifiers
            return header'



-- ADDITIONAL CHECKS


-- Check that a variable has rank == noRank, meaning that it can be generalized.
isGeneric :: Variable -> TS.Solver ()
isGeneric var =
  do  desc <- liftIO $ UF.descriptor var
      if _rank desc == noRank
        then return ()
        else crash "Unable to generalize a type variable. It is not unranked."


crash :: String -> a
crash msg =
  error $
    "It looks like something went wrong with the type inference algorithm.\n\n"
    ++ msg ++ "\n\n"
    ++ "Please create a minimal example that triggers this problem and report it to\n"
    ++ "<https://github.com/elm-lang/elm-compiler/issues>"



-- OCCURS CHECK


occurs :: (Text.Text, A.Located Variable) -> TS.Solver ()
occurs (name, A.A region variable) =
  {-# SCC elm_compiler_type_occurs #-}
  do  hasOccurred <- liftIO $ Occurs.occurs variable
      case hasOccurred of
        False ->
          return ()

        True ->
          do  overallType <- liftIO $ Type.toSrcType variable
              infiniteDescriptor <- liftIO $ UF.descriptor variable
              liftIO $ UF.setDescriptor variable (infiniteDescriptor { _content = Error "∞" })
              TS.addError region (Error.InfiniteType (Right name) overallType)

