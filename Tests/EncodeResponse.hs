-- |
-- Module      : Tests.EncodeResponse
-- License     : BSD-Style
-- Copyright   : Copyright © 2014 AlephCloud Systems, Inc.
--
-- Maintainer  : Nicolas DI PRIMA <ndiprima@alephcloud.com>
-- Stability   : experimental
-- Portability : unknown
--
{-# LANGUAGE FlexibleInstances #-}
module EncodeResponse where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Word (Word8)

import Test.Tasty
import Test.Tasty.QuickCheck

import Control.Applicative
import ArbitraryByteString

import Network.DNS.API.Types

import Control.Monad.Except
import Data.Functor.Identity

instance Arbitrary (Response ByteString) where
  arbitrary =
    let genTxt = arbitrary :: Gen ByteString
        genSignature n = vectorOf n (arbitrary :: Gen Word8) >>= return . B.pack
    in  do
      sizeSignature <- choose (4, 12)
      sig <- genSignature sizeSignature
      txt <- genTxt
      return $ Response txt sig

prop_encode_response :: Response ByteString -> Bool
prop_encode_response resp = do
  case encodeDecode resp of
    Left err -> error err
    Right d1 ->
      case encodeDecode d1 of
        Left err -> error err
        Right d2 -> d1 == d2 && d2 == resp
  where
    encodeDecode d = runIdentity $ runExceptT $ decodeResponse $ encodeResponse d
