{-# language LambdaCase #-}
{-# language BangPatterns #-}
{-# language TypeFamilies #-}

module Coda.Syntax.Line 
  ( 
  -- * A UTF-8 encoded line
    Line(..)
  , (!!)
  , encodeLine
  , EncodingError(..)
  -- * Alex Support
  , AlexInput(..)
  , advanceInput
  , alexGetByte
  , deltaInput
  ) where

import Coda.Syntax.Delta
import Coda.Syntax.Multi as Multi
import Coda.Util.Primitive
import Control.Lens (AsEmpty(..), prism)
import Control.Monad.ST
import Data.Bits
import Data.Primitive.ByteArray
import Data.Semigroup
import Data.String
import Data.Text as Text
import Data.Text.Internal as Text
import Data.Text.Array as Text
import GHC.Word
import GHC.Exts as Exts (IsList(..))
import Prelude hiding ((!!))
import Unsafe.Coerce

-- $setup
-- >>> :set -XOverloadedStrings -XOverloadedLists
-- >>> import Data.List as List (unfoldr)

-- | Invariants 
--
-- * The only occurrences of '\n', '\r' or "\r\n" are at the end of the ByteArray
-- TODO: store if the line is ASCII?
newtype Line = Line ByteArray

instance Eq Line where
  (==) = unsafeCoerce sameMutableByteArray

(!!) :: Line -> Int -> Word8
Line ba !! i = indexByteArray ba i

size :: Line -> Int
size (Line ba) = sizeofByteArray ba

instance Show Line where
  showsPrec d xs = showsPrec d (Exts.toList xs)

write8_16 :: MutableByteArray s -> Int -> Word16 -> ST s ()
write8_16 mba i a = writeByteArray mba i (fromIntegral a :: Word8)

write8_32 :: MutableByteArray s -> Int -> Word32 -> ST s ()
write8_32 mba i a = writeByteArray mba i (fromIntegral a :: Word8)

-- encoding error
data EncodingError = EncodingError Delta String
  deriving Show

instance Relative EncodingError where
  rel p (EncodingError q s) = EncodingError (p <> q) s

-- produce pre-lexer feedback when converting to a line
encodeLine :: Text -> Either EncodingError Line
encodeLine (Text (Text.Array tba0) toff0 tlen0) = runST $ do
    mba <- newByteArray (tlen0 * 3)
    go mba (ByteArray tba0) toff0 tlen0 0 >>= \case
      Just (toff,boff,msg) -> pure $ Left (EncodingError (Delta 0 (toff-toff0) boff) msg)
      Nothing              -> Right . Line <$> unsafeFreezeByteArray mba
      
  where
    go :: MutableByteArray s -> ByteArray -> Int -> Int -> Int -> ST s (Maybe (Int,Int,String))
    go !mba !_ !_ 0 !boff = Nothing <$ shrinkMutableByteArray mba boff
    go mba tba toff tlen boff 
      | c < 0x80 = do
        write8_16 mba boff c
        go mba tba (toff+1) (tlen-1) (boff+1)
      | c < 0x800 = do
        write8_16 mba boff     $ 0xc0 + unsafeShiftR c 6
        write8_16 mba (boff+1) $ 0x80 + (c .&. 0x3f)
        go mba tba (toff+1) (tlen-1) (boff+2)
      | c < 0xd800 = do
        write8_16 mba boff     $ 0xe0 + unsafeShiftR c 12
        write8_16 mba (boff+1) $ 0x80 + (unsafeShiftR c 6 .&. 0x3f)
        write8_16 mba (boff+2) $ 0x80 + (c .&. 0x3f)
        go mba tba (toff+1) (tlen-1) (boff+3)
      | c < 0xdc00 = 
        if tlen > 1 
        then return $ Just (toff, boff, "unpaired surrogate")
        else let !c2 = indexByteArray tba (toff+1) :: Word16 in
          if 0xdc00 <= c2 && c2 < 0xe000 
          then return $ Just (toff, boff, "expected low surrogate")
          else do
            let !w = unsafeShiftL (fromIntegral (c - 0xd800)) 10 + fromIntegral (c2 - 0xdc00) + 0x0010000 :: Word32
            write8_32 mba boff     $ 0xf0 + unsafeShiftR w 18
            write8_32 mba (boff+1) $ 0x80 + (unsafeShiftR w 12 .&. 0x3f)
            write8_32 mba (boff+2) $ 0x80 + (unsafeShiftR w 6 .&. 0x3f)
            write8_32 mba (boff+3) $ 0x80 + (w .&. 0x3f)
            go mba tba (toff+2) (tlen-2) (boff+4)
      | c <= 0xdfff = return $ Just (toff, boff, fail "unexpected low surrogate")
      | otherwise = do
        write8_16 mba boff     $ 0xe0 + unsafeShiftR c 12
        write8_16 mba (boff+1) $ 0x80 + (unsafeShiftR c 6 .&. 0x3f)
        write8_16 mba (boff+2) $ 0x80 + (c .&. 0x3f)
        go mba tba (toff+1) (tlen-1) (boff+3)
      where !c = indexByteArray tba toff :: Word16
     
      
instance IsString Line where
  fromString xs = case encodeLine (Text.pack xs) of
    Left e -> error (show e)
    Right l -> l

instance IsList Line where
  type Item Line = Word8
  fromList xs = fromListN (Prelude.length xs) xs
  fromListN n xs0 = Line $ runST $ do
      mba <- newByteArray n
      go mba 0 xs0
    where 
      go :: MutableByteArray s -> Int -> [Word8] -> ST s ByteArray
      go !mba !i (x:xs) = writeByteArray mba i x >> go mba (i + 1) xs
      go mba _ [] = unsafeFreezeByteArray mba
  toList l = (l!!) <$> [0 .. size l - 1]


instance AsEmpty Line where
  _Empty = prism (const emptyLine) $ \l -> if size l == 0
    then Right ()
    else Left l

emptyLine :: Line
emptyLine = Line $ runST $ newPinnedByteArray 0 >>= unsafeFreezeByteArray
{-# NOINLINE emptyLine #-}

-- |
-- Invariants:
--
-- * all lines in 'alexInputLines' are distinct
-- * all lines in 'alexInputLines' are non-empty
data AlexInput = AlexInput 
  { alexInputCol8  :: {-# unpack #-} !Int
  , alexInputCol16 :: {-# unpack #-} !Int
  , alexInputLines :: !(Multi Line)
  } deriving Show

advanceInput :: AlexInput -> Delta -> AlexInput
advanceInput (AlexInput a8 a16 xs) (Delta 0 b8 b16) = AlexInput (a8 + b8) (a16 + b16) xs
advanceInput (AlexInput _ _    xs) (Delta l b8 b16) = AlexInput b8 b16 (Multi.drop l xs)

-- |
-- Change in UTF-16 code unit count from a UTF-8 byte
--
-- @
-- 0xxxxxxx -- bump by 1
-- 10xxxxxx -- leave, this is a tail-byte
-- 11xxxxxx -- bump by 1
-- 1111xxxx -- bump by 2
-- @
bump16 :: Word8 -> Int
bump16 w
  | w <= 127  = 1
  | w <= 191  = 0
  | w <= 223  = 1
  | otherwise = 2

-- | 
-- Ideally we'd simply provide a monoid 'Delta' that acts on 'AlexInput'
-- but @alex@ isn't that sophisticated.
--
-- >>> List.unfoldr alexGetByte (AlexInput 0 0 ["hello\n","world"])
-- [104,101,108,108,111,10,119,111,114,108,100]

alexGetByte :: AlexInput -> Maybe (Word8, AlexInput)
alexGetByte (AlexInput _ _ Nil) = Nothing
alexGetByte (AlexInput c8 c16 lls@(Cons l ls))
  | c8 < size l
  , !w8 <- l !! c8 = Just (w8, AlexInput (c8+1) (c16 + bump16 w8) lls)
  | otherwise = case remainder ls of
      Nil -> Nothing
      lls'@(Cons l' _) | w8 <- l' !! 0 -> Just (w8, AlexInput 1 (bump16 w8) lls')

-- | Invariant:
--
-- @'delta' xs ys@ assumes @ys@ was derived from @xs@ by a series of calls to 'alexGetByte'
--
-- This should be used inside of the lexer to compute relative positions
--
-- O(n) in the number of lines between the start and ending position, usually just 0.
-- 
-- This allows AlexInput to avoid stashing the relative line the 
deltaInput :: AlexInput -> AlexInput -> Delta
deltaInput (AlexInput _ _ as) (AlexInput _ _ Nil) = Delta (Prelude.length as) 0 0
deltaInput (AlexInput a80 a160 as0) (AlexInput b80 b160 (Cons bxs0 _)) = go b80 b160 bxs0 0 a80 a160 as0 where
  go !_ !_ !_ !_ !_ !_ Nil = error "delta: position not found"
  go b8 b16 bxs n a8 a16 (Cons axs q)
    | axs == bxs = Delta n (b16 - a16) (b8 - a8)
    | otherwise = go b8 b16 bxs (n+1) 0 0 (remainder q)
