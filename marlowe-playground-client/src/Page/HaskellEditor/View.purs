module Page.HaskellEditor.View where

import Prologue hiding (div)
import Component.BottomPanel.Types (Action(..)) as BottomPanel
import Component.BottomPanel.View (render) as BottomPanel
import Component.MetadataTab.View (metadataView)
import Data.Array as Array
import Data.Bifunctor (bimap)
import Data.Enum (toEnum, upFromIncluding)
import Data.Lens (_Right, has, to, view, (^.))
import Data.String (Pattern(..), split)
import Data.String as String
import Effect.Aff.Class (class MonadAff)
import Halogen (ClassName(..), ComponentHTML)
import Halogen.Classes (bgWhite, flex, flexCol, flexGrow, fullHeight, group, maxH70p, minH0, overflowHidden, paddingX, spaceBottom)
import Halogen.Css (classNames)
import Halogen.Extra (renderSubmodule)
import Halogen.HTML (HTML, button, code_, div, div_, option, pre_, section, section_, select, slot, text)
import Halogen.HTML.Events (onClick, onSelectedIndexChange)
import Halogen.HTML.Properties (class_, classes, enabled)
import Halogen.HTML.Properties as HTML
import Halogen.Monaco (monacoComponent)
import Language.Haskell.Interpreter (CompilationError(..), InterpreterError(..), InterpreterResult(..))
import Language.Haskell.Monaco as HM
import MainFrame.Types (ChildSlots, _haskellEditorSlot)
import Marlowe.Extended.Metadata (MetaData)
import Network.RemoteData (RemoteData(..), _Success)
import Page.HaskellEditor.Types (Action(..), BottomPanelView(..), State, _bottomPanelState, _compilationResult, _haskellEditorKeybindings, _metadataHintInfo)
import StaticAnalysis.BottomPanel (analysisResultPane, analyzeButton, clearButton)
import StaticAnalysis.Types (_analysisExecutionState, _analysisState, isCloseAnalysisLoading, isNoneAsked, isReachabilityLoading, isStaticLoading)

render ::
  forall m.
  MonadAff m =>
  MetaData ->
  State ->
  ComponentHTML Action ChildSlots m
render metadata state =
  div [ classes [ flex, flexCol, fullHeight ] ]
    [ section [ classes [ paddingX, minH0, flexGrow, overflowHidden ] ]
        [ haskellEditor state ]
    , section [ classes [ paddingX, maxH70p ] ]
        [ renderSubmodule
            _bottomPanelState
            BottomPanelAction
            (BottomPanel.render panelTitles wrapBottomPanelContents)
            state
        ]
    ]
  where
  panelTitles =
    [ { title: "Metadata", view: MetadataView, classes: [] }
    , { title: "Generated code", view: GeneratedOutputView, classes: [] }
    , { title: "Static Analysis", view: StaticAnalysisView, classes: [] }
    , { title: "Errors", view: ErrorsView, classes: [] }
    ]

  -- TODO: improve this wrapper helper
  actionWrapper = BottomPanel.PanelAction

  wrapBottomPanelContents panelView = bimap (map actionWrapper) actionWrapper $ panelContents state metadata panelView

otherActions :: forall p. State -> HTML p Action
otherActions state =
  div [ classes [ group ] ]
    [ editorOptions state
    , compileButton state
    , sendToSimulationButton state
    -- FIXME: I think we want to change this action to be called from the simulator
    --        with the action "soon to be implemented" ViewAsBlockly
    -- , sendResultButton state "Send To Blockly" SendResultToBlockly
    ]

editorOptions :: forall p. State -> HTML p Action
editorOptions state =
  div [ class_ (ClassName "editor-options") ]
    [ select
        [ HTML.id_ "editor-options"
        , HTML.value $ show $ state ^. _haskellEditorKeybindings
        , onSelectedIndexChange (\idx -> ChangeKeyBindings <$> toEnum idx)
        ]
        (map keybindingItem (upFromIncluding bottom))
    ]
  where
  keybindingItem item =
    if state ^. _haskellEditorKeybindings == item then
      option [ class_ (ClassName "selected-item"), HTML.value (show item) ] [ text $ show item ]
    else
      option [ HTML.value (show item) ] [ text $ show item ]

