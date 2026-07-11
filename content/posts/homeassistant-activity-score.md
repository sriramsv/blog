+++
date = '2026-07-11T06:29:57Z'
draft = false
title = 'Detecting sleep without wearing a watch to bed: a Home Assistant activity score'
tags = ['home-assistant', 'smart-home', 'sleep-tracking', 'automation', 'bayesian']
+++

I wanted my house to know when I'd gone to bed. I do own an Apple Watch, but wearing it overnight
is a hassle — it means remembering to charge it during the day instead of overnight, and honestly
a watch on my wrist all night is just uncomfortable. So instead of leaning on wrist-based sleep
tracking, I built the detection out of presence sensors already in the walls: mmWave motion
sensors, a bed sensor, and whatever the TV and Sonos happen to be doing.

It turned into two related but distinct pieces: a continuous "activity score" that acts as a
dashboard diagnostic, and a Bayesian classifier that actually decides when the house should
switch into Sleep mode.

## The building block: per-room activity fractions

mmWave presence sensors are chatty — they flicker on and off far more than a human's actual
movement would suggest. Rather than reacting to raw on/off state, every room gets a
`history_stats` sensor that computes the fraction of the last five minutes it's spent "on":

```yaml
- platform: history_stats
  name: "Living Room Activity Fraction"
  entity_id: binary_sensor.living_room_presence
  state: "on"
  type: ratio
  duration: "00:05:00"
  end: "{{ now() }}"
  scan_interval: 60
```

This is effectively a low-pass filter: a single missed detection or a stray retrigger gets
averaged out instead of causing a rapid state change downstream. Six of these exist — living
room, dining, kitchen, stairs, bedroom, and guest room.

## Combining them into one number

`sensor.activity_score` is a weighted sum of those fractions, plus a bonus if media is playing,
normalized to a 0–1 range:

```jinja
{% set lr      = states('sensor.living_room_activity_fraction') | float(0) / 100 * 3 %}
{% set dining  = states('sensor.dining_activity_fraction')     | float(0) / 100 * 2 %}
{% set kitchen = states('sensor.kitchen_activity_fraction')    | float(0) / 100 * 2 %}
{% set stairs  = states('sensor.stairs_activity_fraction')     | float(0) / 100 * 1 %}
{% set guest_mode = states('input_select.guest_mode') | lower %}
{% set guest = states('sensor.guest_room_activity_fraction') | float(0) / 100 * 2
               if guest_mode != 'off' else 0 %}
{% set presence = lr + dining + kitchen + stairs + guest %}
{% set tv_on    = is_state('media_player.apple_tv', 'playing') or is_state('media_player.lg_tv', 'playing') %}
{% set sonos_on = is_state('media_player.living_room_sonos', 'playing') %}
{% set media    = (2 if tv_on else 0) + (1 if sonos_on else 0) %}
{{ ([((presence + media) / 9), 1.0] | min) | round(2) }}
```

The weights aren't scientific — living room activity counts for more than stairs, guest room only
counts at all if someone's staying over. It's a rough proxy for "how much is going on in the
house right now," and it's mostly there to look at on a dashboard: a `mini-graph-card` showing
the last 24 hours, bounded 0–1, next to the raw sleep booleans. Notably, it doesn't drive any
automation directly — it's a diagnostic, not a decision input.

## The thing that actually detects sleep

Deciding "has this person gone to sleep" turned out to need something more deliberate than a
single blended number. That's `binary_sensor.sleeping`, built on Home Assistant's native
`bayesian` platform: a prior probability of 0.40, a threshold of 0.85, and four observations —

- Is it currently within the overnight window (11pm–10am)?
- Is the bed-presence sensor on?
- Is bedroom activity fraction ≥ 60%?
- Is living-room presence off?

Each observation nudges the posterior probability up or down; once it crosses 0.85, the sensor
flips to "on":

