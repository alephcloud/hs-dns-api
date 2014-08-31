-- |
-- Module      : Tests.EncodeByteString
-- License     : BSD-Style
-- Copyright   : Copyright © 2014 AlephCloud Systems, Inc.
--
-- Maintainer  : Nicolas DI PRIMA <ndiprima@alephcloud.com>
-- Stability   : experimental
-- Portability : unknown
--
module EncodeByteString where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Base32

import Test.Tasty
import Test.Tasty.QuickCheck

import ArbitraryByteString

------------------------------------------------------------------------------
--                             Property checkers                            --
------------------------------------------------------------------------------

prop_encode_bytestring :: ByteString -> Bool
prop_encode_bytestring s = d1 == d2 && d1 == s
  where
    Just e1 = encode s
    Just d1 = decode e1
    Just e2 = encode d1
    Just d2 = decode e2

prop_guess_encoded_length :: ByteString -> Bool
prop_guess_encoded_length s = guess == B.length e
  where
    Just e = encode s
    guess = guessEncodedLength $ B.length s
