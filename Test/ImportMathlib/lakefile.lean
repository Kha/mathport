import Lake

open Lake DSL System

package importMathlib where
  defaultFacet := PackageFacet.oleans

  dependencies := #[{
    name := "mathbin",
    src := Source.path (FilePath.mk "../../Lib4/mathbin")
  }]

