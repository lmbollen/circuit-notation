{-
 ██████╗██╗██████╗  ██████╗██╗   ██╗██╗████████╗███████╗
██╔════╝██║██╔══██╗██╔════╝██║   ██║██║╚══██╔══╝██╔════╝
██║     ██║██████╔╝██║     ██║   ██║██║   ██║   ███████╗
██║     ██║██╔══██╗██║     ██║   ██║██║   ██║   ╚════██║
╚██████╗██║██║  ██║╚██████╗╚██████╔╝██║   ██║   ███████║
 ╚═════╝╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝   ╚═╝   ╚══════╝
  (C) 2020, Christopher Chalmers

Notation for describing the 'Circuit' type.
-}

{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE ImplicitParams             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module CircuitNotation
  ( plugin
  , mkPlugin
  , thName
  , ExternalNames (..)
  ) where

-- base
import           Control.Exception
import qualified Data.Data              as Data
import           Data.Default
import           Data.Maybe             (fromMaybe)




import           System.IO.Unsafe
import           Data.Typeable

-- ghc
import qualified Language.Haskell.TH    as TH
import qualified Language.Haskell.Syntax    as Syn


import           GHC.Data.Bag
import           GHC.Data.FastString       (mkFastString, unpackFS)

-- import qualified GHC.Driver.Types          (throwOneError)



import           GHC.Plugins               (PromotionFlag(NotPromoted))
import           GHC.Types.SrcLoc
import qualified GHC.Data.FastString       as GHC
import qualified GHC.Driver.Plugins        as GHC
import qualified GHC.Driver.Session        as GHC


import qualified GHC.Types.SourceError     as GHC
import qualified GHC.Types.SourceText      as GHC
import qualified GHC.Driver.Ppr            as GHC
import qualified GHC.Driver.Env            as GHC
import qualified GHC.Driver.Errors.Types   as GHC
import qualified GHC.Parser.Annotation     as GHC
import qualified GHC.Types.Basic           as GHC
import qualified GHC.Types.Name.Occurrence as OccName
import qualified GHC.Types.Name.Reader     as GHC
import qualified GHC.Types.SrcLoc          as GHC
import qualified GHC.Utils.Error           as Err
import qualified GHC.Utils.Outputable      as GHC
import qualified GHC.Utils.Outputable      as Outputable
import qualified GHC                       as GHC
import qualified GHC.Driver.Config.Diagnostic as GHC
import Language.Haskell.Syntax.Binds











import qualified GHC.ThToHs             as Convert
import           GHC.Hs












import           GHC.Builtin.Types      (eqTyCon_RDR)


-- clash-prelude
import Clash.Prelude (Signal, Vec((:>), Nil))

-- containers
import Data.Map (Map)
import qualified Data.Map as Map

-- lens
import qualified Control.Lens           as L
import           Control.Lens.Operators

-- mtl
import           Control.Monad.State

-- pretty-show
-- import qualified Text.Show.Pretty       as SP

-- syb
import qualified Data.Generics          as SYB
import qualified GHC.Plugins as Outputtable
import GHC (HsTupleSort(HsUnboxedTuple))
import GHC.Types.Error (emptyMessages)

-- The stages of this plugin
--
-- 1. Go through the parsed module source and find usages of the circuit keyword (`transform`).
-- 2. Parse the circuit, either do notation or a one liner, go through each statement and convert it
--    to a CircuitQQ.
-- 3. Go through the CircuitQQ and check that everything is consistent (every master has a matching
--    slave).
-- 4. Convert the Bindings to let statements, at the same time build up a description of the types
--    to make the type descriptor helper.


-- Utils ---------------------------------------------------------------
isSomeVar :: (p ~ GhcPs) => GHC.FastString -> HsExpr p -> Bool
isSomeVar s = \case
  HsVar _ (L _ v) -> v == GHC.mkVarUnqual s
  _               -> False

isCircuitVar :: p ~ GhcPs => HsExpr p -> Bool
isCircuitVar = isSomeVar "circuit"

isDollar :: p ~ GhcPs => HsExpr p -> Bool
isDollar = isSomeVar "$"

-- | Is (-<)?
isFletching :: p ~ GhcPs => HsExpr p -> Bool
isFletching = isSomeVar "-<"

imap :: (Int -> a -> b) -> [a] -> [b]
imap f = zipWith f [0 ..]


noExt :: NoExtField
noExt = noExtField





-- Types ---------------------------------------------------------------

-- | The name given to a 'port', i.e. the name of a variable either to the left of a '<-' or to the
--   right of a '-<'.
data PortName = PortName SrcSpan GHC.FastString
  deriving (Eq)

instance Show PortName where
  show (PortName _ fs) = GHC.unpackFS fs

data PortDescription a
    = Tuple [PortDescription a]
    | Vec SrcSpan [PortDescription a]
    | Ref a
    | Lazy SrcSpan (PortDescription a)
    | SignalExpr (LHsExpr GhcPs)
    | SignalPat (LPat GhcPs)
    | PortType (LHsType GhcPs) (PortDescription a)
    | PortErr SrcSpan Err.SDoc
    deriving (Foldable, Functor, Traversable)

_Ref :: L.Prism' (PortDescription a) a
_Ref = L.prism' Ref (\case Ref a -> Just a; _ -> Nothing)

instance L.Plated (PortDescription a) where
  plate f = \case
    Tuple ps -> Tuple <$> traverse f ps
    Vec s ps -> Vec s <$> traverse f ps
    Lazy s p -> Lazy s <$> f p
    PortType t p -> PortType t <$> f p
    p -> pure p

-- | A single circuit binding. These are generated from parsing statements.
-- @
-- bOut <- bCircuit -< bIn
-- @
data Binding exp l = Binding
    { bCircuit :: exp
    , bOut     :: PortDescription l
    , bIn      :: PortDescription l
    }
    deriving (Functor)

data CircuitState dec exp nm = CircuitState
    { _cErrors        :: Bag (Err.MsgEnvelope GHC.GhcMessage)
    , _counter        :: Int
    -- ^ unique counter for generated variables
    , _circuitSlaves  :: PortDescription nm
    -- ^ the final statement in a circuit
    , _circuitTypes   :: [LSig GhcPs]
    -- ^ type signatures in let bindings
    , _circuitLets    :: [dec]
    -- ^ user defined let expression inside the circuit
    , _circuitBinds   :: [Binding exp nm]
    -- ^ @out <- circuit <- in@ statements
    , _circuitMasters :: PortDescription nm
    -- ^ ports bound at the first lambda of a circuit
    , _portVarTypes :: Map GHC.FastString (SrcSpan, LHsType GhcPs)
    -- ^ types of single variable ports
    , _portTypes :: [(LHsType GhcPs, PortDescription nm)]
    -- ^ type of more 'complicated' things (very far from vigorous)
    , _uniqueCounter :: Int
    -- ^ counter to keep internal variables "unique"
    , _circuitLoc :: SrcSpan
    -- ^ span of the circuit expression
    }

L.makeLenses 'CircuitState

-- | The monad used when running a single circuit.
newtype CircuitM a = CircuitM (StateT (CircuitState (LHsBind GhcPs) (LHsExpr GhcPs) PortName) GHC.Hsc a)
  deriving (Functor, Applicative, Monad, MonadIO) --, MonadState (CircuitState (XRec GhcPs (HsBindLR GhcPs GhcPs)) (XRec GhcPs (HsExpr GhcPs)) PortName))

