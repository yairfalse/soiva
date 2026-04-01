# Soiva

Live coding music on the BEAM. Write Elixir, hear sound.

Soiva is a live coding environment where patterns are processes, time is a pluggable function, and everything can be morphed while it plays. It runs on Elixir/OTP and talks to SuperCollider's synthesis engine over OSC.

```elixir
use Soiva

tempo 120
root :c, scale: :minor

play :bass, pattern: "c2:2 eb2:1 g2:1", synth: :default
play :melody, pattern: [:c4, :eb4, :g4, :bb4], time: :drunk

morph :melody, amp: 0.3
scatter :melody, prob: 0.3
```

## Prerequisites

- Elixir 1.17+ / OTP 26+
- SuperCollider (scsynth)

### Installing SuperCollider

**macOS:**
```bash
brew install --cask supercollider
```

**Fedora Linux:**
```bash
sudo dnf install supercollider
```

## Getting started

Start the audio server:

```bash
scsynth -u 57110
```

Load SynthDefs by evaluating `priv/synthdefs/default.scd` in SuperCollider IDE, or let Soiva auto-load it via sclang on boot.

Then:

```bash
iex -S mix
```

```elixir
use Soiva
tempo 120
play :melody, pattern: [:c4, :e4, :g4, :e4], synth: :default
```

## DSL

### Tempo and scale

```elixir
tempo 120                          # BPM
tempo 120, swing: 0.6              # with swing
root :c, scale: :minor             # global root and scale
```

### Patterns

Many ways to write the same music:

```elixir
play :name, pattern: [:c4, :eb4, :g4, :bb4]             # atoms
play :name, pattern: [60, 63, 67, 70]                    # MIDI numbers
play :name, pattern: "c4:1 eb4:0.5 g4:0.5 rest:2"       # string with durations
play :name, pattern: [{:c4, 1.0}, {:eb4, 0.5}]           # tuples
play :name, pattern: [[:c4, :eb4, :g4], :rest]           # chords
```

### Textures

High-level macros that expand into patterns:

```elixir
drone :c2, synth: :pad
burst :c4, density: 0.7, scatter: 0.4
shimmer [:c4, :e4, :g4], rate: 0.5
```

### Control

```elixir
stop :name
pause :name
resume :name
stop :all
```

### Live mutation

Change anything while it plays:

```elixir
morph :name, pattern: [:c4, :d4, :e4]
morph :name, time: :drunk
morph :name, amp: 0.5
```

### Pattern algebra

Transform running patterns:

```elixir
rev :name                  # reverse
stretch :name, 2           # time-stretch
shift :name, 2             # rotate
mirror :name               # forward then backward
scatter :name, prob: 0.3   # randomly drop notes
tense :name                # tighter, more urgent
release :name              # softer, more open
```

### Time shapes

Each pattern has its own sense of time:

```elixir
time: :linear                                    # default, sequential
time: :reverse                                   # backward
time: :drunk                                     # random walk, biased forward
time: curve(:sine, period: 8)                    # oscillate through pattern
time: prob(advance: 0.7, repeat: 0.2, skip: 0.1)  # probabilistic
time: skew(:fast_end)                            # accelerate
time: skew(:slow_end)                            # decelerate
```

### Groups

```elixir
group :rhythm, [:kick, :bass]
stop :rhythm                      # stops both
sync :melody, to: :bass           # align phase
follow :pad, :bass                # follow another pattern
```

## Architecture

```
iex ── DSL ── Parser ── Pattern (GenServer) ── OSC ── scsynth
                              |
                           Clock (ticks at 16th-note resolution)
```

Each named pattern is a supervised process. The clock broadcasts ticks; patterns use pluggable time functions to decide which step to play. Events are immutable structs that flow through parsing, humanization, swing, and OSC encoding before reaching the synth engine.

Patterns are managed through a Registry and DynamicSupervisor — start as many as your CPU and ears can handle.
