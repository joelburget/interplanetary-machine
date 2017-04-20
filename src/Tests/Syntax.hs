{-# language Rank2Types #-}
module Tests.Syntax where

import Test.Tasty
import Test.Tasty.HUnit

import Interplanetary.Syntax

unitTy :: forall a. ValTy a
unitTy = DataTy 1 []

unitTests :: TestTree
unitTests = testGroup "syntax"
  [ testCase "extendAbility 1" $
    let uidMap = uidMapSingleton 1 [TyArgVal unitTy]
        actual :: Ability String
        actual = extendAbility emptyAbility (Adjustment uidMap)
        expected = Ability OpenAbility uidMap
    in expected @=? actual
  , testCase "extendAbility 2" $
    let uidMap = uidMapSingleton 1 [TyArgVal unitTy]
        actual :: Ability String
        actual = extendAbility closedAbility (Adjustment uidMap)
        expected = Ability ClosedAbility uidMap
    in expected @=? actual
  ]
