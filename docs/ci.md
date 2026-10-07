# CI: GitHub Actions runners on the cluster

GitHub Actions jobs for `kleintech/*` repos run on the k3s cluster, on self-hosted runners
managed by **Actions Runner Controller (ARC)** in runner-scale-set mode. Workflows use
`runs-on: lab-k3s`. Starter workflow: `templates/app/.github/workflows/ci.yaml`.

Research verified 2026-10-07 against GitHub's docs (URLs below).

## Is this allowed on GitHub Free, for a personal account?

**Yes, for both public and private repos.** GitHub's billing page states: "GitHub Actions usage is
free for self-hosted runners" — no plan restriction and no public/private split; the
public/private distinction only applies to minutes on GitHub-hosted runners.
[billing: GitHub Actions](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
[about self-hosted runners](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners)
("free to use with GitHub Actions, but you are responsible for the cost of maintaining your
runner machines").

- **Pricing caveat:** on 2025-12-16 GitHub announced a $0.002/min "cloud platform" charge for
  self-hosted runner minutes in *private* repos from 2026-03-01, then postponed it
  ("We're postponing the announced billing change for self-hosted GitHub Actions to take time
  to re-evaluate our approach"). As of this writing no new date exists and the billing docs still say
  free. If it returns, it would bill private-repo minutes on these runners too.
  [community discussion #182089](https://github.com/orgs/community/discussions/182089),
  [summary](https://samexpert.com/github-actions-pricing-backlash-2026/)
- **Security caveat, public repos:** "Self-hosted runners should almost never be used for public
  repositories on GitHub, because any user can open pull requests against the repository and
  compromise the environment."
  [secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)
  These runners are *privileged* dind pods on the LAN-attached node, so only register
  private repos (or public repos with fork-PR workflows locked down to require approval).

## Runner level for a personal account: per repository only

Self-hosted runners attach at the **repository**, **organization** or **enterprise** level; there
is no user-account level. For a personal account: "To add a self-hosted runner to a user
repository, you must be the repository owner."
[add runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)

So ARC needs **one runner scale set per repo** (`githubConfigUrl: https://github.com/kleintech/<repo>`).
`argocd/apps/arc-runners.yaml` is an ApplicationSet that stamps one out per list element.
(An org-level scale set could serve all repos at once, but that means moving the repos into
a GitHub organization.)

## Token: what ARC needs for repo-level scale sets

From [Authenticating ARC to the GitHub API](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api):

| option | repository runners (our case) | organization runners (for reference) |
|---|---|---|
| fine-grained PAT (recommended here) | Repository permission **Administration: Read and write** (Metadata: Read is added automatically) | Administration: Read + Self-hosted runners: Read and write |
| classic PAT | scope **`repo`** | scope `admin:org` |
| GitHub App | Repository permission **Administration: Read and write** (+ Metadata: Read) | Self-hosted runners: Read and write (org) + Metadata: Read |

GitHub recommends a GitHub App for repo/org-level runners. A personal account can own an App and
install it on its own repos; the secret then holds `github_app_id`,
`github_app_installation_id`, `github_app_private_key` instead of `github_token` (same secret
name; `bootstrap/10-secrets.sh` would need extending). The PAT is the simpler start.

**Fine-grained PAT setup:** GitHub -> Settings -> Developer settings -> Fine-grained tokens ->
resource owner `kleintech`, *Only select repositories* (every repo listed in
`arc-runners.yaml`), Repository permissions -> Administration: Read and write. Put it in
`~/.config/lab-k3s/secrets.env` as `GITHUB_RUNNER_TOKEN=...` and run `bootstrap/10-secrets.sh`
(creates `arc-runners/github-runner-token`, key `github_token`). When the token expires the
listeners fail to authenticate and jobs queue forever — note the expiry date.

## What is deployed

| file | what |
|---|---|
| `argocd/apps/arc-controller.yaml` | chart `gha-runner-scale-set-controller` **0.15.0**, ns `arc-systems`, release `arc` |
| `platform/ci/controller-values.yaml` | log level info, modest resources, SA name pinned to `arc-gha-rs-controller` |
| `argocd/apps/arc-runners.yaml` | ApplicationSet: chart `gha-runner-scale-set` **0.15.0** per repo, ns `arc-runners`, release + scale set name `runner-<repo>` |
| `platform/ci/runner-values.yaml` | shared: secret `github-runner-token`, label `lab-k3s`, min 0 / max 4, `containerMode: dind`, controller SA |

Chart source: `oci://ghcr.io/actions/actions-runner-controller-charts/<chart>`; 0.15.0 is the
latest tag in GHCR for both charts as of 2026-10-07 (ARC 0.15.0 released 2026-10-01,
[changelog](https://github.blog/changelog/2026-10-01-actions-runner-controller-release-0-15-0)).
Upgrade both charts together — the controller and scale-set charts must be the same version.

Design notes:

- **`runs-on: lab-k3s` is a label, not the scale set name.** The scale set name is also the
  Kubernetes `AutoscalingRunnerSet` name, and all scale sets share `arc-runners`, so names
  must differ per repo (`runner-<repo>`). The shared handle is `scaleSetLabels: [lab-k3s]`
  (multi-label support, ARC 0.14.0+, [changelog](https://github.blog/changelog/2026-03-19-actions-runner-controller-release-0-14-0/),
  [PR #4408](https://github.com/actions/actions-runner-controller/pull/4408)). `runs-on: runner-<repo>` also works.
- **`controllerServiceAccount` is set explicitly.** Without it the scale-set chart discovers the
  controller with a Helm `lookup`, which returns nothing under Argo CD and fails the render.
- **Label propagation:** the controller is told not to copy `app.kubernetes.io/instance` /
  `argocd.argoproj.io/instance` onto resources it creates, so Argo CD does not adopt and prune
  the listener and runner pods ([ARC #3533](https://github.com/actions/actions-runner-controller/issues/3533)).
- **dind** means each runner pod has a privileged `docker:dind` sidecar; jobs can
  `docker build`/`docker push` to `registry.lab.kleincogroup.com`. Nothing is cached between jobs.

## Adding a repo

1. Add `- repo: <name>` to the list in `argocd/apps/arc-runners.yaml` (lowercase, `[a-z0-9-]`,
   ≤ 38 chars — it becomes part of Kubernetes names).
2. Add the repo to the fine-grained PAT's repository access.
3. Commit and push `main`. Check: `kubectl -n arc-runners get autoscalingrunnersets` and the
   repo's Settings -> Actions -> Runners page shows `runner-<name>`.
4. In the repo, use `runs-on: lab-k3s` (copy `templates/app/.github/workflows/ci.yaml`).

## Troubleshooting

- Listener pod (`arc-systems`, `runner-<repo>-*-listener`) logs show auth errors -> token
  expired / missing Administration permission / repo not in the token's repo list.
- Job stuck "Waiting for a runner": `kubectl -n arc-runners get ephemeralrunners,pods`.
- Network hangs inside `docker build` (e.g. `npm install` stalling on TLS) can be an MTU
  mismatch: dind's bridge defaults to 1500 while flannel VXLAN is 1450. The fix is a custom
  runner template with `dockerd --mtu=1450` (`containerMode` cannot set dind args).
