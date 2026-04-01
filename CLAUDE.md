# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Soiva

BEAM-native live coding environment for music composition and performance. Elixir runtime with SuperCollider (scsynth) as the audio engine, communicating via OSC/UDP on port 57110.

## Commands

```bash
mix deps.get          # install dependencies (currently none)
mix compile           # compile
mix test              # run all tests
mix test test/soiva_test.exs              # run single test file
mix test test/soiva_test.exs:LINE_NUMBER  # run single test
iex -S mix            # start interactive session (then `use Soiva` for DSL)
```

Requires scsynth running (`scsynth -u 57110`) for audio output, but tests run without it.

## Architecture

```
User (iex) → DSL → Parser → Pattern GenServer → OSC → scsynth
                                  ↑
                               Clock (ticks)
```

**Supervision tree** (one_for_one):
- `Soiva.PatternRegistry` — Registry mapping pattern names to PIDs
- `Soiva.PatternSupervisor` — DynamicSupervisor for pattern GenServers
- `Soiva.OSC` — GenServer managing UDP socket to scsynth
- `Soiva.Clock` — Global metronome, ticks at 16th-note resolution (4 ticks/beat)

**Data flow through the pipeline:**

1. **`Soiva.DSL`** — User-facing API (`play`, `tempo`, `morph`, `stop`, pattern algebra). All iex interaction goes through here.
2. **`Soiva.Parser`** — Normalizes all notation formats (atom `:c4`, MIDI int `60`, string `"c4:1 eb4:0.5"`, tuple `{:c4, 1.0}`, chords as nested lists) into `%Soiva.Event{}` structs with beat positions assigned.
3. **`Soiva.Pattern`** — Per-pattern GenServer. Subscribes to Clock, receives `:tick` messages, uses its time function to determine which step to play, applies humanization/swing via Playability, converts MIDI to frequency, sends OSC `/s_new`.
4. **`Soiva.Time`** — Pluggable time functions `(tick, pattern_length) -> step_index`. Built-ins: `:linear`, `:reverse`, `:drunk`, `curve/2`, `prob/1`, `skew/1`. Swappable live via `morph`.
5. **`Soiva.Playability`** — Humanization, swing, pattern algebra transforms (`reverse`, `stretch`, `shift`, `mirror`, `scatter`), emotion shortcuts (`tense`, `release_feel`), random pattern generation.
6. **`Soiva.Evolve`** — Self-evolving texture engine. Spawns a pattern plus a companion GenServer that periodically mutates the pattern, feeding each transformation back on itself. Registered as `:"_evolve_#{name}"` in the PatternRegistry.
7. **`Soiva.OSC`** — Direct OSC binary encoding over UDP (no external library). Handles `s_new`, `n_set`, `n_free`, `d_recv`.
8. **`Soiva.Event`** — Immutable struct: pitch (MIDI), dur, amp, rest flag, synth, pan, attack, release, beat, offset, params map.

**State management:**
- `persistent_term` for root note, scale, and pattern groups
- Registry + DynamicSupervisor for pattern lifecycle
- Clock auto-starts on first subscriber, auto-stops on last unsubscribe

**Key conventions:**
- All pattern transformations produce new Event lists (immutable)
- Patterns only trigger on quarter-note boundaries (every 4 clock ticks)
- Each pattern tracks its own `node_ids` and frees them on termination
- `Soiva.Synths` attempts to find and run `sclang` to load `priv/synthdefs/default.scd` at boot
