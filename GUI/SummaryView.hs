module GUI.SummaryView (
    SummaryView,
    summaryViewNew,
    summaryViewSetEvents,
    summaryViewSetInterval,
  ) where

import GHC.RTS.Events

import GUI.Timeline.Render.Constants
import GUI.Types

import Graphics.UI.Gtk
import Graphics.Rendering.Cairo

import Data.Array
import Data.IORef
import Data.Maybe
import Data.Word (Word64)
import qualified Data.List as L
import qualified Data.IntMap as IM
import Control.Exception (assert)
import Text.Printf

------------------------------------------------------------------------------

data SummaryView = SummaryView
  { gtkLayout      :: !Layout
  , defaultInfoRef :: !(IORef String)  -- ^ info for interval Nothing, speedup
  , meventsRef     :: !(IORef (Maybe (Array Int CapEvent)))
  , mintervalIORef :: !(IORef (Maybe Interval))
  }

------------------------------------------------------------------------------

summaryViewNew :: Builder -> IO SummaryView
summaryViewNew builder = do
  defaultInfoRef <- newIORef ""
  meventsRef <- newIORef Nothing
  mintervalIORef <- newIORef Nothing
  let getWidget cast = builderGetObject builder cast
  gtkLayout  <- getWidget castToLayout "eventsLayoutSummary"
  let infoView = SummaryView{..}
  -- Drawing
  on gtkLayout exposeEvent $ liftIO $ do
    defaultInfo <- readIORef defaultInfoRef
    mevents <- readIORef meventsRef
    minterval <- readIORef mintervalIORef
    drawSummary gtkLayout defaultInfo mevents minterval
    return True
  return infoView

------------------------------------------------------------------------------

drawSummary :: Layout -> String -> Maybe (Array Int CapEvent)
            -> Maybe Interval -> IO ()
drawSummary gtkLayout defaultInfo mevents minterval = do
  let info = case minterval of
        Nothing -> defaultInfo  -- speedup
        _       -> fst (summaryViewProcessEvents minterval mevents)
  win <- layoutGetDrawWindow gtkLayout
  pangoCtx <- widgetGetPangoContext gtkLayout
  layout <- layoutText pangoCtx info
  layoutSetAttributes layout [AttrFamily minBound maxBound "monospace"]
  (_, Rectangle _ _ width height) <- layoutGetPixelExtents layout
  layoutSetSize gtkLayout (width + 30) (height + 10)
  renderWithDrawable win $ do
    moveTo (fromIntegral ox / 2) (fromIntegral ox / 3)
    showLayout layout

------------------------------------------------------------------------------

summaryViewSetInterval :: SummaryView -> Maybe Interval -> IO ()
summaryViewSetInterval SummaryView{gtkLayout, mintervalIORef} minterval = do
  writeIORef mintervalIORef minterval
  widgetQueueDraw gtkLayout

------------------------------------------------------------------------------

genericSetEvents :: (Maybe (Array Int CapEvent)
                     -> (String, Maybe (Array Int CapEvent)))
                 -> SummaryView -> Maybe (Array Int CapEvent) -> IO ()
genericSetEvents processEvents SummaryView{..} mev = do
  let (defaultInfo, mevents) = processEvents mev
  writeIORef defaultInfoRef defaultInfo
  writeIORef meventsRef mevents
  writeIORef mintervalIORef Nothing  -- the old interval may make no sense
  widgetQueueDraw gtkLayout

-- TODO: some of these are unused yet.
data SummaryData = SummaryData
  { dallocTable    :: !(IM.IntMap (Word64, Word64))
  , dcopied        :: Maybe Word64
  , dmaxResidency  :: Maybe Word64
  , dmaxSlop       :: Maybe Word64
  , dmaxMemory     :: Maybe Word64
  , dmaxFrag       :: Maybe Word64
  , dGCTable       :: !(IM.IntMap RtsGC)
  , dparBalance    :: Maybe Double
--, dtaskTable     -- of questionable usefulness, hard to get
  , dsparkTable    :: !(IM.IntMap (RtsSpark, RtsSpark))
--, dInitExitT     -- naturally excluded from eventlog
  , dMutTime       :: Maybe Double
  , dGCTime        :: Maybe Double
  , dtotalTime     :: Maybe Double
  , dproductivity  :: Maybe Double
  }

data RtsSpark = RtsSpark
 { sparkCreated, sparkDud, sparkOverflowed
 , sparkConverted, sparkFizzled, sparkGCd :: !Timestamp
 }

