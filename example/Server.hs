-- |
-- Module      :
-- License     : BSD-Style
-- Copyright   : Copyright © 2014 AlephCloud Systems, Inc.
--
-- Maintainer  : Nicolas DI PRIMA <ndiprima@alephcloud.com>
-- Stability   : experimental
-- Portability : unknown
--
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
import Data.Default (def)
import Data.Char (ord)
import Data.ByteString (ByteString)
import qualified Data.ByteString       as S
import qualified Data.ByteString.Char8 as BS
import Data.Hourglass.Types
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe

import Network.DNS.API.Server
import qualified Network.DNS.API.Types as API
import qualified Network.DNS.API.Utils as API
import API

import System.Environment
import Control.Monad
import Control.Concurrent
import Control.Monad.Except
import Control.Monad.Identity

main :: IO ()
main = do
  args <- getArgs
  name <- getProgName
  case args of
    [d] -> do let d' = runIdentity $ runExceptT $ API.validateFQDN $ API.encodeFQDN $ BS.pack d
              let dom = either (\err -> error $ "the given domain address is not a valid FQDN: " ++ err)
                               (id) d'
              sl <- getDefaultConnections (Just "8053") (Seconds 3) Nothing >>= return.catMaybes
              defaultServer (serverConf dom) sl
    _     -> putStrLn $ "usage: " ++ name ++ " <Database FQDN>"
  where
    serverConf :: API.FQDN -> ServerConf Int Return
    serverConf dom = createServerConf (queryDummy dom)

------------------------------------------------------------------------------
--                          API: queries handling                          --
------------------------------------------------------------------------------

type KeyMap = Map ByteString ByteString

exampleOfDB :: KeyMap
exampleOfDB = Map.fromList exampleDB

exampleDB :: [(ByteString, ByteString)]
exampleDB =
  [ ("short", "a simple key")
  , ("linux", "best kernel ever! <3")
  , ("haskell", "Haskell is an advanced purely-functional programming language. An open-source product of more than twenty years of cutting-edge research, it allows rapid development of robust, concise, correct software. With strong support for integration with other languages, built-in concurrency and parallelism, debuggers, profilers, rich libraries and an active community, Haskell makes it easier to produce flexible, maintainable, high-quality software.")
  ]

-- | example of query manager
-- handle two commands:
-- * echo: the param
-- * db  : return the DB
--
-- This actual example just ignore the connection context and information
queryDummy :: API.FQDN
           -> Connection Int
           -> API.FQDNEncoded
           -> IO (Maybe (API.Response Return))
queryDummy dom conn req = do
  let eReq = runIdentity $ runExceptT $ API.decodeFQDNEncoded $ API.removeFQDNSuffix req dom :: Either String ExampleRequest
  print $ "Connection: " ++ (show $ getSockAddr conn) ++ " opened: " ++ (show $ getCreationDate conn)
  case eReq of
    Left err -> return Nothing
    Right r  -> treatRequest r
  where
    sign :: ByteString -> Return -> API.Response Return
    sign n t = API.Response { signature = n, response = t }

    treatRequest :: API.ExampleRequest -> IO (Maybe (API.Response Return))
    treatRequest r =
        return $ case command $ API.cmd r of
                    "echo" -> Just $ sign (API.nonce r) (Return $ param $ API.cmd r)
                    "db"   -> maybe Nothing (\p -> Just $ sign (API.nonce r) $ Return p) $ Map.lookup (param $ API.cmd r) exampleOfDB
                    _      -> Nothing
