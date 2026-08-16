{-# LANGUAGE BangPatterns #-}

-- ABC470D permutation compiler reference.
--
-- Haskell: compose transformations to express their meaning.
-- FPGA:    spatially expand the composed transformation and apply it at once.
--
-- This version favors a compact, readable algebraic model over AtCoder speed.
module Main where

import Data.Array (Array, (!), array, bounds, elems)
import qualified Data.ByteString.Char8 as BS
import qualified Data.IntMap.Strict as IM
import Data.List (foldl')

-- An identity permutation with only non-identity entries stored explicitly.
data Permutation = Permutation
    { permutationSize :: !Int
    , differences     :: !(IM.IntMap Int)
    }
    deriving (Eq, Show)

identity :: Int -> Permutation
identity n = Permutation n IM.empty

applyPermutation :: Permutation -> Int -> Int
applyPermutation (Permutation _ entries) x = IM.findWithDefault x x entries

setMapping :: Int -> Int -> Permutation -> Permutation
setMapping key value (Permutation n entries)
    | key == value = Permutation n (IM.delete key entries)
    | otherwise    = Permutation n (IM.insert key value entries)

-- Keeping the inverse mapping explicit makes every transposition update local.
data PermutationPair = PermutationPair
    { forwardMapping :: !Permutation
    , inverseMapping :: !Permutation
    }
    deriving (Eq, Show)

identityPair :: Int -> PermutationPair
identityPair n = PermutationPair (identity n) (identity n)

-- F <- F o T(x,y): exchange the input slots x and y.
composeByInputTransposition :: Int -> Int -> PermutationPair -> PermutationPair
composeByInputTransposition x y (PermutationPair forward inverse) =
    let !a        = applyPermutation forward x
        !b        = applyPermutation forward y
        !forward' = setMapping y a (setMapping x b forward)
        !inverse' = setMapping b x (setMapping a y inverse)
    in PermutationPair forward' inverse'

-- F <- T(x,y) o F: exchange the output labels x and y.
composeByOutputTransposition :: Int -> Int -> PermutationPair -> PermutationPair
composeByOutputTransposition x y (PermutationPair forward inverse) =
    let !px       = applyPermutation inverse x
        !py       = applyPermutation inverse y
        !forward' = setMapping py x (setMapping px y forward)
        !inverse' = setMapping y px (setMapping x py inverse)
    in PermutationPair forward' inverse'

data Query = Swap !Int !Int | Invert
    deriving (Eq, Show)

data CompilerState = CompilerState
    { uPermutation :: !PermutationPair
    , vPermutation :: !PermutationPair
    , isInverted   :: !Bool
    }
    deriving (Eq, Show)

initialCompilerState :: Int -> CompilerState
initialCompilerState n = CompilerState (identityPair n) (identityPair n) False

compileQuery :: CompilerState -> Query -> CompilerState
compileQuery state Invert = state { isInverted = not (isInverted state) }
compileQuery state (Swap x y)
    | isInverted state =
        state
            { uPermutation =
                composeByOutputTransposition x y (uPermutation state)
            }
    | otherwise =
        state
            { vPermutation =
                composeByInputTransposition x y (vPermutation state)
            }

compileQueries :: Int -> [Query] -> CompilerState
compileQueries n = foldl' compileQuery (initialCompilerState n)

materialize :: Array Int Int -> CompilerState -> [Int]
materialize initial state
    | not (isInverted state) =
        [ applyPermutation u (initial ! applyPermutation v i)
        | i <- [1 .. n]
        ]
    | otherwise =
        elems $ array (1, n)
            [ (applyPermutation u (initial ! k), applyPermutation vInv k)
            | k <- [1 .. n]
            ]
  where
    n    = snd (bounds initial)
    u    = forwardMapping (uPermutation state)
    v    = forwardMapping (vPermutation state)
    vInv = inverseMapping (vPermutation state)

parseQueries :: Int -> [Int] -> ([Query], [Int])
parseQueries count values = go count values []
  where
    go 0 rest accumulated = (reverse accumulated, rest)
    go remaining (1 : x : y : rest) accumulated =
        go (remaining - 1) rest (Swap x y : accumulated)
    go remaining (2 : rest) accumulated =
        go (remaining - 1) rest (Invert : accumulated)
    go _ _ _ = error "invalid query stream"

readInts :: BS.ByteString -> [Int]
readInts = map readOne . BS.words
  where
    readOne token =
        case BS.readInt token of
            Just (value, suffix) | BS.null suffix -> value
            _ -> error "invalid integer"

main :: IO ()
main = do
    input <- readInts <$> BS.getContents
    case input of
        n : q : rest -> do
            let (pValues, queryInput) = splitAt n rest
                initial = array (1, n) (zip [1 .. n] pValues)
                (queries, trailing) = parseQueries q queryInput
                !state = compileQueries n queries
                result = materialize initial state
            if length pValues /= n || not (null trailing)
                then error "invalid input length"
                else putStrLn (unwords (map show result))
        _ -> error "missing N and Q"
