import           System.Console.ANSI(clearScreen)
import           Control.Monad.Reader(runReaderT)

import           Imj.Graphics.Render
import           Imj.Graphics.Render.Naive

import           Test.Imj.Bresenham2
import           Test.Imj.Bresenham3
--import           Test.Imj.Ease
import           Test.Imj.Interpolation
import           Test.Imj.InterpolatedColorString
import           Test.Imj.Segment
import           Test.Imj.Timing
import           Test.Imj.Vector
import           Test.Imj.ZigZag

main :: IO ()
main = do
  putStrLn "" -- for readablilty
  testBres2 >>= print
  testBres3 >>= print
  testTiming >>= print
  testSegment >>= print
  testVector >>= print
  testZigZag >>= print
  testInterpolation

  clearScreen -- to not overwrite current terminal content.
  runReaderT (testICS >>
              renderToScreen
              ) NaiveDraw
  --testEase
