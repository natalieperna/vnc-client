\section{Client.lhs}

> module RFB.Client where

> import Network.Socket hiding (send, recv)
> import Network.Socket.ByteString (send, recv)
> import qualified Data.ByteString.Char8 as B8
> import Data.Bits ((.|.), (.&.), shiftL, shiftR)
> import Data.Char (ord, chr)
> import Data.Int (Int32)
> import Data.List (foldl1')
> import Graphics.X11.Xlib
> import System.Exit (exitWith, ExitCode(..))
> import Control.Concurrent (threadDelay)

Encoding types are listed in order of desired priority:
\begin{itemize}
  \item 1 - CopyRect
  \item 2 - RRE
  \item 0 - RAW
\end{itemize}
Implemented but not in the encodings list:
\begin{itemize}
  \item (-239) - cursor pseudo-encoding
\end{itemize}

> data RFBFormat =  RFBFormat
>                   { encodingTypes   :: [Int]
>                   , bitsPerPixel    :: Int
>                   , depth           :: Int
>                   , bigEndianFlag   :: Int
>                   , trueColourFlag  :: Int
>                   , redMax          :: Int
>                   , greenMax        :: Int
>                   , blueMax         :: Int
>                   , redShift        :: Int
>                   , greenShift      :: Int
>                   , blueShift       :: Int
>                   } deriving (Show)

> data Box =  Box
>             { x  :: Int
>             , y  :: Int
>             , w  :: Int
>             , h  :: Int
>             } deriving (Show)

> data Rectangle =  Rectangle
>                   { rectangle  :: Box
>                   , pixels     :: [Pixel]
>                   }

> data VNCDisplayWindow =  VNCDisplayWindow
>                          { display  :: Display  -- X display
>                          , rootw    :: Window   -- root window
>                          , win      :: Window   -- output window
>                          , pixmap   :: Pixmap   -- image buffer
>                          , wingc    :: GC       -- graphics contexts
>                          , pixgc    :: GC
>                          , width    :: Dimension
>                          , height   :: Dimension
>                          , bpp      :: Int
>                          }


> createVNCDisplay :: Int -> Int -> Int -> Int -> Int -> IO VNCDisplayWindow
> createVNCDisplay bpp x y w h = do
>     display <- openDisplay ""
>     let defaultX   = defaultScreen display
>         border     = blackPixel display defaultX
>         background = blackPixel display defaultX
>     rootw <- rootWindow display defaultX
>     win <- createSimpleWindow display rootw (fromIntegral x) (fromIntegral y)
>         (fromIntegral w) (fromIntegral h) 0 border background
>     setTextProperty display win "VNC Client" wM_NAME
>     mapWindow display win
>     gc <- createGC display win
>     pixmap <-  createPixmap display rootw (fromIntegral w) (fromIntegral h)
>                (defaultDepthOfScreen (defaultScreenOfDisplay display))
>     pixgc <- createGC display pixmap
>     let vncDisplay = VNCDisplayWindow  { display  = display
>                                        , rootw    = rootw
>                                        , win      = win
>                                        , pixmap   = pixmap
>                                        , wingc    = gc
>                                        , pixgc    = pixgc
>                                        , width    = (fromIntegral w)
>                                        , height   = (fromIntegral h)
>                                        , bpp      = bpp
>                                        }
>     --let eventMask = keyPressMask.|.keyReleaseMask
>     --selectInput display win eventMask
>     return vncDisplay

Swap the buffered image to the displayed window. This function allows double buffering.
This reduces the time it takes to draw an update, and eliminates any tearing effects.

> swapBuffer :: VNCDisplayWindow -> IO ()
> swapBuffer xWindow =  copyArea (display xWindow) (pixmap xWindow) (win xWindow)
>                       (pixgc xWindow) 0 0 (width xWindow) (height xWindow) 0 0

This is the main loop of the application.

> vncMainLoop :: Socket -> Box -> VNCDisplayWindow -> Int -> Int -> IO ()
> vncMainLoop sock framebuffer xWindow l t = do
>     framebufferUpdateRequest sock 1 framebuffer
>     message:_ <-recvInts sock 1
>     handleServerMessage message sock xWindow l t
>     vncMainLoop sock framebuffer xWindow l t

\subsection{RFB Functions}
\subsubsection{Server to Client Messages}

Get a message from the sever, and send it to the right function to handle the data
that will follow after it. The message types are:
\begin{itemize}
  \item 0 - Graphics update
  \item 1 - get color map data (not implemented)
  \item 2 - Beep sound
  \item 3 - cut text from server
\end{itemize}

> handleServerMessage :: Int -> Socket -> VNCDisplayWindow -> Int -> Int -> IO ()
> handleServerMessage 0 sock xWindow l t = refreshWindow sock xWindow l t
> handleServerMessage 2 _    _       _ _ = putStr "\a" -- Beep
> handleServerMessage 3 sock _       _ _ = serverCutText sock
> handleServerMessage _ _    _       _ _ = return ()

> refreshWindow :: Socket -> VNCDisplayWindow -> Int -> Int -> IO ()
> refreshWindow sock xWindow l t = do
>     (_:n1:n2:_) <- recvInts sock 3
>     handleRectangleHeader xWindow sock (bytesToInt [n1, n2]) l t
>     swapBuffer xWindow

> serverCutText :: Socket -> IO ()
> serverCutText sock = do
>     (_:_:_:l1:l2:l3:l4:_) <- recvInts sock 7
>     cutText <- recvString sock (bytesToInt [l1, l2, l3, l4])
>     -- we should be copying cutText to the clipboard here
>     -- but we will print instead
>     putStrLn cutText

\subsubsection{Client to Server Messages}

> setEncodings :: Socket -> RFBFormat -> IO Int
> setEncodings sock format =
>     sendInts sock (  [ 2   -- message-type
>                      , 0]  -- padding
>                      ++ intToBytes 2 (length (encodingTypes format))
>                      ++ concat (map (intToBytes 4) (encodingTypes format)))

> setPixelFormat :: Socket -> RFBFormat -> IO Int
> setPixelFormat sock format =
>     sendInts sock (  [ 0        -- message-type
>                      , 0, 0, 0  -- padding
>                      , bitsPerPixel format
>                      , depth format
>                      , bigEndianFlag format
>                      , trueColourFlag format ]
>                      ++ intToBytes 2 (redMax format)
>                      ++ intToBytes 2 (greenMax format)
>                      ++ intToBytes 2 (blueMax format)
>                      ++
>                      [ redShift format
>                      , greenShift format
>                      , blueShift format
>                      , 0, 0, 0 ]) -- padding

> framebufferUpdateRequest :: Socket -> Int -> Box -> IO Int
> framebufferUpdateRequest sock incremental framebuffer =
>     sendInts sock (  [ 3  -- message-type
>                      , incremental]
>                      ++ intToBytes 2 (x framebuffer)
>                      ++ intToBytes 2 (y framebuffer)
>                      ++ intToBytes 2 (w framebuffer)
>                      ++ intToBytes 2 (h framebuffer))

> sendKeyEvent :: Socket -> Bool -> Int -> IO Int
> sendKeyEvent sock True key =
>     sendInts sock ([4 -- message type
>                   , 1
>                   , 0, 0 ]
>                   ++ (intToBytes 4 key))
> sendKeyEvent sock False key =
>     sendInts sock ([4 -- message type
>                   , 0
>                   , 0, 0 ]
>                   ++ (intToBytes 4 key))  

\subsection {Network Functions and Type Convertions}

> recvFixedLength :: Socket -> Int -> IO B8.ByteString
> recvFixedLength s l = do
>     x <- recv s l
>     if B8.length x < l
>     then if B8.length x == 0
>         then error "Connection Lost" 
>         else do
>             y <- recvFixedLength s (l - B8.length x)
>             return (B8.append x y)
>     else return x

> bytestringToInts :: B8.ByteString -> [Int]
> bytestringToInts = map ord . B8.unpack

> intsToBytestring :: [Int] -> B8.ByteString
> intsToBytestring = B8.pack . map chr

> recvString :: Socket -> Int -> IO [Char]
> recvString s l = fmap B8.unpack (recvFixedLength s l)

> recvInts :: Socket -> Int -> IO [Int]
> recvInts s l = fmap bytestringToInts (recvFixedLength s l)

> sendString :: Socket -> String -> IO Int
> sendString s l = send s (B8.pack l)

> sendInts :: Socket -> [Int] -> IO Int
> sendInts s l = send s (intsToBytestring l)

> bytesToInt :: [Int] -> Int
> bytesToInt []  = 0
> bytesToInt [b] = b 
> bytesToInt bs  = foldl1' (\ a b -> shiftL a 8 .|. b) bs

> intToBytes :: Int -> Int -> [Int]
> intToBytes l x = let lsr = \b -> shiftR (b .&. 0xFFFFFFFFFFFFFF00) 8
>                  in reverse . take l . fmap (.&. 0xFF) $ iterate lsr x


\subsection{Graphics Functions}

Get the header information for each rectangle to be drawn.

> handleRectangleHeader :: VNCDisplayWindow -> Socket -> Int -> Int -> Int -> IO ()
> handleRectangleHeader _       _    0  _  _  = return ()
> handleRectangleHeader xWindow sock n  l  t  = do
>     (x1:x2:
>      y1:y2:
>      w1:w2:
>      h1:h2:
>      e1:e2:e3:e4:
>      _) <- recvInts sock 12
>     let rect = Box  { x = bytesToInt [x1, x2]
>                     , y = bytesToInt [y1, y2]
>                     , w = bytesToInt [w1, w2]
>                     , h = bytesToInt [h1, h2] }
>     displayRectangle (fromIntegral (bytesToInt [e1, e2, e3, e4])) xWindow sock
>         (bpp xWindow) (x rect) (y rect) (w rect) (h rect) l t
>     handleRectangleHeader xWindow sock (n-1) l t

Choose which decoding function to use for the rectangle.

> displayRectangle ::  Int32 -> VNCDisplayWindow -> Socket ->
>                      Int -> Int -> Int -> Int -> Int -> Int -> Int -> IO ()
> displayRectangle  0  xWindow  sock  bpp  x  y  w  h  l  t  =
>     decodeRAW  xWindow  sock  bpp  x  y  w  h  l  t
> displayRectangle  1  xWindow  sock  bpp  x  y  w  h  l  t  =
>     decodeCopyRect  xWindow  sock  x  y  w  h  l  t
> displayRectangle  2  xWindow  sock  bpp  x  y  w  h  l  t  =
>     decodeRRE  xWindow  sock  bpp  x  y  w  h  l  t
> displayRectangle  (-239)  xWindow  sock  bpp  x  y  w  h  l  t  =
>     pseudoDecodeCursor  xWindow  sock  bpp  x  y  w  h  l  t
> displayRectangle  _  _        _     _    _  _  _  _  _  _=
>     return ()

\subsubsection{Image Decoding Functions}

> decodeRAW ::  VNCDisplayWindow -> Socket ->
>               Int -> Int -> Int -> Int -> Int -> Int -> Int -> IO ()
> decodeRAW  xWindow  sock  bpp  x  y  w  h  l  t  = do
>     let colors = recvColorList sock bpp (w*h)
>     sequence_ . zipWith (\ (a,b) c -> displayPixel xWindow a b =<< c) positions $ colors
>     where
>       positions = [(x,y) | y <- [(y-t)..(y-t+h-1)], x <- [(x-l)..(x-l+w-1)]]

> decodeCopyRect :: VNCDisplayWindow -> Socket -> Int -> Int -> Int -> Int -> Int -> Int -> IO ()
> decodeCopyRect xWindow sock x y w h l t = do
>     srcx1:srcx2:srcy1:srcy2:_ <- recvInts sock 4
>     copyArea (display xWindow) (pixmap xWindow) (pixmap xWindow) (pixgc xWindow)
>         (fromIntegral (bytesToInt [srcx1, srcx2] - l))
>         (fromIntegral (bytesToInt [srcy1, srcy2] - t))
>         (fromIntegral w) (fromIntegral h) (fromIntegral (x-l)) (fromIntegral (y-t))

> decodeRRE :: VNCDisplayWindow -> Socket -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> IO ()
> decodeRRE  xWindow  sock  bpp  x  y  w  h  l  t = do
>     s1:s2:s3:s4:_ <- recvInts sock 4
>     color <- recvColor sock bpp
>     drawRect xWindow (fromIntegral (x-l)) (fromIntegral (y-t)) w h color
>     drawRRESubRects xWindow sock bpp x y l t (bytesToInt [s1, s2, s3, s4])

> pseudoDecodeCursor :: VNCDisplayWindow -> Socket -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> IO ()
> pseudoDecodeCursor xWindow sock bpp x y w h l t = do
>     colors  <- sequence $ recvColorList sock bpp (w*h)
>     bitMask <- recvBitMask sock (( (w+7) `div` 8) * h)
>     drawBitmaskedPixels xWindow 100 w (((w+7)`div`8)*8) colors bitMask 100 100

\subsubsection{Supporting Functions for Encoding}

Displays the subractangles for RRE encoding.

> drawRRESubRects :: VNCDisplayWindow -> Socket -> Int -> Int -> Int -> Int -> Int -> Int -> IO ()
> drawRRESubRects _       _    _   _  _  _ _ 0 = return ()
> drawRRESubRects xWindow sock bpp x0 y0 l t n = do
>     color <- recvColor sock bpp
>     (x1:x2:
>      y1:y2:
>      w1:w2:
>      h1:h2:
>      _) <- recvInts sock 8
>     let rect = Box  { x = bytesToInt [x1, x2]
>                     , y = bytesToInt [y1, y2]
>                     , w = bytesToInt [w1, w2]
>                     , h = bytesToInt [h1, h2] }
>     drawRect xWindow (fromIntegral (x0+(x rect)-l)) (fromIntegral (y0+(y rect)-t)) (w rect) (h rect) color
>     drawRRESubRects xWindow sock bpp x0 y0 l t (n-1)

Get list of colors.

> recvColorList :: Socket -> Int -> Int -> [IO Int]
> recvColorList sock bpp size = take size . repeat $ recvColor sock bpp

Get Bitmask array to describe which pixels in an image are valid.

> recvBitMask :: Socket -> Int -> IO [Bool]
> recvBitMask _ 0 = return []
> recvBitMask sock size = do
>     byte:_ <- recvInts sock 1
>     xs <- recvBitMask sock (size-1)
>     return $ ((byte .&. 0x80)>0):
>              ((byte .&. 0x40)>0):
>              ((byte .&. 0x20)>0):
>              ((byte .&. 0x10)>0):
>              ((byte .&. 0x08)>0):
>              ((byte .&. 0x04)>0):
>              ((byte .&. 0x02)>0):
>              ((byte .&. 0x01)>0):xs

Draw pixels based on bitmask data.

> drawBitmaskedPixels :: VNCDisplayWindow -> Int -> Int -> Int -> [Int] -> [Bool] -> Int -> Int -> IO ()
> drawBitmaskedPixels _       _  _ _        []        _       _ _ = return ()
> drawBitmaskedPixels xWindow x0 w wBitMask colorList bitMask x y = do
>     if x >= x0 + w
>     then if x >= x0 + wBitMask
>         then drawBitmaskedPixels xWindow x0 w wBitMask colorList (bitMask) x0 (y+1)
>         else drawBitmaskedPixels xWindow x0 w wBitMask colorList (tail bitMask) (x+1) y
>     else if (head bitMask)
>         then do
>             displayPixel xWindow x y (head colorList)
>             drawBitmaskedPixels xWindow x0 w wBitMask (tail colorList) (tail bitMask) (x+1) y
>         else drawBitmaskedPixels xWindow x0 w wBitMask (tail colorList) (tail bitMask) (x+1) y
> --drawBitmaskedPixels xWindow w widthBitMask colors bitMask x y =
> --    sequence_ . zipWith3 (\ (x, y) c bit -> if bit
> --                                            then displayPixel xWindow x y c
> --                                            else return ()
> --                         )
> --                         positions colors $ bits bitMask
> --    where
> --      positions = [(x,y) | y <- [y..], x <- [x..(x+w-1)]]
> --      bits bs = if widthBitMask > w
> --                then (\ (xs, ys) -> xs ++ (bits . drop (widthBitMask - w) $ ys)) $ splitAt w bs
> --                else bitMask

\subsubsection{Drawing to Screen}

Get the color to be drawn. Supports various bit per pixel formats. 24 bpp is non-standard
in the RFB protocol, but we support it because some servers will accept it.

> recvColor :: Socket -> Int -> IO Int
> recvColor sock 32 = recvInts sock 4 >>= return . bytesToInt . take 3
> recvColor sock 24 = recvInts sock 3 >>= return . bytesToInt
> recvColor sock 16 = recvInts sock 2 >>= return . bytesToInt
> recvColor sock 8  = recvInts sock 1 >>= return . bytesToInt
> recvColor _    _  = error "Unsupported bits-per-pixel setting"

Draw an individual pixel to the buffer

> displayPixel :: VNCDisplayWindow -> Int -> Int -> Int -> IO ()
> displayPixel xWindow x y color = do
>     setForeground (display xWindow) (pixgc xWindow) (fromIntegral color)
>     drawPoint (display xWindow) (pixmap xWindow) (pixgc xWindow)
>         (fromIntegral x) (fromIntegral y)

Draw a filled rectangle to the buffer

> drawRect :: VNCDisplayWindow -> Int -> Int -> Int -> Int -> Int -> IO ()
> drawRect xWindow x y 1 1 color = displayPixel xWindow x y color
> drawRect xWindow x y w h color = do
>     setForeground (display xWindow) (pixgc xWindow) (fromIntegral color)
>     fillRectangle (display xWindow) (pixmap xWindow) (pixgc xWindow)
>         (fromIntegral x) (fromIntegral y) (fromIntegral w) (fromIntegral h)
