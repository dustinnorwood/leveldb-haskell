-- |
-- Module      : Database.LevelDB.Base
-- Copyright   : (c) 2012-2013 The leveldb-haskell Authors
-- License     : BSD3
-- Maintainer  : kim.altintop@gmail.com
-- Stability   : experimental
-- Portability : non-portable
--
-- LevelDB Haskell binding.
--
-- The API closely follows the C-API of LevelDB.
-- For more information, see: <http://leveldb.googlecode.com>

module Database.LevelDB.Base
    ( -- * Exported Types
      DB
    , BatchOp (..)
    , Comparator (..)
    , Compression (..)
    , Options (..)
    , ReadOptions (..)
    , Snapshot
    , WriteBatch
    , WriteOptions (..)
    , Range

    -- * Defaults
    , defaultOptions
    , defaultReadOptions
    , defaultWriteOptions

    -- * Basic Database Manipulations
    , withDB
    , open
    , put
    , delete
    , write
    , get
    , withSnapshot
    , createSnapshot
    , releaseSnapshot

    -- * Filter Policy / Bloom Filter
    , FilterPolicy (..)
    , BloomFilter
    , createBloomFilter
    , releaseBloomFilter

    -- * Administrative Functions
    , Property (..), getProperty
    , destroy
    , repair
    , approximateSize
    , compactRange
    , version

    -- * Iteration
    , module Database.LevelDB.Iterator
    )
where

import           Control.Applicative      ((<$>))
import           Control.Monad            (liftM, void)
import           Control.Monad.Catch
import           Control.Monad.IO.Class   (MonadIO (liftIO))
import           Data.ByteString          (ByteString)
import           Data.ByteString.Internal (ByteString (..))
import           Data.IORef
import           Foreign                  hiding (free, void)
import           Foreign.C.String         (withCString)

import           Database.LevelDB.C
import           Database.LevelDB.Internal
import           Database.LevelDB.Iterator
import           Database.LevelDB.Types

import qualified Data.ByteString          as BS
import qualified Data.ByteString.Unsafe   as BU


-- | Open a database.
--
-- The returned handle has a finalizer attached which will free the underlying
-- pointers once it goes out of scope. Note, however, that finalizers are /not/
-- guaranteed to run, and may not run promptly if they do. Use 'unsafeClose' to
-- free the handle immediately, but ensure it is not used after that (otherwise,
-- the program will segault). Alternatively, use the
-- "Database.LevelDB.MonadResource" API, which will take care of resource
-- management automatically.
open :: MonadIO m => FilePath -> Options -> m DB
open path opts = liftIO $ bracketOnError (mkOpts opts) freeOpts mkDB
  where
    mkDB opts'@(Options' opts_ptr _ _ _) =
        withCString path $ \path_ptr -> do
            db_ptr <- throwIfErr "open" $ c_leveldb_open opts_ptr path_ptr
            alive  <- newIORef True
            let db = DB db_ptr opts' alive
            addFinalizer alive $ unsafeClose db
            return db

    addFinalizer ref = void . mkWeakIORef ref

-- | Run an action with a 'DB'.
--
-- > withDB path opts = bracket (open path opts) unsafeClose
--
-- Note that the 'DB' handle will be released promptly when this function exits.
withDB :: (MonadMask m, MonadIO m) => FilePath -> Options -> (DB -> m a) -> m a
withDB path opts = bracket (open path opts) (liftIO . unsafeClose)

-- | Run an action with a 'Snapshot' of the database.
withSnapshot :: (MonadMask m, MonadIO m) => DB -> (Snapshot -> m a) -> m a
withSnapshot db = bracket (createSnapshot db) (releaseSnapshot db)

-- | Create a snapshot of the database.
--
-- The returned 'Snapshot' should be released with 'releaseSnapshot'.
createSnapshot :: MonadIO m => DB -> m Snapshot
createSnapshot (DB db_ptr _ _) = liftIO $
    Snapshot <$> c_leveldb_create_snapshot db_ptr

-- | Release a snapshot.
--
-- The handle will be invalid after calling this action and should no
-- longer be used.
releaseSnapshot :: MonadIO m => DB -> Snapshot -> m ()
releaseSnapshot (DB db_ptr _ _) (Snapshot snap) = liftIO $
    c_leveldb_release_snapshot db_ptr snap

-- | Get a DB property.
getProperty :: MonadIO m => DB -> Property -> m (Maybe ByteString)
getProperty (DB db_ptr _ _) p = liftIO $
    withCString (prop p) $ \prop_ptr -> do
        val_ptr <- c_leveldb_property_value db_ptr prop_ptr
        if val_ptr == nullPtr
            then return Nothing
            else do res <- Just <$> BS.packCString val_ptr
                    c_leveldb_free val_ptr
                    return res
  where
    prop (NumFilesAtLevel i) = "leveldb.num-files-at-level" ++ show i
    prop Stats               = "leveldb.stats"
    prop SSTables            = "leveldb.sstables"

-- | Destroy the given LevelDB database.
--
-- The database must not be in use during this operation.
destroy :: MonadIO m => FilePath -> Options -> m ()
destroy path opts = liftIO $ bracket (mkOpts opts) freeOpts destroy'
  where
    destroy' (Options' opts_ptr _ _ _) =
        withCString path $ \path_ptr ->
            throwIfErr "destroy" $ c_leveldb_destroy_db opts_ptr path_ptr

-- | Repair the given LevelDB database.
repair :: MonadIO m => FilePath -> Options -> m ()
repair path opts = liftIO $ bracket (mkOpts opts) freeOpts repair'
  where
    repair' (Options' opts_ptr _ _ _) =
        withCString path $ \path_ptr ->
            throwIfErr "repair" $ c_leveldb_repair_db opts_ptr path_ptr


