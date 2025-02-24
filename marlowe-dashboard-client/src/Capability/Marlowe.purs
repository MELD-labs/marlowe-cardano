module Capability.Marlowe
  ( class ManageMarlowe
  , createWallet
  , followContract
  , createPendingFollowerApp
  , followContractWithPendingFollowerApp
  , createContract
  , applyTransactionInput
  , redeem
  , lookupWalletInfo
  , lookupWalletDetails
  , getRoleContracts
  , getFollowerApps
  , subscribeToWallet
  , unsubscribeFromWallet
  , subscribeToPlutusApp
  , unsubscribeFromPlutusApp
  ) where

import Prologue
import API.Lenses (_cicContract, _cicCurrentState, _cicDefinition, _cicWallet, _observableState)
import Affjax (defaultRequest)
import AppM (AppM)
import Bridge (toBack, toFront)
import Capability.Contract (activateContract, getContractInstanceClientState, getContractInstanceObservableState, getWalletContractInstances, invokeEndpoint) as Contract
import Capability.Contract (class ManageContract)
import Capability.MarloweStorage (class ManageMarloweStorage, addAssets, getContracts, getWalletLibrary, getWalletRoleContracts, insertContract, insertWalletRoleContracts)
import Capability.PlutusApps.MarloweApp as MarloweApp
import Capability.Wallet (class ManageWallet)
import Capability.Wallet (createWallet, getWalletInfo, getWalletTotalFunds) as Wallet
import Component.Contacts.Lenses (_companionAppId, _marloweAppId, _pubKeyHash, _wallet, _walletInfo)
import Component.Contacts.Types (Wallet(..), WalletDetails, WalletInfo(..))
import Control.Monad.Except (ExceptT(..), except, lift, mapExceptT, runExcept, runExceptT, withExceptT)
import Control.Monad.Reader (asks)
import Control.Monad.Reader.Class (ask)
import Data.Array (filter) as Array
import Data.Array (find)
import Data.Bifunctor (lmap)
import Data.BigInteger (fromInt)
import Data.Lens (view)
import Data.Map (Map, findMin, fromFoldable, lookup, mapMaybeWithKey, singleton, toUnfoldable, values)
import Data.Map (filter) as Map
import Data.Maybe (fromMaybe)
import Data.Newtype (unwrap)
import Data.Time.Duration (Milliseconds(..))
import Data.Traversable (for, traverse)
import Data.Tuple.Nested ((/\))
import Data.UUID (genUUID, parseUUID, toString)
import Effect.Aff (delay)
import Effect.Class (liftEffect)
import Env (DataProvider(..))
import Foreign (MultipleErrors)
import Foreign.Generic (decodeJSON)
import Halogen (HalogenM, liftAff)
import Marlowe.Client (ContractHistory(..))
import Marlowe.PAB (PlutusAppId(..))
import Marlowe.Semantics (Assets(..), Contract, MarloweData(..), MarloweParams(..), PubKeyHash, TokenName, TransactionInput, _rolePayoutValidatorHash, asset, emptyState)
import MarloweContract (MarloweContract(..))
import Plutus.PAB.Webserver.Types (ContractInstanceClientState)
import Servant.PureScript.Ajax (AjaxError(..), ErrorDescription(..))
import Types (AjaxResponse, CombinedWSStreamToServer(..), DecodedAjaxResponse)
import WebSocket.Support as WS

