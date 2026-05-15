{-# LANGUAGE LambdaCase #-}
-- | Thin wrappers around the sops CLI.
--
-- We always pass `--config /dev/null` because `.sops.yaml` discovery from
-- the working directory is exactly the kind of implicit behavior we don't
-- want — every encrypt/decrypt is fully specified at the call site.
module NixIac.Sops
  ( decryptKey
  , decryptFile
  , encryptToAge
  ) where

import qualified Data.Aeson               as A
import qualified Data.Aeson.Key           as AK
import qualified Data.Aeson.KeyMap        as AKM
import qualified Data.ByteString.Lazy.Char8 as L8
import qualified Data.Map.Strict          as Map
import qualified Data.Text                as T
import NixIac.Run (capture, run)

-- | Extract a single top-level YAML key from a sops file.
decryptKey :: FilePath -> String -> IO String
decryptKey file key = capture "sops"
  [ "--config", "/dev/null"
  , "-d"
  , "--extract", "[\"" <> key <> "\"]"
  , file
  ]

-- | Decrypt a whole sops YAML file once and return top-level scalar keys.
decryptFile :: FilePath -> IO (Map.Map String String)
decryptFile file = do
  jsonText <- capture "sops"
    [ "--config", "/dev/null"
    , "-d"
    , "--output-type", "json"
    , file
    ]
  case A.eitherDecode (L8.pack jsonText) of
    Left err             -> fail ("sops: failed to parse JSON from " <> file <> ": " <> err)
    Right (A.Object obj) -> pure $ Map.fromList
      [ (AK.toString k, jsonAsString v)
      | (k, v) <- AKM.toList obj
      , AK.toString k /= "sops"
      ]
    Right _              -> fail ("sops: expected JSON object from " <> file)

-- | sops-encrypt @inFile@ to @outFile@ for a single age recipient.
encryptToAge :: String   -- ^ recipient age public key
             -> FilePath -- ^ input plaintext (yaml)
             -> FilePath -- ^ output ciphertext
             -> IO ()
encryptToAge age inFile outFile = run "sh"
  [ "-c"
  , "sops --config /dev/null --encrypt --input-type yaml --output-type yaml "
    <> "--age " <> shellQuote age <> " " <> shellQuote inFile <> " > " <> shellQuote outFile
  ]
  where
    shellQuote s = "'" <> concatMap esc s <> "'"
    esc '\'' = "'\\''"
    esc c    = [c]

jsonAsString :: A.Value -> String
jsonAsString = \case
  A.String t -> T.unpack t
  other      -> L8.unpack (A.encode other)
