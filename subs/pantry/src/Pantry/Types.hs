{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-} -- FIXME REMOVE!
module Pantry.Types
  ( PantryConfig (..)
  , HackageSecurityConfig (..)
  , Storage (..)
  , HasPantryConfig (..)
  , BlobKey (..)
  , PackageName
  , Version
  , PackageIdentifier (..)
  , Revision (..)
  , CabalFileInfo (..)
  , PackageNameP (..)
  , VersionP (..)
  , PackageIdentifierRevision (..)
  , FileType (..)
  , FileSize (..)
  , TreeEntry (..)
  , SafeFilePath
  , unSafeFilePath
  , mkSafeFilePath
  , TreeKey (..)
  , Tree (..)
  , renderTree
  , parseTree
  -- , PackageTarball (..)
  , PackageLocation (..)
  , PackageLocationImmutable (..)
  , Archive (..)
  , Repo (..)
  , RepoType (..)
  , parsePackageIdentifier
  , parsePackageName
  , parseFlagName
  , parseVersion
  , displayC
  , UnresolvedPackageLocationImmutable (..)
  , mkUnresolvedPackageLocationImmutable
  , resolvePackageLocationImmutable
  , OptionalSubdirs (..)
  , ArchiveLocation (..)
  , UnresolvedPackageLocation (..)
  , RelFilePath (..)
  , CabalString (..)
  , toCabalStringMap
  , unCabalStringMap
  , parsePackageIdentifierRevision
  , Mismatch (..)
  , PantryException (..)
  , ResolvedPath (..)
  , HpackExecutable (..)
  , WantedCompiler (..)
  , UnresolvedSnapshotLocation
  , resolveSnapshotLocation
  , unresolveSnapshotLocation
  , ltsSnapshotLocation
  , nightlySnapshotLocation
  , SnapshotLocation (..)
  , parseSnapshotLocation
  , parseSnapshot
  , Snapshot (..)
  , parseWantedCompiler
  , PackageMetadata (..)
  ) where

import RIO
import qualified RIO.Text as T
import qualified RIO.ByteString as B
import qualified RIO.ByteString.Lazy as BL
import RIO.Char (isSpace)
import RIO.List (intersperse)
import RIO.Time (toGregorian, Day)
import qualified RIO.Map as Map
import qualified RIO.HashMap as HM
import qualified Data.Map.Strict as Map (mapKeysMonotonic)
import qualified RIO.Set as Set
import Data.Aeson (ToJSON (..), FromJSON (..), withText, FromJSONKey (..))
import Data.Aeson.Types (ToJSONKey (..) ,toJSONKeyText, Parser)
import Data.Aeson.Extended
import Data.ByteString.Builder (toLazyByteString, byteString, wordDec)
import Database.Persist
import Database.Persist.Sql
import Pantry.StaticSHA256
import qualified Distribution.Compat.ReadP as Parse
import Distribution.Parsec.Common (PError (..), PWarning (..), showPos)
import Distribution.Types.PackageName (PackageName)
import Distribution.Types.VersionRange (VersionRange)
import Distribution.PackageDescription (FlagName)
import Distribution.Types.PackageId (PackageIdentifier (..))
import qualified Distribution.Text
import Distribution.Types.Version (Version)
import Data.Store (Size (..), Store (..)) -- FIXME remove
import Network.HTTP.Client (parseRequest)
import Network.URI (URI)
import qualified Network.HTTP.Client.Conduit as HTTP
import Network.HTTP.Types (Status, statusCode)
import Data.Text.Read (decimal)
import Path (Abs, Dir, File, toFilePath, filename)
import Path.Internal (Path (..)) -- FIXME don't import this
import Path.IO (resolveFile)
import Data.Pool (Pool)

newtype Revision = Revision Word
    deriving (Generic, Show, Eq, NFData, Data, Typeable, Ord, Hashable, Store, Display, PersistField, PersistFieldSql)

newtype Storage = Storage (Pool SqlBackend)

data PantryConfig = PantryConfig
  { pcHackageSecurity :: !HackageSecurityConfig
  , pcHpackExecutable :: !HpackExecutable
  , pcRootDir :: !(Path Abs Dir)
  , pcStorage :: !Storage
  , pcUpdateRef :: !(MVar Bool)
  -- ^ Want to try updating the index once during a single run for missing
  -- package identifiers. We also want to ensure we only update once at a
  -- time. Start at @True@.
  {- FIXME add this shortly
  , pcParsedCabalFiles ::
      !(IORef
          ( Map PackageLocation GenericPackageDescription
          , Map FilePath        GenericPackageDescription
          )
       )
  -- ^ Cache of previously parsed cabal files, to save on slow parsing time.
  -}
  , pcConnectionCount :: !Int
  -- ^ concurrently open downloads
  , pcManager :: HTTP.Manager
  -- ^ Manager for connecting to the pantry storage server.
  , pcStorageServerURI :: URI
  -- ^ URI for connecting to the pantry storage server.
  }

-- | A directory which was loaded up relative and has been resolved
-- against the config file it came from.
data ResolvedPath t = ResolvedPath
  { resolvedRelative :: !RelFilePath
  -- ^ Original value parsed from a config file.
  , resolvedAbsolute :: !(Path Abs t)
  }
  deriving (Show, Eq, Data, Generic, Ord)
instance NFData (ResolvedPath t)
instance (Generic t, Store t) => Store (ResolvedPath t)

-- | Either an immutable package location or a local package directory which is
-- a subject to change.
data PackageLocation
  = PLImmutable !PackageLocationImmutable
  | PLMutable !(ResolvedPath Dir)
  deriving (Show, Eq, Data, Generic)
instance NFData PackageLocation
instance Store PackageLocation

instance Display PackageLocation where
  display (PLImmutable loc) = display loc
  display (PLMutable fp) = fromString $ toFilePath $ resolvedAbsolute fp

-- | Location for remote packages or archives assumed to be immutable.
data PackageLocationImmutable
  = PLIHackage !PackageIdentifierRevision !(Maybe TreeKey)
  | PLIArchive !Archive !PackageMetadata
  | PLIRepo    !Repo !PackageMetadata
  deriving (Generic, Show, Eq, Ord, Data, Typeable)
instance NFData PackageLocationImmutable
instance Store PackageLocationImmutable

instance Display PackageLocationImmutable where
  display (PLIHackage pir _tree) = display pir <> " (from Hackage)"
  display (PLIArchive archive pm) =
    "Archive from " <> display (archiveLocation archive) <>
    (if T.null $ pmSubdir pm
       then mempty
       else " in subdir " <> display (pmSubdir pm))
  display (PLIRepo repo pm) =
    "Repo from " <> display (repoUrl repo) <>
    ", commit " <> display (repoCommit repo) <>
    (if T.null $ pmSubdir pm
       then mempty
       else " in subdir " <> display (pmSubdir pm))

