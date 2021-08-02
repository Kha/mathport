/-
Copyright (c) 2021 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Daniel Selsam

Lean3 uses snake_case for everything.

As of now, Lean4 uses:
- camelCase for defs
- PascalCase for types
- snake_case for proofs
-/
import Lean
import Mathport.Util.Misc
import Mathport.Util.String
import Mathport.Util.RenameExt
import Mathport.Binary.Basic


namespace Mathport.Binary

open Lean Lean.Meta

inductive ExprKind
  | eSort
  | eDef
  | eProof

partial def translatePrefix (pfix3 : Name) : BinportM Name := do
  match ← lookupNameExt pfix3 with
  | some pfix4 => pfix4
  | none =>
    match pfix3 with
    | Name.anonymous  ..  => Name.anonymous
    | Name.num pfix3 k .. => Name.mkNum (← translatePrefix pfix3) k
    | Name.str pfix3 s .. =>
      let s := if (← read).config.stringsToKeep.contains s then s else s.snake2pascal
      Name.mkStr (← translatePrefix pfix3) s

def translateSuffix (s : String) (eKind : ExprKind) : BinportM String := do
  if (← read).config.stringsToKeep.contains s then s else
    match eKind with
    | ExprKind.eSort  => s.snake2pascal
    | ExprKind.eDef   => s.snake2camel
    | ExprKind.eProof => s

def mkCandidateLean4NameForKind (n3 : Name) (eKind : ExprKind) : BinportM Name := do
  let pfix4 ← translatePrefix n3.getPrefix
  match n3 with
  | Name.num _ k ..  => Name.mkNum pfix4 k
  | Name.str _ s ..  => Name.mkStr pfix4 (← translateSuffix s eKind)
  | _                => Name.anonymous

def getExprKind (type : Expr) : MetaM ExprKind := do
  if ← isProp type then ExprKind.eProof
  else if ← returnsSort type then ExprKind.eSort
  else ExprKind.eDef
where
  returnsSort (type : Expr) : MetaM Bool := withTransparency TransparencyMode.all do
    forallTelescopeReducing type fun xs b =>
      match b with
      | Expr.sort .. => true
      | _ => false

def mkCandidateLean4Name (n3 : Name) (type : Expr) : BinportM Name := do
  match ← lookupNameExt n3 with
  | none => mkCandidateLean4NameForKind n3 (← liftMetaM <| getExprKind type)
  | some n4 => pure n4

inductive ClashKind
  | foundDefEq : ClashKind
  | freshDecl  : ClashKind
  deriving Inhabited, Repr, BEq

