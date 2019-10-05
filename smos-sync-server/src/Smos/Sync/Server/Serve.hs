{-# LANGUAGE RecordWildCards #-}

module Smos.Sync.Server.Serve where

import Data.Aeson as JSON
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as LB
import Data.Text as T
import Path
import Path.IO
import System.Exit

import Control.Concurrent.MVar
import Control.Monad.Logger
import Control.Monad.Reader

import Network.Wai as Wai
import Network.Wai.Handler.Warp as Warp

import Database.Persist.Sqlite as DB

import Servant

import Smos.Sync.API
import Smos.Sync.Server.Handler
import Smos.Sync.Server.OptParse

serveSmosSyncServer :: ServeSettings -> IO ()
serveSmosSyncServer ss@ServeSettings {..} = do
  pPrint ss
  runStderrLoggingT $
    DB.withSqlitePool (T.pack $ fromAbsFile serveSetDatabaseFile) 1 $ \pool ->
      liftIO $ do
        uuid <- readUUID serveSetUUIDFile
        writeUUID serveSetUUIDFile uuid
        store <-
          flip DB.runSqlPool pool $ do
            DB.runMigration migrateAll
            readServerStore
        cacheVar <- newMVar store
        let env =
              ServerEnv
                { serverEnvServerUUID = uuid
                , serverEnvStoreCache = cacheVar
                , serverEnvConnection = pool
                }
        Warp.run serveSetPort $ makeSyncApp env

makeSyncApp :: ServerEnv -> Wai.Application
makeSyncApp env =
  Servant.serve syncAPI $
  hoistServer syncAPI ((`runReaderT` env) :: SyncHandler a -> Handler a) syncServer

syncServer :: ServerT SyncAPI SyncHandler
syncServer = handlePostSync

readUUID :: Path Abs File -> IO ServerUUID
readUUID p = do
  mContents <- forgivingAbsence $ LB.readFile $ fromAbsFile p
  case mContents of
    Nothing -> nextRandomUUID
    Just contents ->
      case JSON.eitherDecode contents of
        Left err -> die err
        Right u -> pure u

writeUUID :: Path Abs File -> ServerUUID -> IO ()
writeUUID p u = do
  ensureDir (parent p)
  LB.writeFile (fromAbsFile p) $ encodePretty u