data GcMode = ModeInit | ModeStart | ModeGHC | ModeEnd | ModeUnknown
  deriving Eq

data RtsGC = RtsGC
  { gcMode      :: !GcMode
  , gcStartTime :: !Timestamp
  , gcSeq       :: !Int
  , gcPar       :: !Int
  , gcElapsed   :: !Timestamp
  , gcMaxPause  :: !Timestamp
  }

emptySummaryData :: SummaryData
emptySummaryData = SummaryData
  { dallocTable    = IM.empty
  , dcopied        = Nothing
  , dmaxResidency  = Nothing
  , dmaxSlop       = Nothing
  , dmaxMemory     = Nothing
  , dmaxFrag       = Nothing
  , dGCTable       = IM.empty
  , dparBalance    = Nothing
  , dsparkTable    = IM.empty
  , dMutTime       = Nothing
  , dGCTime        = Nothing
  , dtotalTime     = Nothing
  , dproductivity  = Nothing
  }

defaultGC :: Timestamp -> RtsGC
defaultGC time = RtsGC
  { gcMode      = ModeInit
  , gcStartTime = time
  , gcSeq       = 0
  , gcPar       = 0
  , gcElapsed   = 0
  , gcMaxPause  = 0
  }

scanEvents :: SummaryData -> CapEvent -> SummaryData
scanEvents !summaryData (CapEvent mcap ev) =
  let -- For events that contain a counter with a running sum.
      -- Eventually we'll subtract the last found
      -- event from the first. Intervals beginning at time 0
      -- are a special case, because morally the first event should have
      -- value 0, but it may be absent, so we start with @Just (0, 0)@.
      alterCounter n Nothing = Just (n, n)
      alterCounter n (Just (_previous, first)) = Just (n, first)
      -- For events that contain discrete increments. We assume the event
      -- is emitted close to the end of the process it measures,
      -- so we ignore the first found event, because most of the process
      -- could have happened before the start of the current inverval.
      -- This is consistent with @alterCounter@. For interval beginning
      -- at time 0, we start with @Just 0@.
      alterIncrement _ Nothing = Just 0
      alterIncrement n (Just k) = Just (k + n)
      -- For events that contain sampled values, where a max is sought.
      alterMax n Nothing = Just n
      alterMax n (Just k) | n > k = Just n
      alterMax _ jk = jk
      -- Scan events, updating summary data.
      scan cap !sd@SummaryData{..} Event{time, spec} =
        let capGC = IM.findWithDefault (defaultGC time) cap dGCTable
        in case spec of
          -- TODO: check EventBlock elsewhere; define {map,fold}EventBlock
          EventBlock{cap = bcap, block_events} ->
            L.foldl' (scan bcap) sd block_events
          HeapAllocated{allocBytes} ->
            sd { dallocTable =
                   IM.alter (alterCounter allocBytes) cap dallocTable }
          HeapLive{liveBytes} ->
            sd { dmaxResidency = alterMax liveBytes dmaxResidency}
          HeapSize{sizeBytes} ->
            sd { dmaxMemory = alterMax sizeBytes dmaxMemory}
          StartGC ->
            assert (gcMode capGC `elem` [ModeInit, ModeEnd, ModeUnknown]) $
            let newGC = capGC { gcMode = ModeStart
                              , gcStartTime = time
                              }
            -- TODO: Index with generations, not caps.
            in sd { dGCTable = IM.insert cap newGC dGCTable }
          GCStatsGHC{..} ->
            -- All caps must be stopped. Those that take part in the GC
            -- are in ModeInit or ModeStart, those that do not
            -- are in ModeInit or ModeEnd or ModeUnknown.
            assert (L.all ((/= ModeGHC) . gcMode) (IM.elems dGCTable)) $
            sd { dcopied  = alterIncrement copied dcopied
               , dmaxSlop = alterMax slop dmaxSlop
               , dmaxFrag = alterMax frag dmaxFrag  -- TODO
               , dGCTable = IM.map setParSeq dGCTable
               }
             where
              someInit = L.any ((== ModeInit) . gcMode) (IM.elems dGCTable)
              setParSeq dGC
                -- If even any cap could possibly have started GC before
                -- the start of the interval, skip the GC.
                -- TODO: we could be smarter and defer the decision to EndGC,
                -- when we can deduce if the suspect caps take part in GC
                -- or not at all.
                | someInit = dGC { gcMode = ModeUnknown }
                | otherwise = case gcMode dGC of
                  -- Cap takes part in the seq GC.
                  ModeStart | parNThreads == 1 ->
                    dGC { gcMode = ModeGHC
                        , gcSeq = gcSeq dGC + 1
                        }
                  -- Cap takes part in the par GC.
                  ModeStart ->
                    assert (parNThreads > 1) $
                    dGC { gcMode = ModeGHC
                        , gcPar = gcPar dGC + 1
                        }
                  -- Cap not in the GC, leave it alone.
                  ModeEnd -> dGC
                  -- Cap not in the GC, clear its mode.
                  ModeUnknown -> dGC { gcMode = ModeEnd }
                  -- Impossible.
                  ModeInit -> error $ "scanEvents: ModeInit"
                  ModeGHC  -> error $ "scanEvents: ModeGHC"
          EndGC ->
            assert (gcMode capGC `notElem` [ModeStart, ModeEnd]) $
            let duration = time - gcStartTime capGC
                endedGC = capGC { gcMode = ModeEnd }
                timeGC = endedGC { gcElapsed = gcElapsed capGC + duration
                                 , gcMaxPause = max (gcMaxPause capGC) duration
                                 }
            in case gcMode capGC of
                 -- We don't know the exact timing of this GC started before
                 -- the selected interval, so we skip it and clear its mode.
                 ModeInit -> sd { dGCTable = IM.insert cap endedGC dGCTable }
                 ModeUnknown -> sd { dGCTable = IM.insert cap endedGC dGCTable}
                 -- All is known, so we update the times.
                 ModeGHC -> sd { dGCTable = IM.insert cap timeGC dGCTable }
                 _ -> error "scanEvents: impossible gcMode"
          SparkCounters crt dud ovf cnv fiz gcd _rem ->
            -- We are guranteed the first spark counters event has all zeroes,
            -- do we don't need to rig the counters for maximal interval.
            let current = RtsSpark crt dud ovf cnv fiz gcd
            in sd { dsparkTable =
                      IM.alter (alterCounter current) cap dsparkTable }
          _ -> sd
    in scan (fromJust mcap) summaryData ev