-- | A package archive, could be from a URL or a local file
-- path. Local file path archives are assumed to be unchanging
-- over time, and so are allowed in custom snapshots.
data Archive = Archive
  { archiveLocation :: !ArchiveLocation
  , archiveHash :: !(Maybe StaticSHA256)
  , archiveSize :: !(Maybe FileSize)
  }
    deriving (Generic, Show, Eq, Ord, Data, Typeable)
instance Store Archive
instance NFData Archive

-- | A package archive, could be from a URL or a local file
-- path. Local file path archives are assumed to be unchanging
-- over time, and so are allowed in custom snapshots.
data UnresolvedArchive = UnresolvedArchive
  { uaLocation :: !UnresolvedArchiveLocation
  , uaHash :: !(Maybe StaticSHA256)
  , uaSize :: !(Maybe FileSize)
  }
    deriving (Generic, Show, Eq, Ord, Data, Typeable)
instance Store UnresolvedArchive
instance NFData UnresolvedArchive

-- | The type of a source control repository.
data RepoType = RepoGit | RepoHg
    deriving (Generic, Show, Eq, Ord, Data, Typeable)
instance Store RepoType
instance NFData RepoType

-- | Information on packages stored in a source control repository.
data Repo = Repo
    { repoUrl :: !Text
    , repoCommit :: !Text
    , repoType :: !RepoType
    }
    deriving (Generic, Show, Eq, Ord, Data, Typeable)
instance Store Repo
instance NFData Repo

-- An unexported newtype wrapper to hang a 'FromJSON' instance off of. Contains
-- a GitHub user and repo name separated by a forward slash, e.g. "foo/bar".
newtype GitHubRepo = GitHubRepo Text

instance FromJSON GitHubRepo where
    parseJSON = withText "GitHubRepo" $ \s -> do
        case T.split (== '/') s of
            [x, y] | not (T.null x || T.null y) -> return (GitHubRepo s)
            _ -> fail "expecting \"user/repo\""

data HackageSecurityConfig = HackageSecurityConfig
  { hscKeyIds :: ![Text]
  , hscKeyThreshold :: !Int
  , hscDownloadPrefix :: !Text
  }
  deriving Show
instance FromJSON (WithJSONWarnings HackageSecurityConfig) where
  parseJSON = withObjectWarnings "HackageSecurityConfig" $ \o' -> do
    hscDownloadPrefix <- o' ..: "download-prefix"
    Object o <- o' ..: "hackage-security"
    hscKeyIds <- o ..: "keyids"
    hscKeyThreshold <- o ..: "key-threshold"
    pure HackageSecurityConfig {..}

class HasPantryConfig env where
  pantryConfigL :: Lens' env PantryConfig

-- | File size in bytes
newtype FileSize = FileSize Word
  deriving (Show, Eq, Ord, Data, Typeable, Generic, Display, Hashable, NFData, Store, PersistField, PersistFieldSql, ToJSON, FromJSON)

data BlobKey = BlobKey !StaticSHA256 !FileSize
  deriving (Eq, Ord, Data, Typeable, Generic)
instance Store BlobKey
instance NFData BlobKey

instance Show BlobKey where
  show = T.unpack . utf8BuilderToText . display
