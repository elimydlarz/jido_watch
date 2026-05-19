defmodule JidoWatch.Test.Support.Dotenv do
  @moduledoc """
  Loads a `.env` file from the project root into the process environment if
  present, so journey tests can read credentials without a Mix task wrapping
  them. Existing env vars take precedence.
  """

  def load do
    path = Path.join(File.cwd!(), ".env")

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.each(&apply_line/1)
    end

    :ok
  end

  defp apply_line(line) do
    case String.trim(line) do
      "" ->
        :ok

      "#" <> _ ->
        :ok

      trimmed ->
        case String.split(trimmed, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = value |> String.trim() |> strip_quotes()

            if System.get_env(key) in [nil, ""] do
              System.put_env(key, value)
            end

          _ ->
            :ok
        end
    end
  end

  defp strip_quotes(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
  end
end
