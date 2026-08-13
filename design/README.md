# Design reference

Imported from the Claude Design project **"Flutter app for maintenance
operations"** (`243e46a5-e231-4419-bdf6-a81c34513b88`).

| File | What it is |
| --- | --- |
| `Transvolt EM App.dc.html` | The interactive prototype — every screen and flow |
| `support.js` | The `dc-runtime` the prototype needs to render. Do not edit; it is generated |
| `assets/transvolt-logo.png` | Client-supplied wordmark, also copied to `../app/assets/images/` |
| `HANDOFF.md` | The full design spec, verbatim — tokens, screens, behaviour, master data |

## Running the prototype

`support.js` fetches React from a CDN, so open it over HTTP rather than
`file://`:

```sh
cd design
python3 -m http.server 8000
# then open http://localhost:8000/Transvolt%20EM%20App.dc.html
```

## Status

This is a **reference artifact, not source**. The shipping implementation lives
in `../app` (Flutter). When the design project changes, re-import here and diff
against the app rather than editing either copy by hand.
