# Proposal: Automated bug reproduction via labels

## Summary

A label-driven pipeline that reproduces customer-reported bugs automatically. When a lead labels an issue, GitHub Actions provisions the exact environment the bug needs — the right product build, update channel, and Java version — and runs Claude (through the official Claude Code GitHub Action, which is built on the Claude Agent SDK) to execute our existing reproduce skill and post the outcome back as an issue comment. 


## End-to-end experience

A bug is filed. A triage lead reads it, decides it's worth reproducing, and
applies a small set of labels that describe *what* to reproduce against:

- the product and version (`wso2am-4.7.0`),
- optionally the update channel (`update-stage-uat`) or a pinned update level
  (`update-level-340`),
- optionally the model and budget (`mode-opus-4-8`, `max-cost-10`),

and finally the trigger label `needs-repro`.

From there it is hands-off. The pipeline reads those labels, pulls the matching
product pack from S3, updates it to the requested channel, installs the Java
version that build needs, loads the reproduce skill, and hands Claude a fully
prepared product directory. Claude runs the skill, attempts the reproduction, and
posts one comment stating whether it reproduced, the exact steps it ran, the
environment it ran in, and trimmed logs with a link to the full run. It then
re-labels the issue `repro-confirmed` or `repro-failed` and removes `needs-repro`.

The lead returns to a triaged issue with a verdict and evidence attached, without
having provisioned anything themselves.

## Architecture

The pipeline is a sequence of deterministic preparation steps followed by a single
agent step. Everything that touches credentials or must be reproducible is done as
plain workflow steps; the agent is given an already-prepared environment and is
scoped to reproducing and reporting.

1. **Trigger.** The workflow listens for the issue `labeled` event and runs only
   when the added label is `needs-repro`. A concurrency group keyed on the issue
   number prevents duplicate or racing runs for the same issue.
2. **Label parsing.** A single step reads the issue's complete label set and
   resolves the model, budget, product, version, update level, update channel,
   and — via a per-product matrix file — the JDK. A missing product label fails
   the run early with a clear message.
3. **Java setup.** Installs the JDK the product runtime requires, resolved from the 
   product-version matrix.
4. **Skill fetch.** The reproduce skill is cloned from the skills repository into
   the workspace at `.claude/skills/reproduce/`, where the agent discovers it
   automatically at session start.
5. **Product download.** The runner assumes an AWS role via OIDC and downloads
   the pack for that product and version from S3
   (`packs/<product>-<version>.zip`).
6. **Product update.** `prepare-product.sh` extracts the pack into the workspace,
   locates the product home, ensures the WSO2 Update Tool, maps the requested
   channel to the update-level state, and runs the update (retrying once if the
   tool self-updates). The updated product is left in the workspace.
7. **Reproduction.** The Claude Code Action runs with the model and budget from
   the labels, pointed at the prepared product. It runs the skill, comments the
   outcome, and re-labels the issue.

The product is extracted **inside** the workspace deliberately: the agent's file
and shell tools are scoped to its project root, so keeping the product there means
no extra directory-access configuration.

## Label scheme

Labels are the only input. They fall into three groups.

### Configuration labels

| Label | Format | Required | Default | Effect |
| --- | --- | --- | --- | --- |
| `<product>-<version>` | e.g. `wso2am-4.7.0` | Yes | — (run fails) | Selects the product, its S3 pack, and (via the matrix) the JDK |
| `mode-<model>` | model name | No | `claude-sonnet-4-6` | Overrides the model |
| `max-cost-<n>` | dollar amount | No | `5` | Per-run USD budget (`--max-budget-usd`) |
| `update-level-<N>` | level number | No | latest for the channel | Pins a specific update level |
| `update-stage-<s>` | `staging`/`uat`/`live` | No | `live` | Selects the update channel |

### Trigger label

| Label | Effect |
| --- | --- |
| `needs-repro` | Launches the run. **Must be applied last**, after the configuration labels. |

### Outcome labels (applied by the pipeline)

| Label | Meaning |
| --- | --- |
| `repro-confirmed` | The bug reproduced |
| `repro-failed` | The bug did not reproduce / was blocked |

`needs-repro` is removed at the end of the run.

## Mappings

### Product + version → JDK

Because products differ in their Java requirements, JDK is resolved **per product**
against `.github/java-matrix.json`. The lookup order is exact version, then major
version, then the product's default, then a global default — so a product/version
can pin a JDK precisely or inherit a sensible fallback, and an unknown product or
version falls back rather than failing. Replace the sample values with the real
compatibility matrix.

| Product | Version | JDK |
| --- | --- | --- |
| `wso2am` | 4.7.0 | x |
| `wso2am` | other 4.x | x |
| `wso2is` | 7.x | x |
| `wso2is` | 6.x | y |
| (unknown product/version) | — | global default (17) |

The product label is recognised by the `wso2*` glob and split into product +
version on the last hyphen before the version, so hyphenated product names
(`wso2am-analytics-3.2.0`) parse correctly.

### Update channel → update-level state

The lead-facing channel name maps to the WSO2 update-level state, so the label
vocabulary stays in our terms rather than the tool's:

| Label | `WSO2_UPDATES_UPDATE_LEVEL_STATE` |
| --- | --- |
| `update-stage-staging` | `TESTING` |
| `update-stage-uat` | `VERIFYING` |
| `update-stage-live` | (none — production) |

### Model selection

| Label | Resolved model string |
| --- | --- |
| (none) | `claude-sonnet-4-6` |
| `mode-opus-4-8` | `claude-opus-4-8` |
| `mode-claude-opus-4-8` | `claude-opus-4-8` |

The handler prepends `claude-` if the label omits it, so both short and full forms
work.

## Security model

- **Credentials are never given to the agent.** S3 (OIDC role), WSO2 update
  credentials, and the skills-repo token are injected only into the deterministic
  preparation steps. The agent step receives the Anthropic key and a prepared
  product directory — nothing else.
- **Deterministic preparation.** Download and update are plain scripts, not agent
  actions, so the environment is reproducible and auditable independent of the
  model.

## Cost model

Two layers cap spend:

- **Per run:** `max-cost-<n>` → `--max-budget-usd`. The agent halts when it
  reaches the dollar ceiling for that single run (default `$5`).
- **Account backstop:** the API key comes from a dedicated Console workspace with
  a monthly spend limit, capping total spend across all runs regardless of label
  activity.

Model choice scales cost intentionally — Sonnet is the default, Opus is opt-in per
issue via `mode-*` for genuinely hard reproductions.
