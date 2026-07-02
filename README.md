# Tuntun

Tuntun is an iOS keyboard inspired by [Minuum](https://minuum.com): a full
keyboard compressed into a single line, about a third the height of the one
you use now, so you keep seeing the app you're typing in. Flick right for
space, left to delete a word, up for capitals, down for return; hold to zoom
in on an exact letter. Named after *escribir al tuntún* - typing by feel.

## Building

The Xcode project is generated and not committed. With
[XcodeGen](https://github.com/yonaskolb/XcodeGen) installed:

    xcodegen generate
    open Fila.xcodeproj

The core logic tests run on the Mac, no simulator needed:

    swift test --package-path FilaCore

## Architecture

    App (SwiftUI host: onboarding, playground, type tuner)
     └── FilaKit  framework: keyboard UI + engine glue; bundles Resources/Models
          └── FilaCore  SwiftPM package: decoder, language models, layout — Foundation-only
                ↑ also used by Tools/ModelBuilder and Tools/DecodeBench (macOS CLIs)

    Extension (keyboard) is a thin host over FilaKit; it links the framework
    without embedding it, resolving the app's copy at runtime.

Two deliberate choices worth knowing before "fixing" them:

- **FilaKit is an XcodeGen framework target, not a SwiftPM package.** Embedded
  once in the app and linked by the extension, the framework (and the ~15 MB of
  language models inside it) exists once on disk, shared by both processes. A
  package would copy its resource bundle into every client.
- **The models live inside the FilaKit bundle, not an App Group.** The active
  language's `values.blmr` is memory-mapped straight from the bundle, keeping
  resident memory well under the keyboard extension's ~50 MB ceiling.

To regenerate the language models from their public corpora, run
`Tools/rebuild-models.sh` (sources and licenses in [ATTRIBUTION.md](ATTRIBUTION.md)).