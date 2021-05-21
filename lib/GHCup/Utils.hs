{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE ViewPatterns          #-}

{-|
Module      : GHCup.Utils
Description : GHCup domain specific utilities
Copyright   : (c) Julian Ospald, 2020
License     : LGPL-3.0
Maintainer  : hasufell@hasufell.de
Stability   : experimental
Portability : portable

This module contains GHCup helpers specific to
installation and introspection of files/versions etc.
-}
module GHCup.Utils
  ( module GHCup.Utils.Dirs
  , module GHCup.Utils
  )
where


import           GHCup.Errors
import           GHCup.Types
import           GHCup.Types.Optics
import           GHCup.Types.JSON               ( )
import           GHCup.Utils.Dirs
import           GHCup.Utils.File
import           GHCup.Utils.MegaParsec
import           GHCup.Utils.Prelude
import           GHCup.Utils.String.QQ

#if !defined(TAR)
import           Codec.Archive           hiding ( Directory )
#endif
import           Codec.Archive.Zip
import           Control.Applicative
import           Control.Exception.Safe
import           Control.Monad
#if !MIN_VERSION_base(4,13,0)
import           Control.Monad.Fail             ( MonadFail )
#endif
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.ByteString                ( ByteString )
import           Data.Either
import           Data.Foldable
import           Data.List
import           Data.List.Extra
import           Data.List.NonEmpty             ( NonEmpty( (:|) ))
import           Data.Maybe
import           Data.String.Interpolate
import           Data.Text                      ( Text )
import           Data.Versions
import           Data.Word8
import           GHC.IO.Exception
import           Haskus.Utils.Variant.Excepts
import           Optics
import           Safe
import           System.Directory      hiding   ( findFiles )
import           System.FilePath
import           System.IO.Error
import           System.IO.Unsafe               ( unsafeInterleaveIO )
import           Text.Regex.Posix
import           URI.ByteString

#if defined(TAR)
import qualified Codec.Archive.Tar             as Tar
#endif
import qualified Codec.Compression.BZip        as BZip
import qualified Codec.Compression.GZip        as GZip
import qualified Codec.Compression.Lzma        as Lzma
import qualified Data.ByteString               as B
import qualified Data.ByteString.Lazy          as BL
import qualified Data.Map.Strict               as Map
import qualified Data.Text                     as T
import qualified Data.Text.Encoding            as E
import qualified Text.Megaparsec               as MP





    ------------------------
    --[ Symlink handling ]--
    ------------------------


-- | The symlink destination of a ghc tool.
ghcLinkDestination :: (MonadReader AppState m, MonadThrow m, MonadIO m)
                   => FilePath -- ^ the tool, such as 'ghc', 'haddock' etc.
                   -> GHCTargetVersion
                   -> m FilePath
ghcLinkDestination tool ver = do
  AppState { dirs = Dirs {..} } <- ask
  ghcd <- ghcupGHCDir ver
  pure (relativeSymlink binDir (ghcd </> "bin" </> tool))


-- | Removes the minor GHC symlinks, e.g. ghc-8.6.5.
rmMinorSymlinks :: ( MonadReader AppState m
                   , MonadIO m
                   , MonadLogger m
                   , MonadThrow m
                   , MonadFail m
                   , MonadReader AppState m
                   )
                => GHCTargetVersion
                -> Excepts '[NotInstalled] m ()
rmMinorSymlinks tv@GHCTargetVersion{..} = do
  AppState { dirs = Dirs {..} } <- lift ask

  files                         <- liftE $ ghcToolFiles tv
  forM_ files $ \f -> do
    let f_xyz = f <> "-" <> T.unpack (prettyVer _tvVersion)
    let fullF = binDir </> f_xyz
    lift $ $(logDebug) [i|rm -f #{fullF}|]
    liftIO $ hideError doesNotExistErrorType $ removeFile fullF


-- | Removes the set ghc version for the given target, if any.
rmPlain :: ( MonadReader AppState m
           , MonadLogger m
           , MonadThrow m
           , MonadFail m
           , MonadIO m
           )
        => Maybe Text -- ^ target
        -> Excepts '[NotInstalled] m ()
rmPlain target = do
  AppState { dirs = Dirs {..} } <- lift ask
  mtv                           <- lift $ ghcSet target
  forM_ mtv $ \tv -> do
    files <- liftE $ ghcToolFiles tv
    forM_ files $ \f -> do
      let fullF = binDir </> f
      lift $ $(logDebug) [i|rm -f #{fullF}|]
      liftIO $ hideError doesNotExistErrorType $ removeFile fullF
    -- old ghcup
    let hdc_file = binDir </> "haddock-ghc"
    lift $ $(logDebug) [i|rm -f #{hdc_file}|]
    liftIO $ hideError doesNotExistErrorType $ removeFile hdc_file


-- | Remove the major GHC symlink, e.g. ghc-8.6.
rmMajorSymlinks :: ( MonadReader AppState m
                   , MonadIO m
                   , MonadLogger m
                   , MonadThrow m
                   , MonadFail m
                   , MonadReader AppState m
                   )
                => GHCTargetVersion
                -> Excepts '[NotInstalled] m ()
rmMajorSymlinks tv@GHCTargetVersion{..} = do
  AppState { dirs = Dirs {..} } <- lift ask
  (mj, mi) <- getMajorMinorV _tvVersion
  let v' = intToText mj <> "." <> intToText mi

  files                         <- liftE $ ghcToolFiles tv
  forM_ files $ \f -> do
    let f_xyz = f <> "-" <> T.unpack v'
    let fullF = binDir </> f_xyz
    lift $ $(logDebug) [i|rm -f #{fullF}|]
    liftIO $ hideError doesNotExistErrorType $ removeFile fullF




    -----------------------------------
    --[ Set/Installed introspection ]--
    -----------------------------------


-- | Whether the given GHC versin is installed.
ghcInstalled :: (MonadIO m, MonadReader AppState m, MonadThrow m) => GHCTargetVersion -> m Bool
ghcInstalled ver = do
  ghcdir <- ghcupGHCDir ver
  liftIO $ doesDirectoryExist ghcdir


-- | Whether the given GHC version is installed from source.
ghcSrcInstalled :: (MonadIO m, MonadReader AppState m, MonadThrow m) => GHCTargetVersion -> m Bool
ghcSrcInstalled ver = do
  ghcdir <- ghcupGHCDir ver
  liftIO $ doesFileExist (ghcdir </> ghcUpSrcBuiltFile)


-- | Whether the given GHC version is set as the current.
ghcSet :: (MonadReader AppState m, MonadThrow m, MonadIO m)
       => Maybe Text   -- ^ the target of the GHC version, if any
                       --  (e.g. armv7-unknown-linux-gnueabihf)
       -> m (Maybe GHCTargetVersion)
ghcSet mtarget = do
  AppState {dirs = Dirs {..}} <- ask
  let ghc = maybe "ghc" (\t -> T.unpack t <> "-ghc") mtarget
  let ghcBin = binDir </> ghc

  -- link destination is of the form ../ghc/<ver>/bin/ghc
  -- for old ghcup, it is ../ghc/<ver>/bin/ghc-<ver>
  liftIO $ handleIO' NoSuchThing (\_ -> pure Nothing) $ do
    link <- liftIO $ getSymbolicLinkTarget ghcBin
    Just <$> ghcLinkVersion link

ghcLinkVersion :: MonadThrow m => FilePath -> m GHCTargetVersion
ghcLinkVersion (T.pack -> t) = throwEither $ MP.parse parser "ghcLinkVersion" t
 where
  parser =
      (do
         _    <- parseUntil1 ghcSubPath
         _    <- ghcSubPath
         r    <- parseUntil1 pathSep
         rest <- MP.getInput
         MP.setInput r
         x <- ghcTargetVerP
         MP.setInput rest
         pure x
       )
      <* pathSep
      <* MP.takeRest
      <* MP.eof
  ghcSubPath = pathSep <* MP.chunk "ghc" *> pathSep

-- | Get all installed GHCs by reading ~/.ghcup/ghc/<dir>.
-- If a dir cannot be parsed, returns left.
getInstalledGHCs :: (MonadReader AppState m, MonadIO m) => m [Either FilePath GHCTargetVersion]
getInstalledGHCs = do
  ghcdir <- ghcupGHCBaseDir
  fs     <- liftIO $ hideErrorDef [NoSuchThing] [] $ listDirectory ghcdir
  forM fs $ \f -> case parseGHCupGHCDir f of
    Right r -> pure $ Right r
    Left  _ -> pure $ Left f


-- | Get all installed cabals, by matching on @~\/.ghcup\/bin/cabal-*@.
getInstalledCabals :: (MonadLogger m, MonadReader AppState m, MonadIO m, MonadCatch m)
                   => m [Either FilePath Version]
getInstalledCabals = do
  cs <- cabalSet -- for legacy cabal
  getInstalledCabals' cs


getInstalledCabals' :: (MonadLogger m, MonadReader AppState m, MonadIO m, MonadCatch m)
                   => Maybe Version
                   -> m [Either FilePath Version]
getInstalledCabals' cs = do
  AppState {dirs = Dirs {..}} <- ask
  bins   <- liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts compExtended execBlank ([s|^cabal-.*$|] :: ByteString))
  vs <- forM bins $ \f -> case fmap (version . T.pack . dropSuffix exeExt) . stripPrefix "cabal-" $ f of
    Just (Right r) -> pure $ Right r
    Just (Left  _) -> pure $ Left f
    Nothing        -> pure $ Left f
  pure $ maybe vs (\x -> nub $ Right x:vs) cs


-- | Whether the given cabal version is installed.
cabalInstalled :: (MonadLogger m, MonadIO m, MonadReader AppState m, MonadCatch m) => Version -> m Bool
cabalInstalled ver = do
  vers <- fmap rights getInstalledCabals
  pure $ elem ver vers


-- Return the currently set cabal version, if any.
cabalSet :: (MonadLogger m, MonadReader AppState m, MonadIO m, MonadThrow m, MonadCatch m) => m (Maybe Version)
cabalSet = do
  AppState {dirs = Dirs {..}} <- ask
  let cabalbin = binDir </> "cabal"
  b        <- handleIO (\_ -> pure False) $ liftIO $ pathIsSymbolicLink cabalbin
  if
    | b -> do
      handleIO' NoSuchThing (\_ -> pure Nothing) $ do
        broken <- liftIO $ isBrokenSymlink cabalbin
        if broken
          then do
            $(logWarn) [i|Symlink #{cabalbin} is broken.|]
            pure Nothing
          else do
            link <- liftIO $ getSymbolicLinkTarget cabalbin
            case linkVersion link of
              Right v -> pure $ Just v
              Left err -> do
                $(logWarn) [i|Failed to parse cabal symlink target with: "#{err}". The symlink #{cabalbin} needs to point to valid cabal binary, such as 'cabal-3.4.0.0'.|]
                pure Nothing
    | otherwise -> do -- legacy behavior
      mc <- liftIO $ handleIO (\_ -> pure Nothing) $ fmap Just $ executeOut
        cabalbin
        ["--numeric-version"]
        Nothing
      fmap join $ forM mc $ \c -> if
        | not (BL.null (_stdOut c)), _exitCode c == ExitSuccess -> do
          let reportedVer = fst . B.spanEnd (== _lf) . BL.toStrict . _stdOut $ c
          case version $ decUTF8Safe reportedVer of
            Left  e -> throwM e
            Right r -> pure $ Just r
        | otherwise -> pure Nothing
 where
  -- We try to be extra permissive with link destination parsing,
  -- because of:
  --   https://gitlab.haskell.org/haskell/ghcup-hs/-/issues/119
  linkVersion :: MonadThrow m => FilePath -> m Version
  linkVersion = throwEither . MP.parse parser "" . T.pack . dropSuffix exeExt

  parser
    =   MP.try (stripAbsolutePath *> cabalParse)
    <|> MP.try (stripRelativePath *> cabalParse)
    <|> cabalParse
  -- parses the version of "cabal-3.2.0.0" -> "3.2.0.0"
  cabalParse = MP.chunk "cabal-" *> version'
  -- parses any path component ending with path separator,
  -- e.g. "foo/"
  stripPathComponet = parseUntil1 pathSep *> pathSep
  -- parses an absolute path up until the last path separator,
  -- e.g. "/bar/baz/foo" -> "/bar/baz/", leaving "foo"
  stripAbsolutePath = pathSep *> MP.many (MP.try stripPathComponet)
  -- parses a relative path up until the last path separator,
  -- e.g. "bar/baz/foo" -> "bar/baz/", leaving "foo"
  stripRelativePath = MP.many (MP.try stripPathComponet)



-- | Get all installed hls, by matching on
-- @~\/.ghcup\/bin/haskell-language-server-wrapper-<\hlsver\>@.
getInstalledHLSs :: (MonadReader AppState m, MonadIO m, MonadCatch m)
                 => m [Either FilePath Version]
getInstalledHLSs = do
  AppState { dirs = Dirs {..} } <- ask
  bins                          <- liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts compExtended
                   execBlank
                   ([s|^haskell-language-server-wrapper-.*$|] :: ByteString)
    )
  forM bins $ \f ->
    case
          fmap (version . T.pack . dropSuffix exeExt) . stripPrefix "haskell-language-server-wrapper-" $ f
      of
        Just (Right r) -> pure $ Right r
        Just (Left  _) -> pure $ Left f
        Nothing        -> pure $ Left f

-- | Get all installed stacks, by matching on
-- @~\/.ghcup\/bin/stack-<\stackver\>@.
getInstalledStacks :: (MonadReader AppState m, MonadIO m, MonadCatch m)
                   => m [Either FilePath Version]
getInstalledStacks = do
  AppState { dirs = Dirs {..} } <- ask
  bins                          <- liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts compExtended
                   execBlank
                   ([s|^stack-.*$|] :: ByteString)
    )
  forM bins $ \f ->
    case
          fmap (version . T.pack . dropSuffix exeExt) . stripPrefix "stack-" $ f
      of
        Just (Right r) -> pure $ Right r
        Just (Left  _) -> pure $ Left f
        Nothing        -> pure $ Left f

-- Return the currently set stack version, if any.
-- TODO: there's a lot of code duplication here :>
stackSet :: (MonadReader AppState m, MonadIO m, MonadThrow m, MonadCatch m) => m (Maybe Version)
stackSet = do
  AppState {dirs = Dirs {..}} <- ask
  let stackBin = binDir </> "stack"

  liftIO $ handleIO' NoSuchThing (\_ -> pure Nothing) $ do
    broken <- isBrokenSymlink stackBin
    if broken
      then pure Nothing
      else do
        link <- liftIO $ getSymbolicLinkTarget stackBin
        Just <$> linkVersion link
 where
  linkVersion :: MonadThrow m => FilePath -> m Version
  linkVersion = throwEither . MP.parse parser "" . T.pack . dropSuffix exeExt
   where
    parser =
      MP.chunk "stack-" *> version'

-- | Whether the given Stack version is installed.
stackInstalled :: (MonadIO m, MonadReader AppState m, MonadCatch m) => Version -> m Bool
stackInstalled ver = do
  vers <- fmap rights getInstalledStacks
  pure $ elem ver vers

-- | Whether the given HLS version is installed.
hlsInstalled :: (MonadIO m, MonadReader AppState m, MonadCatch m) => Version -> m Bool
hlsInstalled ver = do
  vers <- fmap rights getInstalledHLSs
  pure $ elem ver vers



-- Return the currently set hls version, if any.
hlsSet :: (MonadReader AppState m, MonadIO m, MonadThrow m, MonadCatch m) => m (Maybe Version)
hlsSet = do
  AppState {dirs = Dirs {..}} <- ask
  let hlsBin = binDir </> "haskell-language-server-wrapper"

  liftIO $ handleIO' NoSuchThing (\_ -> pure Nothing) $ do
    broken <- isBrokenSymlink hlsBin
    if broken
      then pure Nothing
      else do
        link <- liftIO $ getSymbolicLinkTarget hlsBin
        Just <$> linkVersion link
 where
  linkVersion :: MonadThrow m => FilePath -> m Version
  linkVersion = throwEither . MP.parse parser "" . T.pack . dropSuffix exeExt
   where
    parser =
      MP.chunk "haskell-language-server-wrapper-" *> version'


-- | Return the GHC versions the currently selected HLS supports.
hlsGHCVersions :: ( MonadReader AppState m
                  , MonadIO m
                  , MonadThrow m
                  , MonadCatch m
                  )
               => m [Version]
hlsGHCVersions = do
  h                             <- hlsSet
  vers                          <- forM h $ \h' -> do
    bins <- hlsServerBinaries h'
    pure $ fmap
      (version
        . T.pack
        . fromJust
        . stripPrefix "haskell-language-server-"
        . head
        . splitOn "~"
        )
      bins
  pure . rights . concat . maybeToList $ vers


-- | Get all server binaries for an hls version, if any.
hlsServerBinaries :: (MonadReader AppState m, MonadIO m)
                  => Version
                  -> m [FilePath]
hlsServerBinaries ver = do
  AppState { dirs = Dirs {..} } <- ask
  liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts
      compExtended
      execBlank
      ([s|^haskell-language-server-.*~|] <> escapeVerRex ver <> E.encodeUtf8 (T.pack exeExt) <> [s|$|] :: ByteString
      )
    )


-- | Get the wrapper binary for an hls version, if any.
hlsWrapperBinary :: (MonadReader AppState m, MonadThrow m, MonadIO m)
                 => Version
                 -> m (Maybe FilePath)
hlsWrapperBinary ver = do
  AppState { dirs = Dirs {..} } <- ask
  wrapper                       <- liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts
      compExtended
      execBlank
      ([s|^haskell-language-server-wrapper-|] <> escapeVerRex ver <> E.encodeUtf8 (T.pack exeExt) <> [s|$|] :: ByteString
      )
    )
  case wrapper of
    []  -> pure Nothing
    [x] -> pure $ Just x
    _   -> throwM $ UnexpectedListLength
      "There were multiple hls wrapper binaries for a single version"


-- | Get all binaries for an hls version, if any.
hlsAllBinaries :: (MonadReader AppState m, MonadIO m, MonadThrow m) => Version -> m [FilePath]
hlsAllBinaries ver = do
  hls     <- hlsServerBinaries ver
  wrapper <- hlsWrapperBinary ver
  pure (maybeToList wrapper ++ hls)


-- | Get the active symlinks for hls.
hlsSymlinks :: (MonadReader AppState m, MonadIO m, MonadCatch m) => m [FilePath]
hlsSymlinks = do
  AppState { dirs = Dirs {..} } <- ask
  oldSyms                       <- liftIO $ handleIO (\_ -> pure []) $ findFiles
    binDir
    (makeRegexOpts compExtended
                   execBlank
                   ([s|^haskell-language-server-.*$|] :: ByteString)
    )
  filterM
    ( liftIO
    . pathIsSymbolicLink
    . (binDir </>)
    )
    oldSyms



    -----------------------------------------
    --[ Major version introspection (X.Y) ]--
    -----------------------------------------


-- | Extract (major, minor) from any version.
getMajorMinorV :: MonadThrow m => Version -> m (Int, Int)
getMajorMinorV Version {..} = case _vChunks of
  ((Digits x :| []) :| ((Digits y :| []):_)) -> pure (fromIntegral x, fromIntegral y)
  _ -> throwM $ ParseError "Could not parse X.Y from version"


matchMajor :: Version -> Int -> Int -> Bool
matchMajor v' major' minor' = case getMajorMinorV v' of
  Just (x, y) -> x == major' && y == minor'
  Nothing     -> False


-- | Get the latest installed full GHC version that satisfies X.Y.
-- This reads `ghcupGHCBaseDir`.
getGHCForMajor :: (MonadReader AppState m, MonadIO m, MonadThrow m)
               => Int        -- ^ major version component
               -> Int        -- ^ minor version component
               -> Maybe Text -- ^ the target triple
               -> m (Maybe GHCTargetVersion)
getGHCForMajor major' minor' mt = do
  ghcs <- rights <$> getInstalledGHCs

  pure
    . lastMay
    . sortBy (\x y -> compare (_tvVersion x) (_tvVersion y))
    . filter
        (\GHCTargetVersion {..} ->
          _tvTarget == mt && matchMajor _tvVersion major' minor'
        )
    $ ghcs


-- | Get the latest available ghc for X.Y major version.
getLatestGHCFor :: Int -- ^ major version component
                -> Int -- ^ minor version component
                -> GHCupDownloads
                -> Maybe (Version, VersionInfo)
getLatestGHCFor major' minor' dls =
  preview (ix GHC % to Map.toDescList) dls >>= lastMay . filter (\(v, _) -> matchMajor v major' minor')




    -----------------
    --[ Unpacking ]--
    -----------------



-- | Unpack an archive to a temporary directory and return that path.
unpackToDir :: (MonadLogger m, MonadIO m, MonadThrow m)
            => FilePath       -- ^ destination dir
            -> FilePath       -- ^ archive path
            -> Excepts '[UnknownArchive
#if !defined(TAR)
                        , ArchiveResult
#endif
                        ] m ()
unpackToDir dfp av = do
  let fn = takeFileName av
  lift $ $(logInfo) [i|Unpacking: #{fn} to #{dfp}|]

#if defined(TAR)
  let untar :: MonadIO m => BL.ByteString -> Excepts '[] m ()
      untar = liftIO . Tar.unpack dfp . Tar.read

      rf :: MonadIO m => FilePath -> Excepts '[] m BL.ByteString
      rf = liftIO . BL.readFile
#else
  let untar :: MonadIO m => BL.ByteString -> Excepts '[ArchiveResult] m ()
      untar = lEM . liftIO . runArchiveM . unpackToDirLazy dfp

      rf :: MonadIO m => FilePath -> Excepts '[ArchiveResult] m BL.ByteString
      rf = liftIO . BL.readFile
#endif

  -- extract, depending on file extension
  if
    | ".tar.gz" `isSuffixOf` fn -> liftE
      (untar . GZip.decompress =<< rf av)
    | ".tar.xz" `isSuffixOf` fn -> do
      filecontents <- liftE $ rf av
      let decompressed = Lzma.decompress filecontents
      liftE $ untar decompressed
    | ".tar.bz2" `isSuffixOf` fn ->
      liftE (untar . BZip.decompress =<< rf av)
    | ".tar" `isSuffixOf` fn -> liftE (untar =<< rf av)
    | ".zip" `isSuffixOf` fn ->
      withArchive av (unpackInto dfp)
    | otherwise -> throwE $ UnknownArchive fn


getArchiveFiles :: (MonadLogger m, MonadIO m, MonadThrow m)
                => FilePath       -- ^ archive path
                -> Excepts '[UnknownArchive
#if defined(TAR)
                            , Tar.FormatError
#else
                            , ArchiveResult
#endif
                            ] m [FilePath]
getArchiveFiles av = do
  let fn = takeFileName av

#if defined(TAR)
  let entries :: Monad m => BL.ByteString -> Excepts '[Tar.FormatError] m [FilePath]
      entries =
          lE @Tar.FormatError
          . Tar.foldEntries
            (\e x -> fmap (Tar.entryPath e :) x)
            (Right [])
            (\e -> Left e)
          . Tar.read

      rf :: MonadIO m => FilePath -> Excepts '[Tar.FormatError] m BL.ByteString
      rf = liftIO . BL.readFile
#else
  let entries :: Monad m => BL.ByteString -> Excepts '[ArchiveResult] m [FilePath]
      entries = (fmap . fmap) filepath . lE . readArchiveBSL

      rf :: MonadIO m => FilePath -> Excepts '[ArchiveResult] m BL.ByteString
      rf = liftIO . BL.readFile
#endif

  -- extract, depending on file extension
  if
    | ".tar.gz" `isSuffixOf` fn -> liftE
      (entries . GZip.decompress =<< rf av)
    | ".tar.xz" `isSuffixOf` fn -> do
      filecontents <- liftE $ rf av
      let decompressed = Lzma.decompress filecontents
      liftE $ entries decompressed
    | ".tar.bz2" `isSuffixOf` fn ->
      liftE (entries . BZip.decompress =<< rf av)
    | ".tar" `isSuffixOf` fn -> liftE (entries =<< rf av)
    | ".zip" `isSuffixOf` fn ->
      withArchive av $ do
        entries' <- getEntries
        pure $ fmap unEntrySelector $ Map.keys entries'
    | otherwise -> throwE $ UnknownArchive fn


intoSubdir :: (MonadLogger m, MonadIO m, MonadThrow m, MonadCatch m)
           => FilePath       -- ^ unpacked tar dir
           -> TarDir         -- ^ how to descend
           -> Excepts '[TarDirDoesNotExist] m FilePath
intoSubdir bdir tardir = case tardir of
  RealDir pr -> do
    whenM (fmap not . liftIO . doesDirectoryExist $ (bdir </> pr))
          (throwE $ TarDirDoesNotExist tardir)
    pure (bdir </> pr)
  RegexDir r -> do
    let rs = split (`elem` pathSeparators) r
    foldlM
      (\y x ->
        (handleIO (\_ -> pure []) . liftIO . findFiles y . regex $ x) >>= (\case
          []      -> throwE $ TarDirDoesNotExist tardir
          (p : _) -> pure (y </> p)) . sort
      )
      bdir
      rs
    where regex = makeRegexOpts compIgnoreCase execBlank




    ------------
    --[ Tags ]--
    ------------


-- | Get the tool version that has this tag. If multiple have it,
-- picks the greatest version.
getTagged :: Tag
          -> AffineFold (Map.Map Version VersionInfo) (Version, VersionInfo)
getTagged tag =
  to (Map.filter (\VersionInfo {..} -> tag `elem` _viTags))
  % to Map.toDescList
  % _head

getLatest :: GHCupDownloads -> Tool -> Maybe (Version, VersionInfo)
getLatest av tool = headOf (ix tool % getTagged Latest) av

getRecommended :: GHCupDownloads -> Tool -> Maybe (Version, VersionInfo)
getRecommended av tool = headOf (ix tool % getTagged Recommended) av


-- | Gets the latest GHC with a given base version.
getLatestBaseVersion :: GHCupDownloads -> PVP -> Maybe (Version, VersionInfo)
getLatestBaseVersion av pvpVer =
  headOf (ix GHC % getTagged (Base pvpVer)) av



    -----------------------
    --[ AppState Getter ]--
    -----------------------


getCache :: MonadReader AppState m => m Bool
getCache = ask <&> cache . settings


getDownloader :: MonadReader AppState m => m Downloader
getDownloader = ask <&> downloader . settings



    -------------
    --[ Other ]--
    -------------


urlBaseName :: ByteString  -- ^ the url path (without scheme and host)
            -> ByteString
urlBaseName = snd . B.breakEnd (== _slash) . urlDecode False


-- | Get tool files from @~\/.ghcup\/bin\/ghc\/\<ver\>\/bin\/\*@
-- while ignoring @*-\<ver\>@ symlinks and accounting for cross triple prefix.
--
-- Returns unversioned relative files, e.g.:
--
--   - @["hsc2hs","haddock","hpc","runhaskell","ghc","ghc-pkg","ghci","runghc","hp2ps"]@
ghcToolFiles :: (MonadReader AppState m, MonadThrow m, MonadFail m, MonadIO m)
             => GHCTargetVersion
             -> Excepts '[NotInstalled] m [FilePath]
ghcToolFiles ver = do
  ghcdir <- lift $ ghcupGHCDir ver
  let bindir = ghcdir </> "bin"

  -- fail if ghc is not installed
  whenM (fmap not $ liftIO $ doesDirectoryExist ghcdir)
        (throwE (NotInstalled GHC ver))

  files    <- liftIO $ listDirectory bindir
  -- figure out the <ver> suffix, because this might not be `Version` for
  -- alpha/rc releases, but x.y.a.somedate.

  ghcIsHadrian    <- liftIO $ isHadrian bindir
  onlyUnversioned <- case ghcIsHadrian of
    Right () -> pure id
    Left (fmap (dropSuffix exeExt) -> [ghc, ghc_ver])
      | (Just symver) <- stripPrefix (ghc <> "-") ghc_ver
      , not (null symver) -> pure $ filter (\x -> not $ symver `isInfixOf` x)
    _ -> fail "Fatal: Could not find internal GHC version"

  pure $ onlyUnversioned $ fmap (dropSuffix exeExt) files
 where
  isNotAnyInfix xs t = foldr (\a b -> not (a `isInfixOf` t) && b) True xs
    -- GHC is moving some builds to Hadrian for bindists,
    -- which doesn't create versioned binaries.
    -- https://gitlab.haskell.org/haskell/ghcup-hs/issues/31
  isHadrian :: FilePath -- ^ ghcbin path
            -> IO (Either [String] ()) -- ^ Right for Hadrian
  isHadrian dir = do
    -- Non-hadrian has e.g. ["ghc", "ghc-8.10.4"]
    -- which also requires us to discover the internal version
    -- to filter the correct tool files.
    -- We can't use the symlink on windows, so we fall back to some
    -- more complicated logic.
    fs <- fmap
         -- regex over-matches
         (filter (isNotAnyInfix ["haddock", "ghc-pkg", "ghci"]))
       $ liftIO $ findFiles
      dir
      (makeRegexOpts compExtended
                     execBlank
                     -- for cross, this won't be "ghc", but e.g.
                     -- "armv7-unknown-linux-gnueabihf-ghc"
                     ([s|^([a-zA-Z0-9_-]*[a-zA-Z0-9_]-)?ghc.*$|] :: ByteString)
      )
    if | length fs == 1 -> pure $ Right ()        -- hadrian
       | length fs == 2 -> pure $ Left
                              (sortOn length fs)  -- legacy make, result should
                                                  -- be ["ghc", "ghc-8.10.4"]
       | otherwise      -> fail "isHadrian failed!"



-- | This file, when residing in @~\/.ghcup\/ghc\/\<ver\>\/@ signals that
-- this GHC was built from source. It contains the build config.
ghcUpSrcBuiltFile :: FilePath
ghcUpSrcBuiltFile = ".ghcup_src_built"


-- | Calls gmake if it exists in PATH, otherwise make.
make :: (MonadThrow m, MonadIO m, MonadReader AppState m)
     => [String]
     -> Maybe FilePath
     -> m (Either ProcessError ())
make args workdir = do
  spaths    <- liftIO getSearchPath
  has_gmake <- isJust <$> liftIO (searchPath spaths "gmake")
  let mymake = if has_gmake then "gmake" else "make"
  execLogged mymake args workdir "ghc-make" Nothing

makeOut :: [String]
        -> Maybe FilePath
        -> IO CapturedProcess
makeOut args workdir = do
  spaths    <- liftIO getSearchPath
  has_gmake <- isJust <$> liftIO (searchPath spaths "gmake")
  let mymake = if has_gmake then "gmake" else "make"
  liftIO $ executeOut mymake args workdir


-- | Try to apply patches in order. Fails with 'PatchFailed'
-- on first failure.
applyPatches :: (MonadLogger m, MonadIO m)
             => FilePath   -- ^ dir containing patches
             -> FilePath   -- ^ dir to apply patches in
             -> Excepts '[PatchFailed] m ()
applyPatches pdir ddir = do
  patches <- (fmap . fmap) (pdir </>) $ liftIO $ listDirectory pdir
  forM_ (sort patches) $ \patch' -> do
    lift $ $(logInfo) [i|Applying patch #{patch'}|]
    fmap (either (const Nothing) Just)
         (liftIO $ exec
           "patch"
           ["-p1", "-i", patch']
           (Just ddir)
           Nothing)
      !? PatchFailed


-- | https://gitlab.haskell.org/ghc/ghc/-/issues/17353
darwinNotarization :: Platform -> FilePath -> IO (Either ProcessError ())
darwinNotarization Darwin path = exec
  "xattr"
  ["-r", "-d", "com.apple.quarantine", path]
  Nothing
  Nothing
darwinNotarization _ _ = pure $ Right ()


getChangeLog :: GHCupDownloads -> Tool -> Either Version Tag -> Maybe URI
getChangeLog dls tool (Left v') =
  preview (ix tool % ix v' % viChangeLog % _Just) dls
getChangeLog dls tool (Right tag) =
  preview (ix tool % getTagged tag % to snd % viChangeLog % _Just) dls


-- | Execute a build action while potentially cleaning up:
--
--   1. the build directory, depending on the KeepDirs setting
--   2. the install destination, depending on whether the build failed
runBuildAction :: (Show (V e), MonadReader AppState m, MonadIO m, MonadMask m)
               => FilePath          -- ^ build directory (cleaned up depending on Settings)
               -> Maybe FilePath  -- ^ dir to *always* clean up on exception
               -> Excepts e m a
               -> Excepts '[BuildFailed] m a
runBuildAction bdir instdir action = do
  AppState { settings = Settings {..} } <- lift ask
  let exAction = do
        forM_ instdir $ \dir ->
          liftIO $ hideError doesNotExistErrorType $ removeDirectoryRecursive dir
        when (keepDirs == Never)
          $ liftIO
          $ hideError doesNotExistErrorType
          $ removeDirectoryRecursive bdir
  v <-
    flip onException exAction
    $ catchAllE
        (\es -> do
          exAction
          throwE (BuildFailed bdir es)
        ) action

  when (keepDirs == Never || keepDirs == Errors) $ liftIO $ removeDirectoryRecursive
    bdir
  pure v


-- | More permissive version of 'createDirRecursive'. This doesn't
-- error when the destination is a symlink to a directory.
createDirRecursive' :: FilePath -> IO ()
createDirRecursive' p =
  handleIO (\e -> if isAlreadyExistsError e then isSymlinkDir e else throwIO e)
    . createDirectoryIfMissing True
    $ p

 where
  isSymlinkDir e = do
    ft <- pathIsSymbolicLink p
    case ft of
      True -> do
        rp <- canonicalizePath p
        rft <- doesDirectoryExist rp
        case rft of
          True -> pure ()
          _ -> throwIO e
      _ -> throwIO e


-- | Recursively copy the contents of one directory to another path.
--
-- This is a rip-off of Cabal library.
copyDirectoryRecursive :: FilePath -> FilePath -> IO ()
copyDirectoryRecursive srcDir destDir = do
  srcFiles <- getDirectoryContentsRecursive srcDir
  copyFilesWith copyFile destDir [ (srcDir, f)
                                   | f <- srcFiles ]
  where
    -- | Common implementation of 'copyFiles', 'installOrdinaryFiles',
    -- 'installExecutableFiles' and 'installMaybeExecutableFiles'.
    copyFilesWith :: (FilePath -> FilePath -> IO ())
                  -> FilePath -> [(FilePath, FilePath)] -> IO ()
    copyFilesWith doCopy targetDir srcFiles = do

      -- Create parent directories for everything
      let dirs = map (targetDir </>) . nub . map (takeDirectory . snd) $ srcFiles
      traverse_ (createDirectoryIfMissing True) dirs

      -- Copy all the files
      sequence_ [ let src  = srcBase   </> srcFile
                      dest = targetDir </> srcFile
                   in doCopy src dest
                | (srcBase, srcFile) <- srcFiles ]

    -- | List all the files in a directory and all subdirectories.
    --
    -- The order places files in sub-directories after all the files in their
    -- parent directories. The list is generated lazily so is not well defined if
    -- the source directory structure changes before the list is used.
    --
    getDirectoryContentsRecursive :: FilePath -> IO [FilePath]
    getDirectoryContentsRecursive topdir = recurseDirectories [""]
      where
        recurseDirectories :: [FilePath] -> IO [FilePath]
        recurseDirectories []         = return []
        recurseDirectories (dir:dirs) = unsafeInterleaveIO $ do
          (files, dirs') <- collect [] [] =<< getDirectoryContents (topdir </> dir)
          files' <- recurseDirectories (dirs' ++ dirs)
          return (files ++ files')

          where
            collect files dirs' []              = return (reverse files
                                                         ,reverse dirs')
            collect files dirs' (entry:entries) | ignore entry
                                                = collect files dirs' entries
            collect files dirs' (entry:entries) = do
              let dirEntry = dir </> entry
              isDirectory <- doesDirectoryExist (topdir </> dirEntry)
              if isDirectory
                then collect files (dirEntry:dirs') entries
                else collect (dirEntry:files) dirs' entries

            ignore ['.']      = True
            ignore ['.', '.'] = True
            ignore _          = False


getVersionInfo :: Version
               -> Tool
               -> GHCupDownloads
               -> Maybe VersionInfo
getVersionInfo v' tool =
  headOf
    ( ix tool
    % to (Map.filterWithKey (\k _ -> k == v'))
    % to Map.elems
    % _head
    )


-- Gathering monoidal values
traverseFold :: (Foldable t, Applicative m, Monoid b) => (a -> m b) -> t a -> m b
traverseFold f = foldl (\mb a -> (<>) <$> mb <*> f a) (pure mempty)

-- | Gathering monoidal values
forFold :: (Foldable t, Applicative m, Monoid b) => t a -> (a -> m b) -> m b
forFold = \t -> (`traverseFold` t)


-- | The file extension for executables.
exeExt :: String
#if defined(IS_WINDOWS)
exeExt = ".exe"
#else
exeExt = ""
#endif

