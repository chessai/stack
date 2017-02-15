{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Stack.Script
    ( scriptCmd
    ) where

import           Control.Exception          (assert)
import           Control.Exception.Safe     (throwM)
import           Control.Monad              (unless, forM)
import           Control.Monad.IO.Class     (liftIO)
import           Control.Monad.Logger
import           Data.ByteString            (ByteString)
import qualified Data.ByteString.Char8      as S8
import qualified Data.Conduit.List          as CL
import           Data.Foldable              (fold)
import           Data.List.Split            (splitWhen)
import           Data.Map                   (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromMaybe, mapMaybe)
import           Data.Monoid
import           Data.Set                   (Set)
import qualified Data.Set                   as Set
import qualified Data.Text                  as T
import           Data.Text.Encoding         (encodeUtf8)
import           Path
import           Path.IO
import qualified Stack.Build
import           Stack.BuildPlan            (loadBuildPlan)
import           Stack.Exec
import           Stack.GhcPkg               (ghcPkgExeName)
import           Stack.Options.ScriptParser
import           Stack.Runners
import           Stack.Types.BuildPlan
import           Stack.Types.Compiler
import           Stack.Types.Config
import           Stack.Types.PackageName
import           Stack.Types.Resolver
import           Stack.Types.StackT
import           System.FilePath            (dropExtension, replaceExtension)
import           System.Process.Read

-- | Run a Stack Script
scriptCmd :: ScriptOpts -> GlobalOpts -> IO ()
scriptCmd opts go' = do
    let go = go'
            { globalConfigMonoid = (globalConfigMonoid go')
                { configMonoidInstallGHC = First $ Just True
                }
            , globalStackYaml = SYLNoConfig
            }
    withBuildConfigAndLock go $ \lk -> do
        -- Some warnings in case the user somehow tries to set a
        -- stack.yaml location. Note that in this functions we use
        -- logError instead of logWarn because, when using the
        -- interpreter mode, only error messages are shown. See:
        -- https://github.com/commercialhaskell/stack/issues/3007
        case globalStackYaml go' of
          SYLOverride fp -> $logError $ T.pack
            $ "Ignoring override stack.yaml file for script command: " ++ fp
          SYLDefault -> return ()
          SYLNoConfig -> assert False (return ())

        config <- view configL
        menv <- liftIO $ configEnvOverride config defaultEnvSettings
        wc <- view $ actualCompilerVersionL.whichCompilerL

        (targetsSet, coresSet) <-
            case soPackages opts of
                [] -> do
                    $logError "No packages provided, using experimental import parser"
                    getPackagesFromImports (globalResolver go) (soFile opts)
                packages -> do
                    let targets = concatMap wordsComma packages
                    targets' <- mapM parsePackageNameFromString targets
                    return (Set.fromList targets', Set.empty)

        unless (Set.null targetsSet) $ do
            -- Optimization: use the relatively cheap ghc-pkg list
            -- --simple-output to check which packages are installed
            -- already. If all needed packages are available, we can
            -- skip the (rather expensive) build call below.
            bss <- sinkProcessStdout
                Nothing menv (ghcPkgExeName wc)
                ["list", "--simple-output"] CL.consume -- FIXME use the package info from envConfigPackages, or is that crazy?
            let installed = Set.fromList
                          $ map toPackageName
                          $ words
                          $ S8.unpack
                          $ S8.concat bss
            if Set.null $ Set.difference (Set.map packageNameString targetsSet) installed
                then $logDebug "All packages already installed"
                else do
                    $logDebug "Missing packages, performing installation"
                    Stack.Build.build (const $ return ()) lk defaultBuildOptsCLI
                        { boptsCLITargets = map packageNameText $ Set.toList targetsSet
                        }

        let ghcArgs = concat
                [ ["-hide-all-packages"]
                , map (\x -> "-package" ++ x)
                    $ Set.toList
                    $ Set.insert "base"
                    $ Set.map packageNameString (Set.union targetsSet coresSet)
                , case soCompile opts of
                    SEInterpret -> []
                    SECompile -> []
                    SEOptimize -> ["-O2"]
                ]
        munlockFile lk -- Unlock before transferring control away.
        case soCompile opts of
          SEInterpret -> exec menv ("run" ++ compilerExeName wc)
                (ghcArgs ++ soFile opts : soArgs opts)
          _ -> do
            file <- resolveFile' $ soFile opts
            let dir = parent file
            -- use sinkProcessStdout to ensure a ProcessFailed
            -- exception is generated for better error messages
            sinkProcessStdout
              (Just dir)
              menv
              (compilerExeName wc)
              (ghcArgs ++ [soFile opts])
              CL.sinkNull
            exec menv (toExeName $ toFilePath file) (soArgs opts)
  where
    toPackageName = reverse . drop 1 . dropWhile (/= '-') . reverse

    -- Like words, but splits on both commas and spaces
    wordsComma = splitWhen (\c -> c == ' ' || c == ',')

    toExeName fp =
      if isWindows
        then replaceExtension fp "exe"
        else dropExtension fp

isWindows :: Bool
#ifdef WINDOWS
isWindows = True
#else
isWindows = False
#endif

-- | Returns packages that need to be installed, and all of the core
-- packages. Reason for the core packages:

-- Ideally we'd have the list of modules per core package listed in
-- the build plan, but that doesn't exist yet. Next best would be to
-- list the modules available at runtime, but that gets tricky with when we install GHC. Instead, we'll just list all core packages
getPackagesFromImports :: Maybe AbstractResolver
                       -> FilePath
                       -> StackT EnvConfig IO (Set PackageName, Set PackageName)
getPackagesFromImports Nothing _ = throwM NoResolverWhenUsingNoLocalConfig
getPackagesFromImports (Just (ARResolver (ResolverSnapshot name))) scriptFP = do
    (pns1, mns) <- liftIO $ parseImports <$> S8.readFile scriptFP
    mi <- loadModuleInfo name
    pns2 <-
        if Set.null mns
            then return Set.empty
            else do
                pns <- forM (Set.toList mns) $ \mn ->
                    case Map.lookup mn $ miModules mi of
                        Just pns ->
                            case Set.toList pns of
                                [] -> assert False $ return Set.empty
                                [pn] -> return $ Set.singleton pn
                                pns' -> error $ concat
                                    [ "Module "
                                    , S8.unpack $ unModuleName mn
                                    , " appears in multiple packages: "
                                    , unwords $ map packageNameString pns'
                                    ]
                        Nothing -> return Set.empty
                return $ Set.unions pns
    return (Set.union pns1 pns2, modifyForWindows $ miCorePackages mi)
  where
    modifyForWindows
        | isWindows = Set.insert $(mkPackageName "Win32") . Set.delete $(mkPackageName "unix")
        | otherwise = id

getPackagesFromImports (Just (ARResolver (ResolverCompiler _))) _ = return (Set.empty, Set.empty)
getPackagesFromImports (Just aresolver) _ = throwM $ InvalidResolverForNoLocalConfig $ show aresolver

newtype ModuleName = ModuleName { unModuleName :: ByteString }
  deriving (Show, Eq, Ord)

data ModuleInfo = ModuleInfo
    { miCorePackages :: !(Set PackageName)
    , miModules      :: !(Map ModuleName (Set PackageName))
    }

toModuleInfo :: BuildPlan -> ModuleInfo
toModuleInfo bp = ModuleInfo
    { miCorePackages = Map.keysSet $ siCorePackages $ bpSystemInfo bp
    , miModules =
              Map.unionsWith Set.union
            $ map ((\(pn, mns) ->
                    Map.fromList
                  $ map (\mn -> (ModuleName $ encodeUtf8 mn, Set.singleton pn))
                  $ Set.toList mns) . fmap (sdModules . ppDesc))
            $ filter (\(_, pp) -> not $ pcHide $ ppConstraints pp)
            $ Map.toList (bpPackages bp)
    }

loadModuleInfo :: SnapName -> StackT EnvConfig IO ModuleInfo
loadModuleInfo name = toModuleInfo <$> loadBuildPlan name -- FIXME caching

parseImports :: ByteString -> (Set PackageName, Set ModuleName)
parseImports =
    fold . mapMaybe parseLine . S8.lines
  where
    stripPrefix x y
      | x `S8.isPrefixOf` y = Just $ S8.drop (S8.length x) y
      | otherwise = Nothing

    parseLine bs0 = do
        bs1 <- stripPrefix "import " bs0
        let bs2 = S8.dropWhile (== ' ') bs1
            bs3 = fromMaybe bs2 $ stripPrefix "qualified " bs2
        case stripPrefix "\"" bs3 of
            Just bs4 -> do
                pn <- parsePackageNameFromString $ S8.unpack $ S8.takeWhile (/= '"') bs4
                Just (Set.singleton pn, Set.empty)
            Nothing -> Just
                ( Set.empty
                , Set.singleton
                    $ ModuleName
                    $ S8.takeWhile (\c -> c /= ' ' && c /= '(') bs3
                )
