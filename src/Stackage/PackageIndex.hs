{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

-- | Package index handling.

module Stackage.PackageIndex
       (PackageIndex(..), getPkgIndex, loadPkgIndex, isIndexOutdated,
        updateIndex, getPkgVersions)
       where

import qualified Codec.Archive.Tar as Tar
import Control.Exception (Exception, IOException, try)
import Control.Monad (unless, when)
import Control.Monad.Catch (MonadThrow, throwM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Logger
       (MonadLogger, logWarn, logInfo, logError, logDebug)
import Control.Monad.Trans.Control (MonadBaseControl)
import qualified Data.ByteString.Lazy as L
import Data.Conduit (($$+-))
import Data.Conduit.Binary (sinkFile)
import Data.Maybe (fromJust, isJust)
import Data.Monoid ((<>))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.String (IsString(fromString))
import qualified Data.Text as T
import Data.Typeable (Typeable)
import Network.HTTP.Conduit
       (Response(responseBody), parseUrl, withManager, http)
import Network.URI (URI, uriToString, parseURI)
import Path
       (Path, Abs, Dir, File, toFilePath, parseAbsDir, parseAbsFile,
        mkRelFile, mkRelDir, (</>))
import Stackage.PackageName (PackageName, packageNameString)
import Stackage.PackageVersion
       (PackageVersion, parsePackageVersionFromString)
import System.Directory
       (removeFile, renameFile, getAppUserDataDirectory, findExecutable,
        doesDirectoryExist, createDirectoryIfMissing)
import System.Exit (ExitCode(ExitSuccess), exitWith)
import System.IO (IOMode(ReadMode), withBinaryFile)
import System.Process (createProcess, cwd, proc, waitForProcess)

data PackageIndexException =
  Couldn'tReadIndexTarball FilePath
                           Tar.FormatError
  deriving (Show,Typeable)
instance Exception PackageIndexException

-- | Wrapper to an existant package index.
newtype PackageIndex =
  PackageIndex (Path Abs Dir)

-- | Try to get the package index.
getPkgIndex :: (MonadIO m,MonadLogger m,MonadThrow m)
            => (Path Abs Dir) -> m (Maybe PackageIndex)
getPkgIndex dir =
  do exists <-
       (liftIO . doesDirectoryExist . toFilePath) dir
     return (if exists
                then Just (PackageIndex dir)
                else Nothing)

-- | Load the package index, if it does not exist, download it.
loadPkgIndex :: (MonadBaseControl IO m,MonadIO m,MonadLogger m,MonadThrow m)
             => Path Abs Dir -> m PackageIndex
loadPkgIndex dir =
  do maybeIdx <- getPkgIndex dir
     case maybeIdx of
       Just idx -> return idx
       Nothing ->
         do let idx = (PackageIndex dir)
            updateIndex idx
            return idx

-- | Check if the index is outdated
isIndexOutdated :: (MonadIO m,MonadLogger m,MonadThrow m)
                => PackageIndex -> m Bool
isIndexOutdated idx =
  do git <- isGitInstalled
     if git
        then isOutdatedGit idx
        else isOutdatedHTTP idx

-- | Check if the index Git repo is outdated
isOutdatedGit :: (MonadIO m,MonadLogger m,MonadThrow m)
              => PackageIndex -> m Bool
isOutdatedGit idx =
  do $logWarn "FIXME: HOW DO WE DETERMINE THE INDEX IS OUTDATED?"
     -- TODO: IF THE INDEX IS PRESENT DO A `git remote update` & CHECK
     -- THE INDEX VS THE MAIN BRANCH WITH THE CABAL FILES.
     return True

-- | Check if the index tarball (via http) is outdated
isOutdatedHTTP :: (MonadIO m,MonadLogger m,MonadThrow m)
               => PackageIndex -> m Bool
isOutdatedHTTP idx =
  do $logWarn "FIXME: HOW DO WE DETERMINE THE INDEX TARBALL IS OUTDATED?"
     -- TODO: IS THE FILE EVEN PRESENT? CHECK DIGEST W/ HTTP HEAD
     -- ETAGS FROM S3?
     return True

-- | Update the index tarball
updateIndex :: (MonadBaseControl IO m,MonadIO m,MonadLogger m,MonadThrow m)
            => PackageIndex -> m ()
updateIndex idx =
  do git <- isGitInstalled
     if git
        then updateIndexGit idx
        else updateIndexHTTP idx

-- | Update the index Git repo and the index tarball
updateIndexGit :: (MonadIO m,MonadLogger m,MonadThrow m)
               => PackageIndex -> m ()
updateIndexGit (PackageIndex idxPath) =
  do path <- liftIO (findExecutable "git")
     case path of
       Nothing ->
         error "Please install git and provide the executable on your PATH"
       Just fp ->
         do gitPath <- parseAbsFile fp
            $logWarn "FIXME: USING LOCAL DEFAULTS FOR URL & PATH"
            let gitUrl =
                  uriToString id pkgIndexGitUriDefault []
                repoName =
                  $(mkRelDir "all-cabal-files")
                cloneArgs =
                  ["clone"
                  ,gitUrl
                  ,(toFilePath repoName)
                  ,"--depth"
                  ,"1"
                  ,"-b"
                  ,"display"]
            sDir <-
              liftIO (parseAbsDir =<<
                      getAppUserDataDirectory "stackage")
            let suDir =
                  sDir </>
                  $(mkRelDir "update")
                acfDir = suDir </> repoName
            repoExists <-
              liftIO (doesDirectoryExist (toFilePath acfDir))
            unless repoExists
                   (do $logInfo ("Cloning repository for first from " <>
                                 T.pack gitUrl)
                       runIn suDir gitPath cloneArgs Nothing)
            runIn acfDir gitPath ["fetch","--tags","--depth=1"] Nothing
            let tarFile = idxPath
            _ <-
              (liftIO . tryIO) (removeFile (toFilePath tarFile))
            $logWarn "FIXME: WE DONT YET HAVE FLAG|SETTING|DEFAULT FOR GIT GPG VALIDATION"
            when False
                 (do runIn acfDir
                           gitPath
                           ["tag","-v","current-hackage"]
                           (Just (unlines ["Signature verification failed. "
                                          ,"Please ensure you've set up your"
                                          ,"GPG keychain to accept the D6CF60FD signing key."
                                          ,"For more information, see:"
                                          ,"https://github.com/fpco/stackage-update#readme"])))
            $logDebug ("Exporting a tarball to " <>
                       (T.pack . toFilePath) tarFile)
            runIn acfDir
                  gitPath
                  ["archive"
                  ,"--format=tar"
                  ,"-o"
                  ,toFilePath tarFile
                  ,"current-hackage"]
                  Nothing

tryIO :: forall a.
         IO a -> IO (Either IOException a)
tryIO = try

runIn :: forall (m :: * -> *).
         (MonadLogger m,MonadIO m)
      => Path Abs Dir -> Path Abs File -> [String] -> Maybe String -> m ()
runIn dir cmd args errMsg =
  do let dir' = toFilePath dir
         cmd' = toFilePath cmd
     liftIO (createDirectoryIfMissing True dir')
     (Nothing,Nothing,Nothing,ph) <-
       liftIO (createProcess
                 (proc cmd' args) {cwd =
                                     Just dir'})
     ec <- liftIO (waitForProcess ph)
     when (ec /= ExitSuccess)
          (do $logError (T.pack (concat ["Exit code "
                                        ,show ec
                                        ," while running "
                                        ,show (cmd' : args)
                                        ," in "
                                        ,dir']))
              when (isJust errMsg)
                   (($logError .
                     T.pack . fromJust) errMsg)
              liftIO (exitWith ec))

-- | Update the index tarball via HTTP
updateIndexHTTP :: (MonadBaseControl IO m,MonadIO m,MonadLogger m,MonadThrow m)
                => PackageIndex -> m ()
updateIndexHTTP (PackageIndex idxPath) =
  do $logWarn "FIXME: USING LOCAL DEFAULTS FOR URL"
     let url =
           uriToString id pkgIndexHttpUriDefault []
         tarPath =
           idxPath </>
           $(mkRelFile "00-index.tar")
         tarFilePath = toFilePath tarPath
         tmpTarPath =
           idxPath </>
           $(mkRelFile "00-index.tar.tmp") -- Path is missing <.>
         tmpTarFilePath = toFilePath tmpTarPath
     req <- parseUrl url
     $logDebug ("Downloading package index from " <> T.pack url)
     withManager
       (\mgr ->
          do res <- http req mgr
             responseBody res $$+-
               sinkFile (fromString tmpTarFilePath))
     liftIO (renameFile tmpTarFilePath tarFilePath)
     $logWarn "FIXME: WE CAN'T RUN GIT GPG SIGNATURE VERIFICATION WITHOUT GIT"

-- | Fetch all the package versions for a given package
getPkgVersions :: (MonadIO m,MonadLogger m,MonadThrow m)
               => PackageIndex -> PackageName -> m (Maybe (Set PackageVersion))
getPkgVersions (PackageIndex idxPath) pkg =
  do let tarPath = idxPath </> $(mkRelFile "00-index.tar")
         tarFilePath = toFilePath tarPath
     $logWarn "FIXME: USING LOCAL DEFAULTS FOR URL & PATH"
     $logDebug ("Iterating through tarball " <> T.pack tarFilePath)
     liftIO (withBinaryFile
               tarFilePath
               ReadMode
               (\h ->
                  do lbs <- L.hGetContents h
                     vers <-
                       liftIO (iterateTarball tarFilePath
                                              (packageNameString pkg)
                                              Set.empty
                                              (Tar.read lbs))
                     case vers of
                       set
                         | Set.empty == set ->
                           return Nothing
                       set -> return (Just set)))
  where iterateTarball tarPath name vers (Tar.Next e es) =
          case (getNameAndVersion (Tar.entryPath e),Tar.entryContent e) of
            (Just (name',ver),_)
              | name' == name ->
                do parsedVer <- parsePackageVersionFromString ver
                   iterateTarball tarPath
                                  name
                                  (Set.insert parsedVer vers)
                                  es
            _ ->
              iterateTarball tarPath name vers es
        iterateTarball tarPath _ _ (Tar.Fail e) =
          throwM (Couldn'tReadIndexTarball tarPath e)
        iterateTarball _ _ vers Tar.Done = return vers
        getNameAndVersion name =
          case T.splitOn "/" (T.pack name) of
            [n,v,fp]
              | T.stripSuffix ".json" fp ==
                  Just n ->
                Just (T.unpack n,T.unpack v)
            _ -> Nothing

-- | Is the git executable installed?
isGitInstalled :: MonadIO m
               => m Bool
isGitInstalled =
  return . isJust =<<
  liftIO (findExecutable "git")

-- | Temporarily define the standard Git repo url locally here in this
-- module until we work out the Stackage.Config for it.
pkgIndexGitUriDefault :: URI
pkgIndexGitUriDefault =
  (fromJust . parseURI) "https://github.com/commercialhaskell/all-cabal-files.git"

-- | Temporarily define the standard HTTP tarball url locally here in
-- this module until we work out the Stackage.Config for it.
pkgIndexHttpUriDefault :: URI
pkgIndexHttpUriDefault =
  (fromJust . parseURI)
    ("https://github.com/commercialhaskell/all-cabal-files" <>
     "files/archive/master.tar.gz")
