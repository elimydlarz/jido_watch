formatters =
  [ExUnit.CLIFormatter] ++
    if System.get_env("CI"), do: [JUnitFormatter], else: []

ExUnit.configure(exclude: [:journey], formatters: formatters)
ExUnit.start(trace: true)
