module Craft.Run.Nspawn where

import           Control.Lens
import qualified Control.Monad.Trans as Trans
import qualified Data.ByteString     as BS
import qualified Data.Map.Strict     as Map
import           System.Process      hiding (readCreateProcessWithExitCode,
                                      readProcessWithExitCode)

import           Craft.Run.Internal
import           Craft.Types


runNspawn :: Path Abs Dir -> CraftRunner
runNspawn dir =
  CraftRunner
  { runExec =
      \ce command args ->
        let p = nspawnProc dir ce command args
        in execProc p
  , runExec_ =
      \ce command args ->
        let p = nspawnProc dir ce command args
        in execProc_ (showProc p) p
  , runFileRead =
      \fp -> do
        fp' <- stripDir $(mkAbsDir "/") fp
        Trans.lift . BS.readFile . fromAbsFile $ dir</>fp'
  , runFileWrite =
      \fp content -> do
        fp' <- stripDir $(mkAbsDir "/") fp
        Trans.lift (BS.writeFile (fromAbsFile (dir</>fp')) content)
  , runSourceFile =
      \src dest -> do
        dest' <- stripDir $(mkAbsDir "/") dest
        let p = (proc "/bin/cp" [src, fromAbsFile (dir</>dest')])
                { env           = Nothing
                , cwd           = Nothing
                , close_fds     = True
                , create_group  = True
                , delegate_ctlc = False
                }
        execProc_ (showProc p) p
  }


nspawnProc :: Path Abs Dir -> CraftEnv -> Command -> Args -> CreateProcess
nspawnProc dir ce cmd args =
  (proc "systemd-nspawn" ("-D":(fromAbsDir dir):"-q":cmd:args))
  { env           = Just $ Map.toList (ce ^. craftExecEnv)
  , cwd           = Just $ fromAbsDir (ce^.craftExecCWD)
  , close_fds     = True
  , create_group  = True
  , delegate_ctlc = False
  }
