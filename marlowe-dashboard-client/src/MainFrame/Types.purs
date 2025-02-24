module MainFrame.Types
  ( State
  , WebSocketStatus(..)
  , ChildSlots
  , Query(..)
  , Msg(..)
  , Action(..)
  ) where

import Prologue
import Analytics (class IsEvent, defaultEvent, toEvent)
import Component.Contacts.Types (WalletDetails, WalletLibrary)
import Component.Expand as Expand
import Component.LoadingSubmitButton.Types as LoadingSubmitButton
import Component.Tooltip.Types (ReferenceId)
import Data.Generic.Rep (class Generic)
import Data.Map (Map)
import Data.Time.Duration (Minutes)
import Halogen as H
import Halogen.Extra (LifecycleEvent)
import Marlowe.PAB (PlutusAppId)
import Marlowe.Semantics (Slot)
import Page.Contract.Types (State) as Contract
import Page.Dashboard.Types (Action, State) as Dashboard
import Page.Welcome.Types (Action, State) as Welcome
import Plutus.PAB.Webserver.Types (CombinedWSStreamToClient)
import Toast.Types (Action, State) as Toast
import Web.Socket.Event.CloseEvent (CloseEvent, reason) as WS
import WebSocket.Support (FromSocket) as WS

-- The app exists in one of two main subStates: the "welcome" state for when you have
-- no wallet, and all you can do is generate one or create a new one; and the "dashboard"
-- state for when you have selected a wallet, and can do all of the things.
type State
  = { webSocketStatus :: WebSocketStatus
    , currentSlot :: Slot
    , tzOffset :: Minutes
    , subState :: Either Welcome.State Dashboard.State
    , toast :: Toast.State
    }

data WebSocketStatus
  = WebSocketOpen
  | WebSocketClosed (Maybe WS.CloseEvent)

derive instance genericWebSocketStatus :: Generic WebSocketStatus _

instance showWebSocketStatus :: Show WebSocketStatus where
  show WebSocketOpen = "WebSocketOpen"
  show (WebSocketClosed Nothing) = "WebSocketClosed"
  show (WebSocketClosed (Just closeEvent)) = "WebSocketClosed " <> WS.reason closeEvent

------------------------------------------------------------
type ChildSlots
  = ( tooltipSlot :: forall query. H.Slot query Void ReferenceId
    , hintSlot :: forall query. H.Slot query Void String
    , submitButtonSlot :: H.Slot LoadingSubmitButton.Query LoadingSubmitButton.Message String
    , lifeCycleSlot :: forall query. H.Slot query LifecycleEvent String
    , expandSlot :: Expand.Slot Void String
    )

------------------------------------------------------------
data Query a
  = ReceiveWebSocketMessage (WS.FromSocket CombinedWSStreamToClient) a
  | MainFrameActionQuery Action a

data Msg
  = MainFrameActionMsg Action

------------------------------------------------------------
data Action
  = Init
  | EnterWelcomeState WalletLibrary WalletDetails (Map PlutusAppId Contract.State)
  | EnterDashboardState WalletLibrary WalletDetails
  | WelcomeAction Welcome.Action
  | DashboardAction Dashboard.Action
  | ToastAction Toast.Action

-- | Here we decide which top-level queries to track as GA events, and
-- how to classify them.
instance actionIsEvent :: IsEvent Action where
  toEvent Init = Just $ defaultEvent "Init"
  toEvent (EnterWelcomeState _ _ _) = Just $ defaultEvent "EnterWelcomeState"
  toEvent (EnterDashboardState _ _) = Just $ defaultEvent "EnterDashboardState"
  toEvent (WelcomeAction welcomeAction) = toEvent welcomeAction
  toEvent (DashboardAction dashboardAction) = toEvent dashboardAction
  toEvent (ToastAction toastAction) = toEvent toastAction
