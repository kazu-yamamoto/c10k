{-|
  Network server library to handle over 10,000 connections. Since
  GHC 6.10.4 or earlier uses select(), it cannot handle connections over
  1,024. This library uses the \"prefork\" technique to get over the
  barrier. Each process handles 'threadNumberPerProcess' connections.
  'preforkProcessNumber' child server processes are preforked. So, this
  server can handle 'preforkProcessNumber' * 'threadNumberPerProcess'
  connections.

  Even if GHC supports kqueue or epoll(), it is difficult for RTS
  to balance over multi-cores. So, this library can be used to
  make a process for each core and to set limitation of the number
  to accept connections.

  To stop all server, send SIGTERM to the parent process.
  (e.g. @kill `cat PIDFILE`@ where the PID file name is
  specified by 'pidFile')
-}
module Network.C10kServer (C10kServer, C10kConfig(..),
                           runC10kServer) where

import Control.Concurrent
import Control.Exception
import Control.Monad
import Network hiding (accept)
import Network.Socket
import Prelude hiding (catch)
import System.Posix.Process
import System.Posix.Signals
import System.Posix.User
import System.Exit

----------------------------------------------------------------

{-|
  The type of the first argument of 'runC10kServer'.
-}
type C10kServer = Socket -> IO ()

{-|
  The type of configuration given to 'runC10kServer' as the second
  argument.
-}
data C10kConfig = C10kConfig {
  -- | A hook called initialization time. This is used topically to
  --   initialize syslog.
    initHook :: IO ()
  -- | A hook called when the server exits due to an error.
  , exitHook :: String -> IO ()
  -- | A hook to be called in the parent process when all child
  --   process are preforked successfully.
  , parentStartedHook :: IO ()
  -- | A hook to be called when each child process is started
  --   successfully.
  , startedHook :: IO ()
  -- | The time in seconds that a main thread of each child process
  --   to sleep when the number of connection reaches
  --   'threadNumberPerProcess'.
  , sleepTimer :: Int
  -- | The number of child process.
  , preforkProcessNumber :: Int
  -- | The number of thread which a process handle.
  , threadNumberPerProcess :: Int
  -- | A port name. e.g. \"http\" or \"80\"
  , portName :: ServiceName
  -- | A file where the process ID of the parent process is written.
  , pidFile :: FilePath
  -- | A user name. When the program linked with this library runs
  --   in the root privilege, set user to this value. Otherwise,
  --   this value is ignored.
  , user :: String
  -- | A group name. When the program linked with this library runs
  --   in the root privilege, set group to this value. Otherwise,
  --   this value is ignored.
  , group :: String
}

----------------------------------------------------------------

{-|
  Run 'C10kServer' with 'C10kConfig'.
-}
runC10kServer :: C10kServer -> C10kConfig -> IO ()
runC10kServer srv cnf = do
    initHook cnf `catch` ignore
    initServer srv cnf `catch` errorHandle
    parentStartedHook cnf `catch` ignore
    doNothing
  where
    errorHandle :: SomeException -> IO ()
    errorHandle e = do
      exitHook cnf (show e)
      exitFailure
    doNothing = do
      threadDelay $ 5 * microseconds
      doNothing

----------------------------------------------------------------

initServer :: C10kServer -> C10kConfig -> IO ()
initServer srv cnf = do
    let port = Service $ portName cnf
        n    = preforkProcessNumber cnf
        pidf = pidFile cnf
    s <- listenOn port
    setGroupUser
    preFork s n srv cnf
    sClose s
    writePidFile pidf
  where
    writePidFile pidf = do
        pid <- getProcessID
        writeFile pidf $ show pid ++ "\n"
    setGroupUser = do
      uid <- getRealUserID
      when (uid == 0) $ do
        getGroupEntryForName (group cnf) >>= setGroupID . groupID
        getUserEntryForName (user cnf) >>= setUserID . userID

preFork :: Socket -> Int -> C10kServer -> C10kConfig -> IO ()
preFork s n srv cnf = do
    ignoreSigChild
    pid <- getProcessID
    cids <- replicateM n $ forkProcess (runServer s srv cnf)
    mapM_ (terminator pid cids) [sigTERM,sigINT]
  where
    ignoreSigChild = installHandler sigCHLD Ignore Nothing
    terminator pid cids sig = installHandler sig (Catch (terminate pid cids)) Nothing
    terminate pid cids = do
        mapM_ terminateChild cids
        signalProcess killProcess pid
    terminateChild cid =  signalProcess sigTERM cid `catch` ignore

----------------------------------------------------------------

runServer :: Socket -> C10kServer -> C10kConfig -> IO ()
runServer s srv cnf = do
    startedHook cnf
    mvar <- newMVar 0
    dispatchOrSleep mvar s srv cnf

dispatchOrSleep :: MVar Int -> Socket -> C10kServer -> C10kConfig -> IO ()
dispatchOrSleep mvar s srv cnf = do
    n <- howMany
    if n > threadNumberPerProcess cnf
        then sleep (sleepTimer cnf * microseconds)
        else dispatch
    dispatchOrSleep mvar s srv cnf
  where
    dispatch = do
        (sock,_) <- accept s
        increase
        forkIO $ srv sock `finally` (decrease >> sClose sock)
        return ()
    howMany = readMVar mvar
    increase = modifyMVar_ mvar (return . succ)
    decrease = modifyMVar_ mvar (return . pred)
    sleep = threadDelay


----------------------------------------------------------------

ignore :: SomeException -> IO ()
ignore _ = return ()

microseconds :: Int
microseconds = 1000000
