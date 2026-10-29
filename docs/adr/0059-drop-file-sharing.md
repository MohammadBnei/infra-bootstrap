# ADR-0059: drop: file sharing for the SilverBullet spaces at `files.bnei.dev`

**Status:** Accepted, not live. Waits on drop's first image (build-runner
onboarding) and on `garage-configure.yml --tags bucket_ops` (Rollout).
**Date:** 2026-10-18
**Related:** [ADR-0030](0030-expose-garage-s3-externally.md) (Garage SigV4
only, path-style), [ADR-0052](0052-wird-adminweb-forwardauth.md) (forward_single proxy
provider in the shared outpost blueprint), [ADR-0058](0058-shared-notes-silverbullet.md)
(SilverBullet, `shared-notes`, N MG on the opus space only), `MohammadBnei/drop`.

## Context

M BN and N MG write in SilverBullet (opus.bnei.dev, notes.bnei.dev). They
need to share files: internally, between themselves, and with external
clients (a devis PDF, a deliverable). SilverBullet attachments land in the
space's git repo, which is fine for a small image and wrong for client files.

The hq app and agent-fleet both have file or PDF code, but both are bound
to `platform-admins`, and N MG is deliberately not in it (ADR-0058).

## Decision

1. **A small Go service, `drop`, signs URLs and never handles bytes.**
   - Uploads: the browser asks drop for a presigned PUT and sends the file
     straight to `s3.bnei.dev`. That host is grey-cloud, so Cloudflare's
     100MB body cap (ADR-0038) does not apply.
   - Bucket `drop` with a 20GB quota, which also serves as the upload cap.
     CORS allows only PUT from `https://files.bnei.dev`.
2. **Internal links** are `https://files.bnei.dev/f/<key>`. Behind login,
   that URL redirects (302) to a presigned GET valid for 5 minutes.
3. **Public links** are presigned GETs valid for 7 days, the SigV4 ceiling.
   - Only a logged-in member can mint one, and the call requires an
     `X-Requested-With` header to stop CSRF.
   - Every GET carries `response-content-disposition=attachment`, so an
     uploaded HTML file never renders on `s3.bnei.dev`.
   - Garage stays SigV4-only (ADR-0030 Decision 2). No website mode.
4. **Access.**
   - drop has its own forward_single proxy provider in
     `authentik-blueprint-forwardauth.yaml` (wird-admin's reason: the
     outpost list needs `!KeyOf`).
   - That provider is bound to `shared-notes` in its own policy file, with
     its own Middleware and its own callback route.
   - Which space each user sees is drop's `DROP_SPACES` map: M BN gets opus
     and notes, N MG gets opus. This follows ADR-0058.
5. **drop trusts `X-authentik-username`.** A NetworkPolicy in drop's values
   admits only the `traefik` namespace, so no other namespace's pod can
   send that header directly. (Amended 2026-10-29: the host identity and any
   cross-namespace IngressRoute through Traefik still reach drop; see the
   common-app-chart `networkPolicy`/`auth.trustsHeaders` section of
   gitops/README.md.)

PDF export is not part of drop: SilverBullet renders a page to HTML and
prints it in the browser (a Space Lua exporter in each space's `CONFIG`).

## Consequences

- **A public link is a bearer URL.** Anyone who has it can download the file
  for 7 days. Deleting the file in drop revokes it. The pod deletes over the
  LAN endpoint; the key's `--write` grant covers DeleteObject.
- **Adding a user means editing `DROP_SPACES` in drop's values.** That is
  fine for two people.

## Rollout

1. `MohammadBnei/drop`: onboard it to the build runner (build-runner-ops
   skill: PAT repository list, `build_runner_repos`, and the OIDC
   `boundClaims.repository`). The first CI run replaces `tag: "unreleased"`.
2. `ansible-playbook ansible/playbooks/garage-configure.yml --tags bucket_ops`
   creates bucket `drop` and writes `DROP_S3_*` to Infisical.
3. Merge this PR. If the policy blueprint lands before the `drop`
   application exists, restart the authentik worker once.
4. Verify:
   - M BN sees opus and notes, N MG sees only opus.
   - A `/f/` link fails in a private window.
   - A public link downloads the file in a private window.