ppWithCommas :: Word64 -> String
ppWithCommas =
  let spl [] = []
      spl l  = let (c3, cs) = L.splitAt 3 l
               in c3 : spl cs
  in L.reverse . L.intercalate "," . spl . L.reverse . show

printW :: String -> Maybe Word64 -> [String]
printW _ Nothing = []
printW s (Just w) = [printf s $ ppWithCommas w]

memLines :: SummaryData -> [String]
memLines SummaryData{..} =
  printW "%16s bytes allocated in the heap"
    (Just $ L.sum $ L.map (uncurry (-)) $ IM.elems dallocTable) ++
  printW "%16s bytes copied during GC" dcopied ++
  printW "%16s bytes maximum residency" dmaxResidency ++
  printW "%16s bytes maximum slop" dmaxSlop ++
  printf ("%16d MB total memory in use "
          ++ printf "(%d MB lost due to fragmentation)"
                (fromMaybe 0 dmaxFrag `div` (1024 * 1024)))
         (fromMaybe 0 dmaxMemory `div` (1024 * 1024)) :
  [""]

timeToSecondsDbl :: Integral a => a -> Double
timeToSecondsDbl t = fromIntegral t / tIME_RESOLUTION
 where tIME_RESOLUTION = 1000000

gcLines :: SummaryData -> (Double, [String])
gcLines SummaryData{dGCTable} =
  let gcLine :: Int -> RtsGC -> String
      gcLine k = displayGCCounter (printf "GC HEC %d" k)
      gcSum = sumGCCounters $ IM.elems dGCTable
      -- TODO: sort by gen, not by cap
      sumGCCounters l =
        let sumPr proj = L.sum $ L.map proj l
        in RtsGC
             ModeInit 0 (sumPr gcSeq) (sumPr gcPar) (sumPr gcElapsed)
             (L.maximum $ 0 : map gcMaxPause l)
      displayGCCounter :: String -> RtsGC -> String
      displayGCCounter header RtsGC{..} =
        let gcColls = gcSeq + gcPar
            gcElapsedS = timeToSecondsDbl gcElapsed
            gcMaxPauseS = timeToSecondsDbl gcMaxPause
            gcAvgPauseS
              | gcColls == 0 = 0
              | otherwise = gcElapsedS / fromIntegral gcColls
        in printf "  %s  Gen 0+1  %5d colls, %5d par      %5.2fs          %3.4fs    %3.4fs" header gcColls gcPar gcElapsedS gcAvgPauseS gcMaxPauseS
  in (timeToSecondsDbl $ gcElapsed gcSum,  -- TODO: do not add HECs
      ["                                            Tot elapsed time   Avg pause  Max pause"] ++
      IM.elems (IM.mapWithKey gcLine dGCTable) ++
      [displayGCCounter "GC TOTAL" gcSum] ++
      [""])

