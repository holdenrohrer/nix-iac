module Main (main) where

import           NixIac             (greet)
import qualified NixIac.Nixify      as Nixify
import qualified NixIac.Probe       as Probe
import           NixIac.Run         (die)
import qualified NixIac.TfState     as TfState
import           System.Environment (getArgs)
import           System.Exit        (ExitCode (..), exitWith)

main :: IO ()
main = getArgs >>= dispatch

dispatch :: [String] -> IO ()
dispatch ["hello", name]                                  = putStrLn (greet name)
dispatch ("tfstate" : "public"  : k : _)                  = TfState.readKey TfState.Public  k >>= putStrLn
dispatch ("tfstate" : "private" : k : _)                  = TfState.readKey TfState.Private k >>= putStrLn
dispatch ["probe-nixos", host, sshKey]                    = do
  ok <- Probe.probeNixos host sshKey
  exitWith (if ok then ExitSuccess else ExitFailure 1)
dispatch ("nixify" : name : flake : host : sshKey : rest) =
  Nixify.nixify name flake host sshKey (extrasOf rest)
  where
    extrasOf (extras : _) | not (null extras) = Just extras
    extrasOf _                                = Nothing
dispatch _ = die usage
  where
    usage = unlines
      [ "usage:"
      , "  infra hello <name>"
      , "  infra tfstate public  <KEY>"
      , "  infra tfstate private <KEY>"
      , "  infra probe-nixos <HOST> <SSH-KEY>"
      , "  infra nixify <NAME> <FLAKE> <HOST> <SSH-KEY> [EXTRAS-DIR]"
      ]
