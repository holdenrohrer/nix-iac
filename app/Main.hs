module Main (main) where

import           NixIac            (greet)
import           NixIac.Run        (die)
import qualified NixIac.TfState    as TfState
import           System.Environment (getArgs)

main :: IO ()
main = getArgs >>= dispatch

dispatch :: [String] -> IO ()
dispatch ["hello", name]                 = putStrLn (greet name)
dispatch ("tfstate" : "public"  : k : _) = TfState.readKey TfState.Public  k >>= putStrLn
dispatch ("tfstate" : "private" : k : _) = TfState.readKey TfState.Private k >>= putStrLn
dispatch _ = die usage
  where
    usage = unlines
      [ "usage:"
      , "  infra hello <name>"
      , "  infra tfstate public  <KEY>"
      , "  infra tfstate private <KEY>"
      ]
