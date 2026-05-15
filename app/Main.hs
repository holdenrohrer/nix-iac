{-# LANGUAGE OverloadedStrings #-}

module Main where

import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as BL
import           NixIac.Orchestrator
import qualified NixIac.Exec as Exec
import qualified System.Process as P
import           System.Environment (getArgs)
import           System.Exit (ExitCode (..), exitWith)
import           System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ("--plan":planPath:rest) -> do
      plan0 <- readPlan planPath
      root <- gitRoot
      let plan = plan0 { planStateDir = root <> "/" <> planStateDir plan0 }
      dispatch plan rest
    _ -> hPutStrLn stderr "usage: nix-iac --plan PLAN.json <subcommand> [args...]" >> exitWith (ExitFailure 64)

readPlan :: FilePath -> IO Plan
readPlan path = do
  bytes <- BL.readFile path
  case A.eitherDecode bytes of
    Right plan -> pure plan
    Left err -> hPutStrLn stderr ("plan parse error: " <> err) >> exitWith (ExitFailure 65)

dispatch :: Plan -> [String] -> IO ()
dispatch plan args = case args of
  []                  -> deployWith plan defaultDeployOpts
  ("deploy":rest)     -> case parseDeployFlags rest defaultDeployOpts of
    Right opts        -> deployWith plan opts
    Left  err         -> hPutStrLn stderr err >> exitWith (ExitFailure 64)
  ("exec":rest)       -> Exec.execEnv plan rest
  ("help":_)          -> usage >> exitWith ExitSuccess
  ("--help":_)        -> usage >> exitWith ExitSuccess
  ("-h":_)            -> usage >> exitWith ExitSuccess
  (cmd:_)             -> do
    hPutStrLn stderr ("error: unknown subcommand: " <> cmd)
    usage
    exitWith (ExitFailure 64)
  where
    deployWith p opts = do
      hPutStrLn stderr ("==> nix-iac: stateDir = " <> planStateDir p)
      orchestrate opts p

parseDeployFlags :: [String] -> DeployOpts -> Either String DeployOpts
parseDeployFlags [] opts = Right opts
parseDeployFlags ("--reinstall":xs) opts =
  parseDeployFlags xs opts { doReinstall = True }
parseDeployFlags ("--bootstrap":xs) opts =
  parseDeployFlags xs opts { doBootstrap = True }
parseDeployFlags ("--host":name:xs) opts =
  let hs = case doHostFilter opts of
        Just acc -> Just (acc ++ [name])
        Nothing  -> Just [name]
  in parseDeployFlags xs opts { doHostFilter = hs }
parseDeployFlags ("--host":[]) _ =
  Left "error: --host requires an argument (host name)"
parseDeployFlags ("--rotate":name:xs) opts =
  parseDeployFlags xs opts { doRotate = doRotate opts ++ [name] }
parseDeployFlags ("--rotate":[]) _ =
  Left "error: --rotate requires an argument (output name)"
parseDeployFlags (x:_) _ =
  Left ("error: unknown deploy flag: " <> x)

usage :: IO ()
usage = mapM_ (hPutStrLn stderr)
  [ "usage: infra <subcommand> [args...]"
  , ""
  , "  deploy [opts]      Apply tfstates and deploy hosts. Options:"
  , "                       --host NAME      only deploy NAME (repeatable)."
  , "                       --reinstall      force nixos-anywhere even on a"
  , "                                        host that's already NixOS, e.g. to"
  , "                                        reformat after a disko-config change."
  , "                       --bootstrap      let Probe + Nixify fall back to ambient"
  , "                                        ssh (agent / ~/.ssh) on a host whose"
  , "                                        deploy key isn't installed yet."
  , "                       --rotate NAME    regenerate a gen.once value."
  , "                                        Repeatable."
  , "  exec <cmd> [...]   Run <cmd> with ssh/scp/sftp/rsync wrapped to"
  , "                     resolve every host by name."
  ]

gitRoot :: IO String
gitRoot = do
  out <- P.readProcess "git" ["rev-parse", "--show-toplevel"] ""
  pure (reverse (dropWhile (== '\n') (reverse out)))