-- The `ManageMarlowe` class provides a window on the `ManageContract` and `ManageWallet`
-- capabilities with functions specific to Marlowe. Or rather, it does when the
-- `dataProvider` env variable is set to `PAB`. When it is set to `LocalStorage`, these functions
-- instead provide what is needed to mimic real PAB behaviour in the frontend.
-- TODO (possibly): make `AppM` a `MonadError` and remove all the `runExceptT`s
class
  (ManageContract m, ManageMarloweStorage m, ManageWallet m) <= ManageMarlowe m where
  createWallet :: m (AjaxResponse WalletDetails)
  followContract :: WalletDetails -> MarloweParams -> m (DecodedAjaxResponse (Tuple PlutusAppId ContractHistory))
  createPendingFollowerApp :: WalletDetails -> m (AjaxResponse PlutusAppId)
  followContractWithPendingFollowerApp :: WalletDetails -> MarloweParams -> PlutusAppId -> m (DecodedAjaxResponse (Tuple PlutusAppId ContractHistory))
  createContract :: WalletDetails -> Map TokenName PubKeyHash -> Contract -> m (AjaxResponse Unit)
  applyTransactionInput :: WalletDetails -> MarloweParams -> TransactionInput -> m (AjaxResponse Unit)
  redeem :: WalletDetails -> MarloweParams -> TokenName -> m (AjaxResponse Unit)
  lookupWalletInfo :: PlutusAppId -> m (AjaxResponse WalletInfo)
  lookupWalletDetails :: PlutusAppId -> m (AjaxResponse WalletDetails)
  getRoleContracts :: WalletDetails -> m (DecodedAjaxResponse (Map MarloweParams MarloweData))
  getFollowerApps :: WalletDetails -> m (DecodedAjaxResponse (Map PlutusAppId ContractHistory))
  subscribeToPlutusApp :: PlutusAppId -> m Unit
  subscribeToWallet :: Wallet -> m Unit
  unsubscribeFromPlutusApp :: PlutusAppId -> m Unit
  unsubscribeFromWallet :: Wallet -> m Unit

