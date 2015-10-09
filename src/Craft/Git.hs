module Craft.Git where

import           Control.Monad.Extra (unlessM)
import           Text.Parsec
import           Text.Parsec.String (Parser)

import           Craft hiding (Version(..))
import qualified Craft.Directory as Directory

type BranchName = String
type TagName    = String
type SHA        = String

data Version
  = Branch BranchName
  | Latest BranchName
  | Tag    TagName
  | Commit SHA
 deriving (Eq)

instance Show Version where
  show (Branch name) = name
  show (Latest name) = name
  show (Tag    name) = "tags/" ++ name
  show (Commit sha)  = sha

master :: Version
master = Latest "master"

origin :: String
origin = "origin"

type URL = String

data Repo
  = Repo
    { url       :: URL
    , directory :: Directory.Path
    , version   :: Version
    }
  deriving (Eq, Show)

repo :: URL -> Directory.Path -> Repo
repo url directory =
  Repo
  { url       = url
  , directory = directory
  , version   = master
  }

gitBin :: FilePath
gitBin = "/usr/bin/git"

git :: String -> [String] -> Craft ()
git cmd args = exec_ gitBin $ cmd : args

remotes :: Craft [String]
remotes = lines . stdout <$> exec gitBin ["remote"]

setURL :: URL -> Craft ()
setURL url = do
  rs <- remotes
  if origin `elem` rs then
    git "remote" ["set-url", origin, url]
  else
    git "remote" ["add", origin, url]

getURL :: Craft URL
getURL = do
  results <- parseExec repoURLParser gitBin ["remote", "-v"]
  return $ case lookup (origin, "fetch") results of
    Nothing -> error $ "git remote `" ++ origin ++ "` not found."
    Just url -> url

-- TESTME
repoURLParser :: Parser [((String, String), String)]
repoURLParser = many1 $ do
  remote <- word
  url <- word
  direction <- char '(' *> many1 alphaNum <* char ')' <* newline
  return ((remote, direction), url)
 where
  word = many1 (noneOf " \t") <* many1 (space <|> tab)

getVersion :: Craft Version
getVersion = Commit <$> parseExec parser gitBin ["rev-parse", "HEAD"]
 where
  parser = many1 alphaNum

get :: Directory.Path -> Craft (Maybe Repo)
get path = do
  exists <- Directory.exists path
  if not exists then
    return Nothing
  else
    withCWD path $ do
      !url'     <- getURL
      !version' <- getVersion
      return . Just $
        Repo { directory = path
              , url       = url'
              , version   = version'
              }

instance Craftable Repo where
  checker = get . directory

  crafter Repo{..} = do
    unlessM (Directory.exists directory) $
      git "clone" [url, directory]
    withCWD directory $ do
      setURL url
      git "fetch" [origin]
      git "checkout" ["--force", show version]
      git "reset" ["--hard"]
      case version of
        Latest branchName -> git "pull" [origin, branchName]
        _                 -> return ()

  remover = notImplemented "remover Git"
