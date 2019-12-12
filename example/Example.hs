--{-# LANGUAGE OverloadedStrings #-}
--{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE Arrows  #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE ExplicitForAll  #-}
---- | Hack idiom-brackets using Source Plugin.
----
---- As nobody (?) writes their lists as `([1, 2, 3])`,
---- we can steal that syntax!
---- module Main (main) where

--import Data.String         (IsString (..))
--import Control.Applicative (some, (<|>))
--import Data.Traversable    (foldMapDefault)
--import Test.HUnit          ((@?=))
--import Text.Parsec         (parse)
--import Text.Parsec.Char    (alphaNum, char, spaces)
--import Text.Parsec.String  (Parser)

{-# OPTIONS -fplugin=CircuitNotation #-}

module Example where

-- idC :: Int
-- idC = 5

-- data DF d a

-- myCircuit :: Int
-- myCircuit = circuit \(v1 :: DF d a) (v3 :: blah) -> do
--   v1' <- total -< (v3 :: DF domain Int)
--   v2 <- total -< (v1 :: DF domain Int)
--   -- v2' <- total2 -< v2
--   -- v3 <- zipC -< (v1', v2')
--   idC -< v3

-- Circuit (() -> a)


-- Circuit (a -> b -> c)
-- Circuit ((a,b) -> c)
-- Circuit (a)

-- (><) :: Circuit (a -> b -> c) -> Circuit a -> Circuit (b -> c)

data Circuit a b = Circuit {runCircuit :: (a,b) -> (b,a)}

myCircuit :: Circuit [Int] Char
myCircuit = undefined

myCircuitRev :: Circuit Char Int
myCircuitRev = undefined

swapC :: forall a b. Circuit (a,b) (b,a)
swapC = circuit \ (a,b) -> do
  idC -< (b,a)

-- myDesire :: Circuit Int Char
-- myDesire = Circuit (\(aM2S,bS2M) -> let
--   (aM2S', bS2M') = runCircuit myCircuit (aM2S, bS2M)
--   in (aM2S', bS2M'))

-- var :: (Int, Int)
-- var = (3, 5)

-- myLet :: Int
-- myLet = let (yo, yo') = var in yo

-- ah :: (Int,Int)
-- ah = (7,11)

tupCir1 :: Circuit (Int, Char) (Char, Int)
tupCir1 = circuit \ input -> do
  (c,i) <- swapC @Int -< input
  ~i' <- myCircuit -< [i]
  let myIdCircuit = circuit \port -> do idC -< port
  c' <- myCircuitRev -< c
  c'' <- myIdCircuit -< c'
  idC -< (i', c'')

-- tupleCircuit :: Circuit Int Char
-- tupleCircuit = id $ circuit \a -> do
--   b <- (circuit \a -> do b <- myCircuit -< a;idC -< b) -< a
--   a' <- myCircuitRev -< b
--   b' <- myCircuit -< a'
--   b'' <- (circuit \aa -> do idC -< aa) -< b'
--   idC -< b''

-- simpleCircuit :: Circuit Int Char
-- simpleCircuit = id $ circuit \a -> do
--   b <- (circuit \a -> do b <- myCircuit -< a;idC -< b) -< a
--   a' <- myCircuitRev -< b
--   b' <- myCircuit -< a'
--   b'' <- (circuit \aa -> do idC -< aa) -< b'
--   idC -< b''

-- myCircuit :: Int
-- myCircuit = circuit \(v1 :: DF d a) (v3 :: blah) -> do
--   v1' <- total -< (v3 :: DF domain Int) -< (v4 :: DF domain Int)
--   v2 <- total -< v1
--   let a = b
--   -- v2' <- total2 -< v2
--   -- v3 <- zipC -< (v1', v2')
--   v1 <- idC -< v3

-- type RunCircuit a b = (Circuit a b -> (M2S a, S2M b) -> (M2S b, S2M a))
-- type CircuitId a b = Circuit a b -> Circuit a b

-- myCircuit = let
--   _circuits :: (RunCircuit a b, RunCircuit c d, RunCircuit (b,d) e, CircuitId (a,c) e)
--   _circuits@(runC1, runC2, runC2, cId) = (runCircuit, runCircuit, runCircuit, id)

--   in cId $ Circuit $ \((v1M2S, v2M2S),outputS2M) -> let

--   (v1'M2S, v1S2M) = runC1 total (v1M2s, v1'S2M)
--   (v2'M2S, v2S2M) = runC2 total2 (v2M2s, v2'S2M)
--   (v3M2S, (v1'S2M, v2'S2M)) = runC3 zipC ((v1'M2S, v2'M2S), v3S2M)

--   in (v3M2S, (v1S2M, v2S2M))




  -- circuitHelper
  --   :: Circuit a b
  --   -> Circuit c d
  --   -> Circuit (b,d) e


-- myCircuit :: Int
-- myCircuit = circuit (\(v1,v2) -> (v2,v1))

-- myCircuit :: Int
-- myCircuit = circuit do
--   (v2,v1) <- yeah
--   idC -< (v1, v2)

-- myCircuit = proc v1 -> do
--   x <- total -< value
  -- fin -< a
  -- idC -< (t / n)
