{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

{-# OPTIONS_GHC -w #-}
module Spec.Marlowe.Marlowe
    ( prop_noFalsePositives, tests, prop_showWorksForContracts, prop_jsonLoops
    )
where

import qualified Codec.CBOR.Write                      as Write
import qualified Codec.Serialise                       as Serialise
import           Control.Exception                     (SomeException, catch)
import           Control.Lens                          ((&), (.~))
import           Control.Monad                         (void)
import           Control.Monad.Freer                   (run)
import           Control.Monad.Freer.Error             (runError)
import           Data.Aeson                            (decode, encode)
import           Data.Aeson.Text                       (encodeToLazyText)
import qualified Data.ByteString                       as BS
import           Data.Default                          (Default (..))
import           Data.Either                           (fromRight, isRight)
import qualified Data.Map.Strict                       as Map
import           Data.Maybe                            (isJust, isNothing)
import           Data.Monoid                           (First (..))
import           Data.Ratio                            ((%))
import           Data.Set                              (Set)
import qualified Data.Set                              as Set
import           Data.String
import qualified Data.Text                             as T
import qualified Data.Text.IO                          as T
import           Data.Text.Lazy                        (toStrict)
import           Data.UUID                             (UUID)
import qualified Data.UUID                             as UUID
import           Language.Haskell.Interpreter          (Extension (OverloadedStrings), MonadInterpreter,
                                                        OptionVal ((:=)), as, interpret, languageExtensions,
                                                        runInterpreter, set, setImports)
import           Language.Marlowe.Analysis.FSSemantics
import           Language.Marlowe.Client
import           Language.Marlowe.Deserialisation      (byteStringToInt, byteStringToList)
import           Language.Marlowe.Scripts              (MarloweInput, mkMarloweStateMachineTransition, rolePayoutScript,
                                                        typedValidator)
import           Language.Marlowe.Semantics
import           Language.Marlowe.SemanticsTypes
import           Language.Marlowe.Serialisation        (intToByteString, listToByteString)
import           Language.Marlowe.Util
import           Ledger                                (Slot (..), pubKeyHash, validatorHash)
import           Ledger.Ada                            (lovelaceValueOf)
import           Ledger.Constraints.TxConstraints      (TxConstraints)
import qualified Ledger.Typed.Scripts                  as Scripts
import qualified Ledger.Value                          as Val
import qualified Plutus.Contract.StateMachine          as SM
import           Plutus.Contract.Test                  hiding ((.&&.))
import qualified Plutus.Contract.Test                  as T
import           Plutus.Contract.Types                 (_observableState)
import qualified Plutus.Trace.Emulator                 as Trace
import           Plutus.Trace.Emulator.Types           (instContractState)
import qualified PlutusTx.AssocMap                     as AssocMap
import           PlutusTx.Builtins                     (emptyByteString)
import           PlutusTx.Lattice
import qualified PlutusTx.Prelude                      as P
import           Spec.Marlowe.Common
import qualified Streaming.Prelude                     as S
import           System.IO.Unsafe                      (unsafePerformIO)
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck
import qualified Wallet.Emulator.Folds                 as Folds
import           Wallet.Emulator.Stream                (foldEmulatorStreamM, takeUntilSlot)

{- HLINT ignore "Reduce duplication" -}
{- HLINT ignore "Redundant if" -}

tests :: TestTree
tests = testGroup "Marlowe"
    [ testCase "Contracts with different creators have different hashes" uniqueContractHash
    , testCase "Token Show instance respects HEX and Unicode" tokenShowTest
    , testCase "Pangram Contract serializes into valid JSON" pangramContractSerialization
    , testCase "State serializes into valid JSON" stateSerialization
    , testCase "Validator size is reasonable" validatorSize
    , testCase "Mul analysis" mulAnalysisTest
    , testCase "Div analysis" divAnalysisTest
    , testCase "Div tests" divTest
    , testCase "Transfers between accounts work" transferBetweenAccountsTest
    , testCase "extractContractRoles" extractContractRolesTest
    , testProperty "Value equality is reflexive, symmetric, and transitive" checkEqValue
    , testProperty "Value double negation" doubleNegation
    , testProperty "Values form abelian group" valuesFormAbelianGroup
    , testProperty "Values can be serialized to JSON" valueSerialization
    , testProperty "Scale Value multiplies by a constant rational" scaleMulTest
    , testProperty "Multiply by zero" mulTest
    , testProperty "Divide zero and by zero" divZeroTest
    , testProperty "DivValue rounding" divisionRoundingTest
    , testGroup "ByteString ad-hoc (de)serialisation"
        [ testProperty "Integer (de)serialisation roundtrip" integerBSRoundtripTest
        , testProperty "Integer list (de)serialisation roundtrip" integerListBSRoundtripTest
        ]
    , zeroCouponBondTest
    , errorHandlingTest
    , trustFundTest
    ]


alice, bob :: Wallet
alice = w1
bob = w2

reqId :: UUID
reqId = UUID.nil


zeroCouponBondTest :: TestTree
zeroCouponBondTest = checkPredicateOptions defaultCheckOptions "Zero Coupon Bond Contract"
    (assertNoFailedTransactions
    -- T..&&. emulatorLog (const False) ""
    T..&&. assertDone marlowePlutusContract (Trace.walletInstanceTag alice) (const True) "contract should close"
    T..&&. assertDone marlowePlutusContract (Trace.walletInstanceTag bob) (const True) "contract should close"
    T..&&. walletFundsChange alice (lovelaceValueOf 150)
    T..&&. walletFundsChange bob (lovelaceValueOf (-150))
    T..&&. assertAccumState marlowePlutusContract (Trace.walletInstanceTag alice) ((==) (OK reqId "close")) "should be OK"
    T..&&. assertAccumState marlowePlutusContract (Trace.walletInstanceTag bob) ((==) (OK reqId "close")) "should be OK"
    ) $ do
    -- Init a contract
    let alicePk = PK (walletPubKeyHash alice)
        bobPk = PK (walletPubKeyHash bob)

    let params = defaultMarloweParams

    let zeroCouponBond = When [ Case
            (Deposit alicePk alicePk ada (Constant 850))
            (Pay alicePk (Party bobPk) ada (Constant 850)
                (When
                    [ Case (Deposit alicePk bobPk ada (Constant 1000)) Close] (Slot 200) Close
                ))] (Slot 100) Close

    bobHdl <- Trace.activateContractWallet bob marlowePlutusContract
    aliceHdl <- Trace.activateContractWallet alice marlowePlutusContract

    Trace.callEndpoint @"create" aliceHdl (reqId, AssocMap.empty, zeroCouponBond)
    Trace.waitNSlots 2

    Trace.callEndpoint @"apply-inputs" aliceHdl (reqId, params, Nothing, [IDeposit alicePk alicePk ada 850])
    Trace.waitNSlots 2

    Trace.callEndpoint @"apply-inputs" bobHdl (reqId, params, Nothing, [IDeposit alicePk bobPk ada 1000])
    void $ Trace.waitNSlots 2

    Trace.callEndpoint @"close" aliceHdl reqId
    Trace.callEndpoint @"close" bobHdl reqId
    void $ Trace.waitNSlots 2


errorHandlingTest :: TestTree
errorHandlingTest = checkPredicateOptions defaultCheckOptions "Error handling"
    (assertAccumState marlowePlutusContract (Trace.walletInstanceTag alice)
    (\case SomeError _ "apply-inputs" (TransitionError _) -> True
           _                                              -> False
    ) "should be fail with SomeError"
    ) $ do
    -- Init a contract
    let alicePk = PK (walletPubKeyHash alice)
        bobPk = PK (walletPubKeyHash bob)

    let params = defaultMarloweParams

    let zeroCouponBond = When [ Case
            (Deposit alicePk alicePk ada (Constant 850))
            (Pay alicePk (Party bobPk) ada (Constant 850)
                (When
                    [ Case (Deposit alicePk bobPk ada (Constant 1000)) Close] (Slot 200) Close
                ))] (Slot 100) Close

    bobHdl <- Trace.activateContractWallet bob marlowePlutusContract
    aliceHdl <- Trace.activateContractWallet alice marlowePlutusContract

    Trace.callEndpoint @"create" aliceHdl (reqId, AssocMap.empty, zeroCouponBond)
    Trace.waitNSlots 2

    Trace.callEndpoint @"apply-inputs" aliceHdl (reqId, params, Nothing, [IDeposit alicePk alicePk ada 1000])
    Trace.waitNSlots 2
    pure ()


trustFundTest :: TestTree
trustFundTest = checkPredicateOptions defaultCheckOptions "Trust Fund Contract"
    (assertNoFailedTransactions
    -- T..&&. emulatorLog (const False) ""
    T..&&. assertNotDone marlowePlutusContract (Trace.walletInstanceTag alice) "contract should not have any errors"
    T..&&. assertNotDone marlowePlutusContract (Trace.walletInstanceTag bob) "contract should not have any errors"
    T..&&. walletFundsChange alice (lovelaceValueOf (-256) <> Val.singleton (rolesCurrency params) "alice" 1)
    T..&&. walletFundsChange bob (lovelaceValueOf 256 <> Val.singleton (rolesCurrency params) "bob" 1)
    -- TODO Commented out because the new chain index does not allow to fetch
    -- all transactions that modified an address. Need to find an alternative
    -- way.
    --T..&&. assertAccumState marloweFollowContract "bob follow"
    --    (\state@ContractHistory{chParams, chHistory} ->
    --        case chParams of
    --            First (Just (mp, MarloweData{marloweContract})) -> mp == params && marloweContract == contract
    --            _                                               -> False) "follower contract state"
    --        --mp MarloweData{marloweContract} history
    --        -- chParams == (_ params) && chParams == (_ contract))
    ) $ do

    -- Init a contract
    let alicePkh = walletPubKeyHash alice
        bobPkh = walletPubKeyHash bob
    bobHdl <- Trace.activateContractWallet bob marlowePlutusContract
    aliceHdl <- Trace.activateContractWallet alice marlowePlutusContract
    bobCompanionHdl <- Trace.activateContract bob marloweCompanionContract "bob companion"
    bobFollowHdl <- Trace.activateContract bob marloweFollowContract "bob follow"

    Trace.callEndpoint @"create" aliceHdl
        (reqId, AssocMap.fromList [("alice", alicePkh), ("bob", bobPkh)],
        contract)
    Trace.waitNSlots 5
    CompanionState r <- _observableState . instContractState <$> Trace.getContractState bobCompanionHdl
    case Map.toList r of
        [] -> pure ()
        (pms, _) : _ -> do

            Trace.callEndpoint @"apply-inputs" aliceHdl (reqId, pms, Nothing,
                [ IChoice chId 256
                , IDeposit "alice" "alice" ada 256
                ])
            Trace.waitNSlots 17

            -- get contract's history and start following our contract
            Trace.callEndpoint @"follow" bobFollowHdl pms
            Trace.waitNSlots 2

            Trace.callEndpoint @"apply-inputs" bobHdl (reqId, pms, Nothing, [INotify])

            Trace.waitNSlots 2
            Trace.callEndpoint @"redeem" bobHdl (reqId, pms, "bob", bobPkh)
            void $ Trace.waitNSlots 2
    where
        alicePk = PK $ walletPubKeyHash alice
        bobPk = PK $ walletPubKeyHash bob
        chId = ChoiceId "1" alicePk

        contract = When [
            Case (Choice chId [Bound 10 1500])
                (When [Case
                    (Deposit "alice" "alice" ada (ChoiceValue chId))
                        (When [Case (Notify (SlotIntervalStart `ValueGE` Constant 15))
                            (Pay "alice" (Party "bob") ada
                                (ChoiceValue chId) Close)]
                        (Slot 40) Close)
                    ] (Slot 30) Close)
            ] (Slot 20) Close
        (params, _ :: TxConstraints MarloweInput MarloweData, _) =
            let con = setupMarloweParams @MarloweSchema @MarloweError
                        (AssocMap.fromList [("alice", walletPubKeyHash alice), ("bob", walletPubKeyHash bob)])
                        contract
                fld = Folds.instanceOutcome con (Trace.walletInstanceTag alice)
                getOutcome (Done a) = a
                getOutcome e        = error $ "not finished: " <> show e
            in either (error . show) (getOutcome . S.fst')
                    $ run
                    $ runError @Folds.EmulatorFoldErr
                    $ foldEmulatorStreamM fld
                    $ Trace.runEmulatorStream def
                    $ do
                        void $ Trace.activateContractWallet alice (void con)
                        Trace.waitNSlots 10


uniqueContractHash :: IO ()
uniqueContractHash = do
    let params cs = MarloweParams
            { rolesCurrency = cs
            , rolePayoutValidatorHash = validatorHash (rolePayoutScript cs) }

    let hash1 = Scripts.validatorHash $ typedValidator (params "11")
    let hash2 = Scripts.validatorHash $ typedValidator (params "22")
    let hash3 = Scripts.validatorHash $ typedValidator (params "22")
    assertBool "Hashes must be different" (hash1 /= hash2)
    assertBool "Hashes must be same" (hash2 == hash3)


validatorSize :: IO ()
validatorSize = do
    let validator = Scripts.validatorScript $ typedValidator defaultMarloweParams
    let vsize = BS.length $ Write.toStrictByteString (Serialise.encode validator)
    assertBool ("Validator is too large " <> show vsize) (vsize < 1100000)


extractContractRolesTest :: IO ()
extractContractRolesTest = do
    extractContractRoles Close @=? mempty
    extractContractRoles
        (Pay (Role "Alice") (Party (Role "Bob")) ada (Constant 1) Close)
            @=? Set.fromList ["Alice", "Bob"]
    extractContractRoles
        (When [Case (Deposit (Role "Bob") (Role "Alice") ada (Constant 10)) Close] 10 Close)
            @=? Set.fromList ["Alice", "Bob"]
    extractContractRoles
        (When [Case (Choice (ChoiceId "test" (Role "Alice")) [Bound 0 1]) Close] 10 Close)
            @=? Set.fromList ["Alice"]


checkEqValue :: Property
checkEqValue = property $ do
    let gen = do
            a <- valueGen
            b <- valueGen
            c <- valueGen
            return (a, b, c)
    forAll gen $ \(a, b, c) ->
        (a P.== a) -- reflective
            .&&. ((a P.== b) == (b P.== a)) -- symmetric
            .&&. (if a P.== b && b P.== c then a P.== c else True) -- transitive


doubleNegation :: Property
doubleNegation = property $ do
    let eval = evalValue (Environment (Slot 10, Slot 1000)) (emptyState (Slot 10))
    forAll valueGen $ \a -> eval (NegValue (NegValue a)) === eval a


valuesFormAbelianGroup :: Property
valuesFormAbelianGroup = property $ do
    let gen = do
            a <- valueGen
            b <- valueGen
            c <- valueGen
            return (a, b, c)
    let eval = evalValue (Environment (Slot 10, Slot 1000)) (emptyState (Slot 10))
    forAll gen $ \(a, b, c) ->
        -- associativity of addition
        eval (AddValue (AddValue a b) c) === eval (AddValue a (AddValue b c)) .&&.
        -- commutativity of addition
        eval (AddValue a b) === eval (AddValue b a) .&&.
        -- additive identity
        eval (AddValue a (Constant 0)) === eval a .&&.
        -- additive inverse
        eval (AddValue a (NegValue a)) === 0 .&&.
        -- substraction works
        eval (SubValue (AddValue a b) b) === eval a


divisionRoundingTest :: Property
divisionRoundingTest = property $ do
    let eval = evalValue (Environment (Slot 10, Slot 1000)) (emptyState (Slot 10))
    -- test half-even rounding
    let gen = do
            n <- amount
            d <- suchThat amount (/= 0)
            return (n, d)
    forAll gen $ \(n, d) -> eval (DivValue (Constant n) (Constant d)) === halfEvenRound (n P.% d)
    where
      halfEvenRound = P.round


scaleMulTest :: Property
scaleMulTest = property $ do
    let eval = evalValue (Environment (Slot 10, Slot 1000)) (emptyState (Slot 10))
    forAll valueGen $ \a ->
        eval (Scale (0 P.% 1) a) === 0 .&&. eval (Scale (1 P.% 1) a) === eval a


mulTest :: Property
mulTest = property $ do
    let eval = evalValue (Environment (Slot 10, Slot 1000)) (emptyState (Slot 10))
    forAll valueGen $ \a ->
        eval (MulValue (Constant 0) a) === 0


divZeroTest :: Property
divZeroTest = property $ do
    let eval = evalValue (Environment (Slot 10, Slot 1000)) (emptyState (Slot 10))
    forAll valueGen $ \a ->
        eval (DivValue (Constant 0) a) === 0 .&&.
        eval (DivValue a (Constant 0)) === 0


valueSerialization :: Property
valueSerialization = property $
    forAll valueGen $ \a ->
        let decoded :: Maybe (Value Observation)
            decoded = decode $ encode a
        in Just a === decoded


mulAnalysisTest :: IO ()
mulAnalysisTest = do
    let muliply = foldl (\a _ -> MulValue (UseValue $ ValueId "a") a) (Constant 1) [1..100]
        alicePk = PK $ walletPubKeyHash alice
        contract = If (muliply `ValueGE` Constant 10000) Close (Pay alicePk (Party alicePk) ada (Constant (-100)) Close)
    result <- warningsTrace contract
    --print result
    assertBool "Analysis ok" $ isRight result


transferBetweenAccountsTest :: IO ()
transferBetweenAccountsTest = do
    let state = State
            { accounts = AssocMap.fromList [((Role "alice", Token "" ""), 100)]
            , choices  = AssocMap.empty
            , boundValues = AssocMap.empty
            , minSlot = 10 }
    let contract = Pay "alice" (Account "bob") (Token "" "") (Constant 100) (When [] 100 Close)
    let marloweData = MarloweData {
                marloweContract = contract,
                marloweState = state }
    let Just result@(constraints, SM.State (MarloweData {marloweState=State{accounts}}) balance) =
            mkMarloweStateMachineTransition
                defaultMarloweParams
                (SM.State marloweData (lovelaceValueOf 100))
                ((20, 30), [])
    balance @=? lovelaceValueOf 100
    assertBool "Accounts check" $ accounts == AssocMap.fromList [(("bob",Token "" ""), 100)]


divAnalysisTest :: IO ()
divAnalysisTest = do
    let
        alicePk = PK $ walletPubKeyHash alice
        contract n d = If (DivValue (Constant n) (Constant d) `ValueGE` Constant 5)
            Close
            (Pay alicePk (Party alicePk) ada (Constant (-100)) Close)
    result <- warningsTrace (contract 11 2)
    assertBool "Analysis ok" $ isRight result && fromRight False (fmap isNothing result)
    result <- warningsTrace (contract 9 2)
    assertBool "Analysis ok" $ isRight result && fromRight False (fmap isJust result)

    let eval = evalValue (Environment (Slot 10, Slot 1000)) (emptyState (Slot 10))
    eval (DivValue (Constant 0) (Constant 2)) @=? 0
    eval (DivValue (Constant 1) (Constant 0)) @=? 0
    eval (DivValue (Constant 5) (Constant 2)) @=? 2
    eval (DivValue (Constant (-5)) (Constant 2)) @=? -2
    eval (DivValue (Constant 7) (Constant 2)) @=? 4
    eval (DivValue (Constant (-7)) (Constant 2)) @=? -4


divTest :: IO ()
divTest = do
    let eval = evalValue (Environment (Slot 10, Slot 1000)) (emptyState (Slot 10))
    eval (DivValue (Constant 0) (Constant 2)) @=? 0
    eval (DivValue (Constant 1) (Constant 0)) @=? 0
    eval (DivValue (Constant 5) (Constant 2)) @=? 2
    eval (DivValue (Constant (-5)) (Constant 2)) @=? -2
    eval (DivValue (Constant 7) (Constant 2)) @=? 4
    eval (DivValue (Constant (-7)) (Constant 2)) @=? -4



pangramContractSerialization :: IO ()
pangramContractSerialization = do
    let json = toStrict (encodeToLazyText pangramContract)
    -- uncomment to generate json after updating pangramContract
    -- T.putStrLn json
    Just pangramContract @=? (decode $ encode pangramContract)
    contract <- readFile "test/contract.json"
    let decoded :: Maybe Contract
        decoded = decode (fromString contract)
    case decoded of
        Just cont -> cont @=? pangramContract
        _         -> assertFailure "Nope"


tokenShowTest :: IO ()
tokenShowTest = do
    -- SCP-834, CurrencySymbol is HEX encoded ByteString,
    -- and TokenSymbol as UTF8 encoded Unicode string
    let actual :: Value Observation
        actual = AvailableMoney (Role "alice") (Token "00010afF" "ÚSD©")

    show actual @=? "AvailableMoney \"alice\" (Token \"00010aff\" \"ÚSD©\")"


stateSerialization :: IO ()
stateSerialization = do
    state <- readFile "test/state.json"
    let decoded :: Maybe State
        decoded = decode (fromString state)
    case decoded of
        Just st ->
            case decode $ encode st of
                Just st' -> assertBool "Should be equal" (st P.== st')
                Nothing  -> assertFailure "Nope"
        Nothing -> assertFailure "Nope"

prop_showWorksForContracts :: Property
prop_showWorksForContracts = forAllShrink contractGen shrinkContract showWorksForContract


showWorksForContract :: Contract -> Property
showWorksForContract contract = unsafePerformIO $ do
  res <- runInterpreter $ setImports ["Language.Marlowe"]
                        >> set [ languageExtensions := [ OverloadedStrings ] ]
                        >> interpretContractString (show contract)
  return (case res of
            Right x  -> x === contract
            Left err -> counterexample (show err) False)


interpretContractString :: MonadInterpreter m => String -> m Contract
interpretContractString contractStr = interpret contractStr (as :: Contract)


noFalsePositivesForContract :: Contract -> Property
noFalsePositivesForContract cont =
  unsafePerformIO (do res <- catch (wrapLeft $ warningsTrace cont)
                                   (\exc -> return $ Left (Left (exc :: SomeException)))
                      return (case res of
                                Left err -> counterexample (show err) False
                                Right answer ->
                                   tabulate "Has counterexample" [show (isJust answer)]
                                   (case answer of
                                      Nothing ->
                                         tabulate "Is empty contract" [show (cont == Close)]
                                                  True
                                      Just (is, li, warns) ->
                                         counterexample ("Trace: " ++ show (is, li)) $
                                         tabulate "Number of warnings" [show (length warns)]
                                                  (warns =/= []))))


wrapLeft :: IO (Either a b) -> IO (Either (Either c a) b)
wrapLeft r = do tempRes <- r
                return (case tempRes of
                          Left x  -> Left (Right x)
                          Right y -> Right y)


prop_noFalsePositives :: Property
prop_noFalsePositives = forAllShrink contractGen shrinkContract noFalsePositivesForContract

jsonLoops :: Contract -> Property
jsonLoops cont = decode (encode cont) === Just cont

prop_jsonLoops :: Property
prop_jsonLoops = withMaxSuccess 1000 $ forAllShrink contractGen shrinkContract jsonLoops

integerBSRoundtripTest :: Property
integerBSRoundtripTest = forAll (arbitrary :: Gen Integer) (\num -> byteStringToInt (intToByteString num) === Just (num, emptyByteString))

integerListBSRoundtripTest :: Property
integerListBSRoundtripTest = forAll (arbitrary :: Gen [Integer]) (\numList -> byteStringToList byteStringToInt (listToByteString intToByteString numList) === Just (numList, emptyByteString))

