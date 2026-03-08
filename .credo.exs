%{
  configs: [
    %{
      name: "default",
      strict: true,
      color: true,
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      plugins: [],
      requires: [],
      check_for_updates: true,
      checks: [
        {Credo.Check.Readability.ModuleDoc, []},
        {Credo.Check.Readability.Specs, []},
        {Credo.Check.Design.TagTODO, [exit_status: 0]},
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 15]},
        {Credo.Check.Refactor.Nesting, [max_nesting: 4]}
      ]
    }
  ]
}
