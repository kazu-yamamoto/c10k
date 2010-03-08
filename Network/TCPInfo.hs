{-|
  Yet another accept() to tell TCP information.
-}
module Network.TCPInfo where

import Data.List
import Network.Socket
import System.IO

{-|
  A Type to carry TCP information.
-}
data TCPInfo = TCPInfo {
  -- | Local IP address
    myAddr :: HostName
  -- | Local port number
  , myPort :: ServiceName
  -- | Remote IP address
  , peerAddr :: HostName
  -- | Remote port number
  , peerPort :: ServiceName
  } deriving (Eq,Show)

----------------------------------------------------------------

{-|
  Yet another accept() to return both 'Handle' and 'TCPInfo'.
-}
accept :: Socket -> IO (Handle, TCPInfo)
accept sock = do
    (sock', sockaddr) <- Network.Socket.accept sock
    let getInfo = getNameInfo [NI_NUMERICHOST, NI_NUMERICSERV] True True
    (Just vMyAddr,   Just vMyPort)   <- getSocketName sock' >>= getInfo
    (Just vPeerAddr, Just vPeerPort) <- getInfo sockaddr
    hdl <- socketToHandle sock' ReadWriteMode
    let info = TCPInfo { myAddr = strip vMyAddr
                       , myPort = vMyPort
                       , peerAddr = strip vPeerAddr
                       , peerPort = vPeerPort}
    return (hdl, info)
  where
    strip x
      | "::ffff:" `isPrefixOf` x = drop 7 x
      | otherwise                = x
