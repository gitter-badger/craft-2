module Craft.DSL where

import           Control.Lens
import           Control.Monad.Free
import           Control.Monad.Logger   (logDebugNS)
import           Control.Monad.Reader
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Char8  as B8
import           Data.List              (intercalate)
import           Data.List.Split        (splitOn)
import qualified Data.Map.Strict        as Map
import qualified Data.Text              as T
import           Text.Megaparsec
import           Text.Megaparsec.String

import           Craft.Types


-- | Craft DSL
exec :: Command -> Args -> Craft ExecResult
exec cmd args = do
  logDebugNS "exec" $ T.unwords $ map T.pack (cmd:args)
  ce <- ask
  liftF $ Exec ce cmd args id


execAs :: User -> Command -> Args -> Craft ExecResult
execAs user cmd args = withUser user $ exec cmd args


exec_ :: Command -> Args -> Craft ()
exec_ cmd args = do
  ce <- ask
  liftF $ Exec_ ce cmd args ()


execAs_ :: User -> Command -> Args -> Craft ExecResult
execAs_ user cmd args = withUser user $ exec cmd args


fileRead :: Path Abs FileP -> Craft BS.ByteString
fileRead fp =
  liftF $ FileRead fp id


fileWrite :: Path Abs FileP -> BS.ByteString -> Craft ()
fileWrite fp content =
  liftF $ FileWrite fp content ()


sourceFile :: (IO FilePath) -> Path Abs FileP -> Craft ()
sourceFile sourcer dest = liftF $ SourceFile sourcer dest ()


parseExecResult :: ExecResult -> Parsec String a -> String -> Craft a
parseExecResult execr parser str =
  case parse parser (showProc $ execResultProc execr) str of
    Right x -> return x
    Left err -> $craftError $
      unlines
      [ "parseExecResult error:"
      , "<<<< process >>>>"
      , showProc $ execResultProc execr
      , "<<<< output >>>>"
      , str
      , "<<<< parse error >>>>"
      , show err
      ]


-- | better than grep
parseExecStdout :: Parsec StdOut a -> Command -> Args -> Craft a
parseExecStdout parser cmd args = do
  r <- exec cmd args
  s <- $stdoutOrError r
  parseExecResult r parser s


-- TODO: XXX: What if the file doesn't exist?
parseFile :: Parser a -> Path Abs FileP -> Craft a
parseFile parser fp = do
  str <- B8.unpack <$> fileRead fp
  case runParser parser (show fp) str of
    Right x  -> return x
    Left err -> $craftError $ "parseFile `"++show fp++"` failed: "++show err


craftExecPath :: CraftEnv -> Craft [Path Abs Dir]
craftExecPath ce = do
  let dps = maybe [] (splitOn ":") . Map.lookup "PATH" $ ce^.craftExecEnv
  mapM parseAbsDir dps


-- TODO: TESTME
prependPath :: Path Abs Dir -> Craft a -> Craft a
prependPath newpath go = do
  ce <- ask
  execpath <- craftExecPath ce
  withPath (newpath:execpath) go


-- TODO: TESTME
withPath :: [Path Abs Dir] -> Craft a -> Craft a
withPath = withEnvVar "PATH" . intercalate ":" . map fromAbsDir


withEnv :: ExecEnv -> Craft a -> Craft a
withEnv env = local (\r -> r & craftExecEnv .~ env)


withCWD :: Directory -> Craft a -> Craft a
withCWD dir = local (\r -> r & craftExecCWD .~ dir ^. directoryPath)


-- TODO: TESTME
withEnvVar :: String -> String -> Craft a -> Craft a
withEnvVar name val go = do
  ce <- ask
  let env = Map.insert name val $ ce ^. craftExecEnv
  withEnv env go


withUser :: User -> Craft a -> Craft a
withUser user = local (\r -> r & craftExecUserID .~ user^.uid)


isExecSucc :: ExecResult -> Bool
isExecSucc (ExecSucc _) = True
isExecSucc (ExecFail _) = False

setMode :: Mode -> Path b t -> Craft ()
setMode m fp = exec_ "chmod" [toOctalString m, toFilePath fp]

setOwnerID :: UserID -> Path b t -> Craft ()
setOwnerID (UserID i) fp = exec_ "chown" [show i, toFilePath fp]


setGroupID :: GroupID -> Path b t -> Craft ()
setGroupID (GroupID i) fp = exec_ "chgrp" [show i, toFilePath fp]


stat :: Command
stat = "stat"

getMode :: Path Abs t -> Craft Mode
getMode fp = parseExecStdout modeParser stat ["-c", "%a", toFilePath fp]


getOwnerID :: Path Abs t -> Craft UserID
getOwnerID fp = UserID <$> parseExecStdout digitParser stat ["-c", "%u", toFilePath fp]


getGroupID :: Path Abs t -> Craft GroupID
getGroupID fp = GroupID <$> parseExecStdout digitParser stat ["-c", "%g", toFilePath fp]


getStats :: Path Abs t -> Craft (Maybe (Mode, UserID, GroupID))
getStats fp =
  exec stat ["-c", "%a:%u:%g", toFilePath fp] >>= \case
    ExecFail _ -> return Nothing
    ExecSucc r -> Just <$> parseExecResult (ExecSucc r) statsParser (r^.stdout)


statsParser :: Parser (Mode, UserID, GroupID)
statsParser = do
  mode' <- modeParser
  void $ char ':'
  owner' <- UserID <$> digitParser
  void $ char ':'
  group' <- GroupID <$> digitParser
  return (mode', owner', group')


modeParser :: Parser Mode
modeParser = fromOctalString <$> some digitChar


digitParser :: Parser Int
digitParser = read <$> some digitChar