instance GHC.HasDynFlags CircuitM where
  getDynFlags = (CircuitM . lift) GHC.getDynFlags

runCircuitM :: CircuitM a -> GHC.Hsc a
runCircuitM (CircuitM m) = do
  let emptyCircuitState = CircuitState
        { _cErrors = emptyBag
        , _counter = 0
        , _circuitSlaves = Tuple []
        , _circuitTypes = []
        , _circuitLets = []
        , _circuitBinds = []
        , _circuitMasters = Tuple []
        , _portVarTypes = Map.empty
        , _portTypes = []
        , _uniqueCounter = 1
        , _circuitLoc = noSrcSpan
        }
  (a, s) <- runStateT m emptyCircuitState
  let errs = _cErrors s
  unless (isEmptyBag errs) $ GHC.throwErrors $ (Err.mkMessages errs)
  pure a

errM :: SrcSpan -> String -> CircuitM ()
errM loc msg = do
  let
    errMsg = Err.mkLocMessage Err.MCFatal loc (Outputable.text msg)
  cErrors %= consBag (Err.mkErrorMsgEnvelope loc Outputtable.reallyAlwaysQualify (GHC.ghcUnknownMessage errMsg))

-- ghc helpers ---------------------------------------------------------

-- It's very possible that most of these are already in the ghc library in some form. It's not the
-- easiest library to discover these kind of functions.

conPatIn :: (p ~ GhcPs) => Located GHC.RdrName -> HsConPatDetails p -> Pat p

conPatIn loc con = ConPat noAnn (reLocA loc) con




tupP :: p ~ GhcPs => [LPat p] -> LPat p
tupP [pat] = pat
tupP pats = noLocA $ TuplePat noAnn pats GHC.Boxed

