# Murmur's icon: "Voice"

Five rounded bars of a voice waveform, amber to coral, on a deep indigo square.

- `appicon.svg` / `appicon-small.svg`: the app icon (1024 × 1024, macOS icon grid). `../AppIcon.icns` is rendered
  from it (scripts/make-icns.py).
- `AppIcon.icon`: the same design as layers for macOS 26 and later (Icon Composer: an indigo fill and the wave).
  `build.sh` compiles it into `Assets.car` with `actool`.
- `menubar.svg`: the menubar mark, a boxed three-bar wave. The app draws it in code (`StatusIcon` in
  `Sources/MurmurApp/StatusMenu.swift`).

Colors: background #2A2150 → #14102A (layered fill #1C1636); wave #FFC46B → #FF6F91.
