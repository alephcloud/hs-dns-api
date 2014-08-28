-- |
-- Module      : Network.DNS.API.Client
-- License     : BSD-Style
-- Copyright   : Copyright © 2014 AlephCloud Systems, Inc.
--
-- Maintainer  : Nicolas DI PRIMA <ndiprima@alephcloud.com>
-- Stability   : experimental
-- Portability : unknown
--
module Network.DNS.API.Client
    ( sendQuery
    , sendQueryDefault
    ) where

import Network.DNS.API.Types
import Network.DNS.API.Utils

import Data.ByteString (ByteString)
import qualified Data.ByteString as B

import qualified Network.DNS as DNS

parseQuery :: Either DNS.DNSError [DNS.RDATA]
           -> Either DNS.DNSError Response
parseQuery (Left err) = Left err
parseQuery (Right l)  = Right $ decodeResponse txt
  where
    txt :: ByteString
    txt = B.concat $ map toByteString l

    toByteString :: DNS.RDATA -> ByteString
    toByteString (DNS.RD_TXT bs) = bs
    toByteString d               = error $ "unexpected type: " ++ (show d)

-- | Send a TXT query with the given DNS Resolver
sendQuery :: Encodable a
          => DNS.Resolver
          -> a            -- ^ the key/request
          -> IO (Either DNS.DNSError Response)
sendQuery res q
  | checkEncoding dom = DNS.lookup res dom DNS.TXT >>= return.parseQuery
  | otherwise         = return $ Left DNS.IllegalDomain
  where
    dom :: DNS.Domain
    dom = encode q

-- | Send a TXT query with the default DNS Resolver
--
-- Equivalent to:
-- @
--  sendQueryDefault dom = do
--    rs <- DNS.makeResolvSeed DNS.defaultResolvConf
--    DNS.withResolver rs $
--           \resolver -> sendQuery resolver dom
-- @
sendQueryDefault :: Encodable a
                 => a
                 -> IO (Either DNS.DNSError Response)
sendQueryDefault dom = do
    rs <- DNS.makeResolvSeed DNS.defaultResolvConf
    DNS.withResolver rs $ \resolver -> sendQuery resolver dom