haskellEditor ::
  forall m.
  MonadAff m =>
  State ->
  ComponentHTML Action ChildSlots m
haskellEditor state = slot _haskellEditorSlot unit component unit (Just <<< HandleEditorMessage)
  where
  setup editor = pure unit

  component = monacoComponent $ HM.settings setup

compileButton :: forall p. State -> HTML p Action
compileButton state =
  button
    [ onClick $ const $ Just Compile
    , enabled enabled'
    , classes classes'
    ]
    [ text buttonText ]
  where
  buttonText = case view _compilationResult state of
    Loading -> "Compiling..."
    Success _ -> "Compiled"
    _ -> "Compile"

  enabled' = case view _compilationResult state of
    NotAsked -> true
    _ -> false

  classes' =
    [ ClassName "btn" ]
      <> case view _compilationResult state of
          Success (Right _) -> [ ClassName "success" ]
          Success (Left _) -> [ ClassName "error" ]
          _ -> []

sendToSimulationButton :: forall p. State -> HTML p Action
sendToSimulationButton state =
  button
    [ onClick $ const $ Just SendResultToSimulator
    , enabled enabled'
    , classNames [ "btn" ]
    ]
    [ text "Send To Simulator" ]
  where
  compilationResult = view _compilationResult state

  enabled' = case compilationResult of
    Success (Right (InterpreterResult _)) -> true
    _ -> false

panelContents :: forall m. MonadAff m => State -> MetaData -> BottomPanelView -> ComponentHTML Action ChildSlots m
panelContents state _ GeneratedOutputView =
  section_ case view _compilationResult state of
    Success (Right (InterpreterResult result)) ->
      [ div [ classes [ bgWhite, spaceBottom, ClassName "code" ] ]
          numberedText
      ]
      where
      numberedText = (code_ <<< Array.singleton <<< text) <$> split (Pattern "\n") result.result
    _ -> [ text "There is no generated code" ]

panelContents state metadata StaticAnalysisView =
  section_
    ( [ analysisResultPane metadata SetIntegerTemplateParam state
      , analyzeButton loadingWarningAnalysis analysisEnabled "Analyse for warnings" AnalyseContract
      , analyzeButton loadingReachability analysisEnabled "Analyse reachability" AnalyseReachabilityContract
      , analyzeButton loadingCloseAnalysis analysisEnabled "Analyse for refunds on Close" AnalyseContractForCloseRefund
      , clearButton clearEnabled "Clear" ClearAnalysisResults
      ]
        <> (if isCompiled then [] else [ div [ classes [ ClassName "choice-error" ] ] [ text "Haskell code needs to be compiled in order to run static analysis" ] ])
    )
  where
  loadingWarningAnalysis = state ^. _analysisState <<< _analysisExecutionState <<< to isStaticLoading

  loadingReachability = state ^. _analysisState <<< _analysisExecutionState <<< to isReachabilityLoading

  loadingCloseAnalysis = state ^. _analysisState <<< _analysisExecutionState <<< to isCloseAnalysisLoading

  noneAskedAnalysis = state ^. _analysisState <<< _analysisExecutionState <<< to isNoneAsked

  anyAnalysisLoading = loadingWarningAnalysis || loadingReachability || loadingCloseAnalysis

  analysisEnabled = not anyAnalysisLoading && isCompiled

  clearEnabled = not (anyAnalysisLoading || noneAskedAnalysis)

  isCompiled = has (_compilationResult <<< _Success <<< _Right) state

panelContents state _ ErrorsView =
  section_ case view _compilationResult state of
    Success (Left (TimeoutError error)) -> [ text error ]
    Success (Left (CompilationErrors errors)) -> map compilationErrorPane errors
    _ -> [ text "No errors" ]

panelContents state metadata MetadataView = metadataView (state ^. _metadataHintInfo) metadata MetadataAction

compilationErrorPane :: forall p. CompilationError -> HTML p Action
compilationErrorPane (RawError error) = div_ [ text error ]

compilationErrorPane (CompilationError error) =
  div
    [ class_ $ ClassName "compilation-error"
    ]
    [ text $ "Line " <> show error.row <> ", Column " <> show error.column <> ":"
    , code_ [ pre_ [ text $ String.joinWith "\n" error.text ] ]
    ]
