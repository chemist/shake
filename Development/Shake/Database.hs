{-# LANGUAGE RecordWildCards, ScopedTypeVariables, PatternGuards #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving #-}

module Development.Shake.Database(
    Time, offsetTime, Duration, duration, Trace,
    Database, withDatabase,
    Ops(..), build, Depends,
    progress,
    Stack, emptyStack, showStack, topStack,
    showJSON, checkValid,
    ) where

import Development.Shake.Classes
import General.Binary
import Development.Shake.Pool
import Development.Shake.Value
import Development.Shake.Errors
import Development.Shake.Storage
import Development.Shake.Types
import Development.Shake.Special
import General.Base
import General.Intern as Intern

import Control.Exception
import Control.Monad
import qualified Data.HashSet as Set
import qualified Data.HashMap.Strict as Map
import Data.IORef
import Data.Maybe
import Data.List
import Data.Monoid

type Map = Map.HashMap


---------------------------------------------------------------------
-- UTILITY TYPES

newtype Step = Step Word32 deriving (Eq,Ord,Show,Binary,NFData,Hashable,Typeable)

incStep (Step i) = Step $ i + 1


---------------------------------------------------------------------
-- CALL STACK

data Stack = Stack (Maybe Key) [Id] !(Set.HashSet Id)

showStack :: Database -> Stack -> IO [String]
showStack Database{..} (Stack _ xs _) = do
    status <- withLock lock $ readIORef status
    return $ reverse $ map (maybe "<unknown>" (show . fst) . flip Map.lookup status) xs

addStack :: Id -> Key -> Stack -> Stack
addStack x key (Stack _ xs set) = Stack (Just key) (x:xs) (Set.insert x set)

topStack :: Stack -> String
topStack (Stack key _ _) = maybe "<unknown>" show key

checkStack :: [Id] -> Stack -> Maybe Id
checkStack new (Stack _ old set)
    | bad:_ <- filter (`Set.member` set) new = Just bad
    | otherwise = Nothing

emptyStack :: Stack
emptyStack = Stack Nothing [] Set.empty


---------------------------------------------------------------------
-- CENTRAL TYPES

type Trace = (BS, Time, Time) -- (message, start, end)

-- | Invariant: The database does not have any cycles when a Key depends on itself
data Database = Database
    {lock :: Lock
    ,intern :: IORef (Intern Key)
    ,status :: IORef (Map Id (Key, Status))
    ,step :: Step
    ,journal :: Id -> (Key, Status {- Loaded or Missing -}) -> IO ()
    ,diagnostic :: String -> IO () -- logging function
    ,assume :: Maybe Assume
    }

data Status
    = Ready Result -- I have a value
    | Error SomeException -- I have been run and raised an error
    | Loaded Result -- Loaded from the database
    | Waiting Pending (Maybe Result) -- Currently checking if I am valid or building
    | Missing -- I am only here because I got into the Intern table
      deriving Show

data Result = Result
    {result :: Value -- the result associated with the Key
    ,built :: {-# UNPACK #-} !Step -- when it was actually run
    ,changed :: {-# UNPACK #-} !Step -- the step for deciding if it's valid
    ,depends :: [[Id]] -- dependencies
    ,execution :: {-# UNPACK #-} !Duration -- how long it took when it was last run (seconds)
    ,traces :: [Trace] -- a trace of the expensive operations (start/end in seconds since beginning of run)
    } deriving Show


newtype Pending = Pending (IORef (IO ()))
    -- you must run this action when you finish, while holding DB lock
    -- after you have set the result to Error or Ready

instance Show Pending where show _ = "Pending"


statusType Ready{} = "Ready"
statusType Error{} = "Error"
statusType Loaded{} = "Loaded"
statusType Waiting{} = "Waiting"
statusType Missing{} = "Missing"

isError Error{} = True; isError _ = False
isWaiting Waiting{} = True; isWaiting _ = False
isReady Ready{} = True; isReady _ = False


-- All the waiting operations are only valid when isWaiting
type Waiting = Status

afterWaiting :: Waiting -> IO () -> IO ()
afterWaiting (Waiting (Pending p) _) act = modifyIORef'' p (>> act)

newWaiting :: Maybe Result -> IO Waiting
newWaiting r = do ref <- newIORef $ return (); return $ Waiting (Pending ref) r

runWaiting :: Waiting -> IO ()
runWaiting (Waiting (Pending p) _) = join $ readIORef p

-- Wait for a set of actions to complete
-- If the action returns True, the function will not be called again
-- If the first argument is True, the thing is ended
waitFor :: [(a, Waiting)] -> (Bool -> a -> IO Bool) -> IO ()
waitFor ws@(_:_) act = do
    todo <- newIORef $ length ws
    forM_ ws $ \(k,w) -> afterWaiting w $ do
        t <- readIORef todo
        when (t /= 0) $ do
            b <- act (t == 1) k
            writeIORef'' todo $ if b then 0 else t - 1


getResult :: Status -> Maybe Result
getResult (Ready r) = Just r
getResult (Loaded r) = Just r
getResult (Waiting _ r) = r
getResult _ = Nothing


---------------------------------------------------------------------
-- OPERATIONS

newtype Depends = Depends {fromDepends :: [Id]}
    deriving (NFData)

data Ops = Ops
    {stored :: Key -> IO (Maybe Value)
        -- ^ Given a Key and a Value from the database, check it still matches the value stored on disk
    ,execute :: Stack -> Key -> IO (Either SomeException (Value, [Depends], Duration, [Trace]))
        -- ^ Given a chunk of stack (bottom element first), and a key, either raise an exception or successfully build it
    }


-- | Return either an exception (crash), or (how much time you spent waiting, the value)
build :: Pool -> Database -> Ops -> Stack -> [Key] -> IO (Either SomeException (Duration,Depends,[Value]))
build pool Database{..} Ops{..} stack ks = do
    join $ withLock lock $ do
        is <- forM ks $ \k -> do
            is <- readIORef intern
            case Intern.lookup k is of
                Just i -> return i
                Nothing -> do
                    (is, i) <- return $ Intern.add k is
                    writeIORef'' intern is
                    modifyIORef'' status $ Map.insert i (k,Missing)
                    return i

        whenJust (checkStack is stack) $ \bad -> do
            status <- readIORef status
            uncurry errorRuleRecursion $ case Map.lookup bad status of
                Nothing -> (Nothing, Nothing)
                Just (k,_) -> (Just $ typeKey k, Just $ show k)

        vs <- mapM (reduce stack) is
        let errs = [e | Error e <- vs]
        if all isReady vs then
            return $ return $ Right (0, Depends is, [result r | Ready r <- vs])
         else if not $ null errs then
            return $ return $ Left $ head errs
         else do
            wait <- newBarrier
            waitFor (filter (isWaiting . snd) $ zip is vs) $ \finish i -> do
                s <- readIORef status
                let done x = do signalBarrier wait x; return True
                case Map.lookup i s of
                    Just (_, Error e) -> done (True, Left e) -- on error make sure we immediately kick off our parent
                    Just (_, Ready{}) | finish -> done (False, Right [result r | i <- is, let Ready r = snd $ fromJust $ Map.lookup i s])
                                      | otherwise -> return False
            return $ do
                (dur,res) <- duration $ blockPool pool $ waitBarrier wait
                return $ case res of
                    Left e -> Left e
                    Right v -> Right (dur,Depends is,v)
    where
        (#=) :: Id -> (Key, Status) -> IO Status
        i #= (k,v) = do
            s <- readIORef status
            writeIORef'' status $ Map.insert i (k,v) s
            diagnostic $ maybe "Missing" (statusType . snd) (Map.lookup i s) ++ " -> " ++ statusType v ++ ", " ++ maybe "<unknown>" (show . fst) (Map.lookup i s)
            return v

        atom x = let s = show x in if ' ' `elem` s then "(" ++ s ++ ")" else s

        -- Rules for each eval* function
        -- * Must NOT lock
        -- * Must have an equal return to what is stored in the db at that point
        -- * Must not return Loaded

        reduce :: Stack -> Id -> IO Status
        reduce stack i = do
            s <- readIORef status
            case Map.lookup i s of
                Nothing -> err $ "interned value missing from database, " ++ show i
                Just (k, Missing) -> run stack i k Nothing
                Just (k, Loaded r) -> do
                    b <- case assume of
                        Just AssumeDirty -> return False
                        Just AssumeSkip -> return True
                        _ -> fmap (== Just (result r)) $ stored k
                    diagnostic $ "valid " ++ show b ++ " for " ++ atom k ++ " " ++ atom (result r)
                    if not b then run stack i k $ Just r else check stack i k r (depends r)
                Just (k, res) -> return res

        run :: Stack -> Id -> Key -> Maybe Result -> IO Waiting
        run stack i k r = do
            w <- newWaiting r
            addPool pool $ do
                let norm = do
                        res <- execute (addStack i k stack) k
                        return $ case res of
                            Left err -> Error err
                            Right (v,deps,execution,traces) ->
                                let c | Just r <- r, result r == v = changed r
                                      | otherwise = step
                                in Ready Result{result=v,changed=c,built=step,depends=map fromDepends deps,..}
                res <- case r of
                    Just r | assume == Just AssumeClean -> do
                        v <- stored k
                        case v of
                            Just v -> return $ Ready r{result=v}
                            Nothing -> norm
                    _ -> norm

                ans <- withLock lock $ do
                    ans <- i #= (k, res)
                    runWaiting w
                    return ans
                case ans of
                    Ready r -> do
                        diagnostic $ "result " ++ atom k ++ " = " ++ atom (result r)
                        journal i (k, Loaded r) -- leave the DB lock before appending
                    Error _ -> do
                        diagnostic $ "result " ++ atom k ++ " = error"
                        journal i (k, Missing)
                    _ -> return ()
            i #= (k, w)

        check :: Stack -> Id -> Key -> Result -> [[Id]] -> IO Status
        check stack i k r [] =
            i #= (k, Ready r)
        check stack i k r (ds:rest) = do
            vs <- mapM (reduce (addStack i k stack)) ds
            let ws = filter (isWaiting . snd) $ zip ds vs
            if any isError vs || any (> built r) [changed | Ready Result{..} <- vs] then
                run stack i k $ Just r
             else if null ws then
                check stack i k r rest
             else do
                self <- newWaiting $ Just r
                waitFor ws $ \finish d -> do
                    s <- readIORef status
                    let buildIt = do
                            b <- run stack i k $ Just r
                            afterWaiting b $ runWaiting self
                            return True
                    case Map.lookup d s of
                        Just (_, Error{}) -> buildIt
                        Just (_, Ready r2)
                            | changed r2 > built r -> buildIt
                            | finish -> do
                                res <- check stack i k r rest
                                if not $ isWaiting res
                                    then runWaiting self
                                    else afterWaiting res $ runWaiting self
                                return True
                            | otherwise -> return False
                i #= (k, self)


---------------------------------------------------------------------
-- PROGRESS

-- Does not need to set shakeRunning, done by something further up
progress :: Database -> IO Progress
progress Database{..} = do
    s <- readIORef status
    return $ foldl' f mempty $ map snd $ Map.elems s
    where
        f s (Ready Result{..}) = if step == built
            then s{countBuilt = countBuilt s + 1, timeBuilt = timeBuilt s + execution}
            else s{countSkipped = countSkipped s + 1, timeSkipped = timeSkipped s + execution}
        f s (Loaded Result{..}) = s{countUnknown = countUnknown s + 1, timeUnknown = timeUnknown s + execution}
        f s (Waiting _ r) =
            let (d,c) = timeTodo s
                t | Just Result{..} <- r = let d2 = d + execution in d2 `seq` (d2,c)
                  | otherwise = let c2 = c + 1 in c2 `seq` (d,c2)
            in s{countTodo = countTodo s + 1, timeTodo = t}
        f s _ = s


---------------------------------------------------------------------
-- QUERY DATABASE

-- | Given a map of representing a dependency order (with a show for error messages), find an ordering for the items such
--   that no item points to an item before itself.
--   Raise an error if you end up with a cycle.
dependencyOrder :: (Eq a, Hashable a) => (a -> String) -> Map a [a] -> [a]
-- Algorithm:
--    Divide everyone up into those who have no dependencies [Id]
--    And those who depend on a particular Id, Dep :-> Maybe [(Key,[Dep])]
--    Where d :-> Just (k, ds), k depends on firstly d, then remaining on ds
--    For each with no dependencies, add to list, then take its dep hole and
--    promote them either to Nothing (if ds == []) or into a new slot.
--    k :-> Nothing means the key has already been freed
dependencyOrder shw status = f (map fst noDeps) $ Map.map Just $ Map.fromListWith (++) [(d, [(k,ds)]) | (k,d:ds) <- hasDeps]
    where
        (noDeps, hasDeps) = partition (null . snd) $ Map.toList status

        f [] mp | null bad = []
                | otherwise = error $ unlines $
                    "Internal invariant broken, database seems to be cyclic" :
                    map ("    " ++) bad ++
                    ["... plus " ++ show (length badOverflow) ++ " more ..." | not $ null badOverflow]
            where (bad,badOverflow) = splitAt 10 $ [shw i | (i, Just _) <- Map.toList mp]

        f (x:xs) mp = x : f (now++xs) later
            where Just free = Map.lookupDefault (Just []) x mp
                  (now,later) = foldl' g ([], Map.insert x Nothing mp) free

        g (free, mp) (k, []) = (k:free, mp)
        g (free, mp) (k, d:ds) = case Map.lookupDefault (Just []) d mp of
            Nothing -> g (free, mp) (k, ds)
            Just todo -> (free, Map.insert d (Just $ (k,ds) : todo) mp)


-- | Eliminate all errors from the database, pretending they don't exist
resultsOnly :: Map Id (Key, Status) -> Map Id (Key, Result)
resultsOnly mp = Map.map (\(k, v) -> (k, let Just r = getResult v in r{depends = map (filter (isJust . flip Map.lookup keep)) $ depends r})) keep
    where keep = Map.filter (isJust . getResult . snd) mp

removeStep :: Map Id (Key, Result) -> Map Id (Key, Result)
removeStep = Map.filter (\(k,_) -> k /= stepKey)

showJSON :: Database -> IO String
showJSON Database{..} = do
    status <- fmap (removeStep . resultsOnly) $ readIORef status
    let order = let shw i = maybe "<unknown>" (show . fst) $ Map.lookup i status
                in dependencyOrder shw $ Map.map (concat . depends . snd) status
        ids = Map.fromList $ zip order [0..]

        steps = let xs = Set.toList $ Set.fromList $ concat [[changed, built] | (_,Result{..}) <- Map.elems status]
                in Map.fromList $ zip (reverse $ sort xs) [0..]

        f (k, Result{..})  =
            let xs = ["name:" ++ show (show k)
                     ,"built:" ++ showStep built
                     ,"changed:" ++ showStep changed
                     ,"depends:" ++ show (mapMaybe (`Map.lookup` ids) (concat depends))
                     ,"execution:" ++ show execution] ++
                     ["traces:[" ++ intercalate "," (map showTrace traces) ++ "]" | traces /= []]
                showStep i = show $ fromJust $ Map.lookup i steps
                showTrace (a,b,c) = "{start:" ++ show b ++ ",stop:" ++ show c ++ ",command:" ++ show (unpack a) ++ "}"
            in  ["{" ++ intercalate ", " xs ++ "}"]
    return $ "[" ++ intercalate "\n," (concat [maybe (error "Internal error in showJSON") f $ Map.lookup i status | i <- order]) ++ "\n]"


checkValid :: Database -> (Key -> IO (Maybe Value)) -> IO ()
checkValid Database{..} stored = do
    status <- readIORef status
    diagnostic "Starting validity/lint checking"
    -- Do not use a forM here as you use too much stack space
    bad <- (\f -> foldM f [] (Map.toList status)) $ \seen (i,v) -> case v of
        (key, Ready Result{..}) -> do
            now <- stored key
            let good = now == Just result
            diagnostic $ "Checking if " ++ show key ++ " is " ++ show result ++ ", " ++ if good then "passed" else "FAILED"
            return $ [(key, result, now) | not good && not (specialAlwaysRebuilds result)] ++ seen
        _ -> return seen
    if null bad then diagnostic "Validity/lint check passed" else do
        let n = length bad
        errorStructured
            ("Lint checking error - " ++ (if n == 1 then "value has" else show n ++ " values have")  ++ " changed since being depended upon")
            (intercalate [("",Just "")] [ [("Key", Just $ show key),("Old", Just $ show result),("New", Just $ maybe "<missing>" show now)]
                                        | (key, result, now) <- bad])
            ""

---------------------------------------------------------------------
-- STORAGE

-- To simplify journaling etc we smuggle the Step in the database, with a special StepKey
newtype StepKey = StepKey ()
    deriving (Show,Eq,Typeable,Hashable,Binary,NFData)

stepKey :: Key
stepKey = newKey $ StepKey ()

toStepResult :: Step -> Result
toStepResult i = Result (newValue i) i i [] 0 []

fromStepResult :: Result -> Step
fromStepResult = fromValue . result


withDatabase :: ShakeOptions -> (String -> IO ()) -> (Database -> IO a) -> IO a
withDatabase opts diagnostic act = do
    registerWitness $ StepKey ()
    registerWitness $ Step 0
    witness <- currentWitness
    withStorage opts diagnostic witness $ \mp2 journal -> do
        let mp1 = Intern.fromList [(k, i) | (i, (k,_)) <- Map.toList mp2]

        (mp1, stepId) <- case Intern.lookup stepKey mp1 of
            Just stepId -> return (mp1, stepId)
            Nothing -> do
                (mp1, stepId) <- return $ Intern.add stepKey mp1
                return (mp1, stepId)

        intern <- newIORef mp1
        status <- newIORef mp2
        let step = case Map.lookup stepId mp2 of
                        Just (_, Loaded r) -> incStep $ fromStepResult r
                        _ -> Step 1
        journal stepId (stepKey, Loaded $ toStepResult step)
        lock <- newLock
        act Database{assume=shakeAssume opts,..}


instance BinaryWith Witness Step where
    putWith _ x = put x
    getWith _ = get

instance BinaryWith Witness Result where
    putWith ws (Result x1 x2 x3 x4 x5 x6) = putWith ws x1 >> put x2 >> put x3 >> put x4 >> put x5 >> put x6
    getWith ws = do x1 <- getWith ws; x2 <- get; x3 <- get; x4 <- get; x5 <- get; x6 <- get; return $ Result x1 x2 x3 x4 x5 x6

instance BinaryWith Witness Status where
    putWith ctx Missing = putWord8 0
    putWith ctx (Loaded x) = putWord8 1 >> putWith ctx x
    putWith ctx x = err $ "putWith, Cannot write Status with constructor " ++ statusType x
    getWith ctx = do i <- getWord8; if i == 0 then return Missing else fmap Loaded $ getWith ctx
