formatters =
  [ExUnit.CLIFormatter] ++
    if System.get_env("CI"), do: [JUnitFormatter], else: []

ExUnit.configure(formatters: formatters)
ExUnit.start(trace: true)