```yaml
binary_sensor:
  - platform: bayesian
    name: Sleeping
    unique_id: bayesian_sleeping
    prior: 0.40
    probability_threshold: 0.85
    observations:
      # Time window: 11pm–10am — all observed sleep periods fall fully in this window
      - platform: template
        value_template: "{{ now().hour >= 23 or now().hour < 10 }}"
        prob_given_true: 0.95
        prob_given_false: 0.12

      # Bed occupied: at least one person in bed
      - platform: state
        entity_id: binary_sensor.bed_presence_2d2168_bed_occupied_either
        to_state: "on"
        prob_given_true: 0.90
        prob_given_false: 0.20

      # Bedroom presence fraction ≥ 60% over last 10 min (smoothed via history_stats)
      - platform: numeric_state
        entity_id: sensor.bedroom_presence_fraction
        above: 60
        prob_given_true: 0.80
        prob_given_false: 0.30

      # Living room presence off: no one in living room
      - platform: state
        entity_id: binary_sensor.living_room_presence
        to_state: "off"
        prob_given_true: 0.85
        prob_given_false: 0.30
```

That raw signal then gets debounced — 5 minutes on, 5 minutes off — into
`binary_sensor.sleeping_smoothed`, which is the one everything else actually listens to:

```yaml
template:
  - binary_sensor:
      - name: "Sleeping (Smoothed)"
        unique_id: sleeping_smoothed
        icon: mdi:sleep
        state: "{{ is_state('binary_sensor.sleeping', 'on') }}"
        delay_on:
          minutes: 5
        delay_off:
          minutes: 5
```

## Wiring it into house mode

`sleeping_smoothed` staying "on" for 10+ minutes during the overnight window triggers a
transition to Sleep mode. Stripped down to the essentials, the trigger looks like this:

```yaml
automation:
  - alias: "Transition: Home->Sleep"
    trigger:
      - trigger: state
        entity_id: binary_sensor.sleeping_smoothed
        to: "on"
        for:
          minutes: 10
    condition:
      - condition: time
        after: "22:00:00"
        before: "07:00:00"
    action:
      - action: input_select.select_option
        target:
          entity_id: input_select.house_mode
        data:
          option: "Sleep"
```

In practice mine has a couple more guard conditions (an opt-out toggle, a check that we're not
already in Sleep mode) and fires a passive notification alongside the mode switch, but the shape
above is the whole idea: wait for sustained confidence, then flip one state.

Entering Sleep mode cascades through the rest of the house:

- notifications get muted
- security arms
- per-room `_sleep` events fire, turning off lights via a `room_sleep_mode` blueprint
- presence detection in common areas gets disabled (so the now-empty living room doesn't confuse
  anything)
- the garage door closes
- a tower fan kicks on
- if a door's still open, a browser_mod card pops a warning

Waking is the mirror image, gated on either the bed sensor clearing before a scheduled wake time
(`input_datetime.sleep_mode_off`) or a 2-hour timeout if it doesn't.

## What's next

The biggest weakness right now is latency. The 5-minute activity-fraction window plus the 5-minute
on/off debounce on `sleeping_smoothed` stacks up fast — by the time the house actually commits to
Sleep mode, I've often already been in bed for 10-15 minutes. That's fine for muting notifications,
but it's noticeably slow for anything I'd want to feel instantaneous, like lights. The next round
of work is tightening that feedback loop: shortening the smoothing windows where the sensors allow
it, and looking at whether a faster-reacting signal (bed sensor transition, say) can front-run the
Bayesian classifier for the parts of Sleep mode that don't need to wait for high confidence.

The other lever is just more data. Right now the classifier only sees room presence and bed
occupancy — adding a couple more low-effort signals (phone charging state, lock/alarm-arm events,
ambient light level in the bedroom) would give the Bayesian model more independent observations
to work with, which should let it reach the same confidence threshold faster without loosening it.

The lesson so far: you don't need to wear anything to infer sleep reasonably well. A handful of
cheap presence sensors, a low-pass filter, and a Bayesian classifier with a sensible threshold
gets you most of the way there — and unlike a watch's black-box sleep score, every input into
the decision is something I can query, graph, and tune myself.
