# Setup guide — automated bug reproduction

This bundle wires up an automated reproduction pipeline: when a triage lead labels
a GitHub issue, a workflow downloads the right product build, updates it to the
requested channel, and runs Claude (via the Claude Code GitHub Action) to attempt
a reproduction and post the result as a comment.

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

The workflow expects packs at `s3://$PRODUCT_BUCKET/packs/<product>-<version>.zip`
(e.g. `packs/wso2am-4.7.0.zip`), where product and version come from the
`<product>-<version>` label. Adjust the key shape in the "Download product pack"
step if your layout differs.

The product label is recognised by the `wso2*` glob in the parse step and split
into product + version on the last hyphen before the version number — so
hyphenated product names like `wso2am-analytics-3.2.0` work too. If you have
non-`wso2` products, broaden that glob.

## 4. The labels (what the lead applies)

| Label | Required? | Example | Effect |
| --- | --- | --- | --- |
| `<product>-<version>` | **yes** | `wso2am-4.7.0` | picks the S3 pack and the JDK |
| `mode-<model>` | no | `mode-opus-4-8` | model override (default `claude-sonnet-4-6`) |
| `max-cost-<n>` | no | `max-cost-10` | per-run USD budget (default `5`) |
| `update-level-<N>` | no | `update-level-340` | pin a specific update level |
| `update-stage-<s>` | no | `update-stage-uat` | update channel (default `live`) |
| `needs-repro` | **trigger** | `needs-repro` | **apply LAST** — kicks off the run |

> **Order matters.** The run reads the issue's full label set but only fires on
> the `needs-repro` event. Apply the config labels first, then add `needs-repro`
> last. Adding config labels *after* `needs-repro` won't re-trigger.

`mode-<model>` accepts either the short form (`mode-opus-4-8`) or the full string
(`mode-claude-opus-4-8`) — the workflow prepends `claude-` if missing.

## 5. Cost controls (two layers)

- **Per run:** `max-cost-<n>` becomes `--max-budget-usd <n>`; the agent stops when
  it hits that dollar amount. Default `$5`.
- **Account backstop:** create a dedicated Console **workspace**, generate
  `ANTHROPIC_API_KEY` from it, and set a **monthly spend limit** on it. This caps
  total spend regardless of how many issues get labeled.

## 6. Verify

1. Create a throwaway issue.
2. Add `<product>-<version>` (e.g. `wso2am-4.7.0`), optionally `mode-*` /
   `max-cost-*` / `update-stage-*`, then add `needs-repro` last.
3. Watch the run under the **Actions** tab. The product is extracted to
   `./product`, the skill to `.claude/skills/reproduce/`, and the agent comments
   with the outcome and re-labels the issue.

## Things to confirm for your environment

- **`--max-budget-usd`** — confirm against `claude --help` for your installed
  Claude Code version; if the flag name differs, change only that one string in
  the workflow's `claude_args`.
- **Default update state** — it is `live` (production). If you'd rather an
  unlabeled run hit the safer channel, change `UPDATE_STATE:-live` to
  `UPDATE_STATE:-staging` in `prepare-product.sh`.
- **Build tool cache** — `setup-java` is set to `cache: maven`; switch to
  `gradle` if your repro builds with Gradle.
- **Relabeling** — the agent applies `repro-confirmed` / `repro-failed`. If that
  proves flaky in your setup, move it into a deterministic final workflow step.