-- TODO: support [Range], like C API does
type Range  = (ByteString, ByteString)

-- | Inspect the approximate sizes of the different levels.
approximateSize :: MonadIO m => DB -> Range -> m Int64
approximateSize (DB db_ptr _ _) (from, to) = liftIO $
    BU.unsafeUseAsCStringLen from $ \(from_ptr, flen) ->
    BU.unsafeUseAsCStringLen to   $ \(to_ptr, tlen)   ->
    withArray [from_ptr]          $ \from_ptrs        ->
    withArray [intToCSize flen]   $ \flen_ptrs        ->
    withArray [to_ptr]            $ \to_ptrs          ->
    withArray [intToCSize tlen]   $ \tlen_ptrs        ->
    allocaArray 1                 $ \size_ptrs        -> do
        c_leveldb_approximate_sizes db_ptr 1
                                    from_ptrs flen_ptrs
                                    to_ptrs tlen_ptrs
                                    size_ptrs
        liftM head $ peekArray 1 size_ptrs >>= mapM toInt64

  where
    toInt64 = return . fromIntegral

-- | Compact the underlying storage for the given Range.
-- In particular this means discarding deleted and overwritten data as well as
-- rearranging the data to reduce the cost of operations accessing the data.
compactRange :: MonadIO m => DB -> Range -> m ()
compactRange (DB db_ptr _ _) (from, to) = liftIO $
    BU.unsafeUseAsCStringLen from $ \(from_ptr, flen) ->
    BU.unsafeUseAsCStringLen to $ \(to_ptr, tlen) ->
        c_leveldb_compact_range db_ptr from_ptr (intToCSize flen) to_ptr (intToCSize tlen)

-- | Write a key/value pair.
put :: MonadIO m => DB -> WriteOptions -> ByteString -> ByteString -> m ()
put (DB db_ptr _ _) opts key value = liftIO $ withCWriteOpts opts $ \opts_ptr ->
    BU.unsafeUseAsCStringLen key   $ \(key_ptr, klen) ->
    BU.unsafeUseAsCStringLen value $ \(val_ptr, vlen) ->
        throwIfErr "put"
            $ c_leveldb_put db_ptr opts_ptr
                            key_ptr (intToCSize klen)
                            val_ptr (intToCSize vlen)

-- | Read a value by key.
get :: MonadIO m => DB -> ReadOptions -> ByteString -> m (Maybe ByteString)
get (DB db_ptr _ _) opts key = liftIO $ withCReadOpts opts $ \opts_ptr ->
    BU.unsafeUseAsCStringLen key $ \(key_ptr, klen) ->
    alloca                       $ \vlen_ptr -> do
        val_ptr <- throwIfErr "get" $
            c_leveldb_get db_ptr opts_ptr key_ptr (intToCSize klen) vlen_ptr
        vlen <- peek vlen_ptr
        if val_ptr == nullPtr
            then return Nothing
            else do
                res' <- Just <$> BS.packCStringLen (val_ptr, cSizeToInt vlen)
                c_leveldb_free val_ptr
                return res'

-- | Delete a key/value pair.
delete :: MonadIO m => DB -> WriteOptions -> ByteString -> m ()
delete (DB db_ptr _ _) opts key = liftIO $ withCWriteOpts opts $ \opts_ptr ->
    BU.unsafeUseAsCStringLen key $ \(key_ptr, klen) ->
        throwIfErr "delete"
            $ c_leveldb_delete db_ptr opts_ptr key_ptr (intToCSize klen)

-- | Perform a batch mutation.
write :: MonadIO m => DB -> WriteOptions -> WriteBatch -> m ()
write (DB db_ptr _ _) opts batch = liftIO $ withCWriteOpts opts $ \opts_ptr ->
    bracket c_leveldb_writebatch_create c_leveldb_writebatch_destroy $ \batch_ptr -> do

    mapM_ (batchAdd batch_ptr) batch

    throwIfErr "write" $ c_leveldb_write db_ptr opts_ptr batch_ptr

    -- ensure @ByteString@s (and respective shared @CStringLen@s) aren't GC'ed
    -- until here
    mapM_ (liftIO . touch) batch

  where
    batchAdd batch_ptr (Put key val) =
        BU.unsafeUseAsCStringLen key $ \(key_ptr, klen) ->
        BU.unsafeUseAsCStringLen val $ \(val_ptr, vlen) ->
            c_leveldb_writebatch_put batch_ptr
                                     key_ptr (intToCSize klen)
                                     val_ptr (intToCSize vlen)

    batchAdd batch_ptr (Del key) =
        BU.unsafeUseAsCStringLen key $ \(key_ptr, klen) ->
            c_leveldb_writebatch_delete batch_ptr key_ptr (intToCSize klen)

    touch (Put (PS p _ _) (PS p' _ _)) = do
        touchForeignPtr p
        touchForeignPtr p'

    touch (Del (PS p _ _)) = touchForeignPtr p

-- | Return the runtime version of the underlying LevelDB library as a (major,
-- minor) pair.
version :: MonadIO m => m (Int, Int)
version = do
    major <- liftIO c_leveldb_major_version
    minor <- liftIO c_leveldb_minor_version

    return (cIntToInt major, cIntToInt minor)

createBloomFilter :: MonadIO m => Int -> m BloomFilter
createBloomFilter i = do
    let i' = fromInteger . toInteger $ i
    fp_ptr <- liftIO $ c_leveldb_filterpolicy_create_bloom i'
    return $ BloomFilter fp_ptr

releaseBloomFilter :: MonadIO m => BloomFilter -> m ()
releaseBloomFilter (BloomFilter fp) = liftIO $ c_leveldb_filterpolicy_destroy fp
