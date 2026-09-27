# BobTV infrastructure receipt

Repository note (2026-09-28): paths under `server-admin-app/sites/bobtv` below record the original deployment. The maintained frontend, backend, deployment files, and API contract now live in `clubTivi4bob/website`.

## Scope and observed state

On 2026-09-27, `bobtv.briconbric.com` was deployed on CCNODE (`203.24.89.50`) as a separate public site and diagnostic intake. The BobTV application repository and the existing GitHub releases were not changed.

- Cloudflare DNS: explicit proxied `CNAME bobtv -> briconbric.com`, automatic TTL. Before the change the name resolved through the proxied wildcard A record. Dashboard search showed the new record after save, 57/200 records in the zone.
- Origin: dedicated Nginx virtual host with a dedicated Let's Encrypt certificate for `bobtv.briconbric.com`, expiring 2026-12-26. Existing shared `briconbric.com` certificate remains unchanged. `nginx -t` passed, reload completed, and `certbot renew --dry-run --cert-name bobtv.briconbric.com` succeeded.
- Service: FastAPI under the `bobtv` system user at `127.0.0.1:8917`; `/var/lib/bobtv` holds private logs and mirrored releases. The mirror and 14-day log pruning timers are enabled daily.
- Release mirror: `v0.9.1-bob.9`, `v0.8.4-bob.8`, and `v0.8.0-bob.7` are served as local ZIP files. The latest package has SHA-256 `5dc081163ea3b2bc6fe5286306ea916c5c08dc0d5d70df5cf2dc8a3ceb7cc817`, matching the GitHub release digest. Public Range request returned `206`, 1024 bytes, with no redirect URL. The mirror service rerun exited successfully.
- Diagnostic intake: public `POST /api/v1/logs` accepts bounded, field-filtered JSONL. A browser upload of synthetic data returned `201`; its persisted content contained only `time`, `event`, and `rssBytes`, with raw `error` and `stream` excluded. The synthetic upload and its database entry were removed after validation. Invalid payloads and limits are covered in tests.

## Checks

| Check | Result |
|---|---|
| Focused BobTV tests in isolated virtual environment | 4 passed, one upstream Starlette/httpx deprecation warning |
| Full repository `pytest` in project environment | 70 passed |
| Python compileall and `git diff --check` | Passed |
| Origin Nginx syntax, service, mirror, timers | Passed |
| Public HTTPS root, local ZIP Range, complete ZIP download | HTTP 200 and 206; no GitHub redirect; complete download SHA-256 matched release digest |
| Desktop 1365x850 and mobile 390x844 browser | 3 releases visible; no overflow, console errors, failed requests, or HTTP 4xx/5xx |
| BobTV certificate renewal dry run | Passed |

Screenshots: [desktop](desktop.png), [mobile](mobile.png). The screenshot-based Gemini review could not run because both callable candidate routes reported no available accounts; direct screenshots and browser checks were completed.

## Boundaries

The existing BobTV release binaries do not upload automatically. The integration contract and implementation acceptance prompt are at `sites/bobtv/CLIENT_INTEGRATION_PROMPT.md`. Mainland-China connectivity was not measured from a mainland network; the download response observed here is served from the BobTV origin and does not redirect users to GitHub.

An initial attempt to extend the shared multi-domain certificate failed because several existing applications did not serve ACME challenge paths. The dedicated BobTV certificate and its renewal dry run succeeded without changing that shared certificate. The service is intentionally scoped to the BobTV host and does not add a link or route to the separate main-site application.
