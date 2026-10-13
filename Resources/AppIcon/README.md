# Murmur's icon: "Starling"

A small coral starling whose wing is a sound wave, on warm cream paper. (A murmuration is a flock of starlings.)

- `appicon.svg` / `appicon-small.svg`: the app icon (1024 × 1024, macOS icon grid; the small one drops the legs and
  thickens the wing for 16–32 px). `../AppIcon.icns` is rendered from it (scripts/make-icns.py).
- `AppIcon.icon`: the same design as layers for macOS 26 and later (Icon Composer: a cream fill, the bird, and the
  wing on its own layer so the glass gives it depth). `build.sh` compiles it into `Assets.car` with `actool`.
- `menubar.svg`: the menubar mark, the bird's silhouette with the eye and wing cut out. The app draws it in code
  (`StatusIcon` in `Sources/MurmurApp/StatusMenu.swift`); `StarlingMark` (VoiceKit) draws it in the app's views.

Geometry (100-unit grid): tail (30,58)(12,47)(16,67); body ellipse c(48,60) 24×19; head c(66,42) r13; beak
(78,40.5)(89,44)(78,47.5); eye c(69,39) r2.6; wing M31 60 q4.5 −8 9 0 t9 0 t9 0; legs x 44 and 53, y 78.5–84.5.
Colors: paper #FFF8F1 → #F8E6D8 (layered fill #FBF3EB); bird #FF8670 → #F25A4C; tail #E2554A; beak, eye #221E1C;
wing #FFF6EF.