instance manageMarloweAppM :: ManageMarlowe AppM where
  createWallet = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB -> do
        -- create the wallet itself
        ajaxWalletInfo <- Wallet.createWallet
        case ajaxWalletInfo of
          Left ajaxError -> pure $ Left ajaxError
          Right walletInfo -> do
            let
              wallet = view _wallet walletInfo
            -- create the WalletCompanion and MarloweApp for this wallet
            ajaxCompanionAppId <- Contract.activateContract WalletCompanion wallet
            ajaxMarloweAppId <- Contract.activateContract MarloweApp wallet
            -- get the wallet's current funds
            -- Note that, because it can take a moment for the initial demo funds to be added, at
            -- this point the funds might be zero. It doesn't matter though - if we connect this
            -- wallet, we'll get a WebSocket notification when the funds are added (and if we don't
            -- connect it, we don't need to know what they are.)
            -- TODO(?): Because of that, we could potentially forget about this call and just set
            -- assets to `mempty`.
            ajaxAssets <- Wallet.getWalletTotalFunds wallet
            let
              createWalletDetails companionAppId marloweAppId assets =
                { walletNickname: ""
                , companionAppId
                , marloweAppId
                , walletInfo
                , assets
                , previousCompanionAppState: Nothing
                }
            pure $ createWalletDetails <$> ajaxCompanionAppId <*> ajaxMarloweAppId <*> ajaxAssets
      LocalStorage -> do
        uuid <- liftEffect genUUID
        let
          uuidString = toString uuid

          walletInfo =
            WalletInfo
              { wallet: Wallet uuidString
              , pubKeyHash: uuidString
              }

          assets = Assets $ singleton "" $ singleton "" (fromInt 1000000 * fromInt 10000)

          walletDetails =
            { walletNickname: ""
            , companionAppId: PlutusAppId uuid
            , marloweAppId: PlutusAppId uuid
            , walletInfo
            , assets
            , previousCompanionAppState: Nothing
            }
        pure $ Right walletDetails
  -- create a MarloweFollower app, call its "follow" endpoint with the given MarloweParams, and then
  -- return its PlutusAppId and observable state
  followContract walletDetails marloweParams = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB ->
        runExceptT do
          let
            wallet = view (_walletInfo <<< _wallet) walletDetails
          followAppId <- withExceptT Left $ ExceptT $ Contract.activateContract MarloweFollower wallet
          void $ withExceptT Left $ ExceptT $ Contract.invokeEndpoint followAppId "follow" marloweParams
          observableStateJson <-
            withExceptT Left $ ExceptT $ Contract.getContractInstanceObservableState followAppId
          observableState <- mapExceptT (pure <<< lmap Right <<< unwrap) $ decodeJSON $ unwrap observableStateJson
          pure $ followAppId /\ observableState
      LocalStorage -> do
        existingContracts <- getContracts
        case lookup marloweParams existingContracts of
          Just (marloweData /\ transactionInputs) -> do
            uuid <- liftEffect genUUID
            let
              -- Note [MarloweParams]: In the PAB, the PlutusAppId and the MarloweParams are completely independent,
              -- and you can have several follower apps (with different PlutusAppIds) all following the same contract
              -- (identified by its MarloweParams). For the LocalStorage simlation we just have one follower app for
              -- each contract, and make its PlutusAppId a function of the MarloweParams. I thought this would be
              -- simpler, but it turned out to lead to a complication (see note [PendingContracts] in Dashboard.State).
              -- I'm not going to change it now though, because this LocalStorage stuff is temporary anyway, and will
              -- be removed when the PAB is working fully.
              mUuid = parseUUID $ view _rolePayoutValidatorHash marloweParams

              followAppId = PlutusAppId $ fromMaybe uuid mUuid

              observableState = ContractHistory { chParams: Just (marloweParams /\ marloweData), chHistory: transactionInputs }
            pure $ Right $ followAppId /\ observableState
          Nothing -> pure $ Left $ Left $ AjaxError { request: defaultRequest, description: NotFound }
  -- create a MarloweFollower app and return its PlutusAppId, but don't call its "follow" endpoint
  -- (this function is used for creating "placeholder" contracts before we know the MarloweParams)
  createPendingFollowerApp walletDetails = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB -> do
        let
          wallet = view (_walletInfo <<< _wallet) walletDetails
        Contract.activateContract MarloweFollower wallet
      LocalStorage -> do
        uuid <- liftEffect genUUID
        pure $ Right $ PlutusAppId uuid
  -- call the "follow" endpoint of a pending MarloweFollower app, and return its PlutusAppId and
  -- observable state (to call this function, we must already know its PlutusAppId, but we return
  -- it anyway because it is convenient to have this function return the same type as
  -- `followContract`)
  followContractWithPendingFollowerApp walletDetails marloweParams followerAppId = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB ->
        runExceptT do
          let
            wallet = view (_walletInfo <<< _wallet) walletDetails
          void $ withExceptT Left $ ExceptT $ Contract.invokeEndpoint followerAppId "follow" marloweParams
          observableStateJson <-
            withExceptT Left $ ExceptT $ Contract.getContractInstanceObservableState followerAppId
          observableState <- mapExceptT (pure <<< lmap Right <<< unwrap) $ decodeJSON $ unwrap observableStateJson
          pure $ followerAppId /\ observableState
      LocalStorage -> do
        existingContracts <- getContracts
        case lookup marloweParams existingContracts of
          Just (marloweData /\ transactionInputs) -> do
            uuid <- liftEffect genUUID
            let
              -- See note [MarloweParams] above.
              mUuid = parseUUID $ view _rolePayoutValidatorHash marloweParams

              correctedFollowerAppId = PlutusAppId $ fromMaybe uuid mUuid

              observableState = ContractHistory { chParams: Just (marloweParams /\ marloweData), chHistory: transactionInputs }
            pure $ Right $ correctedFollowerAppId /\ observableState
          Nothing -> pure $ Left $ Left $ AjaxError { request: defaultRequest, description: NotFound }
  -- "create" a Marlowe contract on the blockchain
  -- FIXME: if we want users to be able to follow contracts that they don't have roles in, we need this function
  -- to return the MarloweParams of the created contract - but this isn't currently possible in the PAB
  -- UPDATE to this FIXME: it is possible this won't be a problem, as it seems role tokens are first paid into
  -- the wallet that created the contract, and distributed to other wallets from there - but this remains to be
  -- seen when all the parts are working together as they should be...
  createContract walletDetails roles contract = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB ->
        let
          marloweAppId = view _marloweAppId walletDetails
        in
          MarloweApp.createContract marloweAppId roles contract
      LocalStorage -> do
        walletLibrary <- getWalletLibrary
        uuid <- liftEffect genUUID
        let
          marloweParams =
            MarloweParams
              { rolePayoutValidatorHash: toString uuid
              , rolesCurrency: { unCurrencySymbol: toString uuid }
              }

          marloweData =
            MarloweData
              { marloweContract: contract
              , marloweState: emptyState zero
              }
        void $ insertContract marloweParams (marloweData /\ mempty)
        void $ insertWalletRoleContracts (view (_walletInfo <<< _pubKeyHash) walletDetails) marloweParams marloweData
        let
          unfoldableRoles :: Array (Tuple TokenName PubKeyHash)
          unfoldableRoles = toUnfoldable roles
        void
          $ for unfoldableRoles \(tokenName /\ pubKeyHash) -> do
              void $ addAssets pubKeyHash $ asset (toString uuid) tokenName (fromInt 1)
              void $ insertWalletRoleContracts pubKeyHash marloweParams marloweData
        pure $ Right unit
  -- "apply-inputs" to a Marlowe contract on the blockchain
  applyTransactionInput walletDetails marloweParams transactionInput = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB ->
        let
          marloweAppId = view _marloweAppId walletDetails
        in
          MarloweApp.applyInputs marloweAppId marloweParams transactionInput
      LocalStorage -> do
        existingContracts <- getContracts
        -- When we emulate these calls we add a 500ms delay so we give time to the submit button
        -- to show a loading indicator (we'll remove this once the PAB is connected)
        liftAff $ delay $ Milliseconds 500.0
        case lookup marloweParams existingContracts of
          Just (marloweData /\ transactionInputs) -> do
            void $ insertContract marloweParams (marloweData /\ (transactionInputs <> [ transactionInput ]))
            pure $ Right unit
          Nothing -> pure $ Left $ AjaxError { request: defaultRequest, description: NotFound }
  -- "redeem" payments from a Marlowe contract on the blockchain
  redeem walletDetails marloweParams tokenName = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB ->
        let
          marloweAppId = view _marloweAppId walletDetails

          pubKeyHash = view (_walletInfo <<< _pubKeyHash) walletDetails
        in
          MarloweApp.redeem marloweAppId marloweParams tokenName pubKeyHash
      LocalStorage -> pure $ Right unit
  -- get the WalletInfo of a wallet given the PlutusAppId of its WalletCompanion
  lookupWalletInfo companionAppId = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB ->
        runExceptT do
          clientState <- ExceptT $ Contract.getContractInstanceClientState companionAppId
          case view _cicDefinition clientState of
            WalletCompanion -> do
              let
                wallet = toFront $ view _cicWallet clientState
              ExceptT $ Wallet.getWalletInfo wallet
            _ -> except $ Left $ AjaxError { request: defaultRequest, description: NotFound }
      LocalStorage ->
        runExceptT do
          walletDetails <- ExceptT $ lookupWalletDetails companionAppId
          pure $ view _walletInfo walletDetails
  -- get the WalletDetails of a wallet given the PlutusAppId of its WalletCompanion
  -- note: this returns an empty walletNickname (because these are only saved locally)
  lookupWalletDetails companionAppId = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB ->
        runExceptT do
          clientState <- ExceptT $ Contract.getContractInstanceClientState companionAppId
          case view _cicDefinition clientState of
            WalletCompanion -> do
              let
                wallet = toFront $ view _cicWallet clientState
              walletContracts <- ExceptT $ Contract.getWalletContractInstances wallet
              walletInfo <- ExceptT $ Wallet.getWalletInfo wallet
              assets <- ExceptT $ Wallet.getWalletTotalFunds wallet
              case find (\state -> view _cicDefinition state == MarloweApp) walletContracts of
                Just marloweApp ->
                  ExceptT $ pure
                    $ Right
                        { walletNickname: mempty
                        , companionAppId
                        , marloweAppId: toFront $ view _cicContract marloweApp
                        , walletInfo
                        , assets
                        , previousCompanionAppState: Nothing
                        }
                Nothing -> except $ Left $ AjaxError { request: defaultRequest, description: NotFound }
            _ -> except $ Left $ AjaxError { request: defaultRequest, description: NotFound }
      LocalStorage -> do
        walletLibrary <- getWalletLibrary
        let
          mWalletDetails = findMin $ Map.filter (\walletDetails -> view _companionAppId walletDetails == companionAppId) walletLibrary
        case mWalletDetails of
          Just { key, value } -> pure $ Right value
          Nothing -> pure $ Left $ AjaxError { request: defaultRequest, description: NotFound }
  -- get the observable state of a wallet's WalletCompanion
  getRoleContracts walletDetails = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB ->
        runExceptT do
          let
            companionAppId = view _companionAppId walletDetails
          observableStateJson <- withExceptT Left $ ExceptT $ Contract.getContractInstanceObservableState companionAppId
          mapExceptT (pure <<< lmap Right <<< unwrap) $ decodeJSON $ unwrap observableStateJson
      LocalStorage -> do
        roleContracts <- getWalletRoleContracts $ view (_walletInfo <<< _pubKeyHash) walletDetails
        pure $ Right roleContracts
  -- get all MarloweFollower apps for a given wallet
  getFollowerApps walletDetails = do
    { dataProvider } <- ask
    case dataProvider of
      MarlowePAB ->
        runExceptT do
          let
            wallet = view (_walletInfo <<< _wallet) walletDetails
          runningApps <- withExceptT Left $ ExceptT $ Contract.getWalletContractInstances wallet
          let
            followerApps = Array.filter (\cic -> view _cicDefinition cic == MarloweFollower) runningApps
          case traverse decodeFollowerAppState followerApps of
            Left decodingError -> except $ Left $ Right decodingError
            Right decodedFollowerApps -> ExceptT $ pure $ Right $ fromFoldable decodedFollowerApps
        where
        decodeFollowerAppState :: ContractInstanceClientState MarloweContract -> Either MultipleErrors (Tuple PlutusAppId ContractHistory)
        decodeFollowerAppState contractInstanceClientState =
          let
            plutusAppId = toFront $ view _cicContract contractInstanceClientState

            rawJson = view (_cicCurrentState <<< _observableState) contractInstanceClientState
          in
            case runExcept $ decodeJSON $ unwrap rawJson of
              Left decodingErrors -> Left decodingErrors
              Right observableState -> Right (plutusAppId /\ observableState)
      LocalStorage -> do
        roleContracts <- getWalletRoleContracts $ view (_walletInfo <<< _pubKeyHash) walletDetails
        allContracts <- getContracts
        let
          roleContractsToHistory :: MarloweParams -> MarloweData -> Maybe (Tuple PlutusAppId ContractHistory)
          roleContractsToHistory marloweParams marloweData =
            let
              -- See note [MarloweParams] above.
              mUuid = parseUUID $ view _rolePayoutValidatorHash marloweParams

              mTransactionInputs = map snd $ lookup marloweParams allContracts
            in
              case mUuid, mTransactionInputs of
                Just uuid, Just transactionInputs ->
                  let
                    plutusAppId = PlutusAppId uuid

                    contractHistory = ContractHistory { chParams: Just $ marloweParams /\ marloweData, chHistory: transactionInputs }
                  in
                    Just $ plutusAppId /\ contractHistory
                _, _ -> Nothing
        pure $ Right $ fromFoldable $ values $ mapMaybeWithKey roleContractsToHistory roleContracts
  subscribeToPlutusApp = toBack >>> Left >>> Subscribe >>> sendWsMessage
  subscribeToWallet = toBack >>> Right >>> Subscribe >>> sendWsMessage
  unsubscribeFromPlutusApp = toBack >>> Left >>> Unsubscribe >>> sendWsMessage
  unsubscribeFromWallet = toBack >>> Right >>> Unsubscribe >>> sendWsMessage

sendWsMessage :: CombinedWSStreamToServer -> AppM Unit
sendWsMessage msg = do
  wsManager <- asks _.wsManager
  dataProvider <- asks _.dataProvider
  when (dataProvider == MarlowePAB)
    $ liftAff
    $ WS.managerWriteOutbound wsManager
    $ WS.SendMessage msg

instance monadMarloweHalogenM :: (ManageMarlowe m) => ManageMarlowe (HalogenM state action slots msg m) where
  createWallet = lift createWallet
  followContract walletDetails marloweParams = lift $ followContract walletDetails marloweParams
  createPendingFollowerApp = lift <<< createPendingFollowerApp
  followContractWithPendingFollowerApp walletDetails marloweParams followAppId = lift $ followContractWithPendingFollowerApp walletDetails marloweParams followAppId
  createContract walletDetails roles contract = lift $ createContract walletDetails roles contract
  applyTransactionInput walletDetails marloweParams transactionInput = lift $ applyTransactionInput walletDetails marloweParams transactionInput
  redeem walletDetails marloweParams tokenName = lift $ redeem walletDetails marloweParams tokenName
  lookupWalletInfo = lift <<< lookupWalletInfo
  lookupWalletDetails = lift <<< lookupWalletDetails
  getRoleContracts = lift <<< getRoleContracts
  getFollowerApps = lift <<< getFollowerApps
  subscribeToPlutusApp = lift <<< subscribeToPlutusApp
  subscribeToWallet = lift <<< subscribeToWallet
  unsubscribeFromPlutusApp = lift <<< unsubscribeFromPlutusApp
  unsubscribeFromWallet = lift <<< unsubscribeFromWallet
