-- | Thin wrappers around `process`: exec a command and capture its trimmed
-- stdout, or run-or-die. Assumes a UTF-8 locale (mkInfraApp's wrapper
-- pins LANG=C.UTF-8 so we can rely on it).
module NixIac.Run
  ( capture
  , captureExit
  , run
  , die
  ) where

import           Data.Char (isSpace)
import           System.Exit (ExitCode (..), exitWith)
import qualified System.IO  as IO
import           System.Process

-- | Run a command, return (exit code, trimmed stdout). Stderr discarded.
captureExit :: FilePath -> [String] -> IO (ExitCode, String)
captureExit cmd args = do
  (ec, out, _err) <- readCreateProcessWithExitCode (proc cmd args) ""
  pure (ec, dropWhileEnd isSpace out)

-- | Run a command; on success return trimmed stdout. On failure exit
-- with the subprocess' exit code, propagating its stderr to ours.
capture :: FilePath -> [String] -> IO String
capture cmd args = do
  (ec, out, err) <- readCreateProcessWithExitCode (proc cmd args) ""
  case ec of
    ExitSuccess   -> pure (dropWhileEnd isSpace out)
    ExitFailure _ -> do IO.hPutStr IO.stderr err; exitWith ec

-- | Run a command for its side effects; inherit stdio. Die on failure.
run :: FilePath -> [String] -> IO ()
run cmd args = do
  ec <- waitForProcess =<< spawnProcess cmd args
  case ec of
    ExitSuccess   -> pure ()
    ExitFailure _ -> exitWith ec

die :: String -> IO a
die msg = IO.hPutStrLn IO.stderr msg >> exitWith (ExitFailure 1)

dropWhileEnd :: (a -> Bool) -> [a] -> [a]
dropWhileEnd p = foldr (\x xs -> if p x && null xs then [] else x : xs) []
