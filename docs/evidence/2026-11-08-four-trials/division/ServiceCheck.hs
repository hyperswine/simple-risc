module Main where
import qualified DivisionService as D
import Control.Monad (forM_,unless)

expected :: Int -> Integer -> Integer -> Integer
expected op a b
 | b==0 = if op<6 then 4294967295 else a
 | op==4 = signed a `quot` signed b
 | op==5 = a `quot` b
 | op==6 = signed a `rem` signed b
 | otherwise = a `rem` b
 where signed x=if x>=2147483648 then x-4294967296 else x

run :: D.Command -> (Integer,D.Service,Int)
run cmd = go 0 D.Idle
 where
 go n state | n>75 = error "timeout"            | otherwise = case D.serviceStep state (False,Just cmd,False) of
                (_,Just value) -> (toInteger value,state,n)
                (next,Nothing) -> go (n+1) next

main :: IO ()
main=do
 let edges=[0,1,2,4294967295,4294967294,2147483648,2147483647]
     pairs=[(a,b)|a<-edges,b<-edges] ++ take 500 (zip randoms (drop 7 randoms))
     randoms=tail (iterate (\x -> (1664525*x+1013904223) `mod` 4294967296) 123456)
 forM_ [4..7] $ \op -> forM_ pairs $ \(a,b) -> do
  let cmd=(fromIntegral op,fromInteger a,fromInteger b)
      (value,complete,latency)=run cmd
      want=expected op a b `mod` 4294967296
  unless(value==want)(error "arithmetic")
  -- A completion survives backpressure and repeated valid command inputs.
  let held=iterate (\s -> fst (D.serviceStep s (False,Just cmd,False))) complete !! 12
  unless(held==complete)(error "completion not held")
  let (idle,answer)=D.serviceStep held (False,Just cmd,True)
  unless(idle==D.Idle && fmap toInteger answer==Just want)(error "consume")
  unless(snd (D.serviceStep idle (False,Nothing,False))==Nothing)(error "duplicate completion")
  -- Cancel at every step, including a held completion, then start again.
  forM_ [0..latency] $ \at -> do
   let state=iterate (\s -> fst (D.serviceStep s (False,Just cmd,False))) D.Idle !! at
       (cancelled,output)=D.serviceStep state (True,Just cmd,True)
   unless(cancelled==D.Idle && output==Nothing)(error "cancellation")
 putStrLn "PASS: division service 2196 operand/op cases, held completions, consumption, cancellation at every cycle"
