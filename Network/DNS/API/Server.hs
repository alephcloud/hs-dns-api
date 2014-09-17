-- |
-- Module      : Network.DNS.API.Server
-- License     : BSD-Style
-- Copyright   : Copyright © 2014 AlephCloud Systems, Inc.
--
-- Maintainer  : Nicolas DI PRIMA <ndiprima@alephcloud.com>
-- Stability   : experimental
-- Portability : unknown
--
module Network.DNS.API.Server
  ( -- * Helpers
    ServerConf(..)
  , createServerConf
  , handleRequest
    -- * defaultServer
  , DNSAPIConnection(..)
  , getDefaultSockets
  , defaultServer
    -- * Create DNSFormat
  , defaultQuery
  , defaultResponse
  ) where

import Control.Monad
import Control.Applicative
import System.Timeout

import Data.ByteString (ByteString)
import qualified Data.ByteString      as B
import qualified Data.ByteString.Lazy as SL (toChunks, fromChunks)
import Data.Maybe
import Data.Monoid (mconcat)

import Network.DNS hiding (lookup)
import qualified Network.DNS.API.Types as API
import Network.Socket hiding (recvFrom, recv, send)
import Network.Socket.ByteString (sendAllTo, recvFrom, recv, send)

import Control.Monad.STM
import Control.Concurrent
import Control.Concurrent.STM.TChan

------------------------------------------------------------------------------
--                         Server Configuration                             --
------------------------------------------------------------------------------

-- | Server configuration
data API.Packable p => ServerConf p = ServerConf
  { query   :: SockAddr -> ByteString -> IO (Maybe (API.Response p)) -- ^ the method to perform a request
  , inFail  :: DNSFormat -> IO (Either String DNSFormat) -- ^ the method to use to handle query failure
  }

-- | Smart constructor for DNS API configuration
--
-- Use this function instead of the default one:
-- > let conf = def :: ServerConf
-- this method will only refuse every DNS query and will return an error Code : ServFail
--
-- you need to replace the @query@ method. The best way to use it is to use this function
createServerConf :: API.Packable p
                 => (SockAddr -> ByteString -> IO (Maybe (API.Response p)))
                 -> ServerConf p
createServerConf function =
   ServerConf
      { query   = function
      , inFail  = inFailError
      }

-- | Default implementation of an inFail
inFailError :: DNSFormat -> IO (Either String DNSFormat)
inFailError req =
  let hd = header req
      flg = flags hd
  in  return $ Right $ req { header = hd { flags = flg { qOrR = QR_Response
                                                       , rcode = ServFail
                                                       }
                                         }
                           }

------------------------------------------------------------------------------
--                         The main function                                --
------------------------------------------------------------------------------

splitTxt :: ByteString -> [ByteString]
splitTxt bs
  | B.length bs < 255 = [bs]
  | otherwise = node:(splitTxt xs)
  where
    (node, xs) = B.splitAt 255 bs

-- Handle a request:
-- try the query function given in the ServerConf
-- if it fails, then call the given proxy
handleRequest :: API.Packable p => ServerConf p -> SockAddr -> DNSFormat -> IO (Either String ByteString)
handleRequest conf addr req =
  case listToMaybe . filterTXT . question $ req of
    Just q -> do
        mres <- query conf addr $ qname q
        case mres of
           Just txt -> return $ Right $ mconcat . SL.toChunks $ encode $ responseTXT q (splitTxt $ API.encodeResponse txt)
           Nothing  -> inFail conf req >>= return.inFailWrapper
    Nothing -> inFail conf req >>= return.inFailWrapper
  where
    filterTXT = filter ((==TXT) . qtype)

    ident :: Int
    ident = identifier . header $ req

    inFailWrapper :: Either String DNSFormat -> Either String ByteString
    inFailWrapper (Right r) = Right $ mconcat . SL.toChunks $ encode r
    inFailWrapper (Left er) = Left er

    responseTXT :: Question -> [ByteString] -> DNSFormat
    responseTXT q l =
      let hd = header defaultResponse
          dom = qname q
          al = map (\txt -> ResourceRecord dom TXT 0 (B.length txt) (RD_TXT txt)) l
      in  defaultResponse
            { header = hd { identifier = ident, qdCount = 1, anCount = length al }
            , question = [q]
            , answer = al
            }

-- | imported from dns:Network/DNS/Internal.hs
--
-- use this to get a default DNS format to send a query (if needed)
defaultQuery :: DNSFormat
defaultQuery = DNSFormat {
    header = DNSHeader {
       identifier = 0
     , flags = DNSFlags {
           qOrR         = QR_Query
         , opcode       = OP_STD
         , authAnswer   = False
         , trunCation   = False
         , recDesired   = True
         , recAvailable = False
         , rcode        = NoErr
         }
     , qdCount = 0
     , anCount = 0
     , nsCount = 0
     , arCount = 0
     }
  , question   = []
  , answer     = []
  , authority  = []
  , additional = []
  }

