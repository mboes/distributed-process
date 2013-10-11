{-# LANGUAGE DeriveDataTypeable        #-}
{-# OPTIONS_GHC -fno-warn-orphans      #-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , newMVar
  , putMVar
  , takeMVar
  )
import Control.Distributed.Process
import Control.Distributed.Process.Debug
import Control.Distributed.Process.Management
  ( MxEvent(..)
  )
import Control.Distributed.Process.Node
  ( forkProcess
  , closeLocalNode
  , LocalNode)
import qualified Network.Transport as NT

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch, log)
#endif

import Test.Framework
  ( Test
  , testGroup
  )
import Test.Framework.Providers.HUnit (testCase)
import TestUtils

testSpawnTracing :: TestResult Bool -> Process ()
testSpawnTracing result = do
  setTraceFlags defaultTraceFlags {
      traceSpawned = (Just TraceAll)
    , traceDied    = (Just TraceAll)
    }

  evSpawned <- liftIO $ newEmptyMVar
  evDied <- liftIO $ newEmptyMVar
  tracer <- startTracer $ \ev -> do
    case ev of
      (MxSpawned p)       -> liftIO $ putMVar evSpawned p
      (MxProcessDied p r) -> liftIO $ putMVar evDied (p, r)
      _ -> return ()

  (sp, rp) <- newChan
  pid <- spawnLocal $ sendChan sp ()
  () <- receiveChan rp

  tracedAlive <- liftIO $ takeMVar evSpawned
  (tracedDead, tracedReason) <- liftIO $ takeMVar evDied

  mref <- monitor tracer
  stopTracer -- this is asynchronous, so we need to wait...
  receiveWait [
      matchIf (\(ProcessMonitorNotification ref _ _) -> ref == mref)
              ((\_ -> return ()))
    ]
  setTraceFlags defaultTraceFlags
  stash result (tracedAlive  == pid &&
                tracedDead   == pid &&
                tracedReason == DiedNormal)

