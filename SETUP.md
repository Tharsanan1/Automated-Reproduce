# Setup guide — automated bug reproduction

This bundle wires up an automated reproduction pipeline: a lead launches a
run — either by labeling a GitHub issue or via `workflow_dispatch` — and a
workflow downloads the right product build, updates it to the requested stage,
and runs Claude (via the Claude Code GitHub Action) to attempt a reproduction and
post the result as a comment.

Identity vs. run params: `<product>-<version>` identifies the bug and stays a bare
label. The settings that configure one attempt — model, budget, update level,
update stage — are per-run, so they carry a `reproduce-` prefix as labels (visible
at a glance) or are passed as `workflow_dispatch` inputs.

## 1. Where the files go

Copy the contents of this bundle into the **product repository** (the repo that
holds the issues), preserving the paths:

```
<your-repo>/
└── .github/
    ├── workflows/
    │   └── claude-repro.yml        # the workflow
    ├── scripts/
    │   └── prepare-product.sh      # extract + update the product
    └── java-matrix.json            # per-product version -> JDK map
```

After copying, make sure the script is executable (the workflow also `chmod`s it,
but it's cleaner in git):

```bash
git update-index --chmod=+x .github/scripts/prepare-product.sh
```

The reproduce **skill is not committed here** — the workflow clones it from your
skills repo at run time into `.claude/skills/reproduce/`. Keep the skill as a
plain skill folder (a `SKILL.md` plus any scripts), **not** a plugin-packaged one,
to avoid the workspace-trust prompt in headless mode.

## 2. Install the GitHub App

Install the Claude GitHub App on the repo (the easiest path is running
`/install-github-app` from Claude Code in your terminal). This is what lets the
action authenticate and act on issues.

## 3. Secrets and variables

Set these under **Settings → Secrets and variables → Actions**.

**Secrets** (sensitive — never exposed to the agent):

| Secret | What it is |
| --- | --- |
| `ANTHROPIC_API_KEY` | API key from a dedicated Console **workspace** (see §5) |
| `AWS_ROLE_ARN` | IAM role the runner assumes via OIDC to read the S3 bucket |
| `WSO2_UPDATE_USER` | update.wso2.com username |
| `WSO2_UPDATE_PASS` | update.wso2.com password |
| `SKILLS_REPO_TOKEN` | read token for the private skills repo (PAT or App token) |

**Variables** (non-sensitive):

| Variable | Example | What it is |
| --- | --- | --- |
| `AWS_REGION` | `us-east-1` | region of the product bucket |
| `PRODUCT_BUCKET` | `acme-product-packs` | S3 bucket holding the packs |
| `SKILLS_REPO` | `your-org/repro-skills` | `owner/repo` of the skills repo |
| `REPRO_MAX_BUDGET_CEILING` | `25` | optional — hard per-run USD cap; budgets above this are clamped (default `25`) |

The workflow expects packs at `s3://$PRODUCT_BUCKET/packs/<product>-<version>.zip`
(e.g. `packs/wso2am-4.7.0.zip`), where product and version come from the
`<product>-<version>` label. Adjust the key shape in the "Download product pack"
step if your layout differs.

The product label is recognised by the `wso2*` glob in the parse step and split
into product + version on the last hyphen before the version number — so
hyphenated product names like `wso2am-analytics-3.2.0` work too. If you have
non-`wso2` products, broaden that glob.

## 4. Launching a run

There are two ways to launch. Pick whichever fits.

### Label path (what the lead applies on the issue)

| Label | Required? | Example | Effect |
| --- | --- | --- | --- |
| `<product>-<version>` | **yes** | `wso2am-4.7.0` | identity — picks the S3 pack and the JDK |
| `reproduce-mode-<model>` | no | `reproduce-mode-opus-4-8` | model override (default `claude-sonnet-4-6`) |
| `reproduce-max-cost-<n>` | no | `reproduce-max-cost-10` | per-run USD budget (default `5`, clamped to the ceiling) |
| `reproduce-update-level-<N>` | no | `reproduce-update-level-340` | pin a specific update level |
| `reproduce-update-stage-<s>` | no | `reproduce-update-stage-uat` | update stage (default `live`) |
| `needs-repro` | **trigger** | `needs-repro` | **apply LAST** — kicks off the run |

> **Order matters.** The run reads the issue's full label set but only fires on
> the `needs-repro` event. Apply the config labels first, then add `needs-repro`
> last. Adding config labels *after* `needs-repro` won't re-trigger.
>
> The `reproduce-*` config labels stay on the issue, so the active settings are
> visible at a glance. They're per-run by design — change them and re-trigger to
> run the same issue against a different stage/level/model.

`reproduce-mode-<model>` accepts either the short form (`reproduce-mode-opus-4-8`)
or the full string (`reproduce-mode-claude-opus-4-8`) — the workflow prepends
`claude-` if missing.

### Dispatch path (Actions → Run workflow)

| Input | Required? | Example | Falls back to |
| --- | --- | --- | --- |
| `issue_number` | **yes** | `4821` | — |
| `model` | no | `opus-4-8` | issue's `reproduce-mode-*`, then default |
| `cost` | no | `10` | issue's `reproduce-max-cost-*`, then default |
| `update_level` | no | `340` | issue's `reproduce-update-level-*`, then latest |
| `update_state` | no | `uat` | issue's `reproduce-update-stage-*`, then `live` |

Product and version are read from the issue's identity label even on dispatch, so
the issue must still carry a `<product>-<version>` label. Blank inputs inherit the
issue's labels, then the defaults.

### Repeat attempts — either path works

To reproduce the **same issue** against several configs (customer's update level,
then live, then staging), you can use *either* path — dispatch is not required:

- **Re-label:** the run removes `needs-repro` when it finishes, so just change the
  `reproduce-*` labels and add `needs-repro` again to fire another run.
- **Dispatch:** re-run with different inputs, leaving the issue's labels untouched.

Dispatch is usually less friction for several runs in a row — no add/remove label
dance, the issue's labels stay stable, and it still works after a *failed* run
(where `needs-repro` is intentionally left on, so re-adding the label wouldn't
re-trigger until you remove it first).

## 5. Cost controls (two layers)

- **Per run:** `reproduce-max-cost-<n>` (or the dispatch `cost` input) becomes
  `--max-budget-usd <n>`; the agent stops when it hits that dollar amount.
  Default `$5`.
- **Policy ceiling:** the requested budget is clamped to
  `REPRO_MAX_BUDGET_CEILING` (default `$25`) so neither a label nor an input can
  push one run past policy.
- **Account backstop:** create a dedicated Console **workspace**, generate
  `ANTHROPIC_API_KEY` from it, and set a **monthly spend limit** on it. This caps
  total spend regardless of how many issues get labeled.

## 6. Verify

1. Create a throwaway issue.
2. Add `<product>-<version>` (e.g. `wso2am-4.7.0`), optionally
   `reproduce-mode-*` / `reproduce-max-cost-*` / `reproduce-update-stage-*`, then
   add `needs-repro` last. (Or: skip the trigger label and launch from **Actions →
   claude-repro → Run workflow** with the issue number.)
3. Watch the run under the **Actions** tab. A "reproduction started" comment
   appears once the environment is ready; the product is extracted to `./product`
   and the skill to `.claude/skills/reproduce/`. The agent comments the outcome and
   writes a verdict file, then a workflow step applies `repro-confirmed` /
   `repro-failed` and removes `needs-repro`. If the run errors, a failure comment
   is posted instead.

## Things to confirm for your environment

- **`--max-budget-usd`** — confirm against `claude --help` for your installed
  Claude Code version; if the flag name differs, change only that one string in
  the workflow's `claude_args`.
- **Default update state** — it is `live` (production). If you'd rather an
  unlabeled run hit the safer channel, change `UPDATE_STATE:-live` to
  `UPDATE_STATE:-staging` in `prepare-product.sh`.
- **Build tool cache** — `setup-java` is set to `cache: maven`; switch to
  `gradle` if your repro builds with Gradle.
- **Relabeling** — handled deterministically by the workflow: the agent writes a
  one-word verdict to `verdict.txt` and the **Apply verdict labels** step maps it
  to `repro-confirmed` / `repro-failed` and removes `needs-repro`. A missing or
  unrecognized verdict fails the run loud (and triggers the failure comment)
  rather than mislabeling — change the `*)` case in that step if you'd prefer a
  fail-safe default instead.