-- | imported from dns:Network/DNS/Internal.hs
--
-- use this to get a default DNS format to send a response
defaultResponse :: DNSFormat
defaultResponse =
  let hd = header defaultQuery
      flg = flags hd
  in  defaultQuery {
        header = hd {
          flags = flg {
              qOrR = QR_Response
            , authAnswer = True
            , recAvailable = True
            }
    }
  }

------------------------------------------------------------------------------
--                          Internal Queue System                           --
------------------------------------------------------------------------------

data DNSReqToHandle = DNSReqToHandle
    { connection :: DNSAPIConnection
    , sender     :: SockAddr
    , getReq     :: DNSFormat
    }

type DNSReqToHandleChan = TChan DNSReqToHandle

newDNSReqToHandleChan :: IO DNSReqToHandleChan
newDNSReqToHandleChan = atomically $ newTChan

putReqToHandle :: DNSReqToHandleChan -> DNSReqToHandle -> IO ()
putReqToHandle chan req = atomically $ writeTChan chan req

popReqToHandle :: DNSReqToHandleChan -> IO DNSReqToHandle
popReqToHandle = atomically . readTChan

------------------------------------------------------------------------------
--                         Default server: helpers                          --
------------------------------------------------------------------------------

data DNSAPIConnection
    = UDPConnection Socket
    | TCPConnection Socket
    deriving (Show, Eq)

defaultQueryHandler :: API.Packable p => ServerConf p -> DNSReqToHandleChan -> IO ()
defaultQueryHandler conf chan = do
  dnsReq <- popReqToHandle chan
  eResp <- handleRequest conf (sender dnsReq) (getReq dnsReq)
  case eResp of
    Right bs -> defaultResponder dnsReq bs
    Left err -> putStrLn err
  where
    defaultResponder :: DNSReqToHandle -> ByteString -> IO ()
    defaultResponder req resp =
      case connection req of
        UDPConnection sock -> void $ timeout (3 * 1000 * 1000) (sendAllTo sock resp (sender req))
        TCPConnection sock -> do
            void $ timeout (3 * 1000 * 1000) (send sock resp)
            close sock

-- | a default server: handle queries for ever
defaultListener :: DNSReqToHandleChan -> DNSAPIConnection -> IO ()
defaultListener chan (UDPConnection sock) = do
  -- wait to get some request
  (bs, addr) <- recvFrom sock 512
  -- Try to decode it, if it works then add it to the queue
  case decode (SL.fromChunks [bs]) of
    Left  _   -> return () -- We don't want to throw an error if the command is wrong
    Right req -> putReqToHandle chan $ DNSReqToHandle (UDPConnection sock) addr req
defaultListener chan (TCPConnection sock) = do
  listen sock 10
  -- TODO: for now block it to no more than 10 connections
  -- start accepting connection:
  forever $ do
    -- wait to get some request
    (sockClient, addr) <- accept sock
    -- read data
    bs <- recv sock 512
    -- Try to decode it, if it works then add it to the queue
    case decode (SL.fromChunks [bs]) of
      Left  _   -> return () -- We don't want to throw an error if the command is wrong
      Right req -> putReqToHandle chan $ DNSReqToHandle (TCPConnection sockClient) addr req

-- | Simple helper to get the default DNS Sockets
--
-- all sockets TCP/UDP + IPv4 + port(53)
getDefaultSockets :: (Monad m, Applicative m)
                  => Maybe String
                  -> IO [m DNSAPIConnection]
getDefaultSockets mport = do
  let (mflags, service) = maybe (([], Just "domain")) (\port -> ([AI_NUMERICSERV], Just port)) mport
  addrinfos <- getAddrInfo
                   (Just (defaultHints
                            { addrFlags = AI_PASSIVE:mflags
                            , addrFamily = AF_INET
                            }
                         )
                   )
                   (Nothing)
                   service
  mapM addrInfoToSocket addrinfos
  where
    addrInfoToSocket :: (Monad m, Applicative m) => AddrInfo -> IO (m DNSAPIConnection)
    addrInfoToSocket addrinfo
      | (addrSocketType addrinfo) `notElem` [Datagram, Stream] = return $ fail $ "socket type not supported: " ++ (show addrinfo)
      | otherwise = do
          sock <- socket (addrFamily addrinfo) (addrSocketType addrinfo) defaultProtocol
          bindSocket sock (addrAddress addrinfo)
          return $ case addrSocketType addrinfo of
                        Datagram -> pure $ UDPConnection sock
                        Stream   -> pure $ TCPConnection sock
                        _        -> fail $ "Socket Type not handle: " ++ (show addrinfo)

defaultServer :: API.Packable p
              => ServerConf p
              -> [DNSAPIConnection]
              -> IO ()
defaultServer _    []       = error $ "Network.DNS.API.Server: defaultServer: list of DNSApiConnection is empty"
defaultServer conf sockList = do
  -- creat a TChan to pass request from the listeners to the handler
  chan <- newDNSReqToHandleChan
  -- start the listerners
  mapM_ (forkIO . forever . defaultListener chan) sockList
  -- start the query Hander
  forever $ defaultQueryHandler conf chan
