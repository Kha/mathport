/-
Copyright (c) 2021 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Mario Carneiro
-/
import Mathport.Syntax.Translate.Tactic.Basic
import Mathport.Syntax.Translate.Tactic.Lean3
import Mathport.Syntax.Translate.Tactic.Mathlib.RCases

open Lean
open Lean.Elab.Tactic (Location)

namespace Mathport.Translate.Tactic
open AST3 Parser

-- # tactic.congr
@[tr_tactic congr'] def trCongr' : TacM Syntax.Tactic := do
  let n ← parse (smallNat)?
  let args ← parse (tk "with" *> return (← rintroPat*, ← (tk ":" *> smallNat)?))?
  let pats ← liftM <| args.mapM (·.1.mapM trRIntroPat)
  let ks := args.map (·.2.map quote)
  `(tactic| congr $[$(n.map quote)]? $[with $[$pats]* $[: $ks]?]?)

@[tr_tactic rcongr] def trRCongr : TacM Syntax.Tactic := do
  let pats ← liftM $ (← parse rintroPat*).mapM trRIntroPat
  `(tactic| rcongr $[$pats]*)

@[tr_tactic convert] def trConvert : TacM Syntax.Tactic := do
  let sym := optTk (← parse (tk "<-")?).isSome
  let r ← trExpr (← parse pExpr)
  let n ← parse (tk "using" *> smallNat)?
  `(tactic| convert $[←%$sym]? $r $[using $(n.map quote)]?)

@[tr_tactic convert_to] def trConvertTo : TacM Syntax.Tactic := do
  `(tactic| convert_to $(← trExpr (← parse pExpr))
    $[using $((← parse (tk "using" *> smallNat)?).map Quote.quote)]?)

@[tr_tactic ac_change] def trAcChange : TacM Syntax.Tactic := do
  `(tactic| ac_change $(← trExpr (← parse pExpr))
    $[using $((← parse (tk "using" *> smallNat)?).map Quote.quote)]?)


