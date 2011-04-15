{-# LANGUAGE QuasiQuotes, TypeFamilies, TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
module Yesod.Helpers.Auth
    ( -- * Subsite
      Auth
    , AuthPlugin (..)
    , AuthRoute (..)
    , getAuth
    , YesodAuth (..)
      -- * Plugin interface
    , Creds (..)
    , setCreds
      -- * User functions
    , maybeAuthId
    , maybeAuth
    , requireAuthId
    , requireAuth
    ) where

import Yesod.Core
import Yesod.Persist
import Yesod.Json
import Text.Blaze
import Language.Haskell.TH.Syntax hiding (lift)
import qualified Network.Wai as W
import Text.Hamlet (hamlet)
import qualified Data.Map as Map
import Control.Monad.Trans.Class (lift)
import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Monoid (mconcat)

data Auth = Auth

type Method = Text
type Piece = Text

data AuthPlugin m = AuthPlugin
    { apName :: Text
    , apDispatch :: Method -> [Piece] -> GHandler Auth m ()
    , apLogin :: forall s. (Route Auth -> Route m) -> GWidget s m ()
    }

getAuth :: a -> Auth
getAuth = const Auth

-- | User credentials
data Creds m = Creds
    { credsPlugin :: Text -- ^ How the user was authenticated
    , credsIdent :: Text -- ^ Identifier. Exact meaning depends on plugin.
    , credsExtra :: [(Text, Text)]
    }

class (Yesod m, SinglePiece (AuthId m)) => YesodAuth m where
    type AuthId m

    -- | Default destination on successful login, if no other
    -- destination exists.
    loginDest :: m -> Route m

    -- | Default destination on successful logout, if no other
    -- destination exists.
    logoutDest :: m -> Route m

    getAuthId :: Creds m -> GHandler s m (Maybe (AuthId m))

    authPlugins :: [AuthPlugin m]

    -- | What to show on the login page.
    loginHandler :: GHandler Auth m RepHtml
    loginHandler = defaultLayout $ do
        setTitle "Login"
        tm <- lift getRouteToMaster
        mapM_ (flip apLogin tm) authPlugins

    ----- Message strings. In theory in the future make this localizable
    ----- See gist: https://gist.github.com/778712
    messageNoOpenID :: m -> Html
    messageNoOpenID _ = "No OpenID identifier found"
    messageLoginOpenID :: m -> Html
    messageLoginOpenID _ = "Login via OpenID"

    messageEmail :: m -> Html
    messageEmail _ = "Email"
    messagePassword :: m -> Html
    messagePassword _ = "Password"
    messageRegister :: m -> Html
    messageRegister _ = "Register"
    messageRegisterLong :: m -> Html
    messageRegisterLong _ = "Register a new account"
    messageEnterEmail :: m -> Html
    messageEnterEmail _ = "Enter your e-mail address below, and a confirmation e-mail will be sent to you."
    messageConfirmationEmailSentTitle :: m -> Html
    messageConfirmationEmailSentTitle _ = "Confirmation e-mail sent"
    messageConfirmationEmailSent :: m -> Text -> Html
    messageConfirmationEmailSent _ email = toHtml $ mconcat
        ["A confirmation e-mail has been sent to ", email, "."]
    messageAddressVerified :: m -> Html
    messageAddressVerified _ = "Address verified, please set a new password"
    messageInvalidKeyTitle :: m -> Html
    messageInvalidKeyTitle _ = "Invalid verification key"
    messageInvalidKey :: m -> Html
    messageInvalidKey _ = "I'm sorry, but that was an invalid verification key."
    messageInvalidEmailPass :: m -> Html
    messageInvalidEmailPass _ = "Invalid email/password combination"
    messageBadSetPass :: m -> Html
    messageBadSetPass _ = "You must be logged in to set a password"
    messageSetPassTitle :: m -> Html
    messageSetPassTitle _ = "Set password"
    messageSetPass :: m -> Html
    messageSetPass _ = "Set a new password"
    messageNewPass :: m -> Html
    messageNewPass _ = "New password"
    messageConfirmPass :: m -> Html
    messageConfirmPass _ = "Confirm"
    messagePassMismatch :: m -> Html
    messagePassMismatch _ = "Passwords did not match, please try again"
    messagePassUpdated :: m -> Html
    messagePassUpdated _ = "Password updated"

    messageFacebook :: m -> Html
    messageFacebook _ = "Login with Facebook"

type Texts = [Text]

mkYesodSub "Auth"
    [ ClassP ''YesodAuth [VarT $ mkName "master"]
    ]
#define STRINGS *Texts
#if GHC7
    [parseRoutes|
#else
    [$parseRoutes|
#endif
/check                 CheckR      GET
/login                 LoginR      GET
/logout                LogoutR     GET POST
/page/#Text/STRINGS PluginR
|]

credsKey :: Text
credsKey = "_ID"

-- | FIXME: won't show up till redirect
setCreds :: YesodAuth m => Bool -> Creds m -> GHandler s m ()
setCreds doRedirects creds = do
    y <- getYesod
    maid <- getAuthId creds
    case maid of
        Nothing ->
            if doRedirects
                then do
                    case authRoute y of
                        Nothing -> do
                            rh <- defaultLayout
#if GHC7
                                [hamlet|
#else
                                [$hamlet|
#endif
                                <h1>Invalid login
|]
                            sendResponse rh
                        Just ar -> do
                            setMessage "Invalid login"
                            redirect RedirectTemporary ar
                else return ()
        Just aid -> do
            setSession credsKey $ toSinglePiece aid
            if doRedirects
                then do
                    setMessage "You are now logged in"
                    redirectUltDest RedirectTemporary $ loginDest y
                else return ()

getCheckR :: YesodAuth m => GHandler Auth m RepHtmlJson
getCheckR = do
    creds <- maybeAuthId
    defaultLayoutJson (do
        setTitle "Authentication Status"
        addHtml $ html creds) (json' creds)
  where
    html creds =
#if GHC7
        [hamlet|
#else
        [$hamlet|
#endif
<h1>Authentication Status
$maybe _ <- creds
    <p>Logged in.
$nothing
    <p>Not logged in.
|]
    json' creds =
        Object $ Map.fromList
            [ (T.pack "logged_in", Bool $ maybe False (const True) creds)
            ]

getLoginR :: YesodAuth m => GHandler Auth m RepHtml
getLoginR = loginHandler

getLogoutR :: YesodAuth m => GHandler Auth m ()
getLogoutR = postLogoutR -- FIXME redirect to post

postLogoutR :: YesodAuth m => GHandler Auth m ()
postLogoutR = do
    y <- getYesod
    deleteSession credsKey
    redirectUltDest RedirectTemporary $ logoutDest y

handlePluginR :: YesodAuth m => Text -> [Text] -> GHandler Auth m ()
handlePluginR plugin pieces = do
    env <- waiRequest
    let method = decodeUtf8With lenientDecode $ W.requestMethod env
    case filter (\x -> apName x == plugin) authPlugins of
        [] -> notFound
        ap:_ -> apDispatch ap method pieces

-- | Retrieves user credentials, if user is authenticated.
maybeAuthId :: YesodAuth m => GHandler s m (Maybe (AuthId m))
maybeAuthId = do
    ms <- lookupSession credsKey
    case ms of
        Nothing -> return Nothing
        Just s -> return $ fromSinglePiece s

maybeAuth :: ( YesodAuth m
             , Key val ~ AuthId m
             , PersistBackend (YesodDB m (GGHandler s m IO))
             , PersistEntity val
             , YesodPersist m
             ) => GHandler s m (Maybe (Key val, val))
maybeAuth = do
    maid <- maybeAuthId
    case maid of
        Nothing -> return Nothing
        Just aid -> do
            ma <- runDB $ get aid
            case ma of
                Nothing -> return Nothing
                Just a -> return $ Just (aid, a)

requireAuthId :: YesodAuth m => GHandler s m (AuthId m)
requireAuthId = maybeAuthId >>= maybe redirectLogin return

requireAuth :: ( YesodAuth m
               , Key val ~ AuthId m
               , PersistBackend (YesodDB m (GGHandler s m IO))
               , PersistEntity val
               , YesodPersist m
               ) => GHandler s m (Key val, val)
requireAuth = maybeAuth >>= maybe redirectLogin return

redirectLogin :: Yesod m => GHandler s m a
redirectLogin = do
    y <- getYesod
    setUltDest'
    case authRoute y of
        Just z -> redirect RedirectTemporary z
        Nothing -> permissionDenied "Please configure authRoute"
