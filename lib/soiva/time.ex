defmodule Soiva.Time do
  @moduledoc """
  Pluggable time functions for patterns.
  Each time function maps a clock tick to a step index in the pattern.
  Time functions are data — they can be swapped live.
  """

  @doc "Resolve a time spec to a function (tick, pattern_length) -> step_index."
  def resolve(:linear), do: &linear/2
  def resolve(:reverse), do: &reverse/2
  def resolve(:drunk), do: &drunk/2
  def resolve({:curve, :sine, opts}), do: curve_sine(opts)
  def resolve({:prob, opts}), do: make_prob(opts)
  def resolve({:skew, :fast_end}), do: &skew_fast_end/2
  def resolve({:skew, :slow_end}), do: &skew_slow_end/2
  def resolve(fun) when is_function(fun, 2), do: fun
  def resolve(_), do: &linear/2

  # Built-in time shapes

  def linear(tick, len), do: rem(tick, len)

  def reverse(tick, len), do: len - 1 - rem(tick, len)

  def drunk(tick, len) do
    # seeded random walk that advances forward on average
    :rand.seed(:exsss, {tick, tick * 7, tick * 13})
    r = :rand.uniform()

    cond do
      r < 0.6 -> rem(tick + 1, len)
      r < 0.8 -> rem(tick, len)
      r < 0.95 -> rem(tick + 2, len)
      true -> rem(max(tick - 1, 0), len)
    end
  end

  defp curve_sine(opts) do
    period = Keyword.get(opts, :period, 8)

    fn tick, len ->
      phase = tick / period * 2 * :math.pi()
      normalized = (:math.sin(phase) + 1) / 2
      round(normalized * (len - 1))
    end
  end

  defp make_prob(opts) do
    advance = Keyword.get(opts, :advance, 0.7)
    repeat = Keyword.get(opts, :repeat, 0.2)
    _skip = Keyword.get(opts, :skip, 0.1)

    fn tick, len ->
      :rand.seed(:exsss, {tick, tick * 11, tick * 23})
      r = :rand.uniform()

      cond do
        r < advance -> rem(tick, len)
        r < advance + repeat -> rem(max(tick - 1, 0), len)
        true -> rem(tick + 2, len)
      end
    end
  end

  def skew_fast_end(tick, len) do
    cycle = rem(tick, len)
    # quadratic acceleration
    scaled = :math.pow(cycle / len, 0.5) * len
    min(round(scaled), len - 1)
  end

  def skew_slow_end(tick, len) do
    cycle = rem(tick, len)
    # quadratic deceleration
    scaled = :math.pow(cycle / len, 2) * len
    min(round(scaled), len - 1)
  end

  # DSL helpers for time spec construction

  def curve(shape, opts \\ []), do: {:curve, shape, opts}
  def prob(opts), do: {:prob, opts}
  def skew(direction), do: {:skew, direction}
end
