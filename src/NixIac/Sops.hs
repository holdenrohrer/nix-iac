-- | Thin wrappers around the sops CLI.
--
-- We always pass `--config /dev/null` because `.sops.yaml` discovery from
-- the working directory is exactly the kind of implicit behavior we don't
-- want — every encrypt/decrypt is fully specified at the call site.
module NixIac.Sops
  ( decryptKey
  , encryptToAge
  ) where

import NixIac.Run (capture, run)

-- | Extract a single top-level YAML key from a sops file.
decryptKey :: FilePath -> String -> IO String
decryptKey file key = capture "sops"
  [ "--config", "/dev/null"
  , "-d"
  , "--extract", "[\"" <> key <> "\"]"
  , file
  ]

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
