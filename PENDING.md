# Pending work

State as of the first commit. Ordered by what blocks the most.

## 1. Backend: site management — **blocks most of the Site section**

`backend/PROMPT_site_management.md` is a complete, self-contained brief. Run it
in `backend/`. Until it lands, the connected API still speaks `depot` and has no
site/config/import endpoints, so the client detects that at sign-in and runs in
legacy mode: registers and users work against the live API, but Sites, Fleet
editing, Docking schedule and Import are read-only and say so.

Covers: the depot→site rename, `super_admin`, first-class sites, editable
vehicles with odometers, the preventive-maintenance config, the odometer
scheduler, spreadsheet import, and the master lists becoming objects.

When it is done, delete the legacy branches in
`app/lib/data/api/api_repositories.dart` (`_requireSiteManagement`, the
`/master/depots` and `/master/buses` fallbacks) and the `ApiCapabilities` probe
in `api_client.dart`, and set `scopeParam` to `site` unconditionally.

## 2. Microsoft SSO

`ApiAuthRepository.signInWithMicrosoft` throws a clear "use your User ID"
message. The backend's `POST /auth/sso` already does real Entra ID validation
(JWKS, iss, aud, exp) — what is missing is MSAL on the device to obtain the
token. Set `MS_TENANT_ID` / `MS_CLIENT_ID` on the API, then wire an MSAL client
and post the id_token.

## 3. Photo attachment

`PhotoAttachButton` toggles a flag only. The backend endpoints exist
(`POST/DELETE /entries/{id}/photo`). Needs `image_picker`, then an
`uploadPhoto` on `EntryRepository` calling `ApiClient.upload` — the multipart
path is already written and used by the import.

## 4. Offline capture

Ground staff work with patchy connectivity. Entries should queue locally and
sync when the network returns. The repository interface is the right seam: a
`QueuedEntryRepository` decorating the real one, backed by local storage. No UI
change needed beyond a pending indicator.

## 5. Live-socket integration test

`app/test/integration/api_live_test.dart` self-skips when the API is
unreachable, and **could not execute in the sandbox this was built in** — the
Dart VM's sockets were intercepted, so every request came back as an empty 400
while `curl` succeeded. Run it yourself with the API up:

```sh
cd backend && API_PORT=8123 PUBLIC_BASE_URL=http://localhost:8123 docker compose up -d
cd ../app && flutter test test/integration/api_live_test.dart
```

If it passes, the contract tests in `app/test/api_contract_test.dart` (which do
run, against captured real responses in `app/test/fixtures/`) stay as the fast
regression net and this becomes a smoke test.

## 6. Smaller things

- **Widget and golden tests.** None yet. The logic is well covered; the widgets
  are verified only by having been driven in a browser.
- **Mobile platforms.** Only web is scaffolded:
  `cd app && flutter create --platforms=ios,android,macos .`
- **`.xlsx` import offline.** The demo reads `.csv` only by design — Excel
  parsing is the server's job. Nothing to do unless offline xlsx is wanted.
- **Entry form does not yet offer "record service".** Completing a PM entry
  could offer to close out the matching service plan; today that is a separate
  action on the Docking pane.
- **Import profile editing.** A saved profile can be used or deleted, not
  re-mapped without re-uploading a file.
- **`design/` is a frozen reference.** If the Claude Design project changes,
  re-import rather than hand-editing either copy.

## Verified at this commit

- `flutter analyze` — clean.
- `flutter test` — 177 passing.
- `flutter build web --release` — succeeds.
- Driven end to end in Chrome: login (super admin and manager), site picker,
  home, register entry form, registers with filters and export, breakdowns,
  Site → Fleet / Master data / Docking / Import, Admin → Sites / Users,
  profile with a real password change, and the 430px mobile layout.
- The backend was run locally on `:8123` and its real responses captured as
  test fixtures; that is what caught the client and server disagreeing about
  register `data` field names.
