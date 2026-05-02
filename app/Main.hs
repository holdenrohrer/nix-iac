module Main (main) where

import NixIac (greet)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["hello", name] -> putStrLn (greet name)
    _ -> do
      hPutStrLn stderr "usage: infra hello <name>"
      exitFailure