sparkLines :: SummaryData -> [String]
sparkLines SummaryData{dsparkTable} =
  let diffSparks (RtsSpark crt1 dud1 ovf1 cnv1 fiz1 gcd1,
                  RtsSpark crt2 dud2 ovf2 cnv2 fiz2 gcd2) =
        RtsSpark (crt1 - crt2) (dud1 - dud2) (ovf1 - ovf2)
                 (cnv1 - cnv2) (fiz1 - fiz2) (gcd1 - gcd2)
      dsparkDiff = IM.map diffSparks dsparkTable
      sparkLine :: Int -> RtsSpark -> String
      sparkLine k = displaySparkCounter (printf "SPARKS HEC %d" k)
      sparkSum = sumSparkCounters $ IM.elems dsparkDiff
      sumSparkCounters l =
        let sumPr proj = L.sum $ L.map proj l
        in RtsSpark
             (sumPr sparkCreated) (sumPr sparkDud) (sumPr sparkOverflowed)
             (sumPr sparkConverted) (sumPr sparkFizzled) (sumPr sparkGCd)
      displaySparkCounter :: String -> RtsSpark -> String
      displaySparkCounter header RtsSpark{..} =
        printf "  %s: %7d (%7d converted, %7d overflowed, %7d dud, %7d GC'd, %7d fizzled)" header (sparkCreated + sparkDud + sparkOverflowed) sparkConverted sparkOverflowed sparkDud sparkGCd sparkFizzled
  in IM.elems (IM.mapWithKey sparkLine dsparkDiff) ++
     [displaySparkCounter "SPARKS TOTAL" sparkSum] ++
     [""]

summaryViewProcessEvents :: Maybe Interval -> Maybe (Array Int CapEvent)
                         -> (String, Maybe (Array Int CapEvent))
summaryViewProcessEvents _ Nothing = ("", Nothing)
summaryViewProcessEvents minterval (Just events) =
  let start =
        if istart == 0
        then -- Intervals beginning at time 0 are a special case,
             -- because morally the first event should have value 0,
             -- but it may be absent, so we start with 0.
             emptySummaryData
               { dallocTable = -- a hack: we assume no more than 999 caps
                   IM.fromDistinctAscList $ zip [0..999] $ repeat (0, 0)
               , dcopied = Just 0
               }
        else emptySummaryData
      eventBlockEnd e | EventBlock{ end_time=t } <- spec $ ce_event e = t
      eventBlockEnd e = time $ ce_event e
      -- Warning: stack overflow when done like in ReadEvents.hs:
      fx acc e = max acc (eventBlockEnd e)
      lastTx = L.foldl' fx 1 (elems $ events)
      (istart, iend) = fromMaybe (0, lastTx) minterval
      f summaryData CapEvent{ce_event=Event{time}}
        | time < istart || time > iend = summaryData
      f summaryData ev = scanEvents summaryData ev
      sd@SummaryData{..} = L.foldl' f start $ elems $ events
      totalElapsed = timeToSecondsDbl $ iend - istart
      (gcTotalElapsed, gcLines_sd) = gcLines sd
      mutElapsed = totalElapsed - gcTotalElapsed
      totalAllocated =
        fromIntegral $ L.sum $ L.map (uncurry (-)) $ IM.elems dallocTable
      allocRate = ppWithCommas $ truncate $ totalAllocated / mutElapsed
      timeLines =
        [ printf "  MUT     time  %6.2fs elapsed" mutElapsed
        , printf "  GC      time  %6.2fs elapsed" gcTotalElapsed
        , printf "  Total   time  %6.2fs elapsed" totalElapsed
        , ""
        , printf "  Alloc rate    %s bytes per MUT second" allocRate
        , ""
        , printf "  Productivity %.1f%% of total elapsed" $
            mutElapsed * 100 / totalElapsed
        ]
      info = unlines $ memLines sd ++ gcLines_sd ++ sparkLines sd ++ timeLines
  in (info, Just events)

summaryViewSetEvents :: SummaryView -> Maybe (Array Int CapEvent) -> IO ()
summaryViewSetEvents = genericSetEvents (summaryViewProcessEvents Nothing)
