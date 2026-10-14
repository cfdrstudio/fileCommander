# fileCommander brand

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="logo-dark.png">
  <img src="logo-light.png" alt="fileCommander" width="420">
</picture>

**The mark:** two panes (it's a dual-pane file manager), a selected row in amber, and an amber
command badge with › — the "copy to the other pane" action (F5) everything is built around.

## Name

Written **fileCommander**: lowercase *f*, capital *C*, one word. In the wordmark "file" is set
lighter than "Commander".

## Colours

| | Hex | Use |
|---|---|---|
| Commander Blue | `#2A3BC4` | primary brand colour, theme colour, touch-icon background |
| Bright Blue | `#4361FF` | gradient start, highlights |
| Midnight | `#151C5E` | gradient end, dark backgrounds |
| Amber | `#FF9A0F` → `#FFC94A` | the selection and the command badge only |
| Mist | `#D9E0FF` | second pane, soft fills |
| Ink | `#141A3D` | wordmark "Commander" on light backgrounds |
| Slate | `#5A6392` | wordmark "file" on light backgrounds |

Amber is the accent: use it sparingly so the badge stays the focal point.

## Type

Avenir Next (ships with macOS): **Bold** for "Commander", **Medium** for "file". The SVG logos
keep the text live and fall back to Avenir, Nunito Sans, Segoe UI, Helvetica Neue or Arial; use
the PNG logos where exact rendering matters.

## Files

| File | What it is |
|---|---|
| `icon.svg` | app icon master (1024 canvas, macOS 824 px body grid) |
| `mark.svg` | the icon cropped to its body: avatars, beside text |
| `favicon.svg` | simplified mark for 16–48 px (favicons, small app-icon slots) |
| `logo-light.svg/png` | mark + wordmark for light backgrounds |
| `logo-dark.svg/png` | mark + wordmark for dark backgrounds |
| `app/AppIcon.icns` | macOS app icon (bundled by `../build-app.sh`) |
| `app/icon-1024.png` | full-size icon render (App Store-style artwork, README use) |
| `web/` | `favicon.ico` (16/32/48), `favicon.svg`, `favicon-32.png`, `apple-touch-icon.png`, `icon-192/512.png`, `site.webmanifest` |

Using the web set on a site:

```html
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
```

## Usage

- Keep clear space around the mark of at least a quarter of its width.
- Don't recolour the mark, stretch it, add effects, or put the light logo on dark backgrounds
  (use `logo-dark`).
- Below 48 px use `favicon.svg` (or the PNG/ICO renders of it), not `icon.svg`.

## Regenerating

Edit the SVGs, then run `./make-assets.sh`. It uses only macOS tools (Swift/AppKit,
`iconutil`, `python3`) and rewrites `app/`, `web/` and the `logo-*` files.
