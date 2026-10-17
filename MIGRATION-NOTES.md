# Part 4 — GitLab CI → GitHub Actions

Source: `ci/legacy.gitlab-ci.yml`. Target: `.github/workflows/ci.yml`.

## What changed, and why

| Legacy | Problem | Now | Why |
|---|---|---|---|
| `sonar_check` with `allow_failure: true` | A scan that can't fail is decoration. | `sast` job runs Semgrep with `--error`, and `image` `needs: sast`. | Any finding fails the pipeline. Semgrep runs with no server and no account. SonarQube CE needs a JVM-sized container and a token. |
| `npm test \|\| echo "tests flaky, continuing"` | Failing tests always pass. | `pytest -q` as a plain step. | Flaky tests should be fixed or quarantined, not hidden. The service is now Python, so the Node 16 job is gone. |
| Hard-coded `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `variables:` | Credentials in the repo. Even the AWS documentation examples here show the wrong pattern, and any real keys would be leaked in git history. | No static keys. The pipeline has no AWS step. For AWS access later, use GitHub OIDC with an IAM role. | Short-lived credentials, nothing to rotate or leak. |
| `docker login -p "$CI_REGISTRY_PASSWORD"` | Password on the command line, visible in process listings. | `docker/login-action` with `GITHUB_TOKEN`. | Scoped, short-lived token; no password handling. |
| `docker build -t $IMAGE:latest` and `push :latest` only | Not reproducible. `latest` can't be traced to a commit. | Tag = bare full git SHA (`type=sha,format=long,prefix=`). No `latest`. | Immutable, traceable. `scripts/20-deploy.sh` deploys exactly `HEAD`'s SHA, so the tag format must match (the action's default `sha-` prefix would not). |
| Single-arch build | The legacy job built for the runner's arch only. Apple Silicon k3s nodes are arm64 and would fail with `exec format error`. | `linux/amd64,linux/arm64` via QEMU + Buildx. | Works on any reviewer laptop and on Graviton nodes in production. |
| `docker:20.10` + `dind` service | Old Docker, privileged service container. | `docker/setup-buildx-action` on the runner. | Maintained action; no privileged sidecar. |
| `node:16` | End-of-life runtime. | Python 3.12 (the app was rewritten in Part 1). | — |
| `only: [master]` | Deprecated syntax, and no pull request checks. | `on: push` to `main` and `pull_request`. Image push runs only on `push`. | PRs are tested and scanned; forks never get a push token. |
| `bitnami/kubectl:1.24` + `kubectl set image … :latest` with `when: manual` | Old client; deploy by mutating the cluster outside git; `latest` tag. | No deploy job in CI. Argo CD syncs the chart from git (`scripts/20-deploy.sh`). | GitOps: the cluster state comes from a commit. CI doesn't need cluster credentials. |
| `KUBECONFIG_CONTENT` variable written to `/tmp/kubeconfig` | A long-lived cluster credential in CI. | Removed. | Argo CD runs inside the cluster and needs no external credential. |
| Sonar `-Dsonar.login=$SONAR_TOKEN` on the command line | Token in process listings. | Not applicable. | — |
| Every push runs a full pipeline | Redundant runs pile up. | `concurrency` cancels stale runs on the same ref. | Saves runner time. |

## Permissions

The workflow sets `permissions: contents: read` at the top. Only the `image` job adds `packages: write`,
and only for GHCR. Least privilege per job.

## Migrating the GitLab CI variables and secrets (for a real project)

1. **Inventory.** List all variables with the GitLab API (`GET /projects/:id/variables`), noting which are
   masked, protected, and scoped to an environment. Don't copy values yet.
2. **Classify.** Config (image names, regions, URLs) goes into GitHub **variables**. Secrets (tokens, passwords)
   go into GitHub **secrets** or, better, are removed by moving to OIDC or a secrets manager.
3. **Rotate before moving.** Any credential that ever lived in a `.gitlab-ci.yml` file, even as an example, is treated
   as exposed. Rotate it, then move the new value only if it is still needed.
4. **Recreate environments.** Protected variables map to GitHub **environments** with required reviewers and
   branch restrictions (for example, `production` only from `main`).
5. **Prefer OIDC.** For AWS, create an IAM role that trusts `token.actions.githubusercontent.com` for this repo, and
   use `aws-actions/configure-aws-credentials` with `role-to-assume`. No static keys at all.
6. **Set and verify.** Use `gh secret set NAME --env ENV` (or `--body` from a file, never the shell history). Run the
   pipeline on a branch first and check that no value appears in logs.
7. **Cut over.** Disable the GitLab pipeline only after one green GitHub run on `main`.

## What I did not migrate

- The Sonar project and its server (replaced by Semgrep).
- Container signing and Trivy scanning (bonus, not done).
- The `manual` deploy job (replaced by Argo CD).
