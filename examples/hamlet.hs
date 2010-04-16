{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

import Yesod
import Network.Wai.Handler.SimpleServer

data Ham = Ham

mkYesod "Ham" [$parseRoutes|
/          Homepage GET
/#another  Another  GET
|]

instance Yesod Ham where
    approot _ = "http://localhost:3000"

data NextLink = NextLink { nextLink :: HamRoutes }

template :: Monad m => NextLink -> Hamlet HamRoutes m ()
template = [$hamlet|
%a!href=@nextLink@ Next page
|]

getHomepage :: Handler Ham RepHtml
getHomepage = hamletToRepHtml $ template $ NextLink $ Another 1

getAnother :: Integer -> Handler Ham RepHtml
getAnother i = hamletToRepHtml $ template $ NextLink next
  where
    next = case i of
                5 -> Homepage
                _ -> Another $ i + 1

main :: IO ()
main = do
    putStrLn "Running..."
    toWaiApp Ham >>= run 3000