-- Given a declaration whose expressions have already been translated to Lean4
-- (i.e. the names *occurring* in the expressions have been translated
-- TODO: this is awkward, the `List Name` is just the list of constructor names for defEq inductive clashes
partial def refineLean4Names (decl : Declaration) : BinportM (Declaration × ClashKind × List Name) := do
  match decl with
  | Declaration.axiomDecl ax                =>
    refineAx { ax with name := ← mkCandidateLean4Name ax.name ax.type }
  | Declaration.thmDecl thm                 =>
    refineThm { thm with name := ← mkCandidateLean4Name thm.name thm.type}
  | Declaration.defnDecl defn               =>
    let name ← ← mkCandidateLean4Name defn.name defn.type
    -- Optimization: don't bother def-eq checking constructions that we know will be def-eq
    if name.isStr && (← read).config.defEqConstructions.contains name.getString! then
      let clashKind := if (← getEnv).contains name then ClashKind.foundDefEq else ClashKind.freshDecl
      return (Declaration.defnDecl { defn with name := name }, clashKind, [])
    refineDef { defn with name := name }
  | Declaration.inductDecl lps nps [indType] iu =>
    refineInd lps nps (indType.updateNames (← mkCandidateLean4Name indType.name indType.type)) iu
  | _                                       => throwError "unexpected declaration type"

where
  refineAx (ax3 : AxiomVal) := do
    println! "[refineAx] {ax3.name} {ax3.type}"
    match (← getEnv).find? ax3.name with
    | some (ConstantInfo.axiomInfo ax4) =>
      if ← isDefEqUpto ax3.levelParams ax3.type ax4.levelParams ax4.type then
        pure (Declaration.axiomDecl ax3, ClashKind.foundDefEq, [])
      else
        refineAx { ax3 with name := extendName ax3.name }
    | none => pure (Declaration.axiomDecl ax3, ClashKind.freshDecl, [])
    | _ => refineAx { ax3 with name := extendName ax3.name }

  refineThm (thm3 : TheoremVal) := do
    println! "[refineThm] {thm3.name}"
    match (← getEnv).find? thm3.name with
    | some (ConstantInfo.thmInfo thm4) =>
      if ← isDefEqUpto thm3.levelParams thm3.type thm4.levelParams thm4.type then
        pure (Declaration.thmDecl thm3, ClashKind.foundDefEq, [])
      else
        refineThm { thm3 with name := extendName thm3.name }
    | none => pure (Declaration.thmDecl thm3, ClashKind.freshDecl, [])
    | _ => refineThm { thm3 with name := extendName thm3.name }

  refineDef (defn3 : DefinitionVal) := do
    println! "[refineDef] {defn3.name}"
    match (← getEnv).find? defn3.name with
    | some (ConstantInfo.defnInfo defn4) =>
      if ← isDefEqUpto defn3.levelParams defn3.value defn4.levelParams defn4.value then
        pure (Declaration.defnDecl defn3, ClashKind.foundDefEq, [])
      else
        refineDef { defn3 with name := extendName defn3.name }
    | none => pure (Declaration.defnDecl defn3, ClashKind.freshDecl, [])
    | _ => refineDef { defn3 with name := extendName defn3.name }

  refineInd (lps : List Name) (numParams : Nat) (indType3 : InductiveType) (isUnsafe : Bool) := do
    println! "[refineInd] {indType3.name}"
    let recurse := refineInd lps numParams (indType3.updateNames (extendName indType3.name)) isUnsafe
    match (← getEnv).find? indType3.name with
    | some (ConstantInfo.inductInfo indVal) =>
      if indVal.numParams ≠ numParams then recurse
      else if not (← isDefEqUpto lps indType3.type indVal.levelParams indVal.type) then recurse
      else
        let ctors := indType3.ctors.zip indVal.ctors
        let ctorsDefEq (ctor3 : Constructor) (name4 : Name) : BinportM Bool := do
          let some (ConstantInfo.ctorInfo ctor4) ← (← getEnv).find? name4 | throwError "constructor '{name4}' not found"
          isDefEqUpto lps ctor3.type ctor4.levelParams ctor4.type
        if ← ctors.allM (fun (x, y) => ctorsDefEq x y) then
          pure (Declaration.inductDecl lps numParams [indType3] isUnsafe, ClashKind.foundDefEq, indVal.ctors)
        else recurse
    | none => pure (Declaration.inductDecl lps numParams [indType3] isUnsafe, ClashKind.freshDecl, [])
    | _ => println! "[refineInd] not an IND"
           recurse

  isDefEqUpto (lvls₁ : List Name) (t₁ : Expr) (lvls₂ : List Name) (t₂ : Expr) : BinportM Bool := do
    Kernel.isDefEq (← getEnv) {} t₁ (t₂.instantiateLevelParams lvls₂ $ lvls₁.map mkLevelParam)

  extendName : Name → Name
    | Name.str p s _ => Name.mkStr p (s ++ "'")
    | n              => Name.mkStr n "'"

def refineLean4NamesAndUpdateMap (decl : Declaration) : BinportM (Declaration × ClashKind) := do
  let (decl', clashKind, ctors) ← refineLean4Names decl
  let tr (n3 n4 : Name) := do
    println! "[translateName] {n3} -> {n4}"
    addNameAlignment n3 n4

  tr decl.toName decl'.toName

  match decl, decl' with
  | Declaration.inductDecl _ _ [indType3] _, Declaration.inductDecl _ _ [indType4] _ =>
    tr (indType3.name ++ `rec) (indType4.name ++ `rec)
    for (ctor3, ctor4) in List.zip indType3.ctors (if ctors.isEmpty then indType4.ctors.map Constructor.name else ctors) do
      tr ctor3.name ctor4
  | _, _ => pure ()

  pure (decl', clashKind)

end Mathport.Binary
