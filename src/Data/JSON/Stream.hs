{-# LANGUAGE OverloadedStrings #-}
module Data.JSON.Stream (parseValue) where

import           Control.Applicative
import           Numeric (readHex)
import           Data.Word (Word8)
import qualified Data.Char as Char
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8

import qualified Data.Text as T
import           Data.Text (Text)
import           Data.Text.Encoding (encodeUtf8, decodeUtf8')
import           Data.Aeson (Value(..), toJSON, object, (.=))
import           Data.Aeson.Types (Pair)

type Parser a = ByteString -> Maybe (a, ByteString)

parseValue :: Parser Value
parseValue = go
  where
    go input = do
      (x, xs) <- B.uncons input
      let cont
            | x == ord '{' = parseObject xs
            | x == ord '[' = parseArray xs
            | x == ord '"' = parseString xs
            | x == ord 't' = parseTrue xs
            | x == ord 'f' = parseFalse xs
            | x == ord 'n' = parseNull xs
            | otherwise = parseNumber input
      cont

parseNull :: Parser Value
parseNull input = case B.splitAt 3 input of
  ("ull", rest) -> Just (Null, rest)
  _ -> Nothing

parseTrue :: Parser Value
parseTrue input = case B.splitAt 3 input of
  ("rue", rest) -> Just (Bool True, rest)
  _ -> Nothing

parseFalse :: Parser Value
parseFalse input = case B.splitAt 4 input of
  ("alse", rest) -> Just (Bool False, rest)
  _ -> Nothing

parseString :: Parser Value
parseString = fmap (mapFst String) . parseStringLit

parseStringLit :: Parser Text
parseStringLit input = do
  (str, rest) <- parseStringLit_ input
  str_ <- (either (const Nothing) Just . decodeUtf8' . B.concat) str
  return (str_, rest)

parseStringLit_ :: Parser [ByteString]
parseStringLit_ = go
  where
    go :: Parser [ByteString]
    go input = do
      let (xs, ys) = B.break (\c -> c == ord '"' || c == ord '\\') input
      case B.uncons ys of
        Just (z, zs) -> do
          let cont
                | z == ord '"' = Just ([xs], zs)
                | z == ord '\\' = xs <:> unescape zs
          cont
        Nothing -> Nothing

    unescape :: Parser [ByteString]
    unescape input = do
      (x, xs) <- B.uncons input
      let cont
            | x == ord 'u' = unescapeUnicode xs
            | x == ord 'b' = "\b" <:> go xs
            | x == ord 'f' = "\f" <:> go xs
            | x == ord 'n' = "\n" <:> go xs
            | x == ord 'r' = "\r" <:> go xs
            | x == ord 't' = "\t" <:> go xs
            | otherwise = B.pack [x] <:> go xs
      cont

    unescapeUnicode :: Parser [ByteString]
    unescapeUnicode input = do
      -- FIXME: Make tihs more efficient
      let (xs, ys) = B.splitAt 4 input
      case readHex (B8.unpack xs) of
        [(n, "")] -> (encodeUtf8 $ T.pack [Char.chr n]) <:> go ys
        _ -> Nothing

    (<:>) :: ByteString -> Maybe ([ByteString], ByteString) -> Maybe ([ByteString], ByteString)
    xs <:> ys = mapFst (xs :) <$> ys

-- FIXME: This is not correct yet..
parseNumber :: Parser Value
parseNumber input = case B.span (\x -> ord '0' <= x && x <= ord '9') input of
  (xs, rest) | (not . B.null) xs -> Just ((Number . read . B8.unpack) xs, rest)
  _ -> Nothing

parseArray :: Parser Value
parseArray = fmap (mapFst toJSON) . go
  where
    go :: Parser [Value]
    go input = do
      (value, rest) <- parseValue input
      case B.uncons rest of
        Just (y, ys) -> do
          let cont
                | y == ord ']' = return ([value], ys)
                | y == ord ',' = do
                    (zs, rest_) <- go ys
                    return (value : zs, rest_)
                | otherwise = Nothing
          cont
        Nothing -> Nothing

parseObject :: Parser Value
parseObject = fmap (mapFst object) . go
  where
    go :: ByteString -> Maybe ([Pair], ByteString)
    go input = do
      (name, rest) <- parseName input
      (x, xs) <- B.uncons rest
      let cont
            | x == ord ':' = do
                (value, r) <- parseValue xs
                (z, zs) <- B.uncons r
                let cont_
                      | z == ord ',' = mapFst ((name .= value) :) <$> go zs
                      | z == ord '}' = return ([name .= value], zs)
                      | otherwise = Nothing
                cont_
            | otherwise = Nothing
      cont

    parseName :: Parser Text
    parseName input = do
      (x, xs) <- B.uncons input
      let cont
            | x == ord '"' = parseStringLit xs
            | otherwise = Nothing
      cont

ord :: Char -> Word8
ord = fromIntegral . Char.ord

mapFst :: (a -> b) -> (a, c) -> (b, c)
mapFst f (a, b) = (f a, b)
