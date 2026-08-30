# Cardwire GPU Mode

A Noctalia v5 plugin that adds a bar widget + picker panel for switching
GPU mode through [cardwire](https://github.com/OpenGamingCollective/cardwire),
the eBPF-based GPU manager (successor to `supergfxctl`/`asusctl` for this use
case). It exposes the three modes cardwire actually supports on a laptop:

- **Integrated** — `cardwire set integrated` (iGPU only, best battery life)
- **Hybrid** — `cardwire set hybrid` (both GPUs, apps choose)
- **Smart** — `cardwire set smart` (dGPU blocked by default, auto-allowed for
  approved apps)

`manual` mode exists in cardwire too, but it's desktop-only (block/unblock
individual GPU IDs) and isn't exposed here.

## Requirements

- `cardwire` installed and on `PATH` (declared in `dependencies` so it shows
  in the plugin listing, but it does not block enabling the plugin).
- The `cardwire` user/group permissions needed to call `cardwire set` without
  a password prompt (see cardwire's own docs for your distro).

## How it works

- `service.luau` polls `cardwire get` on an interval (default 3s, configurable
  in **Settings → Plugins**) and publishes the parsed mode over
  `noctalia.state`.
- `widget.luau` is a bar widget that shows the current mode's glyph + label,
  pulled from that shared state. Left- or right-click opens the panel.
- `panel.luau` renders a themed list of the three modes (colors come from
  Noctalia's palette tokens, so it follows whatever theme is active). Tapping
  a row runs `cardwire set <mode>` and updates the shared state on success,
  or shows an error notification + inline message on failure.

## Install

Drop this whole `cardwire-gpu/` directory under
`$XDG_DATA_HOME/noctalia/plugins/cardwire-gpu/` (or add a path source
pointing at wherever you keep it), then enable it from Noctalia's plugin
settings. Add the bar widget to a bar with:

```toml
[bar.default]
end = [
  "you/cardwire-gpu:gpu_mode",
  # ...your other widgets
]
```

If you plan to publish this to `community-plugins`, rename the `id`/`author`
fields in `plugin.toml` from the `you/cardwire-gpu` placeholder to your own
`<github-username>/cardwire-gpu`, and update the `PANEL_ID` string in
`widget.luau` to match.

## Notes / caveats

- cardwire is early-stage software (breaking changes expected upstream), and
  the exact text `cardwire get` prints isn't documented in a stable schema.
  `service.luau` parses it defensively — it just looks for the substrings
  `integrated` / `hybrid` / `smart` / `manual` anywhere in the output — but
  if a future cardwire release renames its modes, update `KNOWN_MODES` in
  `service.luau` and the mode list in `panel.luau`/`widget.luau` to match.
- If `cardwire` isn't found on `PATH`, the widget shows an error glyph
  instead of silently doing nothing.