instance Display BlobKey where
  display (BlobKey sha size') = display sha <> "," <> display size'

blobKeyPairs :: BlobKey -> [(Text, Value)]
blobKeyPairs (BlobKey sha size') =
    [ "sha256" .= sha
    , "size" .= size'
    ]

instance ToJSON BlobKey where
  toJSON = object . blobKeyPairs
instance FromJSON BlobKey where
  parseJSON = withObject "BlobKey" $ \o -> BlobKey
    <$> o .: "sha256"
    <*> o .: "size"

newtype PackageNameP = PackageNameP PackageName
instance PersistField PackageNameP where
  toPersistValue (PackageNameP pn) = PersistText $ displayC pn
  fromPersistValue v = do
    str <- fromPersistValue v
    case parsePackageName str of
      Nothing -> Left $ "Invalid package name: " <> T.pack str
      Just pn -> Right $ PackageNameP pn
instance PersistFieldSql PackageNameP where
  sqlType _ = SqlString

newtype VersionP = VersionP Version
instance PersistField VersionP where
  toPersistValue (VersionP v) = PersistText $ displayC v
  fromPersistValue v = do
    str <- fromPersistValue v
    case parseVersion str of
      Nothing -> Left $ "Invalid version number: " <> T.pack str
      Just ver -> Right $ VersionP ver
instance PersistFieldSql VersionP where
  sqlType _ = SqlString

-- | Information on the contents of a cabal file
data CabalFileInfo
  = CFILatest
  -- ^ Take the latest revision of the cabal file available. This
  -- isn't reproducible at all, but the running assumption (not
  -- necessarily true) is that cabal file revisions do not change
  -- semantics of the build.
  | CFIHash !StaticSHA256 !(Maybe FileSize)
  -- ^ Identify by contents of the cabal file itself. Only reason for
  -- @Maybe@ on @FileSize@ is for compatibility with input that
  -- doesn't include the file size.
  | CFIRevision !Revision
  -- ^ Identify by revision number, with 0 being the original and
  -- counting upward. This relies on Hackage providing consistent
  -- versioning. @CFIHash@ should be preferred wherever possible for
  -- reproducibility.
    deriving (Generic, Show, Eq, Ord, Data, Typeable)
instance Store CabalFileInfo
instance NFData CabalFileInfo
instance Hashable CabalFileInfo

instance Display CabalFileInfo where
  display CFILatest = mempty
  display (CFIHash hash' msize) =
    "@sha256:" <> display hash' <> maybe mempty (\i -> "," <> display i) msize
  display (CFIRevision rev) = "@rev:" <> display rev

data PackageIdentifierRevision = PackageIdentifierRevision !PackageName !Version !CabalFileInfo
  deriving (Generic, Eq, Ord, Data, Typeable)
instance NFData PackageIdentifierRevision

instance Show PackageIdentifierRevision where
  show = T.unpack . utf8BuilderToText . display

instance Display PackageIdentifierRevision where
  display (PackageIdentifierRevision name version cfi) =
    displayC name <> "-" <> displayC version <> display cfi

instance ToJSON PackageIdentifierRevision where
  toJSON = toJSON . utf8BuilderToText . display
instance FromJSON PackageIdentifierRevision where
  parseJSON = withText "PackageIdentifierRevision" $ \t ->
    case parsePackageIdentifierRevision t of
      Left e -> fail $ show e
      Right pir -> pure pir

-- | Parse a 'PackageIdentifierRevision'
parsePackageIdentifierRevision :: MonadThrow m => Text -> m PackageIdentifierRevision
parsePackageIdentifierRevision t = maybe (throwM $ PackageIdentifierRevisionParseFail t) pure $ do
  let (identT, cfiT) = T.break (== '@') t
  PackageIdentifier name version <- parsePackageIdentifier $ T.unpack identT
  cfi <-
    case splitColon cfiT of
      Just ("@sha256", shaSizeT) -> do
        let (shaT, sizeT) = T.break (== ',') shaSizeT
        sha <- either (const Nothing) Just $ mkStaticSHA256FromText shaT
        msize <-
          case T.stripPrefix "," sizeT of
            Nothing -> Just Nothing
            Just sizeT' ->
              case decimal sizeT' of
                Right (size', "") -> Just $ Just $ FileSize size'
                _ -> Nothing
        pure $ CFIHash sha msize
      Just ("@rev", revT) ->
        case decimal revT of
          Right (rev, "") -> pure $ CFIRevision $ Revision rev
          _ -> Nothing
      Nothing -> pure CFILatest
      _ -> Nothing
  pure $ PackageIdentifierRevision name version cfi
  where
    splitColon t' =
      let (x, y) = T.break (== ':') t'
       in (x, ) <$> T.stripPrefix ":" y

data Mismatch a = Mismatch
  { mismatchExpected :: !a
  , mismatchActual :: !a
  }

data PantryException
  = PackageIdentifierRevisionParseFail !Text
  | InvalidCabalFile
      !(Either PackageLocationImmutable (Path Abs File))
      !(Maybe Version)
      ![PError]
      ![PWarning]
  | TreeWithoutCabalFile !PackageLocationImmutable
  | TreeWithMultipleCabalFiles !PackageLocationImmutable ![SafeFilePath]
  | MismatchedCabalName !(Path Abs File) !PackageName
  | NoCabalFileFound !(Path Abs Dir)
  | MultipleCabalFilesFound !(Path Abs Dir) ![Path Abs File]
  | InvalidWantedCompiler !Text
  | InvalidSnapshotLocation !(Path Abs Dir) !Text
  | InvalidOverrideCompiler !WantedCompiler !WantedCompiler
  | InvalidFilePathSnapshot !Text
  | InvalidSnapshot !SnapshotLocation !SomeException
  | TreeKeyMismatch
      !PackageLocationImmutable
      !TreeKey -- expected
      !TreeKey -- actual
  | MismatchedPackageMetadata
      !PackageLocationImmutable
      !PackageMetadata
      !BlobKey -- cabal file found
      !PackageIdentifier
  | Non200ResponseStatus !Status
  | InvalidBlobKey !(Mismatch BlobKey)
  | Couldn'tParseSnapshot !SnapshotLocation !String
  | WrongCabalFileName !PackageLocationImmutable !SafeFilePath !PackageName

  deriving Typeable
instance Exception PantryException where
instance Show PantryException where
  show = T.unpack . utf8BuilderToText . display
instance Display PantryException where
  display (PackageIdentifierRevisionParseFail text) =
    "Invalid package identifier (with optional revision): " <>
    display text
  display (InvalidCabalFile loc _mversion errs warnings) =
    "Unable to parse cabal file from package " <>
    either display (fromString . toFilePath) loc <>

    {-

     Not actually needed, the errors will indicate if a newer version exists.
     Also, it seems that this is set to Just the version even if we support it.

    , case mversion of
        Nothing -> ""
        Just version -> "\nRequires newer Cabal file parser version: " ++
                        versionString version
    -}

    "\n\n" <>
    foldMap
      (\(PError pos msg) ->
          "- " <>
          fromString (showPos pos) <>
          ": " <>
          fromString msg <>
          "\n")
      errs <>
    foldMap
      (\(PWarning _ pos msg) ->
          "- " <>
          fromString (showPos pos) <>
          ": " <>
          fromString msg <>
          "\n")
      warnings
  display (TreeWithoutCabalFile pl) = "No cabal file found for " <> display pl
  display (TreeWithMultipleCabalFiles pl sfps) =
    "Multiple cabal files found for " <> display pl <> ": " <>
    fold (intersperse ", " (map display sfps))
  display (MismatchedCabalName fp name) =
    "cabal file path " <>
    fromString (toFilePath fp) <>
    " does not match the package name it defines.\n" <>
    "Please rename the file to: " <>
    displayC name <>
    ".cabal\n" <>
    "For more information, see: https://github.com/commercialhaskell/stack/issues/317"
  display (NoCabalFileFound dir) =
    "Stack looks for packages in the directories configured in\n" <>
    "the 'packages' and 'extra-deps' fields defined in your stack.yaml\n" <>
    "The current entry points to " <>
    fromString (toFilePath dir) <>
    ",\nbut no .cabal or package.yaml file could be found there."
  display (MultipleCabalFilesFound dir files) =
    "Multiple .cabal files found in directory " <>
    fromString (toFilePath dir) <>
    ":\n" <>
    fold (intersperse "\n" (map (\x -> "- " <> fromString (toFilePath (filename x))) files))
  display (InvalidWantedCompiler t) = "Invalid wanted compiler: " <> display t
  display (InvalidSnapshotLocation dir t) =
    "Invalid snapshot location " <>
    displayShow t <>
    " relative to directory " <>
    displayShow (toFilePath dir)
  display (InvalidOverrideCompiler x y) =
    "Specified compiler for a resolver (" <>
    display x <>
    "), but also specified an override compiler (" <>
    display y <>
    ")"
  display (InvalidFilePathSnapshot t) =
    "Specified snapshot as file path with " <>
    displayShow t <>
    ", but not reading from a local file"
  display (InvalidSnapshot loc e) =
    "Exception while reading snapshot from " <>
    display loc <>
    ":\n" <>
    displayShow e
  display (TreeKeyMismatch loc expected actual) =
    "Tree key mismatch when getting " <> display loc <>
    "\nExpected: " <> display expected <>
    "\nActual:   " <> display actual
  display (MismatchedPackageMetadata loc pm foundCabal foundIdent) =
    "Mismatched package metadata for " <> display loc <>
    "\nFound: " <> displayC foundIdent <> " with cabal file " <>
    display foundCabal <> "\nExpected: " <> display pm
  display (Non200ResponseStatus status) =
    "Unexpected non-200 HTTP status code: " <>
    displayShow (statusCode status)
  display (InvalidBlobKey Mismatch{..}) =
    "Invalid blob key found, expected: " <>
    display mismatchExpected <>
    ", actual: " <>
    display mismatchActual
  display (Couldn'tParseSnapshot sl e) =
    "Couldn't parse snapshot from " <> display sl <> ": " <> fromString e
  display (WrongCabalFileName pl sfp name) =
    "Wrong cabal file name for package " <> display pl <>
    "\nCabal file is named " <> display sfp <>
    ", but package name is " <> displayC name
    -- FIXME include the issue link relevant to why we care about this

data FileType = FTNormal | FTExecutable
  deriving Show
instance PersistField FileType where
  toPersistValue FTNormal = PersistInt64 1
  toPersistValue FTExecutable = PersistInt64 2

  fromPersistValue v = do
    i <- fromPersistValue v
    case i :: Int64 of
      1 -> Right FTNormal
      2 -> Right FTExecutable
      _ -> Left $ "Invalid FileType: " <> tshow i
instance PersistFieldSql FileType where
  sqlType _ = SqlInt32

data TreeEntry = TreeEntry !BlobKey !FileType
  deriving Show

newtype SafeFilePath = SafeFilePath Text
  deriving (Show, Eq, Ord, Display)

instance PersistField SafeFilePath where
  toPersistValue = toPersistValue . unSafeFilePath
  fromPersistValue v = do
    t <- fromPersistValue v
    maybe (Left $ "Invalid SafeFilePath: " <> t) Right $ mkSafeFilePath t
instance PersistFieldSql SafeFilePath where
  sqlType _ = SqlString

unSafeFilePath :: SafeFilePath -> Text
unSafeFilePath (SafeFilePath t) = t

mkSafeFilePath :: Text -> Maybe SafeFilePath
mkSafeFilePath t = do
  guard $ not $ "\\" `T.isInfixOf` t
  guard $ not $ "//" `T.isInfixOf` t
  guard $ not $ "\n" `T.isInfixOf` t
  guard $ not $ "\0" `T.isInfixOf` t

  (c, _) <- T.uncons t
  guard $ c /= '/'

  guard $ all (not . T.all (== '.')) $ T.split (== '/') t

  Just $ SafeFilePath t

newtype TreeKey = TreeKey BlobKey
  deriving (Show, Eq, Ord, Generic, Data, Typeable, ToJSON, FromJSON, NFData, Store, Display)

newtype Tree
  = TreeMap (Map SafeFilePath TreeEntry)
  -- FIXME in the future, consider allowing more lax parsing
  -- See: https://www.fpcomplete.com/blog/2018/07/pantry-part-2-trees-keys
  -- TreeTarball !PackageTarball
  deriving Show

renderTree :: Tree -> ByteString
renderTree = BL.toStrict . toLazyByteString . go
  where
    go :: Tree -> Builder
    go (TreeMap m) = "map:" <> Map.foldMapWithKey goEntry m

    goEntry sfp (TreeEntry (BlobKey sha (FileSize size')) ft) =
      netstring (unSafeFilePath sfp) <>
      byteString (staticSHA256ToRaw sha) <>
      netword size' <>
      (case ft of
         FTNormal -> "N"
         FTExecutable -> "X")

netstring :: Text -> Builder
netstring t =
  let bs = encodeUtf8 t
   in netword (fromIntegral (B.length bs)) <> byteString bs

netword :: Word -> Builder
netword w = wordDec w <> ":"

parseTree :: ByteString -> Maybe Tree
parseTree bs1 = do
  tree <- parseTree' bs1
  let bs2 = renderTree tree
  guard $ bs1 == bs2
  Just tree

parseTree' :: ByteString -> Maybe Tree
parseTree' = undefined

    {-
data PackageTarball = PackageTarball
  { ptBlob :: !BlobKey
  -- ^ Contains the tarball itself
  , ptCabal :: !BlobKey
  -- ^ Contains the cabal file contents
  , ptSubdir :: !FilePath
  -- ^ Subdir containing the files we want for this package.
  --
  -- There must be precisely one file with a @.cabal@ file extension
  -- located there. Thanks to Hackage revisions, its contents will be
  -- overwritten by the value of @ptCabal@.
  }
  deriving Show
    -}

-- | This is almost a copy of Cabal's parser for package identifiers,
-- the main difference is in the fact that Stack requires version to be
-- present while Cabal uses "null version" as a defaul value
parsePackageIdentifier :: String -> Maybe PackageIdentifier
parsePackageIdentifier str =
    case [p | (p, s) <- Parse.readP_to_S parser str, all isSpace s] of
        [] -> Nothing
        (p:_) -> Just p
  where
    parser = do
        n <- Distribution.Text.parse
        -- version is a required component of a package identifier for Stack
        v <- Parse.char '-' >> Distribution.Text.parse
        return (PackageIdentifier n v)

parsePackageName :: String -> Maybe PackageName
parsePackageName = Distribution.Text.simpleParse

parseVersion :: String -> Maybe Version
parseVersion = Distribution.Text.simpleParse

parseVersionRange :: String -> Maybe VersionRange
parseVersionRange = Distribution.Text.simpleParse

parseFlagName :: String -> Maybe FlagName
parseFlagName = Distribution.Text.simpleParse

-- | Display Cabal types using 'Distribution.Text.Text'.
displayC :: (IsString str, Distribution.Text.Text a) => a -> str
displayC = fromString . Distribution.Text.display

data OptionalSubdirs
  = OSSubdirs !Text ![Text] -- non-empty list
  | OSPackageMetadata !PackageMetadata
  deriving (Show, Eq, Data, Generic)
instance NFData OptionalSubdirs
instance Store OptionalSubdirs

data PackageMetadata = PackageMetadata
  { pmName :: !(Maybe PackageName)
  , pmVersion :: !(Maybe Version)
  , pmTree :: !(Maybe TreeKey)
  , pmCabal :: !(Maybe BlobKey)
  , pmSubdir :: !Text
  }
  deriving (Show, Eq, Ord, Generic, Data, Typeable)
instance Store PackageMetadata
instance NFData PackageMetadata

instance Display PackageMetadata where
  display pm = fold $ intersperse ", " $ catMaybes
    [ (\name -> "name == " <> displayC name) <$> pmName pm
    , (\version -> "version == " <> displayC version) <$> pmVersion pm
    , (\tree -> "tree == " <> display tree) <$> pmTree pm
    , (\cabal -> "cabal file == " <> display cabal) <$> pmCabal pm
    , if T.null $ pmSubdir pm
        then Nothing
        else Just ("subdir == " <> display (pmSubdir pm))
    ]

osNoInfo :: OptionalSubdirs
osNoInfo = OSPackageMetadata $ PackageMetadata Nothing Nothing Nothing Nothing T.empty

-- | File path relative to the configuration file it was parsed from
newtype RelFilePath = RelFilePath Text
  deriving (Show, ToJSON, FromJSON, Eq, Ord, Generic, Data, Typeable, Store, NFData)

data ArchiveLocation
  = ALUrl !Text
  | ALFilePath !(ResolvedPath File)
  deriving (Show, Eq, Ord, Generic, Data, Typeable)
instance Store ArchiveLocation
instance NFData ArchiveLocation

instance Display ArchiveLocation where
  display (ALUrl url) = display url
  display (ALFilePath resolved) = fromString $ toFilePath $ resolvedAbsolute resolved

data UnresolvedArchiveLocation
  = RALUrl !Text
  | RALFilePath !RelFilePath
  -- ^ relative to the configuration file it came from
  deriving (Show, Eq, Ord, Generic, Data, Typeable)
instance Store UnresolvedArchiveLocation
instance NFData UnresolvedArchiveLocation
instance ToJSON UnresolvedArchiveLocation where
  toJSON (RALUrl url) = object ["url" .= url]
  toJSON (RALFilePath (RelFilePath fp)) = object ["filepath" .= fp]
instance FromJSON UnresolvedArchiveLocation where
  parseJSON v = asObjectUrl v <|> asObjectFilePath v <|> asText v
    where
      asObjectUrl = withObject "ArchiveLocation (URL object)" $ \o ->
        RALUrl <$> ((o .: "url") >>= validateUrl)
      asObjectFilePath = withObject "ArchiveLocation (FilePath object)" $ \o ->
        RALFilePath <$> ((o .: "url") >>= validateFilePath)

      asText = withText "ArchiveLocation (Text)" $ \t ->
        (RALUrl <$> validateUrl t) <|> (RALFilePath <$> validateFilePath t)

      validateUrl t =
        case parseRequest $ T.unpack t of
          Left _ -> fail $ "Could not parse URL: " ++ T.unpack t
          Right _ -> pure t

      validateFilePath t =
        if any (\ext -> ext `T.isSuffixOf` t) (T.words ".zip .tar .tar.gz")
          then pure (RelFilePath t)
          else fail $ "Does not have an archive file extension: " ++ T.unpack t

-- | An unresolved package location /or/ a file path to a directory containing a package.
data UnresolvedPackageLocation
  = UPLImmutable !UnresolvedPackageLocationImmutable
  | UPLMutable !RelFilePath
  deriving Show
instance ToJSON UnresolvedPackageLocation where
  toJSON (UPLImmutable rpl) = toJSON rpl
  toJSON (UPLMutable (RelFilePath fp)) = toJSON fp
instance FromJSON (WithJSONWarnings UnresolvedPackageLocation) where
  parseJSON v =
    (fmap UPLImmutable <$> parseJSON v) <|>
    ((noJSONWarnings . UPLMutable . RelFilePath) <$> parseJSON v)

-- | The unresolved representation of packages allowed in a snapshot
-- specification.
data UnresolvedPackageLocationImmutable
  = UPLIHackage !PackageIdentifierRevision !(Maybe TreeKey)
  | UPLIArchive !UnresolvedArchive !OptionalSubdirs
  | UPLIRepo !Repo !OptionalSubdirs
  deriving (Show, Eq, Data, Generic)
instance Store UnresolvedPackageLocationImmutable
instance NFData UnresolvedPackageLocationImmutable
instance ToJSON UnresolvedPackageLocationImmutable where
  toJSON (UPLIHackage pir mtree) = object $ concat
    [ ["hackage" .= pir]
    , maybe [] (\tree -> ["pantry-tree" .= tree]) mtree
    ]
  toJSON (UPLIArchive (UnresolvedArchive loc msha msize) os) = object $ concat
    [ ["location" .= loc]
    , maybe [] (\sha -> ["sha256" .= sha]) msha
    , maybe [] (\size' -> ["size " .= size']) msize
    , osToPairs os
    ]
  toJSON (UPLIRepo (Repo url commit typ) os) = object $ concat
    [ [ urlKey .= url
      , "commit" .= commit
      ]
    , osToPairs os
    ]
    where
      urlKey =
        case typ of
          RepoGit -> "git"
          RepoHg  -> "hg"

osToPairs :: OptionalSubdirs -> [(Text, Value)]
osToPairs (OSSubdirs x xs) = [("subdirs" .= (x:xs))]
osToPairs (OSPackageMetadata (PackageMetadata mname mversion mtree mcabal subdir)) = concat
  [ maybe [] (\name -> ["name" .= CabalString name]) mname
  , maybe [] (\version -> ["version" .= CabalString version]) mversion
  , maybe [] (\tree -> ["pantry-tree" .= tree]) mtree
  , maybe [] (\cabal -> ["cabal-file" .= cabal]) mcabal
  , if T.null subdir
      then []
      else ["subdir" .= subdir]
  ]

instance FromJSON (WithJSONWarnings UnresolvedPackageLocationImmutable) where
  parseJSON v
      = http v
    <|> hackageText v
    <|> hackageObject v
    <|> repo v
    <|> archiveObject v
    <|> github v
    <|> fail ("Could not parse a UnresolvedPackageLocationImmutable from: " ++ show v)
    where
      http = withText "UnresolvedPackageLocationImmutable.UPLIArchive (Text)" $ \t -> do
        loc <- parseJSON $ String t
        pure $ noJSONWarnings $ UPLIArchive
          UnresolvedArchive
            { uaLocation = loc
            , uaHash = Nothing
            , uaSize = Nothing
            }
          osNoInfo

      hackageText = withText "UnresolvedPackageLocationImmutable.UPLIHackage (Text)" $ \t ->
        case parsePackageIdentifierRevision t of
          Left e -> fail $ show e
          Right pir -> pure $ noJSONWarnings $ UPLIHackage pir Nothing

      hackageObject = withObjectWarnings "UnresolvedPackageLocationImmutable.UPLIHackage" $ \o -> UPLIHackage
        <$> o ..: "hackage"
        <*> o ..:? "pantry-tree"

      optionalSubdirs :: Object -> WarningParser OptionalSubdirs
      optionalSubdirs o =
        -- if subdirs exists, it needs to be valid
        case HM.lookup "subdirs" o of
          Just v' -> do
            subdirs <- lift $ parseJSON v'
            case subdirs of
              [] -> fail "Invalid empty subdirs"
              x:xs -> pure $ OSSubdirs x xs
          Nothing -> OSPackageMetadata <$> (PackageMetadata
            <$> (fmap unCabalString <$> (o ..:? "name"))
            <*> (fmap unCabalString <$> (o ..:? "version"))
            <*> o ..:? "pantry-tree"
            <*> o ..:? "cabal-file"
            <*> o ..:? "subdir" ..!= T.empty)

      repo = withObjectWarnings "UnresolvedPackageLocationImmutable.UPLIRepo" $ \o -> do
        (repoType, repoUrl) <-
          ((RepoGit, ) <$> o ..: "git") <|>
          ((RepoHg, ) <$> o ..: "hg")
        repoCommit <- o ..: "commit"
        UPLIRepo Repo {..} <$> optionalSubdirs o

      archiveObject = withObjectWarnings "UnresolvedPackageLocationImmutable.UPLIArchive" $ \o -> do
        uaLocation <- o ..: "archive" <|> o ..: "location" <|> o ..: "url"
        uaHash <- o ..:? "sha256"
        uaSize <- o ..:? "size"
        UPLIArchive UnresolvedArchive {..} <$> optionalSubdirs o

      github = withObjectWarnings "PLArchive:github" $ \o -> do
        GitHubRepo ghRepo <- o ..: "github"
        commit <- o ..: "commit"
        let uaLocation = RALUrl $ T.concat
              [ "https://github.com/"
              , ghRepo
              , "/archive/"
              , commit
              , ".tar.gz"
              ]
        uaHash <- o ..:? "sha256"
        uaSize <- o ..:? "size"
        UPLIArchive UnresolvedArchive {..} <$> optionalSubdirs o

-- | Convert a 'UnresolvedPackageLocationImmutable' into a list of 'PackageLocation's.
resolvePackageLocationImmutable
  :: MonadIO m
  => Maybe (Path Abs Dir) -- ^ directory to resolve relative paths from, if local
  -> UnresolvedPackageLocationImmutable
  -> m [PackageLocationImmutable]
resolvePackageLocationImmutable _mdir (UPLIHackage pir mtree) = pure [PLIHackage pir mtree]
resolvePackageLocationImmutable mdir (UPLIArchive ra os) = do
  loc <-
    case uaLocation ra of
      RALUrl url -> pure $ ALUrl url
      RALFilePath rel@(RelFilePath t) -> do
        abs' <-
          case mdir of
            Nothing -> error $ "Cannot resolve relative archive path with URL-based config: " ++ show t
            Just dir -> resolveFile dir $ T.unpack t
        pure $ ALFilePath $ ResolvedPath rel abs'
  let archive = Archive
        { archiveLocation = loc
        , archiveHash = uaHash ra
        , archiveSize = uaSize ra
        }
  pure $ map (PLIArchive archive) $ osToPms os
resolvePackageLocationImmutable _mdir (UPLIRepo repo os) = pure $ map (PLIRepo repo) $ osToPms os

osToPms :: OptionalSubdirs -> [PackageMetadata]
osToPms (OSSubdirs x xs) = map (PackageMetadata Nothing Nothing Nothing Nothing) (x:xs)
osToPms (OSPackageMetadata pm) = [pm]

-- | Convert a 'PackageLocationImmutable' into a 'UnresolvedPackageLocationImmutable'.
mkUnresolvedPackageLocationImmutable :: PackageLocationImmutable -> UnresolvedPackageLocationImmutable
mkUnresolvedPackageLocationImmutable (PLIHackage pir mtree) = UPLIHackage pir mtree
mkUnresolvedPackageLocationImmutable (PLIArchive archive pm) =
  UPLIArchive
    UnresolvedArchive
      { uaLocation =
          case archiveLocation archive of
            ALUrl url -> RALUrl url
            ALFilePath resolved -> RALFilePath $ resolvedRelative resolved
      , uaHash = archiveHash archive
      , uaSize = archiveSize archive
      }
    (OSPackageMetadata pm)
mkUnresolvedPackageLocationImmutable (PLIRepo repo pm) = UPLIRepo repo (OSPackageMetadata pm)

-- | Newtype wrapper for easier JSON integration with Cabal types.
newtype CabalString a = CabalString { unCabalString :: a }
  deriving (Show, Eq, Ord, Typeable)

toCabalStringMap :: Map a v -> Map (CabalString a) v
toCabalStringMap = Map.mapKeysMonotonic CabalString -- FIXME why doesn't coerce work?

unCabalStringMap :: Map (CabalString a) v -> Map a v
unCabalStringMap = Map.mapKeysMonotonic unCabalString -- FIXME why doesn't coerce work?

instance Distribution.Text.Text a => ToJSON (CabalString a) where
  toJSON = toJSON . Distribution.Text.display . unCabalString
instance Distribution.Text.Text a => ToJSONKey (CabalString a) where
  toJSONKey = toJSONKeyText $ displayC . unCabalString

instance forall a. IsCabalString a => FromJSON (CabalString a) where
  parseJSON = withText name $ \t ->
    case cabalStringParser $ T.unpack t of
      Nothing -> fail $ "Invalid " ++ name ++ ": " ++ T.unpack t
      Just x -> pure $ CabalString x
    where
      name = cabalStringName (Nothing :: Maybe a)
instance forall a. IsCabalString a => FromJSONKey (CabalString a) where
  fromJSONKey =
    FromJSONKeyTextParser $ \t ->
    case cabalStringParser $ T.unpack t of
      Nothing -> fail $ "Invalid " ++ name ++ ": " ++ T.unpack t
      Just x -> pure $ CabalString x
    where
      name = cabalStringName (Nothing :: Maybe a)

class IsCabalString a where
  cabalStringName :: proxy a -> String
  cabalStringParser :: String -> Maybe a
instance IsCabalString PackageName where
  cabalStringName _ = "package name"
  cabalStringParser = parsePackageName
instance IsCabalString Version where
  cabalStringName _ = "version"
  cabalStringParser = parseVersion
instance IsCabalString VersionRange where
  cabalStringName _ = "version range"
  cabalStringParser = parseVersionRange
instance IsCabalString PackageIdentifier where
  cabalStringName _ = "package identifier"
  cabalStringParser = parsePackageIdentifier
instance IsCabalString FlagName where
  cabalStringName _ = "flag name"
  cabalStringParser = parseFlagName

data HpackExecutable
    = HpackBundled
    | HpackCommand String
    deriving (Show, Read, Eq, Ord)

data WantedCompiler
  = WCGhc !Version
  | WCGhcjs
      !Version -- GHCJS version
      !Version -- GHC version
 deriving (Show, Eq, Ord, Data, Generic)
instance NFData WantedCompiler
instance Store WantedCompiler
instance Display WantedCompiler where
  display (WCGhc vghc) = "ghc-" <> displayC vghc
  display (WCGhcjs vghcjs vghc) = "ghcjs-" <> displayC vghcjs <> "_ghc-" <> displayC vghc
instance ToJSON WantedCompiler where
  toJSON = toJSON . utf8BuilderToText . display
instance FromJSON WantedCompiler where
  parseJSON = withText "WantedCompiler" $ either (fail . show) pure . parseWantedCompiler

parseWantedCompiler :: Text -> Either PantryException WantedCompiler
parseWantedCompiler t0 = maybe (Left $ InvalidWantedCompiler t0) Right $
  case T.stripPrefix "ghcjs-" t0 of
    Just t1 -> parseGhcjs t1
    Nothing -> T.stripPrefix "ghc-" t0 >>= parseGhc
  where
    parseGhcjs = undefined
    parseGhc = fmap WCGhc . parseVersion . T.unpack

data UnresolvedSnapshotLocation
  = USLCompiler !WantedCompiler
  | USLUrl !Text !(Maybe BlobKey)
  | USLFilePath !RelFilePath
  deriving (Show, Eq, Ord, Data, Typeable, Generic)
instance ToJSON UnresolvedSnapshotLocation where
  toJSON (USLCompiler c) = object ["compiler" .= c]
  toJSON (USLUrl t mblob) = object $ concat
    [ ["url" .= t]
    , maybe [] (\blob -> ["blob" .= blob]) mblob
    ]
  toJSON (USLFilePath fp) = object ["filepath" .= fp]
instance FromJSON (WithJSONWarnings UnresolvedSnapshotLocation) where
  parseJSON v = text v <|> obj v
    where
      text = withText "UnresolvedSnapshotLocation (Text)" $ pure . noJSONWarnings . parseSnapshotLocation

      obj = withObjectWarnings "UnresolvedSnapshotLocation (Object)" $ \o ->
        (USLCompiler <$> o ..: "compiler") <|>
        (USLUrl <$> o ..: "url" <*> o ..:? "blob") <|>
        (USLFilePath <$> o ..: "filepath")

resolveSnapshotLocation
  :: UnresolvedSnapshotLocation
  -> Maybe (Path Abs Dir)
  -> Maybe WantedCompiler
  -> IO SnapshotLocation
resolveSnapshotLocation (USLCompiler compiler) _ Nothing = pure $ SLCompiler compiler
resolveSnapshotLocation (USLCompiler compiler1) _ (Just compiler2) = throwIO $ InvalidOverrideCompiler compiler1 compiler2
resolveSnapshotLocation (USLUrl url mblob) _ mcompiler = pure $ SLUrl url mblob mcompiler
resolveSnapshotLocation (USLFilePath (RelFilePath t)) Nothing _mcompiler = throwIO $ InvalidFilePathSnapshot t
resolveSnapshotLocation (USLFilePath rfp@(RelFilePath t)) (Just dir) mcompiler = do
  abs' <- resolveFile dir (T.unpack t) `catchAny` \_ -> throwIO (InvalidSnapshotLocation dir t)
  pure $ SLFilePath
            ResolvedPath
              { resolvedRelative = rfp
              , resolvedAbsolute = abs'
              }
            mcompiler

unresolveSnapshotLocation
  :: SnapshotLocation
  -> (UnresolvedSnapshotLocation, Maybe WantedCompiler)
unresolveSnapshotLocation (SLCompiler compiler) = (USLCompiler compiler, Nothing)
unresolveSnapshotLocation (SLUrl url mblob mcompiler) = (USLUrl url mblob, mcompiler)
unresolveSnapshotLocation (SLFilePath fp mcompiler) = (USLFilePath $ resolvedRelative fp, mcompiler)

instance Display UnresolvedSnapshotLocation where
  display (USLCompiler compiler) = display compiler
  display (USLUrl url Nothing) = display url
  display (USLUrl url (Just blob)) = display url <> " (" <> display blob <> ")"
  display (USLFilePath (RelFilePath t)) = display t

instance Display SnapshotLocation where
  display sl =
    let (usl, mcompiler) = unresolveSnapshotLocation sl
     in display usl <>
        (case mcompiler of
           Nothing -> mempty
           Just compiler -> ", override compiler: " <> display compiler)

parseSnapshotLocation :: Text -> UnresolvedSnapshotLocation
parseSnapshotLocation t0 = fromMaybe parsePath $
  (either (const Nothing) (Just . USLCompiler) (parseWantedCompiler t0)) <|>
  parseLts <|>
  parseNightly <|>
  parseGithub <|>
  parseUrl
  where
    parseLts = do
      t1 <- T.stripPrefix "lts-" t0
      Right (x, t2) <- Just $ decimal t1
      t3 <- T.stripPrefix "." t2
      Right (y, "") <- Just $ decimal t3
      Just $ fst $ ltsSnapshotLocation Nothing x y
    parseNightly = do
      t1 <- T.stripPrefix "nightly-" t0
      date <- readMaybe (T.unpack t1)
      Just $ fst $ nightlySnapshotLocation Nothing date

    parseGithub = do
      t1 <- T.stripPrefix "github:" t0
      let (user, t2) = T.break (== '/') t1
      t3 <- T.stripPrefix "/" t2
      let (repo, t4) = T.break (== ':') t3
      path <- T.stripPrefix ":" t4
      Just $ fst $ githubSnapshotLocation Nothing user repo path

    parseUrl = parseRequest (T.unpack t0) $> USLUrl t0 Nothing

    parsePath = USLFilePath $ RelFilePath t0

githubSnapshotLocation :: Maybe WantedCompiler -> Text -> Text -> Text -> (UnresolvedSnapshotLocation, SnapshotLocation)
githubSnapshotLocation mcompiler user repo path =
  let url = T.concat
        [ "https://raw.githubusercontent.com/"
        , user
        , "/"
        , repo
        , "/master/"
        , path
        ]
   in (USLUrl url Nothing, SLUrl url Nothing mcompiler)

defUser :: Text
defUser = "commercialhaskell"

defRepo :: Text
defRepo = "stackage-snapshots"

ltsSnapshotLocation :: Maybe WantedCompiler -> Int -> Int -> (UnresolvedSnapshotLocation, SnapshotLocation)
ltsSnapshotLocation mcompiler x y =
  githubSnapshotLocation mcompiler defUser defRepo $
  utf8BuilderToText $
  "lts/" <> display x <> "/" <> display y <> ".yaml"

nightlySnapshotLocation :: Maybe WantedCompiler -> Day -> (UnresolvedSnapshotLocation, SnapshotLocation)
nightlySnapshotLocation mcompiler date =
  githubSnapshotLocation mcompiler defUser defRepo $
  utf8BuilderToText $
  "nightly/" <> display year <> "/" <> display month <> "/" <> display day <> ".yaml"
  where
    (year, month, day) = toGregorian date

data SnapshotLocation
  = SLCompiler !WantedCompiler
  | SLUrl !Text !(Maybe BlobKey) !(Maybe WantedCompiler)
  | SLFilePath !(ResolvedPath File) !(Maybe WantedCompiler)
  deriving (Show, Eq, Data, Ord, Generic)
instance Store SnapshotLocation
instance NFData SnapshotLocation

data Snapshot = Snapshot
  { snapshotParent :: !SnapshotLocation
  -- ^ The snapshot to extend from. This is either a specific
  -- compiler, or a @SnapshotLocation@ which gives us more information
  -- (like packages). Ultimately, we'll end up with a
  -- @CompilerVersion@.
  , snapshotName :: !Text
  -- ^ A user-friendly way of referring to this resolver.
  , snapshotLocations :: ![PackageLocationImmutable]
  -- ^ Where to grab all of the packages from.
  , snapshotDropPackages :: !(Set PackageName)
  -- ^ Packages present in the parent which should not be included
  -- here.
  , snapshotFlags :: !(Map PackageName (Map FlagName Bool))
  -- ^ Flag values to override from the defaults
  , snapshotHidden :: !(Map PackageName Bool)
  -- ^ Packages which should be hidden when registering. This will
  -- affect, for example, the import parser in the script
  -- command. We use a 'Map' instead of just a 'Set' to allow
  -- overriding the hidden settings in a parent snapshot.
  , snapshotGhcOptions :: !(Map PackageName [Text])
  -- ^ GHC options per package
  , snapshotGlobalHints :: !(Map PackageName (Maybe Version))
  -- ^ Hints about which packages are available globally. When
  -- actually building code, we trust the package database provided
  -- by GHC itself, since it may be different based on platform or
  -- GHC install. However, when we want to check the compatibility
  -- of a snapshot with some codebase without installing GHC (e.g.,
  -- during stack init), we would use this field.
  }
  deriving (Show, Eq, Data, Generic)
instance Store Snapshot
instance NFData Snapshot
instance ToJSON Snapshot where
  toJSON snap = object $ concat
    [ case snapshotParent snap of
        SLCompiler compiler -> ["compiler" .= compiler]
        SLUrl url mblob mcompiler -> concat
          [ pure $ "resolver" .= concat
              [ ["url" .= url]
              , maybe [] blobKeyPairs mblob
              ]
          , case mcompiler of
              Nothing -> []
              Just compiler -> ["compiler" .= compiler]
          ]
        SLFilePath resolved mcompiler -> concat
          [ pure $ "resolver" .= object ["filepath" .= resolvedRelative resolved]
          , case mcompiler of
              Nothing -> []
              Just compiler -> ["compiler" .= compiler]
          ]
    , ["name" .= snapshotName snap]
    , ["packages" .= map mkUnresolvedPackageLocationImmutable (snapshotLocations snap)]
    , if Set.null (snapshotDropPackages snap) then [] else ["drop-packages" .= Set.map CabalString (snapshotDropPackages snap)]
    , if Map.null (snapshotFlags snap) then [] else ["flags" .= fmap toCabalStringMap (toCabalStringMap (snapshotFlags snap))]
    , if Map.null (snapshotHidden snap) then [] else ["hidden" .= toCabalStringMap (snapshotHidden snap)]
    , if Map.null (snapshotGhcOptions snap) then [] else ["ghc-options" .= toCabalStringMap (snapshotGhcOptions snap)]
    , if Map.null (snapshotGlobalHints snap) then [] else ["global-hints" .= fmap (fmap CabalString) (toCabalStringMap (snapshotGlobalHints snap))]
    ]

parseSnapshot :: Maybe (Path Abs Dir) -> Value -> Parser (WithJSONWarnings (IO Snapshot))
parseSnapshot mdir = withObjectWarnings "Snapshot" $ \o -> do
  mcompiler <- o ..:? "compiler"
  mresolver <- jsonSubWarningsT $ o ..:? "resolver"
  iosnapshotParent <-
    case (mcompiler, mresolver) of
      (Nothing, Nothing) -> fail "Snapshot must have either resolver or compiler"
      (Just compiler, Nothing) -> pure $ pure $ SLCompiler compiler
      (_, Just usl) -> pure $ resolveSnapshotLocation usl mdir mcompiler

  snapshotName <- o ..: "name"
  unresolvedLocs <- jsonSubWarningsT (o ..:? "packages" ..!= [])
  snapshotDropPackages <- Set.map unCabalString <$> (o ..:? "drop-packages" ..!= Set.empty)
  snapshotFlags <- (unCabalStringMap . fmap unCabalStringMap) <$> (o ..:? "flags" ..!= Map.empty)
  snapshotHidden <- unCabalStringMap <$> (o ..:? "hidden" ..!= Map.empty)
  snapshotGhcOptions <- unCabalStringMap <$> (o ..:? "ghc-options" ..!= Map.empty)
  snapshotGlobalHints <- unCabalStringMap . (fmap.fmap) unCabalString <$> (o ..:? "global-hints" ..!= Map.empty)
  pure $ do
    snapshotLocations <- fmap concat $ mapM (resolvePackageLocationImmutable mdir) unresolvedLocs
    snapshotParent <- iosnapshotParent
    pure Snapshot {..}

-- FIXME ORPHANS remove

instance Store PackageIdentifier where
  size =
    VarSize $ \(PackageIdentifier name version) ->
    (case size of
       ConstSize x -> x
       VarSize f -> f name) +
    (case size of
       ConstSize x -> x
       VarSize f -> f version)
  peek = PackageIdentifier <$> peek <*> peek
  poke (PackageIdentifier name version) = poke name *> poke version
instance Store PackageName where
  size =
    VarSize $ \name ->
    case size of
      ConstSize x -> x
      VarSize f -> f (displayC name :: String)
  peek = peek >>= maybe (fail "Invalid package name") pure . parsePackageName
  poke name = poke (displayC name :: String)
instance Store Version where
  size =
    VarSize $ \version ->
    case size of
      ConstSize x -> x
      VarSize f -> f (displayC version :: String)
  peek = peek >>= maybe (fail "Invalid version") pure . parseVersion
  poke version = poke (displayC version :: String)
instance Store FlagName where
  size =
    VarSize $ \fname ->
    case size of
      ConstSize x -> x
      VarSize f -> f (displayC fname :: String)
  peek = peek >>= maybe (fail "Invalid flag name") pure . parseFlagName
  poke fname = poke (displayC fname :: String)
instance Store PackageIdentifierRevision where
  size =
    VarSize $ \(PackageIdentifierRevision name version cfi) ->
    (case size of
       ConstSize x -> x
       VarSize f -> f name) +
    (case size of
       ConstSize x -> x
       VarSize f -> f version) +
    (case size of
       ConstSize x -> x
       VarSize f -> f cfi)
  peek = PackageIdentifierRevision <$> peek <*> peek <*> peek
  poke (PackageIdentifierRevision name version cfi) = poke name *> poke version *> poke cfi

deriving instance Data Abs
deriving instance Data Dir
deriving instance Data File
deriving instance (Data a, Data t) => Data (Path a t)

deriving instance Generic Abs
deriving instance Generic Dir
deriving instance Generic File
deriving instance (Generic a, Generic t) => Generic (Path a t)

instance Store Abs
instance Store Dir
instance Store File
instance (Generic a, Generic t, Store a, Store t) => Store (Path a t)