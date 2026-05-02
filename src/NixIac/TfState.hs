{-# LANGUAGE OverloadedStrings #-}
-- | Read values out of terraform state files.
--
-- Two visibilities, two access paths:
--
--   * 'Public'  state is hosted at an anonymous-readable S3 URL. We curl
--     the JSON and pluck `.outputs.<KEY>.value`. No AWS creds required.
--   * 'Private' state is read via `tofu output -raw <KEY>` against a local
--     working directory whose backend points at the locked-down bucket.
--     The caller is responsible for having run `tofu init` and having
--     deployer creds in the environment.
--
-- Write semantics live in NixIac.Infra; this module is read-only.
module NixIac.TfState
  ( Visibility (..)
  , readKey
  ) where

import qualified Data.Aeson                 as A
import qualified Data.Aeson.Key             as K
import qualified Data.Aeson.KeyMap          as KM
import qualified Data.ByteString.Lazy.Char8 as L8
import qualified Data.Text                  as T
import           NixIac.Run                 (capture, die)
import           System.Environment         (lookupEnv)

data Visibility = Public | Private deriving (Eq, Show)

readKey :: Visibility -> String -> IO String
readKey Public  k = readPublic k
readKey Private k = readPrivate k

readPublic :: String -> IO String
readPublic k = do
  url <- maybe (die missingEnv) pure =<< lookupEnv "NIX_IAC_PUBLIC_STATE_URL"
  body <- capture "curl" ["-fsS", url]
  case A.eitherDecode (L8.pack body) of
    Left e -> die ("public tfstate not valid JSON: " <> e)
    Right (A.Object root) ->
      case KM.lookup "outputs" root of
        Just (A.Object outs) -> case KM.lookup (K.fromString k) outs of
          Just (A.Object out) -> case KM.lookup "value" out of
            Just v  -> pure (jsonAsString v)
            Nothing -> die ("no .outputs." <> k <> ".value")
          _ -> die ("output missing from public state: " <> k)
        _ -> die "tfstate has no top-level .outputs"
    Right _ -> die "public tfstate root is not an object"
  where
    missingEnv = "NIX_IAC_PUBLIC_STATE_URL not set; can't read public state"

-- | Render a JSON value as the raw string `tofu output -raw` would emit.
jsonAsString :: A.Value -> String
jsonAsString (A.String t) = T.unpack t
jsonAsString v            = L8.unpack (A.encode v)

readPrivate :: String -> IO String
readPrivate k = do
  dir <- maybe (die missingEnv) pure =<< lookupEnv "NIX_IAC_PRIVATE_DIR"
  capture "tofu" ["-chdir=" <> dir, "output", "-raw", k]
  where
    missingEnv = "NIX_IAC_PRIVATE_DIR not set; can't read private state"
