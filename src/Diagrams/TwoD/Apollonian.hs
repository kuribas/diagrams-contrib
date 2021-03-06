{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE ViewPatterns          #-}
{-# OPTIONS_GHC -fno-warn-missing-methods #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Diagrams.TwoD.Apollonian
-- Copyright   :  (c) 2011, 2016 Brent Yorgey
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  byorgey@cis.upenn.edu
--
-- Generation of Apollonian gaskets.  Any three mutually tangent
-- circles uniquely determine exactly two others which are mutually
-- tangent to all three.  This process can be repeated, generating a
-- fractal circle packing.
--
-- See J. Lagarias, C. Mallows, and A. Wilks, \"Beyond the Descartes
-- circle theorem\", /Amer. Math. Monthly/ 109 (2002), 338--361.
-- <http://arxiv.org/abs/math/0101066>.
--
-- A few examples:
--
-- > import Diagrams.TwoD.Apollonian
-- > apollonian1 = apollonianGasket 0.01 2 2 2
--
-- <<diagrams/src_Diagrams_TwoD_Apollonian_apollonian1.svg#diagram=apollonian1&width=400>>
--
-- > import Diagrams.TwoD.Apollonian
-- > apollonian2 = apollonianGasket 0.01 2 3 3
--
-- <<diagrams/src_Diagrams_TwoD_Apollonian_apollonian2.svg#diagram=apollonian2&width=400>>
--
-- > import Diagrams.TwoD.Apollonian
-- > apollonian3 = apollonianGasket 0.01 2 4 7
--
-- <<diagrams/src_Diagrams_TwoD_Apollonian_apollonian3.svg#diagram=apollonian3&width=400>>
--
-----------------------------------------------------------------------------

module Diagrams.TwoD.Apollonian
       ( -- * Circles

         Circle(..), mkCircle, center, radius

         -- * Descartes' Theorem
       , descartes, other, initialConfig

         -- * Apollonian gasket generation

       , apollonian

         -- ** Kissing sets

       , KissingSet(..), kissingSets, flipSelected, selectOthers

         -- ** Apollonian trees

       , apollonianTrees, apollonianTree

         -- * Diagram generation

       , drawCircle
       , drawGasket
       , apollonianGasket

       ) where

import           Data.Complex
import qualified Data.Foldable    as F
import           Data.Maybe       (catMaybes)
import           Data.Tree

import           Diagrams.Prelude hiding (center, radius)

import           Control.Arrow    (second, (&&&))

------------------------------------------------------------
--  Circles
------------------------------------------------------------

-- | Representation for circles that lets us quickly compute an
--   Apollonian gasket.
data Circle n = Circle
  { bend :: n
    -- ^ The bend is the reciprocal of signed
    --   radius: a negative radius means the
    --   outside and inside of the circle are
    --   switched.  The bends of any four mutually
    --   tangent circles satisfy Descartes'
    --   Theorem.
  , cb   :: Complex n
    -- ^ /Product/ of bend and center represented
    --   as a complex number.  Amazingly, these
    --   products also satisfy the equation of
    --   Descartes' Theorem.
  }
  deriving (Eq, Show)

-- | Create a @Circle@ given a signed radius and a location for its center.
mkCircle :: Fractional n =>
            n -- ^ signed radius
         -> P2 n     -- ^ center
         -> Circle n
mkCircle r (unp2 -> (x,y)) = Circle (1/r) (b*x :+ b*y)
  where b = 1/r

-- | Get the center of a circle.
center :: Fractional n => Circle n -> P2 n
center (Circle b (cbx :+ cby)) = p2 (cbx / b, cby / b)

-- | Get the (unsigned) radius of a circle.
radius :: Fractional n => Circle n -> n
radius = abs . recip . bend

liftF :: RealFloat n => (forall a. Floating a => a -> a) -> Circle n -> Circle n
liftF f (Circle b c) = Circle (f b) (f c)

liftF2 :: RealFloat n => (forall a. Floating a => a -> a -> a) ->
          Circle n -> Circle n -> Circle n
liftF2 f (Circle b1 cb1) (Circle b2 cb2) = Circle (f b1 b2) (f cb1 cb2)

instance RealFloat n => Num (Circle n) where
  (+)           = liftF2 (+)
  (-)           = liftF2 (-)
  (*)           = liftF2 (*)
  negate        = liftF negate
  abs           = liftF abs
  fromInteger n = Circle (fromInteger n) (fromInteger n)

instance RealFloat n => Fractional (Circle n) where
  (/)   = liftF2 (/)
  recip = liftF recip

-- | The @Num@, @Fractional@, and @Floating@ instances for @Circle@
--   (all simply lifted elementwise over @Circle@'s fields) let us use
--   Descartes' Theorem directly on circles.
instance RealFloat n => Floating (Circle n) where
  sqrt = liftF sqrt

------------------------------------------------------------
--  Descartes' Theorem
------------------------------------------------------------

-- XXX generalize these for higher dimensions?

-- | Descartes' Theorem states that if @b1@, @b2@, @b3@ and @b4@ are
--   the bends of four mutually tangent circles, then
--
--   @
--     b1^2 + b2^2 + b3^2 + b4^2 = 1/2 * (b1 + b2 + b3 + b4)^2.
--   @
--
--   Surprisingly, if we replace each of the @bi@ with the /product/
--   of @bi@ and the center of the corresponding circle (represented
--   as a complex number), the equation continues to hold! (See the
--   paper referenced at the top of the module.)
--
--   @descartes [b1,b2,b3]@ solves for @b4@, returning both solutions.
--   Notably, @descartes@ works for any instance of @Floating@, which
--   includes both @Double@ (for bends), @Complex Double@ (for
--   bend/center product), and @Circle@ (for both at once).
descartes :: Floating n => [n] -> [n]
descartes [b1,b2,b3] = [r + s, -r + s]
  where r = 2 * sqrt (b1*b2 + b1*b3 + b2*b3)
        s = b1+b2+b3
descartes _ = error "descartes must be called on a list of length 3"

-- | If we have /four/ mutually tangent circles we can choose one of
--   them to replace; the remaining three determine exactly one other
--   circle which is mutually tangent.  However, in this situation
--   there is no need to apply 'descartes' again, since the two
--   solutions @b4@ and @b4'@ satisfy
--
--   @
--     b4 + b4' = 2 * (b1 + b2 + b3)
--   @
--
--   Hence, to replace @b4@ with its dual, we need only sum the other
--   three, multiply by two, and subtract @b4@.  Again, this works for
--   bends as well as bend/center products.
other :: Num n => [n] -> n -> n
other xs x = 2 * sum xs - x

-- | Generate an initial configuration of four mutually tangent
--   circles, given just the signed bends of three of them.
initialConfig :: RealFloat n => n -> n -> n -> [Circle n]
initialConfig b1 b2 b3 = cs ++ [c4]
  where cs     = [Circle b1 0, Circle b2 ((b2/b1 + 1) :+ 0), Circle b3 cb3]
        a      = 1/b1 + 1/b2
        b      = 1/b1 + 1/b3
        c      = 1/b2 + 1/b3
        x      = (b*b + a*a - c*c)/(2*a)
        y      = sqrt (b*b - x*x)
        cb3    = b3*x :+ b3*y
        [c4,_] = descartes cs

------------------------------------------------------------
--  Gasket generation
------------------------------------------------------------

select :: [a] -> [(a, [a])]
select [] = []
select (x:xs) = (x,xs) : (map . second) (x:) (select xs)

-- | The basic idea of a kissing set is supposed to represent a set of
--   four mutually tangent circles with one selected, though in fact
--   it is more general than that: it represents any set of objects
--   with one distinguished object selected.
data KissingSet n = KS { selected :: n, others :: [n] }
  deriving (Show)

-- | Generate all possible kissing sets from a set of objects by
--   selecting each object in turn.
kissingSets :: [n] -> [KissingSet n]
kissingSets = map (uncurry KS) . select

-- | \"Flip\" the selected circle to the 'other' circle mutually tangent
--   to the other three.  The new circle remains selected.
flipSelected :: Num n => KissingSet n -> KissingSet n
flipSelected (KS c cs) = KS (other cs c) cs

-- | Make the selected circle unselected, and select each of the
--   others, generating a new kissing set for each.
selectOthers :: KissingSet n -> [KissingSet n]
selectOthers (KS c cs) = [ KS c' (c:cs') | (c',cs') <- select cs ]

-- | Given a threshold radius and a list of /four/ mutually tangent
--   circles, generate the Apollonian gasket containing those circles.
--   Stop the recursion when encountering a circle with an (unsigned)
--   radius smaller than the threshold.
apollonian :: RealFloat n => n -> [Circle n] -> [Circle n]
apollonian thresh cs
  = (cs++)
  . concat
  . map (maybe [] flatten . prune p . fmap selected)
  . apollonianTrees
  $ cs
  where
    p c = radius c >= thresh

-- | Given a set of /four/ mutually tangent circles, generate the
--   infinite Apollonian tree rooted at the given set, represented as
--   a list of four subtrees.  Each node in the tree is a kissing set
--   with one circle selected which has just been flipped.  The three
--   children of a node represent the kissing sets obtained by
--   selecting each of the other three circles and flipping them.  The
--   initial roots of the four trees are chosen by selecting and
--   flipping each of the circles in the starting set. This
--   representation has the property that each circle in the
--   Apollonian gasket is the selected circle in exactly one node
--   (except that the initial four circles never appear as the
--   selected circle in any node).
apollonianTrees :: RealFloat n => [Circle n] -> [Tree (KissingSet (Circle n))]
apollonianTrees = map (apollonianTree . flipSelected) . kissingSets

-- | Generate a single Apollonian tree from a root kissing set.  See
--   the documentation for 'apollonianTrees' for an explanation.
apollonianTree :: RealFloat n => KissingSet (Circle n) -> Tree (KissingSet (Circle n))
apollonianTree = unfoldTree (id &&& (map flipSelected . selectOthers))

-- | Prune a tree at the shallowest points where the predicate is not
--   satisfied.
prune :: (a -> Bool) -> Tree a -> Maybe (Tree a)
prune p (Node a ts)
  | not (p a) = Nothing
  | otherwise = Just $ Node a (catMaybes (map (prune p) ts))

------------------------------------------------------------
--  Diagram generation
------------------------------------------------------------

-- | Draw a circle.
drawCircle :: (Renderable (Path V2 n) b, TypeableFloat n) =>
              Circle n -> QDiagram b V2 n Any
drawCircle c = circle (radius c) # moveTo (center c)
                                 # fcA transparent

-- | Draw a generated gasket, using a line width 0.003 times the
--   radius of the largest circle.
drawGasket :: (Renderable (Path V2 n) b, TypeableFloat n) =>
              [Circle n] -> QDiagram b V2 n Any
drawGasket cs = F.foldMap drawCircle cs

-- | Draw an Apollonian gasket: the first argument is the threshold;
--   the recursion will stop upon reaching circles with radii less than
--   it. The next three arguments are bends of three circles.
apollonianGasket :: (Renderable (Path V2 n) b, TypeableFloat n)
                 => n -> n -> n -> n -> QDiagram b V2 n Any
apollonianGasket thresh b1 b2 b3 = drawGasket . apollonian thresh $ (initialConfig b1 b2 b3)

------------------------------------------------------------
-- Some notes on floating-point error
-- (only for the intrepid)
------------------------------------------------------------
{-

-- code from Gerald Gutierrez, personal communication

module Main where

import           Data.Complex
import           Diagrams.Backend.SVG.CmdLine
import           Diagrams.Prelude

-- ------^---------^---------^---------^---------^---------^---------^--------

data Circle = Circle Double (Complex Double) deriving (Show)

descartes a b c
  = (s + r, s - r)
  where
    s = a + b + c
    r = 2 * sqrt ((a * b) + (b * c) + (c * a))

descartesDual a b c d
  = 2 * (a + b + c) - d

soddies (Circle k1 b1) (Circle k2 b2) (Circle k3 b3)
  = ( Circle k4 b4
    , Circle k5 b5 )
  where
    (k4, k5) = descartes k1 k2 k3
    (b4, b5) = descartes b1 b2 b3

soddiesDual (Circle k1 b1) (Circle k2 b2) (Circle k3 b3) (Circle k4 b4)
  = Circle (descartesDual k1 k2 k3 k4) (descartesDual b1 b2 b3 b4)

mutuallyTangentCirclesFromTriangle z1 z2 z3
  = ( Circle k1 (z1 * (k1 :+ 0))
    , Circle k2 (z2 * (k2 :+ 0))
    , Circle k3 (z3 * (k3 :+ 0)) )
  where
    a = magnitude (z2 - z3)
    b = magnitude (z3 - z1)
    c = magnitude (z1 - z2)
    s = (a + b + c) / 2
    k1 = 1 / (s - a)
    k2 = 1 / (s - b)
    k3 = 1 / (s - c)

main :: IO ()
main = mainWith picture

pic = mainWith picture

mkCircle :: Circle -> Diagram B
mkCircle (Circle k b)
  = circle (1 / k) # moveTo (p2 (realPart z, imagPart z))
  where
    z = b / (k :+ 0)

picture :: Diagram B
picture
  = mkCircle c1 <> mkCircle c2 <> mkCircle c3 <> mkCircle c4 <> mkCircle c5
  where
    (c1, c2, c3) = mutuallyTangentCirclesFromTriangle z1 z2 z3
    (c4, c5) = soddies c1 c2 c3

    -- z1 = 0 :+ 0
    -- z2 = 3 :+ 0
    -- z3 = 0 :+ 4

    -- z1 = (-0.546) :+ (-0.755)
    -- z2 = ( 0.341) :+ (-0.755)
    -- z3 = (-0.250) :+ ( 0.428)

ofsBad = 0.15397 -- doesn't work
ofsGood = 0.15398 -- works

ofs = ofsGood

z1 = ofs + ((-0.546) :+ (-0.755))
z2 = ofs + (( 0.341) :+ (-0.755))
z3 = ofs + ((-0.250) :+ ( 0.428))


------------------------------------------------------------

Email to Gerald Gutierrez, 30 Sep 2016:

I got a chance to sit down and think hard about your code today, and
I think I have figured out what the problem is.

If you look at the outputs of 'soddies c1 c2 c3' using the two
different values for 'ofs', you will see that they are *almost* the
same, except that the complex numbers have been switched (though in
fact their real components are almost the same so you only notice the
difference in the imaginary components).  This clearly causes
incorrect results since the y-coordinates represented by the imaginary
components are now getting scaled by different bend values.  So the
resulting circles are of the right size and have (close to) the
correct x-coordinates, but their y-coordinates are wrong.

The problem is that in the 'soddies' function, you make independent
calls to 'descartes k1 k2 k3' (to solve for the bends) and 'descartes
b1 b2 b3' (to solve for the bend-center products), and then *assume*
that they return their solutions *in the same order*, so that you can
match up the first values to make one circle and the second values to
make another circle.  I would guess that this is *usually* true but
apparently not when certain values are hovering right around a branch
cut of sqrt, or something like that.

I think my code in Diagrams.TwoD.Apollonian suffers from the same
problem.  Ultimately I think it is due to the inherent inaccuracy of
floating-point numbers; there is nothing wrong with the formula
itself.  It would be nice to figure out how to correct for this, but I
am not sure how off the top of my head.  The interesting thing is that
switching the bend-center products does not seem to violate the
generalized Descartes' Theorem at all --- so it would seem that it
does not actually completely characterize mutually tangent circles,
that is, there exist sets of circles satisfying the theorem which are
not in fact mutually tangent.

-}