testTraceRecvExplicitPid :: TestResult Bool -> Process ()
testTraceRecvExplicitPid result = do
  res <- liftIO $ newEmptyMVar
  pid <- spawnLocal $ do
    self <- getSelfPid
    expect >>= (flip sendChan) self
  withFlags defaultTraceFlags {
    traceRecv = traceOnly [pid]
    } $ do
    withTracer
      (\ev ->
        case ev of
          (MxReceived pid' _) -> stash res (pid == pid')
          _                        -> return ()) $ do
        (sp, rp) <- newChan
        send pid sp
        p <- receiveChan rp
        res' <- liftIO $ takeMVar res
        stash result (res' && (p == pid))
  return ()

testTraceRecvNamedPid :: TestResult Bool -> Process ()
testTraceRecvNamedPid result = do
  res <- liftIO $ newEmptyMVar
  pid <- spawnLocal $ do
    self <- getSelfPid
    register "foobar" self
    expect >>= (flip sendChan) self
  withFlags defaultTraceFlags {
    traceRecv = traceOnly ["foobar"]
    } $ do
    withTracer
      (\ev ->
        case ev of
          (MxReceived pid' _) -> stash res (pid == pid')
          _                        -> return ()) $ do
        (sp, rp) <- newChan
        send pid sp
        p <- receiveChan rp
        res' <- liftIO $ takeMVar res
        stash result (res' && (p == pid))
  return ()

testTraceSending :: TestResult Bool -> Process ()
testTraceSending result = do
  pid <- spawnLocal $ (expect :: Process String) >> return ()
  self <- getSelfPid
  res <- liftIO $ newEmptyMVar
  withFlags defaultTraceFlags { traceSend = traceOn } $ do
    withTracer
      (\ev ->
        case ev of
          (MxSent to from msg) -> do
            let Just s = unwrapMessage msg :: Maybe String
            stash res (to == pid && from == self && s == "hello there")
            stash res (to == pid && from == self)
          _ ->
            return ()) $ do
        send pid "hello there"
  res' <- liftIO $ takeMVar res
  stash result res'

testTraceRegistration :: TestResult Bool -> Process ()
testTraceRegistration result = do
  (sp, rp) <- newChan
  pid <- spawnLocal $ do
    self <- getSelfPid
    () <- expect
    register "foobar" self
    sendChan sp ()
    () <- expect
    return ()
  res <- liftIO $ newEmptyMVar
  withFlags defaultTraceFlags { traceRegistered = traceOn } $ do
    withTracer
      (\ev ->
        case ev of
          MxRegistered p s ->
            stash res (p == pid && s == "foobar")
          _ ->
            return ()) $ do
        _ <- monitor pid
        send pid ()
        () <- receiveChan rp
        send pid ()
        receiveWait [
          match (\(ProcessMonitorNotification _ _ _) -> return ())
          ]
  res' <- liftIO $ takeMVar res
  stash result res'

testTraceUnRegistration :: TestResult Bool -> Process ()
testTraceUnRegistration result = do
  pid <- spawnLocal $ do
    () <- expect
    unregister "foobar"
    () <- expect
    return ()
  register "foobar" pid
  res <- liftIO $ newEmptyMVar
  withFlags defaultTraceFlags { traceUnregistered = traceOn } $ do
    withTracer
      (\ev ->
        case ev of
          MxUnRegistered p n -> do
            stash res (p == pid && n == "foobar")
            send pid ()
          _ ->
            return ()) $ do
        mref <- monitor pid
        send pid ()
        receiveWait [
          matchIf (\(ProcessMonitorNotification mref' _ _) -> mref == mref')
                  (\_ -> return ())
          ]
  res' <- liftIO $ takeMVar res
  stash result res'

testTraceLayering :: TestResult () -> Process ()
testTraceLayering result = do
  pid <- spawnLocal $ do
    getSelfPid >>= register "foobar"
    () <- expect
    traceMessage ("traceMsg", 123 :: Int)
    return ()
  withFlags defaultTraceFlags {
      traceDied = traceOnly [pid]
    , traceRecv = traceOnly ["foobar"]
    } $ doTest pid result
  return ()
  where
    doTest :: ProcessId -> MVar () -> Process ()
    doTest pid result' = do
      -- TODO: this is pretty gross, even for a test case
      died <- liftIO $ newEmptyMVar
      withTracer
       (\ev ->
         case ev of
           MxProcessDied _ _ -> liftIO $ putMVar died ()
           _                 -> return ())
       ( do {
           recv <- liftIO $ newEmptyMVar
         ; withTracer
            (\ev' ->
              case ev' of
                MxReceived _ _ -> liftIO $ putMVar recv ()
                _                   -> return ())
            ( do {
                user <- liftIO $ newEmptyMVar
              ; withTracer
                  (\ev'' ->
                    case ev'' of
                      MxUser _ -> liftIO $ putMVar user ()
                      _             -> return ())
                  (send pid () >> (liftIO $ takeMVar user))
              ; liftIO $ takeMVar recv
              })
         ; liftIO $ takeMVar died
         })
      liftIO $ putMVar result' ()

testRemoteTraceRelay :: TestResult Bool -> Process ()
testRemoteTraceRelay result =
  let flags = defaultTraceFlags { traceSpawned = traceOn }
  in do
    node2 <- liftIO $ mkNode "8082"
    mvNid <- liftIO $ newEmptyMVar

    -- As well as needing node2's NodeId, we want to
    -- redirect all its logs back here, to avoid generating
    -- garbage on stderr for the duration of the test run.
    -- Here we set up that relay, and then wait for a signal
    -- that the tracer (on node1) has seen the expected
    -- MxSpawned message, at which point we're finished
    (Just log') <- whereis "logger"
    pid <- liftIO $ forkProcess node2 $ do
      logRelay <- spawnLocal $ relay log'
      reregister "logger" logRelay
      getSelfNode >>= stash mvNid >> (expect :: Process ())

    nid <- liftIO $ takeMVar mvNid
    mref <- monitor pid
    observedPid <- liftIO $ newEmptyMVar
    spawnedPid <- liftIO $ newEmptyMVar
    setTraceFlagsRemote flags nid

    withFlags defaultTraceFlags { traceSpawned = traceOn } $ do
      withTracer
        (\ev ->
          case ev of
            MxSpawned p -> stash observedPid p >> send pid ()
            _                -> return ()) $ do
          relayPid <- startTraceRelay nid
          liftIO $ threadDelay 1000000
          p <- liftIO $ forkProcess node2 $ do
            expectTimeout 1000000 :: Process (Maybe ())
            return ()
          stash spawnedPid p

          -- Now we wait for (the outer) pid to exit. This won't happen until
          -- our tracer has seen the trace event for `p' and send `p' the
          -- message its waiting for prior to exiting
          receiveWait [
            matchIf (\(ProcessMonitorNotification mref' _ _) -> mref == mref')
                    (\_ -> return ())
            ]

          relayRef <- monitor relayPid
          kill relayPid "stop"
          receiveWait [
            matchIf (\(ProcessMonitorNotification rref' _ _) -> rref' == relayRef)
                    (\_ -> return ())
            ]
    observed <- liftIO $ takeMVar observedPid
    expected <- liftIO $ takeMVar spawnedPid
    stash result (observed == expected)
    -- and just to be polite...
    liftIO $ closeLocalNode node2

tests :: LocalNode -> IO [Test]
tests node1 = do
  -- if we execute the test cases in parallel, the
  -- various tracers will race with one another and
  -- we'll get garbage results (or worse, deadlocks)
  lock <- liftIO $ newMVar ()
  return [
    testGroup "Tracing" [
           testCase "Spawn Tracing"
             (synchronisedAssertion
              "expected dead process-info to be ProcessInfoNone"
              node1 True testSpawnTracing lock)
         , testCase "Recv Tracing (Explicit Pid)"
             (synchronisedAssertion
              "expected a recv trace for the supplied pid"
              node1 True testTraceRecvExplicitPid lock)
         , testCase "Recv Tracing (Named Pid)"
             (synchronisedAssertion
              "expected a recv trace for the process registered as 'foobar'"
              node1 True testTraceRecvNamedPid lock)
         , testCase "Trace Send(er)"
             (synchronisedAssertion
              "expected a 'send' trace with the requisite fields set"
              node1 True testTraceSending lock)
         , testCase "Trace Registration"
              (synchronisedAssertion
               "expected a 'registered' trace"
               node1 True testTraceRegistration lock)
         , testCase "Trace Unregistration"
              (synchronisedAssertion
               "expected an 'unregistered' trace"
               node1 True testTraceUnRegistration lock)
         , testCase "Trace Layering"
              (synchronisedAssertion
               "expected blah"
               node1 () testTraceLayering lock)
         , testCase "Remote Trace Relay"
              (synchronisedAssertion
               "expected blah"
               node1 True testRemoteTraceRelay lock)
         ] ]

timerTests :: NT.Transport -> IO [Test]
timerTests _ = do
  mkNode "8080" >>= tests >>= return

main :: IO ()
main = testMain $ timerTests
