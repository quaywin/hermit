defmodule Hermit do
  @moduledoc """
  Hermit keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  Returns true if the application is running in mock mode (Docker disabled).
  """
  def mock? do
    config = Application.get_env(:hermit, :docker, [])
    Keyword.get(config, :mock, false)
  end

  @doc """
  Recursively stringifies keys of any map.
  """
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  def stringify_keys(val), do: val

  @doc """
  Formats bytes into human-readable string (B, KiB, MiB, GiB).
  """
  def format_bytes(nil), do: "0 B"

  def format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes < 1024 -> "#{bytes} B"
      bytes < 1024 * 1024 -> "#{Float.round(bytes / 1024, 1)} KiB"
      bytes < 1024 * 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 2)} MiB"
      true -> "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GiB"
    end
  end

  def format_bytes(_), do: "0 B"

  @doc """
  Formats an integer with comma separators (e.g., 1,234,567).
  """
  def format_number(nil), do: "0"

  def format_number(num) when is_integer(num) and num < 0 do
    "-" <> format_number(-num)
  end

  def format_number(num) when is_integer(num) do
    num
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def format_number(num), do: to_string(num)
end
