module NixIac (greet) where

greet :: String -> String
greet name = "hello " <> name <> ", from nix-iac (haskell)"