vecP :: p ~ GhcPs => SrcSpan -> [LPat p] -> LPat p
vecP srcLoc = \case
  [] -> go srcLoc []
  as -> reLocA $ L srcLoc (ParPat noAnn noHsTok (go srcLoc $ fmap reLoc as) noHsTok)
  where
  go loc (p@(L l _):pats) = reLocA $ L loc $ conPatIn (L l (thName '(:>))) (InfixCon (reLocA p) (go loc pats))
  go loc [] = reLocA $ L loc $ WildPat noExt

varP :: p ~ GhcPs => SrcSpan -> String -> LPat p
varP loc nm = reLocA $ L loc $ VarPat noExt (reLocA $ L loc $ var nm)

tildeP :: p ~ GhcPs => SrcSpan -> LPat p -> LPat p
tildeP loc lpat = reLocA $ L loc (LazyPat noAnn lpat)

tupT :: p ~ GhcPs => [LHsType p] -> LHsType p
tupT [ty] = ty
tupT tys = noLocA $ HsTupleTy noAnn HsUnboxedTuple tys

vecT :: p ~ GhcPs => SrcSpan -> [LHsType p] -> LHsType p
vecT s [] = reLocA $ L s $ HsParTy noAnn (conT s (thName ''Vec) `appTy` tyNum s 0 `appTy` (varT s (genLocName s "vec")))
vecT s tys = reLocA $ L s $ HsParTy noAnn (conT s (thName ''Vec) `appTy` tyNum s (length tys) `appTy` head tys)

tyNum :: p ~ GhcPs => SrcSpan -> Int -> LHsType p
tyNum s i = reLocA $ L s (HsTyLit noExt (HsNumTy GHC.NoSourceText (fromIntegral i)))

appTy :: p ~ GhcPs => LHsType p -> LHsType p -> LHsType p
appTy a b = reLocA $ L noSrcSpan (HsAppTy noExt a (parenthesizeHsType GHC.appPrec b))

appE :: p ~ GhcPs => LHsExpr p -> LHsExpr p -> LHsExpr p
appE fun arg = reLocA $ L noSrcSpan $ HsApp noAnn fun (parenthesizeHsExpr GHC.appPrec arg)

varE :: p ~ GhcPs => SrcSpan -> GHC.RdrName -> LHsExpr p
varE loc rdr = reLocA $ L loc (HsVar noExt (reLocA $ L loc rdr))

parenE :: p ~ GhcPs => LHsExpr p -> LHsExpr p
parenE e@(L l _) = L l (HsPar noAnn noHsTok e noHsTok)

var :: String -> GHC.RdrName
var = GHC.Unqual . OccName.mkVarOcc

tyVar :: String -> GHC.RdrName
tyVar = GHC.Unqual . OccName.mkTyVarOcc

tyCon :: String -> GHC.RdrName
tyCon = GHC.Unqual . OccName.mkTcOcc

vecE :: p ~ GhcPs => SrcSpan -> [LHsExpr p] -> LHsExpr p
vecE srcLoc = \case
  [] -> go srcLoc []
  as -> parenE $ go srcLoc $ fmap reLoc as
  where
  go loc (e@(L l _):es) = reLocA $ L loc $ OpApp noAnn (reLocA e) (varE l (thName '(:>))) (go loc es)
  go loc [] = varE loc (thName 'Nil)

tupE :: p ~ GhcPs => SrcSpan -> [LHsExpr p] -> LHsExpr p
tupE _ [ele] = ele
tupE loc elems = reLocA $ L loc $ ExplicitTuple noAnn (fmap unLoc tupArgs) GHC.Boxed
  where
    tupArgs = map (\arg@(L l _) -> L l (Present noAnn arg)) elems

unL :: Located a -> a
unL (L _ a) = a

-- | Get a ghc name from a TH name that's known to be unique.
thName :: TH.Name -> GHC.RdrName
thName nm =
  case Convert.thRdrNameGuesses nm of
    [name] -> name
    _      -> error "thName called on a non NameG Name"

-- | Make a type signature from a port description. Things without a concrete type (e.g. Signal a),
--   are given a type name based on the location of the port.
portTypeSigM :: (p ~ GhcPs, ?nms :: ExternalNames) => PortDescription PortName -> CircuitM (LHsType p)
portTypeSigM = \case
  Tuple ps -> tupT <$> mapM portTypeSigM ps
  Vec s ps -> vecT s <$> mapM portTypeSigM ps
  Ref (PortName loc fs) -> do
    L.use (portVarTypes . L.at fs) <&> \case
      Nothing -> varT loc (GHC.unpackFS fs <> "Ty")
      Just (_sigLoc, sig) -> sig
  PortErr loc msgdoc -> do
    let errMsg = Outputable.text "portTypeSig" Outputtable.$+$ msgdoc
    dflags <- GHC.getDynFlags
    unsafePerformIO . Outputtable.throwOneError $ Err.mkErrorMsgEnvelope loc Outputtable.reallyAlwaysQualify (GHC.ghcUnknownMessage errMsg)
    --  Err.mkLocMessage Err.MCFatal loc $ Outputable.text "portTypeSig" Outputtable.$+$ msgdoc
  Lazy _ p -> portTypeSigM p
  SignalExpr (reLoc -> L l _) -> do
    n <- uniqueCounter <<+= 1
    pure $ (conT l (thName ''Signal)) `appTy` (varT l (genLocName l "dom")) `appTy` (varT l (genLocName l ("sig_" <> show n)))
  SignalPat (reLoc -> L l _) -> do
    n <- uniqueCounter <<+= 1
    pure $ (conT l (thName ''Signal)) `appTy` (varT l (genLocName l "dom")) `appTy` (varT l (genLocName l ("sig_" <> show n)))
  PortType _ p -> portTypeSigM p

-- | Generate a "unique" name by appending the location as a string.
genLocName :: SrcSpan -> String -> String

genLocName (GHC.RealSrcSpan rss _) prefix =



  prefix <> "_" <>
    foldMap (\f -> show (f rss)) [srcSpanStartLine, srcSpanEndLine, srcSpanStartCol, srcSpanEndCol]
genLocName _ prefix = prefix

-- | Extract a simple lambda into inputs and body.
simpleLambda :: forall p . HsExpr p -> ([LPat p], LHsExpr p)
simpleLambda expr = (matchPats, body)
 where
  HsLam _ (MG _x alts _origin) = expr
  [(unXRec @p -> Match _matchX _matchContext matchPats matchGr)] = unXRec @p alts
  GRHSs _grX grHss _grLocalBinds = matchGr
  [unXRec @p -> (GRHS _ _ body)] = grHss

-- | Create a simple let binding.
letE
  :: p ~ GhcPs
  => SrcSpan
  -- ^ location for top level let bindings
  -> [LSig GhcPs]
  -- ^ type signatures
  -> [LHsBind p]
  -- ^ let bindings
  -> LHsExpr p
  -- ^ final `in` expressions
  -> LHsExpr p
letE loc sigs binds expr = reLocA $ L loc (HsLet noAnn noHsTok localBinds noHsTok expr)
  where
    localBinds :: HsLocalBindsLR GhcPs GhcPs
    localBinds = HsValBinds noAnn valBinds

    valBinds :: HsValBindsLR GhcPs GhcPs
    valBinds = ValBinds NoAnnSortKey hsBinds sigs

    hsBinds :: LHsBindsLR GhcPs GhcPs
    hsBinds = listToBag binds

-- | Simple construction of a lambda expression
lamE :: p ~ GhcPs => [LPat p] -> LHsExpr p -> LHsExpr p
lamE pats expr = noLocA $ HsLam noExt mg
  where
    mg = MG noExt matches GHC.Generated

    matches :: LocatedAn an [LMatch GhcPs (LHsExpr GhcPs)]
    matches = noLocA $ [singleMatch]

    singleMatch :: LMatch GhcPs (LHsExpr GhcPs)
    singleMatch = noLocA $ Match noAnn LambdaExpr pats grHss

    grHss :: GRHSs GhcPs (LHsExpr GhcPs)
    grHss = GRHSs emptyComments [grHs] (EmptyLocalBinds noExt)

    grHs :: LGRHS GhcPs (LHsExpr GhcPs)
    grHs = noLocA $ GRHS noAnn [] expr

-- | Kinda hacky function to get a string name for named ports.
fromRdrName :: GHC.RdrName -> GHC.FastString
fromRdrName = \case
  GHC.Unqual occName -> mkFastString (OccName.occNameString occName)
  GHC.Orig _ occName -> mkFastString (OccName.occNameString occName)
  nm -> mkFastString (deepShowD nm)

-- Parsing -------------------------------------------------------------

-- | "parse" a circuit, i.e. convert it from ghc's ast to our representation of a circuit. This is
-- the expression following the 'circuit' keyword.
parseCircuit
  :: p ~ GhcPs
  => LHsExpr p
  -> CircuitM ()
parseCircuit = \case
  -- strip out parenthesis
  L _ (HsPar _ _ lexp _) -> parseCircuit lexp

  -- a lambda to match the slave ports
  L _ (simpleLambda -> ([matchPats], body)) -> do
    circuitSlaves .= bindSlave matchPats
    circuitBody body

  -- a version without a lambda (i.e. no slaves)
  e -> circuitBody e

-- | The main part of a circuit expression. Either a do block or simple rearranging case.
circuitBody
  :: p ~ GhcPs
  => LHsExpr p
  -> CircuitM ()
circuitBody inp = case reLoc inp of
  -- strip out parenthesis
  L _ (HsPar _ _ lexp _) -> circuitBody lexp

  L loc (HsDo _x _stmtContext (unsnoc . unXRec @GhcPs -> Just (stmts, reLoc -> L finLoc finStmt))) -> do
    circuitLoc .= loc
    mapM_ handleStmtM $ fmap reLoc stmts

    case finStmt of
      BodyStmt _bodyX bod _idr _idr' ->
        case bod of
          -- special case for idC as the final statement, gives better type inferences and generates nicer
          -- code




          L _ (OpApp _ (L _ (HsVar _ (L _ (GHC.Unqual occ)))) (L _ op) port)
            | isFletching op
            , OccName.occNameString occ == "idC" -> do
                circuitMasters .= bindMaster port


          -- Otherwise create a binding and use that as the master. This is equivalent to changing
          --   c -< x
          -- into
          --   finalStmt <- c -< x
          --   idC -< finalStmt
          _ -> do
            let ref = Ref (PortName finLoc "final:stmt")
            bodyBinding (Just ref) $ reLoc bod
            circuitMasters .= ref

      stmt -> errM finLoc ("Unhandled final stmt " <> show (Data.toConstr stmt))

  -- the simple case without do notation
  L loc master -> do
    circuitLoc .= loc
    circuitMasters .= bindMaster (reLocA $ L loc master)

-- | Handle a single statement.
handleStmtM
  :: (p ~ GhcPs, loc ~ SrcSpan, idL ~ GhcPs, idR ~ GhcPs)
  => Located (StmtLR idL idR (LHsExpr p))
  -> CircuitM ()
handleStmtM (L loc stmt) = case stmt of
  LetStmt _xlet (noLoc -> L _ letBind) ->
    -- a regular let bindings
    case letBind of
      HsValBinds _ (ValBinds _ valBinds sigs) -> do
        circuitLets <>= bagToList valBinds
        circuitTypes <>= sigs
      _ -> errM loc ("Unhandled let statement" <> show (Data.toConstr letBind))
  BodyStmt _xbody body _idr _idr' ->
    bodyBinding Nothing $ reLoc body

  BindStmt _ bind body ->



    bodyBinding (Just $ bindSlave bind) $ reLoc body
  _ -> errM loc "Unhandled stmt"

-- | Turn patterns to the left of a @<-@ into a PortDescription.
bindSlave :: p ~ GhcPs => LPat p -> PortDescription PortName
bindSlave (reLoc -> L loc expr) = case expr of
  VarPat _ (L _ rdrName) -> Ref (PortName loc (fromRdrName rdrName))
  TuplePat _ lpat _ -> Tuple $ fmap bindSlave lpat
  ParPat _ _ lpat _ -> bindSlave lpat

  ConPat _ (L _ (GHC.Unqual occ)) (PrefixCon _ [lpat])



    | OccName.occNameString occ == "Signal" -> SignalPat lpat
  -- empty list is done as the constructor

  ConPat _ (L _ rdr) _



    | rdr == thName '[] -> Vec loc []
    | rdr == thName '() -> Tuple []





  SigPat _ port ty -> PortType (hsps_body ty) (bindSlave port)

  LazyPat _ lpat -> Lazy loc (bindSlave lpat)
  ListPat _ pats -> Vec loc (map bindSlave pats)
  pat ->
    PortErr loc
            (Err.mkLocMessageAnn
              Nothing
              Err.MCFatal
              loc
              (Outputable.text $ "Unhandled pattern " <> show (Data.toConstr pat))
              )

-- | Turn expressions to the right of a @-<@ into a PortDescription.
bindMaster :: p ~ GhcPs => LHsExpr p -> PortDescription PortName
bindMaster (reLoc -> L loc expr) = case expr of
  HsVar _xvar (reLoc -> L vloc rdrName)
    | rdrName == thName '() -> Tuple []
    | rdrName == thName '[] -> Vec vloc []
    | otherwise -> Ref (PortName vloc (fromRdrName rdrName))
  HsApp _xapp (reLoc -> L _ (HsVar _ (L _ (GHC.Unqual occ)))) sig
    | OccName.occNameString occ == "Signal" -> SignalExpr sig
  ExplicitTuple _ tups _ -> let
    vals = fmap ((\(L _ (Present _ e)) -> e) . noLoc) tups
    in Tuple $ fmap bindMaster vals
  ExplicitList _ exprs -> Vec loc $ fmap bindMaster exprs






  -- XXX: Untested?
  HsProc _ _ (L _ (HsCmdTop _ (L _ (HsCmdArrApp _xapp (L _ (HsVar _ (L _ (GHC.Unqual occ)))) sig _ _))))
    | OccName.occNameString occ == "Signal" -> SignalExpr sig
  ExprWithTySig _ expr' ty -> PortType (hsSigWcType ty) (bindMaster expr')


  -- OpApp _xapp (L _ circuitVar) (L _ infixVar) appR -> k

  _ -> PortErr loc
    (Err.mkLocMessageAnn
      Nothing
      Err.MCFatal
      loc
      (Outputable.text $ "Unhandled expression " <> show (Data.toConstr expr))
      )

-- | Create a binding expression
bodyBinding
  :: (p ~ GhcPs, loc ~ SrcSpan)
  => Maybe (PortDescription PortName)
  -- ^ the bound variable, this can be Nothing if there is no @<-@ (a circuit with no slaves)
  -> GenLocated loc (HsExpr p)
  -- ^ the statement with an optional @-<@
  -> CircuitM ()
bodyBinding mInput lexpr@(L loc expr) = do
  case expr of








    OpApp _ circuit (L _ op) port | isFletching op -> do
      circuitBinds <>= [Binding
        { bCircuit = circuit
        , bOut     = bindMaster port
        , bIn      = fromMaybe (Tuple []) mInput
        }]


    _ -> case mInput of
      Nothing -> errM loc "standalone expressions are not allowed (are Arrows enabled?)"
      Just input -> circuitBinds <>= [Binding
        { bCircuit = lexpr
        , bOut     = Tuple []
        , bIn      = input
        }]

-- Checking ------------------------------------------------------------

data Dir = Slave | Master

checkCircuit :: p ~ GhcPs => CircuitM ()
checkCircuit = do
  slaves <- L.use circuitSlaves
  masters <- L.use circuitMasters
  binds <- L.use circuitBinds

  let portNames d = L.toListOf (L.cosmos . _Ref . L.to (f d))
      f :: Dir -> PortName -> (GHC.FastString, ([SrcSpan], [SrcSpan]))
      f Slave (PortName srcLoc portName) = (portName, ([srcLoc], []))
      f Master (PortName srcLoc portName) = (portName, ([], [srcLoc]))
      bindingNames = \b -> portNames Master (bOut b) <> portNames Slave (bIn b)
      topNames = portNames Slave slaves <> portNames Master masters
      nameMap = Map.fromListWith mappend $ topNames <> concatMap bindingNames binds

  L.iforM_ nameMap \name occ ->
    case occ of
      ([_], [_]) -> pure ()
      (ss, ms) -> do
        unless (head (unpackFS name) == '_') $ do
          when (null ms) $ errM (head ss) $ "Slave port " <> show name <> " has no associated master"
          when (null ss) $ errM (head ms) $ "Master port " <> show name <> " has no associated slave"
        -- would be nice to show locations of all occurrences here, not sure how to do that while
        -- keeping ghc api
        when (length ms > 1) $
          errM (head ms) $ "Master port " <> show name <> " defined " <> show (length ms) <> " times"
        when (length ss > 1) $
          errM (head ss) $ "Slave port " <> show name <> " defined " <> show (length ss) <> " times"

-- Creating ------------------------------------------------------------

bindWithSuffix :: (p ~ GhcPs, ?nms :: ExternalNames) => GHC.DynFlags -> String -> PortDescription PortName -> LPat p
bindWithSuffix dflags suffix = \case
  Tuple ps -> tildeP noSrcSpan $ tupP $ fmap (bindWithSuffix dflags suffix) ps
  Vec s ps -> vecP s $ fmap (bindWithSuffix dflags suffix) ps
  Ref (PortName loc fs) -> varP loc (GHC.unpackFS fs <> suffix)
  PortErr loc msgdoc -> do
    let errMsg = Outputable.text "Unhandled bind" Outputtable.$+$ msgdoc
    unsafePerformIO . Outputtable.throwOneError $ Err.mkErrorMsgEnvelope loc Outputtable.reallyAlwaysQualify (GHC.ghcUnknownMessage errMsg)

  Lazy loc p -> tildeP loc $ bindWithSuffix dflags suffix p
  SignalExpr (L l _) -> L l (WildPat noExt)
  SignalPat lpat -> lpat
  PortType _ p -> bindWithSuffix dflags suffix p

data Direc = Fwd | Bwd

bindOutputs
  :: (p ~ GhcPs, ?nms :: ExternalNames)
  => GHC.DynFlags
  -> Direc
  -> PortDescription PortName
  -- ^ slave ports
  -> PortDescription PortName
  -- ^ master ports
  -> LPat p
bindOutputs dflags Fwd slaves masters = noLocA $ conPatIn (noLoc (fwdBwdCon ?nms)) (InfixCon m2s s2m)
  where
  m2s = bindWithSuffix dflags "_Fwd" masters
  s2m = bindWithSuffix dflags "_Bwd" slaves
bindOutputs dflags Bwd slaves masters = noLocA $ conPatIn (noLoc (fwdBwdCon ?nms)) (InfixCon m2s s2m)
  where
  m2s = bindWithSuffix dflags "_Bwd" masters
  s2m = bindWithSuffix dflags "_Fwd" slaves

expWithSuffix :: p ~ GhcPs => String -> PortDescription PortName -> LHsExpr p
expWithSuffix suffix = \case
  Tuple ps -> tupE noSrcSpan $ fmap (expWithSuffix suffix) ps
  Vec s ps -> vecE s $ fmap (expWithSuffix suffix) ps
  Ref (PortName loc fs)   -> varE loc (var $ GHC.unpackFS fs <> suffix)
  -- laziness only affects the pattern side
  Lazy _ p   -> expWithSuffix suffix p
  PortErr _ _ -> error "expWithSuffix PortErr!"
  SignalExpr lexpr -> lexpr
  SignalPat (noLoc -> L l _) -> tupE l []
  PortType _ p -> expWithSuffix suffix p

createInputs
  :: (p ~ GhcPs, ?nms :: ExternalNames)
  => Direc
  -> PortDescription PortName
  -- ^ slave ports
  -> PortDescription PortName
  -- ^ master ports
  -> LHsExpr p
createInputs Fwd slaves masters = noLocA $ OpApp noAnn s2m (varE noSrcSpan (fwdBwdCon ?nms)) m2s
  where
  m2s = expWithSuffix "_Bwd" masters
  s2m = expWithSuffix "_Fwd" slaves
createInputs Bwd slaves masters = noLocA $ OpApp noAnn s2m (varE noSrcSpan (fwdBwdCon ?nms)) m2s
  where
  m2s = expWithSuffix "_Fwd" masters
  s2m = expWithSuffix "_Bwd" slaves

decFromBinding :: (p ~ GhcPs, ?nms :: ExternalNames) => GHC.DynFlags -> Int -> Binding (LHsExpr p) PortName -> HsBind p
decFromBinding dflags i Binding {..} = do
  let bindPat  = bindOutputs dflags Bwd bIn bOut
      inputExp = createInputs Fwd bOut bIn
      bod = varE noSrcSpan (var $ "run" <> show i) `appE` bCircuit `appE` inputExp
   in patBind bindPat bod

patBind :: p ~ GhcPs => LPat p -> LHsExpr p -> HsBind p
patBind lhs expr = PatBind noAnn lhs rhs ([], [])
  where
    rhs = GRHSs emptyComments [la2la gr] (EmptyLocalBinds noExt)
    gr  = L (getLoc expr) (GRHS noAnn [] expr)

circuitConstructor :: (p ~ GhcPs, ?nms :: ExternalNames) => SrcSpan -> LHsExpr p
circuitConstructor loc = varE loc (circuitCon ?nms)

runCircuitFun :: (p ~ GhcPs, ?nms :: ExternalNames) => SrcSpan -> LHsExpr p
runCircuitFun loc = varE loc (runCircuitName ?nms)

constVar :: p ~ GhcPs => SrcSpan -> LHsExpr p
constVar loc = varE loc (thName 'const)

deepShowD :: Data.Data a => a -> String
deepShowD a = show (Data.toConstr a) <>
  -- " (" <> (unwords . fst) (SYB.gmapM (\x -> ([show $ Data.toConstr x], x)) a) <> ")"
  " (" <> (unwords . fst) (SYB.gmapM (\x -> ([deepShowD x], x)) a) <> ")"

unsnoc :: [a] -> Maybe ([a], a)
unsnoc [] = Nothing
unsnoc [x] = Just ([], x)
unsnoc (x:xs) = Just (x:a, b)
    where Just (a,b) = unsnoc xs

hsFunTy :: (p ~ GhcPs) => LHsType p -> LHsType p -> HsType p
hsFunTy =
  HsFunTy noAnn

    (HsUnrestrictedArrow noHsUniTok)


arrTy :: p ~ GhcPs => LHsType p -> LHsType p -> LHsType p
arrTy a b = noLocA $ hsFunTy (parenthesizeHsType GHC.funPrec a) (parenthesizeHsType GHC.funPrec b)

varT :: SrcSpan -> String -> LHsType GhcPs
varT loc nm = reLocA $ L loc (HsTyVar noAnn NotPromoted (reLocA $ L loc (tyVar nm)))

conT :: SrcSpan -> GHC.RdrName -> LHsType GhcPs
conT loc nm = reLocA $ L loc (HsTyVar noAnn NotPromoted (reLocA $ L loc nm))

circuitTy :: (p ~ GhcPs, ?nms :: ExternalNames) => LHsType p -> LHsType p -> LHsType p
circuitTy a b = conT noSrcSpan (circuitTyCon ?nms) `appTy` a `appTy` b

circuitTTy :: (p ~ GhcPs, ?nms :: ExternalNames) => LHsType p -> LHsType p -> LHsType p
circuitTTy a b = conT noSrcSpan (circuitTTyCon ?nms) `appTy` a `appTy` b

-- a b -> (Circuit a b -> CircuitT a b)
mkRunCircuitTy :: (p ~ GhcPs, ?nms :: ExternalNames) => LHsType p -> LHsType p -> LHsType p
mkRunCircuitTy a b = noLocA $ hsFunTy (circuitTy a b) (circuitTTy a b)

-- a b -> (CircuitT a b -> Circuit a b)
mkCircuitTy :: (p ~ GhcPs, ?nms :: ExternalNames) => LHsType p -> LHsType p -> LHsType p
mkCircuitTy a b = noLocA $ hsFunTy (circuitTTy a b) (circuitTy a b)

-- perhaps this should happen on construction
gatherTypes
  :: p ~ GhcPs
  => PortDescription PortName
  -> CircuitM ()
gatherTypes = L.traverseOf_ L.cosmos addTypes
  where
    addTypes = \case
      PortType ty (Ref (PortName loc fs)) -> portVarTypes . L.at fs ?= (loc, ty)
      PortType ty p -> portTypes <>= [(ty, p)]
      _             -> pure ()

tyEq :: p ~ GhcPs => SrcSpan -> LHsType p -> LHsType p -> LHsType p
tyEq l a b = reLocA $ L l $ HsOpTy noAnn NotPromoted a (noLocA eqTyCon_RDR) b
-- eqTyCon is a special name that has to be exactly correct for ghc to recognise it. In 8.6 this
-- lives in PrelNames and is called eqTyCon_RDR, in later ghcs it's from TysWiredIn.

-- Final construction --------------------------------------------------

circuitQQExpM
  :: (p ~ GhcPs, ?nms :: ExternalNames)
  => CircuitM (LHsExpr p)
circuitQQExpM = do
  checkCircuit

  dflags <- GHC.getDynFlags
  binds <- L.use circuitBinds
  lets <- L.use circuitLets
  letTypes <- L.use circuitTypes
  slaves <- L.use circuitSlaves
  masters <- L.use circuitMasters

  -- Construction of the circuit expression
  let decs = lets ++ imap (\i -> noLoc . decFromBinding dflags i) binds
  let pats = bindOutputs dflags Fwd masters slaves
      res  = createInputs Bwd slaves masters

      body :: LHsExpr GhcPs
      body = letE noSrcSpan letTypes (fmap reLocA decs) res

  -- see [inference-helper]
  mapM_
    (\(Binding _ outs ins) -> gatherTypes outs >> gatherTypes ins)
    binds
  mapM_ gatherTypes [masters, slaves]

  slavesTy <- portTypeSigM slaves
  mastersTy <- portTypeSigM masters
  let mkRunTy bind =
        mkRunCircuitTy <$>
          portTypeSigM (bOut bind) <*>
          portTypeSigM (bIn bind)
  bindTypes <- mapM mkRunTy binds
  let runCircuitsType =
        noLocA (HsParTy noAnn (tupT bindTypes `arrTy` circuitTTy slavesTy mastersTy))
          `arrTy` circuitTy slavesTy mastersTy

  allTypes <- L.use portTypes

  context <- mapM (\(ty, p) -> tyEq noSrcSpan <$> portTypeSigM p <*> pure ty) allTypes

  -- the full signature
  loc <- L.use circuitLoc
  let inferenceHelperName = genLocName loc "inferenceHelper"
      inferenceSig :: LHsSigType GhcPs
      inferenceSig = noLocA $ HsSig noExt mkHsOuterImplicit (noLocA $ HsQualTy noExt (noLocA context) runCircuitsType)
      inferenceHelperTy =
        TypeSig noAnn
          [noLocA (var inferenceHelperName)]
          (HsWC noExt inferenceSig)

  let numBinds = length binds
      runCircuitExprs = lamE [varP noSrcSpan "f"] $
        circuitConstructor noSrcSpan `appE`
          noLocA (HsPar noAnn noHsTok
          (varE noSrcSpan (var "f") `appE` tupE noSrcSpan (replicate numBinds (runCircuitFun noSrcSpan))) noHsTok )
      runCircuitBinds = tupP $ map (\i -> varP noSrcSpan ("run" <> show i)) [0 .. numBinds-1]

  let c = letE noSrcSpan
            [noLocA inferenceHelperTy]
            [noLocA $ patBind (varP noSrcSpan inferenceHelperName) (runCircuitExprs)]
            (varE noSrcSpan (var inferenceHelperName) `appE` lamE [runCircuitBinds, pats] body)
  -- ppr c
  pure c

  -- pure $ varE noSrcSpan (var "undefined")

-- [inference-helper]
-- The inference helper constructs the circuit and provides all the `runCircuit`s with the types
-- matching the structure of the port expressions. This way we can enforce that ports 'keep the
-- same type' which normally gets lost when deconstructing and reconstructing types. It also means
-- that we can add type annotations of the ports as a context to this helper function. For example
--
-- swapIC c = circuit $ \(a :: Int, b) -> do
--   a' <- c -< a
--   b' <- c -< b
--   idC -< (b',a')
--
-- will produce the helper
--
-- inferenceHelper ::
--   aTy ~ Int =>
--   -> (   (Circuit aTy a'Ty -> CircuitT aTy a'Ty)
--       -> (Circuit bTy b'Ty -> CircuitT bTy b'Ty)
--       -> CircuitT (aTy, bTy) (b'Ty, a'Ty)
--      ) -> CircuitT (aTy, bTy) (b'Ty, a'Ty)
-- inferenceHelper = \f -> Circuit (f runCircuit runCircuit)


grr :: MonadIO m => OccName.NameSpace -> m ()
grr nm
  | nm == OccName.tcName = liftIO $ putStrLn "tcName"
  | nm == OccName.clsName = liftIO $ putStrLn "clsName"
  | nm == OccName.tcClsName = liftIO $ putStrLn "tcClsName"
  | nm == OccName.dataName = liftIO $ putStrLn "dataName"
  | nm == OccName.varName = liftIO $ putStrLn "varName"
  | nm == OccName.tvName = liftIO $ putStrLn "tvName"
  | otherwise = liftIO $ putStrLn "I dunno"

completeUnderscores :: CircuitM ()
completeUnderscores = do
  binds <- L.use circuitBinds
  masters <- L.use circuitMasters
  slaves <- L.use circuitSlaves
  let addDef :: String -> PortDescription PortName -> CircuitM ()
      addDef suffix = \case
        Ref (PortName loc (unpackFS -> name@('_':_))) -> do
          let bind = patBind (varP loc (name <> suffix)) (varE loc (thName 'def))
          circuitLets <>= [L loc bind]

        _ -> pure ()
      addBind :: Binding exp PortName -> CircuitM ()
      addBind (Binding _ bOut bIn) = do
        L.traverseOf_ L.cosmos (addDef "_Fwd") bOut
        L.traverseOf_ L.cosmos (addDef "_Bwd") bIn
  mapM_ addBind binds
  addBind (Binding undefined masters slaves)


-- | Transform declarations in the module by converting circuit blocks.
transform
    :: (?nms :: ExternalNames)
    => Bool
#if __GLASGOW_HASKELL__ >= 900
    -> GHC.Located HsModule
    -> GHC.Hsc (GHC.Located HsModule)
#else
    -> GHC.Located (HsModule GhcPs)
    -> GHC.Hsc (GHC.Located (HsModule GhcPs))
#endif
transform debug = SYB.everywhereM (SYB.mkM transform') where
  transform' :: LHsExpr GhcPs -> GHC.Hsc (LHsExpr GhcPs)

  -- the circuit keyword directly applied (either with parenthesis or with BlockArguments)
  transform' (L _ (HsApp _xapp (L _ circuitVar) lappB))
    | isCircuitVar circuitVar = runCircuitM $ do
        x <- parseCircuit lappB >> completeUnderscores >> circuitQQExpM
        when debug $ ppr x
        pure x

  -- `circuit $` application
  transform' (L _ (OpApp _xapp c@(L _ circuitVar) (L _ infixVar) appR))
    | isDollar infixVar && dollarChainIsCircuit circuitVar = do
        runCircuitM $ do
          x <- parseCircuit appR >> completeUnderscores >> circuitQQExpM
          when debug $ ppr x
          pure (dollarChainReplaceCircuit x c)

  transform' e = pure e

-- | check if circuit is applied via `a $ chain $ of $ dollars`.
dollarChainIsCircuit :: HsExpr GhcPs -> Bool
dollarChainIsCircuit = \case
  HsVar _ (L _ v)                             -> v == GHC.mkVarUnqual "circuit"
  OpApp _xapp _appL (L _ infixVar) (L _ appR) -> isDollar infixVar && dollarChainIsCircuit appR
  _                                           -> False

-- | Replace the circuit if it's part of a chain of `$`.
dollarChainReplaceCircuit :: LHsExpr GhcPs -> LHsExpr GhcPs -> LHsExpr GhcPs
dollarChainReplaceCircuit circuitExpr (L loc app) = case app of
  HsVar _ (L _loc v)
    -> if v == GHC.mkVarUnqual "circuit"
         then circuitExpr
         else error "dollarChainAddCircuit: not a circuit"
  OpApp xapp appL (L infixLoc infixVar) appR
    -> L loc $ OpApp xapp appL (L infixLoc infixVar) (dollarChainReplaceCircuit circuitExpr appR)
  t -> error $ "dollarChainAddCircuit unhandled case " <> showC t

-- | The plugin for circuit notation.
plugin :: GHC.Plugin
plugin = mkPlugin defExternalNames

-- | Make a plugin with custom external names
mkPlugin :: ExternalNames -> GHC.Plugin
mkPlugin nms = GHC.defaultPlugin
  { GHC.parsedResultAction = let ?nms = nms in pluginImpl
    -- Mark plugin as 'pure' to prevent recompilations.
  , GHC.pluginRecompile = \_cliOptions -> pure GHC.NoForceRecompile
  }

-- | The actual implementation.
pluginImpl :: (?nms :: ExternalNames) => [GHC.CommandLineOption] -> GHC.ModSummary -> GHC.ParsedResult -> GHC.Hsc GHC.ParsedResult
pluginImpl cliOptions _modSummary (Outputtable.ParsedResult m _)  = do
    -- cli options are activated by -fplugin-opt=CircuitNotation:debug
    debug <- case cliOptions of
      []        -> pure False
      ["debug"] -> pure True
      _ -> do
        let errMsg = Outputable.text $ "CircuitNotation: unknown cli options " <> show cliOptions
        liftIO . Outputtable.throwOneError $ Err.mkErrorMsgEnvelope noSrcSpan Outputtable.reallyAlwaysQualify (GHC.ghcUnknownMessage errMsg)
    hpm_module' <- do
      transform debug (GHC.hpm_module m)
    let module' = m { GHC.hpm_module = hpm_module' }
    return $ Outputtable.ParsedResult  module' (Outputtable.PsMessages emptyMessages emptyMessages)

-- Debugging functions -------------------------------------------------

ppr :: GHC.Outputable a => a -> CircuitM ()
ppr a = do
  dflags <- GHC.getDynFlags
  liftIO $ putStrLn (GHC.showPpr dflags a)

showC :: Data.Data a => a -> String
showC a = show (typeOf a) <> " " <> show (Data.toConstr a)

-- ppp :: MonadIO m => String -> m ()
-- ppp s = case SP.parseValue s of
--   Just a -> valToStr a

-- Names ---------------------------------------------------------------

-- | Collection of names external to circuit-notation.
data ExternalNames = ExternalNames
  { circuitCon :: GHC.RdrName
  , circuitTyCon :: GHC.RdrName
  , circuitTTyCon :: GHC.RdrName
  , runCircuitName :: GHC.RdrName
  , fwdBwdCon :: GHC.RdrName
  }

defExternalNames :: ExternalNames
defExternalNames = ExternalNames
  { circuitCon = GHC.Unqual (OccName.mkDataOcc "Circuit")
  , circuitTyCon = GHC.Unqual (OccName.mkTcOcc "Circuit")
  , circuitTTyCon = GHC.Unqual (OccName.mkTcOcc "CircuitT")
  , runCircuitName = GHC.Unqual (OccName.mkVarOcc "runCircuit")
  , fwdBwdCon = GHC.Unqual (OccName.mkDataOcc ":->")
  }
