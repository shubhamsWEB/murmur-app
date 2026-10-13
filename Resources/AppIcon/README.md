# Murmur's icon: "Voice"

Five rounded bars of a voice waveform in coral, on warm cream paper.

- `appicon.svg` / `appicon-small.svg`: the app icon (1024 × 1024, macOS icon grid). `../AppIcon.icns` is rendered
  from it (scripts/make-icns.py).
- `AppIcon.icon`: the same design as layers for macOS 26 and later (Icon Composer: a cream fill and the wave).
  `build.sh` compiles it into `Assets.car` with `actool`.
- `menubar.svg`: the menubar mark, a boxed three-bar wave. The app draws it in code (`StatusIcon` in
  `Sources/MurmurApp/StatusMenu.swift`).

Colors: paper #FFF8F1 → #F6E7DA (layered fill #FBF3EB); wave #FF8A6B → #F2524A.
