{-# LANGUAGE CPP, OverloadedStrings, RecordWildCards, LambdaCase #-}
module Main (main) where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
import Data.Monoid (mappend)
#endif
import qualified Control.Concurrent.Async as Async
import Control.Exception (try)
import Control.Concurrent
import Control.Monad
import Control.Monad.Trans
import qualified Data.List as L
import Data.Time
import Data.Time.Clock.POSIX
import qualified Test.Framework as Test (Test, defaultMain)
import qualified Test.Framework.Providers.HUnit as Test (testCase)
import qualified Test.HUnit as HUnit

import Database.Redis
import PubSubTest

------------------------------------------------------------------------------
-- Main and helpers
--
main :: IO ()
main = do
    conn <- connectCluster defaultConnectInfo {
            connectPort = PortNumber 7000
        }
    Test.defaultMain (tests conn)

type Test = Connection -> Test.Test

testCase :: String -> Redis () -> Test
testCase name r conn = Test.testCase name $ do
    withTimeLimit 0.5 $ runRedis conn $ resetDB >> r
  where
    resetDB = do
        del ["key"]
        del ["set"]
        del ["{9}key", "{9}key'"]
        del ["{1}set", "{1}set'"]
        del ["{1}s1", "{1}s2", "{1}s3"]
        del ["{1}hll1", "{1}hll2", "{1}hll3"]
        del ["hash"]
        del ["{1}k1", "{1}k2", "{1}k3"]
    withTimeLimit limit act = do
        start <- getCurrentTime
        _ <- act
        deltaT <-fmap (`diffUTCTime` start) getCurrentTime
        when (deltaT > limit) $
            putStrLn $ name ++ ": " ++ show deltaT

(>>=?) :: (Eq a, Show a) => Redis (Either Reply a) -> a -> Redis ()
redis >>=? expected = do
    a <- redis
    liftIO $ case a of
        Left reply   -> HUnit.assertFailure $ "Redis error: " ++ show reply
        Right actual -> expected HUnit.@=? actual

assert :: Bool -> Redis ()
assert = liftIO . HUnit.assert

------------------------------------------------------------------------------
-- Tests
--
tests :: Connection -> [Test.Test]
tests conn = map ($conn) $ concat
    [ testsMisc, testsKeys, testsStrings, [testHashes], testsLists, testsSets, [testHyperLogLog]
    , testsZSets, [testTransaction], [testScripting]
    , testsServer, [testZrangelex]
    -- NOTE: not supported in a redis cluster
    -- , [testXAddRead, testXReadGroup, testXRange, testXpending, testXClaim, testXInfo, testXDel, testXTrim]
    , testPubSubThreaded
      -- should always be run last as connection gets closed after it
    , [testQuit]
    ]

------------------------------------------------------------------------------
-- Miscellaneous
--
testsMisc :: [Test]
testsMisc =
    [ testConstantSpacePipelining, testForceErrorReply, testPipelining
    , testEvalReplies
    ]

testConstantSpacePipelining :: Test
testConstantSpacePipelining = testCase "constant-space pipelining" $ do
    -- This testcase should not exceed the maximum heap size, as set in
    -- the run-test.sh script.
    replicateM_ 100000 ping
    -- If the program didn't crash, pipelining takes constant memory.
    assert True

testForceErrorReply :: Test
testForceErrorReply = testCase "force error reply" $ do
    set "key" "value" >>= \case
      Left _ -> error "impossible"
      _ -> return ()
    -- key is not a hash -> wrong kind of value
    reply <- hkeys "key"
    assert $ case reply of
        Left (Error _) -> True
        _              -> False

testPipelining :: Test
testPipelining = testCase "pipelining" $ do
    let n = 100
    tPipe <- deltaT $ do
        pongs <- replicateM n ping
        assert $ pongs == replicate n (Right Pong)

    tNoPipe <- deltaT $ replicateM_ n (ping >>=? Pong)
    -- pipelining should at least be twice as fast.
    assert $ tNoPipe / tPipe > 2
  where
    deltaT redis = do
        start <- liftIO $ getCurrentTime
        _ <- redis
        liftIO $ fmap (`diffUTCTime` start) getCurrentTime

testEvalReplies :: Test
testEvalReplies conn = testCase "eval unused replies" go conn
  where
    go = do
      _ <- liftIO $ runRedis conn $ set "key" "value"
      result <- liftIO $ do
         threadDelay $ 10 ^ (5 :: Int)
         mvar <- newEmptyMVar
         _ <-
           (Async.wait =<< Async.async (runRedis conn (get "key"))) >>= putMVar mvar
         takeMVar mvar
      pure result >>=? Just "value"

------------------------------------------------------------------------------
-- Keys
--
testsKeys :: [Test]
testsKeys = [ testKeys, testExpireAt, testSort, testGetType, testObject ]

testKeys :: Test
testKeys = testCase "keys" $ do
    set "{9}key" "value"     >>=? Ok
    get "{9}key"             >>=? Just "value"
    exists "{9}key"          >>=? True
    -- NOTE randomkey, move and select can't be tested in a cluster
    -- randomkey             >>=? Just "key"
    -- move "{9}key" 13         >>=? True
    -- select 13             >>=? Ok
    expire "{9}key" 1        >>=? True
    pexpire "{9}key" 1000    >>=? True
    ttl "{9}key" >>= \case
      Left _ -> error "error"
      Right t -> do
        assert $ t `elem` [0..1]
        pttl "{9}key" >>= \case
          Left _ -> error "error"
          Right pt -> do
            assert $ pt `elem` [990..1000]
            persist "{9}key"         >>=? True
            dump "{9}key" >>= \case
              Left _ -> error "impossible"
              Right s -> do
                restore "{9}key'" 0 s    >>=? Ok
                rename "{9}key" "{9}key'"   >>=? Ok
                renamenx "{9}key'" "{9}key" >>=? True
                del ["{9}key"]           >>=? 1
                select 0              >>=? Ok

testExpireAt :: Test
testExpireAt = testCase "expireat" $ do
    set "key" "value"             >>=? Ok
    t <- ceiling . utcTimeToPOSIXSeconds <$> liftIO getCurrentTime
    let expiry = t+1
    expireat "key" expiry         >>=? True
    pexpireat "key" (expiry*1000) >>=? True

testSort :: Test
testSort = testCase "sort" $ do
    lpush "{1}k1"     ["1","2","3"]                >>=? 3
    sort "{1}k1" defaultSortOpts                   >>=? ["1","2","3"]
    sortStore "{1}k1" "{1}k2" defaultSortOpts >>=? 3
    mset
         [("{1}weight_1","1")
         ,("{1}weight_2","2")
         ,("{1}weight_3","3")
         ,("{1}object_1","foo")
         ,("{1}object_2","bar")
         ,("{1}object_3","baz")
         ] >>= \case
      Left _ -> error "error"
      _ -> return ()
    -- NOTE sort options not supported in a cluster.
    -- Is this correct?
    -- let opts = defaultSortOpts { sortOrder = Desc, sortAlpha = True
    --                            , sortLimit = (1,2)
    --                            , sortBy    = Just "weight_*"
    --                            , sortGet   = ["#", "object_*"] }
    -- sort "{1}k1" opts >>=? ["2", "bar", "1", "foo"]


testGetType :: Test
testGetType = testCase "getType" $ do
    getType "key"     >>=? None
    forM_ ts $ \(setKey, typ) -> do
        setKey
        getType "key" >>=? typ
        del ["key"]   >>=? 1
  where
    ts = [ (set "key" "value"                         >>=? Ok,   String)
         , (hset "key" "field" "value"                >>=? True, Hash)
         , (lpush "key" ["value"]                     >>=? 1,    List)
         , (sadd "key" ["member"]                     >>=? 1,    Set)
         , (zadd "key" [(42,"member"),(12.3,"value")] >>=? 2,    ZSet)
         ]

testObject :: Test
testObject = testCase "object" $ do
    set "key" "value"    >>=? Ok
    objectRefcount "key" >>=? 1
    objectEncoding "key" >>= \case
      Left _ -> error "error"
      _ -> return ()
    objectIdletime "key" >>=? 0

------------------------------------------------------------------------------
-- Strings
--
testsStrings :: [Test]
testsStrings = [testStrings, testBitops]

testStrings :: Test
testStrings = testCase "strings" $ do
    setnx "key" "value"                     >>=? True
    setnx "key" "value"                     >>=? False
    getset "key" "hello"                    >>=? Just "value"
    append "key" "world"                    >>=? 10
    strlen "key"                            >>=? 10
    setrange "key" 0 "hello"                >>=? 10
    getrange "key" 0 4                      >>=? "hello"
    mset [("{1}k1","v1"), ("{1}k2","v2")]   >>=? Ok
    msetnx [("{1}k1","v1"), ("{1}k2","v2")] >>=? False
    mget ["key"]                            >>=? [Just "helloworld"]
    setex "key" 1 "42"                      >>=? Ok
    psetex "key" 1000 "42"                  >>=? Ok
    decr "key"                              >>=? 41
    decrby "key" 1                          >>=? 40
    incr "key"                              >>=? 41
    incrby "key" 1                          >>=? 42
    incrbyfloat "key" 1                     >>=? 43
    del ["key"]                             >>=? 1
    setbit "key" 42 "1"                     >>=? 0
    getbit "key" 42                         >>=? 1
    bitcount "key"                          >>=? 1
    bitcountRange "key" 0 (-1)              >>=? 1

testBitops :: Test
testBitops = testCase "bitops" $ do
    set "{1}k1" "a"                     >>=? Ok
    set "{1}k2" "b"                     >>=? Ok
    bitopAnd "{1}k3" ["{1}k1", "{1}k2"] >>=? 1
    bitopOr "{1}k3" ["{1}k1", "{1}k2"]  >>=? 1
    bitopXor "{1}k3" ["{1}k1", "{1}k2"] >>=? 1
    bitopNot "{1}k3" "{1}k1"            >>=? 1

------------------------------------------------------------------------------
-- Hashes
--
testHashes :: Test
testHashes = testCase "hashes" $ do
    hset "key" "field" "value"   >>=? True
    hsetnx "key" "field" "value" >>=? False
    hexists "key" "field"        >>=? True
    hlen "key"                   >>=? 1
    hget "key" "field"           >>=? Just "value"
    hmget "key" ["field", "-"]   >>=? [Just "value", Nothing]
    hgetall "key"                >>=? [("field","value")]
    hkeys "key"                  >>=? ["field"]
    hvals "key"                  >>=? ["value"]
    hdel "key" ["field"]         >>=? 1
    hmset "key" [("field","40")] >>=? Ok
    hincrby "key" "field" 2      >>=? 42
    hincrbyfloat "key" "field" 2 >>=? 44

------------------------------------------------------------------------------
-- Lists
--
testsLists :: [Test]
testsLists =
    [testLists, testBpop]

testLists :: Test
testLists = testCase "lists" $ do
    lpushx "notAKey" "-"          >>=? 0
    rpushx "notAKey" "-"          >>=? 0
    lpush "key" ["value"]         >>=? 1
    lpop "key"                    >>=? Just "value"
    rpush "key" ["value"]         >>=? 1
    rpop "key"                    >>=? Just "value"
    rpush "key" ["v2"]            >>=? 1
    linsertBefore "key" "v2" "v1" >>=? 2
    linsertAfter "key" "v2" "v3"  >>=? 3
    lindex "key" 0                >>=? Just "v1"
    lrange "key" 0 (-1)           >>=? ["v1", "v2", "v3"]
    lset "key" 1 "v2"             >>=? Ok
    lrem "key" 0 "v2"             >>=? 1
    llen "key"                    >>=? 2
    ltrim "key" 0 1               >>=? Ok

testBpop :: Test
testBpop = testCase "blocking push/pop" $ do
    lpush "{1}k3" ["v3","v2","v1"] >>=? 3
    blpop ["{1}k3"] 1              >>=? Just ("{1}k3","v1")
    brpop ["{1}k3"] 1              >>=? Just ("{1}k3","v3")
    rpush "{1}k1" ["v1","v2"]       >>=? 2
    brpoplpush "{1}k1" "{1}k2" 1       >>=? Just "v2"
    rpoplpush "{1}k1" "{1}k2"          >>=? Just "v1"

------------------------------------------------------------------------------
-- Sets
--
testsSets :: [Test]
testsSets = [testSets, testSetAlgebra]

testSets :: Test
testSets = testCase "sets" $ do
    sadd "set" ["member"]       >>=? 1
    sismember "set" "member"    >>=? True
    scard "set"                 >>=? 1
    smembers "set"              >>=? ["member"]
    srandmember "set"           >>=? Just "member"
    spop "set"                  >>=? Just "member"
    srem "set" ["member"]       >>=? 0
    smove "{1}set" "{1}set'" "member" >>=? False
    _ <- sadd "set" ["member1", "member2"]
    (fmap L.sort <$> spopN "set" 2) >>=? ["member1", "member2"]
    _ <- sadd "set" ["member1", "member2"]
    (fmap L.sort <$> srandmemberN "set" 2) >>=? ["member1", "member2"]

testSetAlgebra :: Test
testSetAlgebra = testCase "set algebra" $ do
    sadd "{1}s1" ["member"]          >>=? 1
    sdiff ["{1}s1", "{1}s2"]            >>=? ["member"]
    sunion ["{1}s1", "{1}s2"]           >>=? ["member"]
    sinter ["{1}s1", "{1}s2"]           >>=? []
    sdiffstore "{1}s3" ["{1}s1", "{1}s2"]  >>=? 1
    sunionstore "{1}s3" ["{1}s1", "{1}s2"] >>=? 1
    sinterstore "{1}s3" ["{1}s1", "{1}s2"] >>=? 0

------------------------------------------------------------------------------
-- Sorted Sets
--
testsZSets :: [Test]
testsZSets = [testZSets, testZStore]

testZSets :: Test
testZSets = testCase "sorted sets" $ do
    zadd "key" [(1,"v1"),(2,"v2"),(40,"v3")]          >>=? 3
    zcard "key"                                       >>=? 3
    zscore "key" "v3"                                 >>=? Just 40
    zincrby "key" 2 "v3"                              >>=? 42

    zrank "key" "v1"                                  >>=? Just 0
    zrevrank "key" "v1"                               >>=? Just 2
    zcount "key" 10 100                               >>=? 1

    zrange "key" 0 1                                  >>=? ["v1","v2"]
    zrevrange "key" 0 1                               >>=? ["v3","v2"]
    zrangeWithscores "key" 0 1                        >>=? [("v1",1),("v2",2)]
    zrevrangeWithscores "key" 0 1                     >>=? [("v3",42),("v2",2)]
    zrangebyscore "key" 0.5 1.5                       >>=? ["v1"]
    zrangebyscoreWithscores "key" 0.5 1.5             >>=? [("v1",1)]
    zrangebyscoreWithscores "key" (-inf) inf          >>=? [("v1",1.0),("v2",2.0),("v3",42.0)]
    zrangebyscoreLimit "key" 0.5 2.5 0 1              >>=? ["v1"]
    zrangebyscoreWithscoresLimit "key" 0.5 2.5 0 1    >>=? [("v1",1)]
    zrevrangebyscore "key" 1.5 0.5                    >>=? ["v1"]
    zrevrangebyscoreWithscores "key" 1.5 0.5          >>=? [("v1",1)]
    zrevrangebyscoreLimit "key" 2.5 0.5 0 1           >>=? ["v2"]
    zrevrangebyscoreWithscoresLimit "key" 2.5 0.5 0 1 >>=? [("v2",2)]

    zrem "key" ["v2"]                                 >>=? 1
    zremrangebyscore "key" 10 100                     >>=? 1
    zremrangebyrank "key" 0 0                         >>=? 1

testZStore :: Test
testZStore = testCase "zunionstore/zinterstore" $ do
    zadd "{1}k1" [(1, "v1"), (2, "v2")] >>= \case
      Left _ -> error "error"
      _ -> return ()
    zadd "{1}k2" [(2, "v2"), (3, "v3")] >>= \case
      Left _ -> error "error"
      _ -> return ()
    zinterstore "{1}key'" ["{1}k1","{1}k2"] Sum                >>=? 1
    zinterstoreWeights "{1}key'" [("{1}k1",1),("{1}k2",2)] Max >>=? 1
    zunionstore "{1}key'" ["{1}k1","{1}k2"] Sum                >>=? 3
    zunionstoreWeights "{1}key'" [("{1}k1",1),("{1}k2",2)] Min >>=? 3

------------------------------------------------------------------------------
-- HyperLogLog
--

testHyperLogLog :: Test
testHyperLogLog = testCase "hyperloglog" $ do
  -- test creation
  pfadd "{1}hll1" ["a"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfcount ["{1}hll1"] >>=? 1
  -- test cardinality
  pfadd "{1}hll1" ["a"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfcount ["{1}hll1"] >>=? 1
  pfadd "{1}hll1" ["b", "c", "foo", "bar"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfcount ["{1}hll1"] >>=? 5
  -- test merge
  pfadd "{1}hll2" ["1", "2", "3"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfadd "{1}hll3" ["4", "5", "6"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfmerge "{1}hll4" ["{1}hll2", "{1}hll3"] >>= \case
      Left _ -> error "error"
      _ -> return ()
  pfcount ["{1}hll4"] >>=? 6
  -- test union cardinality
  pfcount ["{1}hll2", "{1}hll3"] >>=? 6


------------------------------------------------------------------------------
-- Transaction
--
testTransaction :: Test
testTransaction = testCase "transaction" $ do
    watch ["{1}k1", "{1}k2"] >>=? Ok
    unwatch            >>=? Ok
    set "{1}k1" "foo" >>= \case
      Left _ -> error "error"
      _ -> return ()
    set "{1}k2" "bar" >>= \case
      Left _ -> error "error"
      _ -> return ()
    k1k2 <- multiExec $ do
        k1 <- get "{1}k1"
        k2 <- get "{1}k2"
        return $ (,) <$> k1 <*> k2
    assert $ k1k2 == TxSuccess (Just "foo", Just "bar")


------------------------------------------------------------------------------
-- Scripting
--
testScripting :: Test
testScripting conn = testCase "scripting" go conn
  where
    go = do
        let script    = "return {false, 42}"
            scriptRes = (False, 42 :: Integer)
        scriptLoad script >>= \case
          Left _ -> error "error"
          Right scriptHash -> do
            eval script [] []                       >>=? scriptRes
            evalsha scriptHash [] []                >>=? scriptRes
            scriptExists [scriptHash, "notAScript"] >>=? [True, False]
            scriptFlush                             >>=? Ok
            -- start long running script from another client
            configSet "lua-time-limit" "100"        >>=? Ok
            evalFinished <- liftIO newEmptyMVar
            asyncScripting <- liftIO $ Async.async $ runRedis conn $ do
                -- we must pattern match to block the thread
                (eval "while true do end" [] []
                    :: Redis (Either Reply Integer)) >>= \case
                    Left _ -> return ()
                    _ -> error "impossible"
                liftIO (putMVar evalFinished ())
                return ()
            liftIO (threadDelay 500000) -- 0.5s
            scriptKill                              >>=? Ok
            () <- liftIO (takeMVar evalFinished)
            liftIO $ Async.wait asyncScripting
            return ()

------------------------------------------------------------------------------
-- Connection
--
testsConnection :: [Test]
testsConnection = [ testConnectAuth, testConnectAuthUnexpected, testConnectDb
                  , testConnectDbUnexisting, testEcho, testPing, testSelect ]

testConnectAuth :: Test
testConnectAuth = testCase "connect/auth" $ do
    configSet "requirepass" "pass" >>=? Ok
    liftIO $ do
        c <- checkedConnect defaultConnectInfo { connectAuth = Just "pass" }
        runRedis c (ping >>=? Pong)
    auth "pass"                    >>=? Ok
    configSet "requirepass" ""     >>=? Ok

testConnectAuthUnexpected :: Test
testConnectAuthUnexpected = testCase "connect/auth/unexpected" $ do
    liftIO $ do
        res <- try $ void $ checkedConnect connInfo
        HUnit.assertEqual "" err res

    where connInfo = defaultConnectInfo { connectAuth = Just "pass" }
          err = Left $ ConnectAuthError $
                  Error "ERR Client sent AUTH, but no password is set"

testConnectDb :: Test
testConnectDb = testCase "connect/db" $ do
    set "connect" "value" >>=? Ok
    liftIO $ void $ do
        c <- checkedConnect defaultConnectInfo { connectDatabase = 1 }
        runRedis c (get "connect" >>=? Nothing)

testConnectDbUnexisting :: Test
testConnectDbUnexisting = testCase "connect/db/unexisting" $ do
    liftIO $ do
        res <- try $ void $ checkedConnect connInfo
        case res of
          Left (ConnectSelectError _) -> return ()
          _ -> HUnit.assertFailure $
                  "Expected ConnectSelectError, got " ++ show res

    where connInfo = defaultConnectInfo { connectDatabase = 100 }

testEcho :: Test
testEcho = testCase "echo" $
    echo ("value" ) >>=? "value"

testPing :: Test
testPing = testCase "ping" $ ping >>=? Pong

testQuit :: Test
testQuit = testCase "quit" $ quit >>=? Ok

testSelect :: Test
testSelect = testCase "select" $ do
    select 13 >>=? Ok
    select 0 >>=? Ok


------------------------------------------------------------------------------
-- Server
--
testsServer :: [Test]
testsServer =
    [testBgrewriteaof, testFlushall, testInfo
    ,testSlowlog, testDebugObject]

testBgrewriteaof :: Test
testBgrewriteaof = testCase "bgrewriteaof/bgsave/save" $ do
    save >>=? Ok
    bgsave >>= \case
      Right (Status _) -> return ()
      _ -> error "error"
    -- Redis needs time to finish the bgsave
    liftIO $ threadDelay (10^(5 :: Int))
    bgrewriteaof >>= \case
      Right (Status _) -> return ()
      _ -> error "error"
    return ()

testConfig :: Test
testConfig = testCase "config/auth" $ do
    configGet "requirepass"        >>=? [("requirepass", "")]
    configSet "requirepass" "pass" >>=? Ok
    auth "pass"                    >>=? Ok
    configSet "requirepass" ""     >>=? Ok

testFlushall :: Test
testFlushall = testCase "flushall/flushdb" $ do
    flushall >>=? Ok
    flushdb  >>=? Ok

testInfo :: Test
testInfo = testCase "info/lastsave/dbsize" $ do
    info >>= \case
      Left _ -> error "error"
      _ -> return ()
    lastsave >>= \case
      Left _ -> error "error"
      _ -> return ()
    dbsize          >>=? 0
    configResetstat >>=? Ok

testSlowlog :: Test
testSlowlog = testCase "slowlog" $ do
    slowlogReset >>=? Ok
    slowlogGet 5 >>=? []
    slowlogLen   >>=? 0

testDebugObject :: Test
testDebugObject = testCase "debugObject/debugSegfault" $ do
    set "key" "value" >>=? Ok
    debugObject "key" >>= \case
      Left _ -> error "error"
      _ -> return ()
    return ()

testZrangelex ::Test
testZrangelex = testCase "zrangebylex" $ do
    let testSet = [(10, "aaa"), (10, "abb"), (10, "ccc"), (10, "ddd")]
    zadd "key" testSet                          >>=? 4
    zrangebylex "key" (Incl "aaa") (Incl "bbb") >>=? ["aaa","abb"]
    zrangebylex "key" (Excl "aaa") (Excl "ddd") >>=? ["abb","ccc"]
    zrangebylex "key" Minr Maxr                 >>=? ["aaa","abb","ccc","ddd"]
    zrangebylexLimit "key" Minr Maxr 2 1        >>=? ["ccc"]

testXAddRead ::Test
testXAddRead = testCase "xadd/xread" $ do
    xadd "somestream" "123" [("key", "value"), ("key2", "value2")]
    xadd "otherstream" "456" [("key1", "value1")]
    xaddOpts "thirdstream" "*" [("k", "v")] (Maxlen 1)
    xaddOpts "thirdstream" "*" [("k", "v")] (ApproxMaxlen 1)
    xread [("somestream", "0"), ("otherstream", "0")] >>=? Just [
        XReadResponse {
            stream = "somestream",
            records = [StreamsRecord{recordId = "123-0", keyValues = [("key", "value"), ("key2", "value2")]}]
        },
        XReadResponse {
            stream = "otherstream",
            records = [StreamsRecord{recordId = "456-0", keyValues = [("key1", "value1")]}]
        }]
    xlen "somestream" >>=? 1

testXReadGroup ::Test
testXReadGroup = testCase "XGROUP */xreadgroup/xack" $ do
    xadd "somestream" "123" [("key", "value")]
    xgroupCreate "somestream" "somegroup" "0"
    xreadGroup "somegroup" "consumer1" [("somestream", ">")] >>=? Just [
        XReadResponse {
            stream = "somestream",
            records = [StreamsRecord{recordId = "123-0", keyValues = [("key", "value")]}]
        }]
    xack "somestream" "somegroup" ["123-0"] >>=? 1
    xreadGroup "somegroup" "consumer1" [("somestream", ">")] >>=? Nothing
    xgroupSetId "somestream" "somegroup" "0" >>=? Ok
    xgroupDelConsumer "somestream" "somegroup" "consumer1" >>=? 0
    xgroupDestroy "somestream" "somegroup" >>=? True

testXRange ::Test
testXRange = testCase "xrange/xrevrange" $ do
    xadd "somestream" "121" [("key1", "value1")]
    xadd "somestream" "122" [("key2", "value2")]
    xadd "somestream" "123" [("key3", "value3")]
    xadd "somestream" "124" [("key4", "value4")]
    xrange "somestream" "122" "123" Nothing >>=? [
        StreamsRecord{recordId = "122-0", keyValues = [("key2", "value2")]},
        StreamsRecord{recordId = "123-0", keyValues = [("key3", "value3")]}
        ]
    xrevRange "somestream" "123" "122" Nothing >>=? [
        StreamsRecord{recordId = "123-0", keyValues = [("key3", "value3")]},
        StreamsRecord{recordId = "122-0", keyValues = [("key2", "value2")]}
        ]

testXpending ::Test
testXpending = testCase "xpending" $ do
    xadd "somestream" "121" [("key1", "value1")]
    xadd "somestream" "122" [("key2", "value2")]
    xadd "somestream" "123" [("key3", "value3")]
    xadd "somestream" "124" [("key4", "value4")]
    xgroupCreate "somestream" "somegroup" "0"
    xreadGroup "somegroup" "consumer1" [("somestream", ">")]
    xpendingSummary "somestream" "somegroup" Nothing >>=? XPendingSummaryResponse {
        numPendingMessages = 4,
        smallestPendingMessageId = "121-0",
        largestPendingMessageId = "124-0",
        numPendingMessagesByconsumer = [("consumer1", 4)]
    }
    detail <- xpendingDetail "somestream" "somegroup" "121" "121" 10 Nothing
    liftIO $ case detail of
        Left reply   -> HUnit.assertFailure $ "Redis error: " ++ show reply
        Right [XPendingDetailRecord{..}] -> do
            messageId HUnit.@=? "121-0"
        Right bad -> HUnit.assertFailure $ "Unexpectedly got " ++ show bad

testXClaim ::Test
testXClaim =
  testCase "xclaim" $ do
    xadd "somestream" "121" [("key1", "value1")] >>=? "121-0"
    xadd "somestream" "122" [("key2", "value2")] >>=? "122-0"
    xgroupCreate "somestream" "somegroup" "0" >>=? Ok
    xreadGroupOpts
      "somegroup"
      "consumer1"
      [("somestream", ">")]
      (defaultXreadOpts {recordCount = Just 2}) >>=?
      Just
        [ XReadResponse
            { stream = "somestream"
            , records =
                [ StreamsRecord
                    {recordId = "121-0", keyValues = [("key1", "value1")]}
                , StreamsRecord
                    {recordId = "122-0", keyValues = [("key2", "value2")]}
                ]
            }
        ]
    xclaim "somestream" "somegroup" "consumer2" 0 defaultXClaimOpts ["121-0"] >>=?
      [StreamsRecord {recordId = "121-0", keyValues = [("key1", "value1")]}]
    xclaimJustIds
      "somestream"
      "somegroup"
      "consumer2"
      0
      defaultXClaimOpts
      ["122-0"] >>=?
      ["122-0"]

testXInfo ::Test
testXInfo = testCase "xinfo" $ do
    xadd "somestream" "121" [("key1", "value1")]
    xadd "somestream" "122" [("key2", "value2")]
    xgroupCreate "somestream" "somegroup" "0"
    xreadGroupOpts "somegroup" "consumer1" [("somestream", ">")] (defaultXreadOpts { recordCount = Just 2})
    consumerInfos <- xinfoConsumers "somestream" "somegroup"
    liftIO $ case consumerInfos of
        Left reply -> HUnit.assertFailure $ "Redis error: " ++ show reply
        Right [XInfoConsumersResponse{..}] -> do
            xinfoConsumerName HUnit.@=? "consumer1"
            xinfoConsumerNumPendingMessages HUnit.@=? 2
        Right bad -> HUnit.assertFailure $ "Unexpectedly got " ++ show bad
    xinfoGroups "somestream" >>=? [
        XInfoGroupsResponse{
            xinfoGroupsGroupName = "somegroup",
            xinfoGroupsNumConsumers = 1,
            xinfoGroupsNumPendingMessages = 2,
            xinfoGroupsLastDeliveredMessageId = "122-0"
        }]
    xinfoStream "somestream" >>=? XInfoStreamResponse
        { xinfoStreamLength = 2
        , xinfoStreamRadixTreeKeys = 1
        , xinfoStreamRadixTreeNodes = 2
        , xinfoStreamNumGroups = 1
        , xinfoStreamLastEntryId = "122-0"
        , xinfoStreamFirstEntry = StreamsRecord
            { recordId = "121-0"
            , keyValues = [("key1", "value1")]
            }
        , xinfoStreamLastEntry = StreamsRecord
            { recordId = "122-0"
            , keyValues = [("key2", "value2")]
            }
        }

testXDel ::Test
testXDel = testCase "xdel" $ do
    xadd "somestream" "121" [("key1", "value1")]
    xadd "somestream" "122" [("key2", "value2")]
    xdel "somestream" ["122"] >>=? 1
    xlen "somestream" >>=? 1

testXTrim ::Test
testXTrim = testCase "xtrim" $ do
    xadd "somestream" "121" [("key1", "value1")]
    xadd "somestream" "122" [("key2", "value2")]
    xadd "somestream" "123" [("key3", "value3")]
    xadd "somestream" "124" [("key4", "value4")]
    xadd "somestream" "125" [("key5", "value5")]
    xtrim "somestream" (Maxlen 2) >>=? 3
