# tests/

- `fixtures/generated/` : vidéos **synthétiques** produites par `scripts/make_fixtures.sh` (mire ffmpeg, métadonnées fictives `creation_time` et `location +00.0000+000.0000/`). Non versionnées.
- Les tests eux-mêmes sont à côté du code qu'ils vérifient :
  - `backend/apps-script/test/` — service Apps Script contre le Drive simulé (`node --test`).
  - `SpectreCore/Tests/SpectreCoreTests/` — cœur Swift, scénarios T01–T14 contre le mock HTTP (`swift test`).
  - `TellaTests/SpectreIntegrationTests.swift` — intégration dans l'app (Xcode, Mac uniquement).
- Tout lancer : `./scripts/run_all_tests.sh`. Plan : `docs/TEST_PLAN.md`. Résultats : `docs/TEST_REPORT.md`.
