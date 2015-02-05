module RFB.Client where

import Network.Socket hiding (send, recv)
import Network.Socket.ByteString (send, recv)
import qualified Data.ByteString.Char8 as B8
import Data.Char (ord, chr)

connect :: String -> Int -> IO()
connect host port = withSocketsDo $ do

    -- Connect to server via socket
    addrInfo <- getAddrInfo Nothing (Just host) (Just $ show port)
    let serverAddr = head addrInfo
    sock <- socket (addrFamily serverAddr) Stream defaultProtocol
    Network.Socket.connect sock (addrAddress serverAddr)

    -- Check for VNC server
    send sock B8.empty
    msg <- recvString sock 12
    -- TODO Verify version format
    putStr $ "Server Protocol Version: " ++ msg

    -- TODO Actually compare version numbers before blindy choosing
    let version = "RFB 003.007\n"
    putStr $ "Requsted Protocol Version: " ++ version
    send sock $ B8.pack version

    -- Receive number of security types
    msg <- recvInts sock 1
    let numberOfSecurityTypes = head msg

    -- Receive security types
    securityTypes <- recvString sock numberOfSecurityTypes
    putStrLn $ "Server Security Types: " ++ securityTypes

    -- TODO Actually check security types before blindy choosing
    send sock (intsToBytestring [1])

    -- I don't know why SecurityResult isn't being sent
    -- msg <- recv sock 1

    -- Allow shared desktop
    send sock (intsToBytestring [1])

    -- Get ServerInit message
    serverInit <- recvInts sock 20
    let framebufferWidth = 256 * serverInit !! 0 + serverInit !! 1
    let framebufferHeight = 256 * serverInit !! 2 + serverInit !! 3
    let bitsPerPixel = serverInit !! 4
    let depth = serverInit !! 5
    let bigEndianFlag = serverInit !! 6
    let trueColourFlag = serverInit !! 7
    let redMax = 256 * serverInit !! 8 + serverInit !! 9
    let blueMax = 256 * serverInit !! 10 + serverInit !! 11
    let greenMax = 256 * serverInit !! 12 + serverInit !! 13
    let redShift = serverInit !! 14
    let greenShift = serverInit !! 15
    let blueShift = serverInit !! 16
    -- Last 3 bytes for padding
    putStrLn $ "serverInit: " ++ show serverInit
    putStrLn $ "framebufferWidth: " ++ show framebufferWidth
    putStrLn $ "framebufferHeight: " ++ show framebufferHeight
    putStrLn $ "bitsPerPixel: " ++ show bitsPerPixel
    putStrLn $ "depth: " ++ show depth
    putStrLn $ "bigEndianFlag: " ++ show bigEndianFlag
    putStrLn $ "trueColourFlag: " ++ show trueColourFlag
    putStrLn $ "redMax: " ++ show redMax
    putStrLn $ "blueMax: " ++ show blueMax
    putStrLn $ "greenMax: " ++ show greenMax
    putStrLn $ "redShift: " ++ show redShift
    putStrLn $ "greenShift: " ++ show greenShift
    putStrLn $ "blueShift: " ++ show blueShift

    let framebufferUpdateRequest = [3, 0, 0, 0, 0, 0, framebufferWidth `quot` 256, framebufferWidth `rem` 256, framebufferHeight `quot` 256, framebufferHeight `rem` 256]
    send sock (intsToBytestring framebufferUpdateRequest)
    framebufferUpdate <- recvInts sock 4
    let messageType = framebufferUpdate !! 0
    let padding = framebufferUpdate !! 1
    let numberofRectangles = 256 * serverInit !! 2 + serverInit !! 3
    putStrLn $ "numberofRectangles: " ++ show numberofRectangles

    hold <- getLine

    -- Close socket
    sClose sock

bytestringToInts :: B8.ByteString -> [Int]
bytestringToInts b = map ord (B8.unpack b)

intsToBytestring :: [Int] -> B8.ByteString
intsToBytestring b = B8.pack (map chr b)

recvString :: Socket -> Int -> IO [Char]
recvString s l = fmap B8.unpack (recv s l)

recvInts :: Socket -> Int -> IO [Int]
recvInts s l = fmap bytestringToInts (recv s l)
