# App artwork

The Cantrip mark is a pearl-violet **C** casting a warm golden spark: a small,
useful spell on a midnight-amethyst background. The same mark is used by the
Mac and Windows apps, [Cantrip Agent](https://github.com/FlyingViet/CantripIOS) and
[Cantrip Gateway Mac](https://github.com/FlyingViet/CantripGatewayMac).

Run `make artwork` on macOS to regenerate the artwork using native CoreGraphics
and ImageIO, with no fonts, downloaded images, or extra dependencies.
Edit `Scripts/generate-artwork.swift`, not the generated assets:

| Asset | Use |
|---|---|
| `Resources/Cantrip.svg` | Scalable full-color artwork |
| `Resources/CantripIcon.png` | Opaque, full-bleed 1024px iOS master; let iOS apply its own corner mask |
| `Resources/AppIcon.png` / `AppIcon.icns` | Mac icon with rounded tile and transparent desktop padding |
| `windows/assets/Cantrip.ico` | Windows app/installer icon at 16, 24, 32, 48, 64, 128, and 256px |

To sync the companion in a sibling checkout, run
`cp Resources/CantripIcon.png ../Hermes/Sources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`.
Normal app builds use the checked-in PNG/ICO assets; `make app` regenerates
the ignored ICNS as needed without requiring artwork regeneration.
