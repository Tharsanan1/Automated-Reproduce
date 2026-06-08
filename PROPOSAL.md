# Proposal: Automated bug reproduction via labels

## Summary

A pipeline that reproduces customer-reported bugs automatically. A run can be launched two ways — by labeling an issue, or via `workflow_dispatch` — and in either case GitHub Actions provisions the exact environment the bug needs (the right product build, update channel, and Java version) and runs Claude (through the official Claude Code GitHub Action, which is built on the Claude Agent SDK) to execute our existing reproduce skill and post the outcome back as an issue comment.

A deliberate distinction runs through the design: **issue identity vs. run parameters.** The `<product>-<version>` label is identity — a stable, selectable property of the bug. Everything else that configures an attempt — model, budget, update level, update stage — is a *per-run* parameter that describes one attempt, not the bug. The same issue is routinely reproduced against several configurations (the customer's update level, then live, then staging), so those parameters must be free to change run to run. They are kept out of the bare label namespace: on the label path they sit behind a `reproduce-` prefix (so the active settings are visible on the issue at a glance), and on the dispatch path they are workflow inputs.


## End-to-end experience

A bug is filed. A lead reads it, decides it's worth reproducing, and
launches a run one of two ways.

**Label path.** The lead applies the identity label (`wso2am-4.7.0`), optionally
sets per-run config via prefixed labels — the update stage
(`reproduce-update-stage-uat`) or a pinned level (`reproduce-update-level-340`),
the model (`reproduce-mode-opus-4-8`), the budget (`reproduce-max-cost-10`) — and
finally adds the trigger label `needs-repro`. Because the config labels carry the
`reproduce-` prefix, anyone glancing at the issue can see exactly what settings
the run is using.

**Dispatch path.** The lead runs the workflow manually, passing `issue_number`
plus any run params to override. Blank inputs fall back to the issue's
`reproduce-*` labels, then to defaults.

**Repeat attempts work from either path.** A single issue is often reproduced
against several configs — the customer's update level, then live, then staging.
Either path supports this:

- *Re-label:* because the run removes `needs-repro` when it finishes, the lead can
  change the `reproduce-*` labels and add `needs-repro` again to fire another run.
- *Dispatch:* re-run with different inputs, leaving the issue's labels untouched.

Neither is required — they're alternatives. Dispatch is usually the lower-friction
choice for trying several configs in a row: it avoids the add/remove label dance,
keeps the issue's labels stable as a canonical config while you vary one run, and
works even after a *failed* run (where `needs-repro` is deliberately left in place,
so re-adding the label wouldn't re-trigger without first removing it).

From there it is hands-off:

- The pipeline resolves the config, pulls the matching product pack from S3, and
  updates it to the requested stage/level.
- It installs the Java version that build needs, loads the reproduce skill, and
  hands Claude a fully prepared product directory.
- The pipeline posts a "reproduction started" comment echoing the resolved config
  the moment the environment is ready, so the lead has instant confirmation.
- Claude runs the skill, attempts the reproduction, records its verdict to a file,
  and posts one comment with the exact steps it ran, the environment, and trimmed
  logs with a link to the full run.
- The workflow — not the agent — reads that verdict file and deterministically
  re-labels the issue `repro-confirmed` or `repro-failed` and removes `needs-repro`.
- If any step errors before completion, the workflow comments that the run failed
  (a pipeline error, not a repro verdict) and leaves `needs-repro` in place.

The lead returns to an issue with a verdict and evidence attached, without
having provisioned anything themselves.

## Architecture

The pipeline is a sequence of deterministic preparation steps followed by a single
agent step. Everything that touches credentials or must be reproducible is done as
plain workflow steps; the agent is given an already-prepared environment and is
scoped to reproducing and reporting.

1. **Trigger.** The workflow fires on either the issue `labeled` event (only when
   the added label is `needs-repro`) or a manual `workflow_dispatch`. A
   concurrency group keyed on the issue number prevents duplicate or racing runs
   for the same issue regardless of how it was launched.
2. **Config resolution.** A single step resolves the run config through one code
   path for both triggers. It reads the issue's labels via the API, takes product
   and version from the bare `<product>-<version>` label, and resolves the run
   params (model, budget, update level, update stage) from the `reproduce-*`
   labels — then lets `workflow_dispatch` inputs override any of those params when
   provided. The JDK is resolved via a per-product matrix file. The budget is
   clamped to an account-policy ceiling so neither a label nor an input can raise
   spend past policy. A missing product label fails the run early with a clear
   message.
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
7. **Reproduction.** The Claude Code Action runs with the resolved model and
   budget, pointed at the prepared product. It runs the skill, writes a one-word
   verdict to `verdict.txt`, and comments the outcome on the resolved issue number.
8. **Relabeling (deterministic).** A workflow step reads `verdict.txt` and applies
   `repro-confirmed`/`repro-failed`, then removes `needs-repro`. Labeling lives in
   the workflow — not the model — so it is identical every run and cannot be
   mistyped or forgotten; a missing/unrecognized verdict fails loud rather than
   mislabeling. A final `if: failure()` step comments on any pipeline error so a
   broken run never leaves a silent issue.

The product is extracted **inside** the workspace deliberately: the agent's file
and shell tools are scoped to its project root, so keeping the product there means
no extra directory-access configuration.

## Inputs

Inputs split along the identity-vs-run-parameter line.

### Identity label

| Label | Format | Required | Effect |
| --- | --- | --- | --- |
| `<product>-<version>` | e.g. `wso2am-4.7.0` | Yes | Selects the product, its S3 pack, and (via the matrix) the JDK. Bare and selectable — this is a property of the bug. |

### Run-config labels (`reproduce-` prefix)

These configure a single attempt. The prefix keeps them out of the bare label
namespace and makes the active settings visible on the issue. On
`workflow_dispatch` the equivalent inputs override them.

| Label | Format | Default | Effect |
| --- | --- | --- | --- |
| `reproduce-mode-<model>` | model name | `claude-sonnet-4-6` | Overrides the model |
| `reproduce-max-cost-<n>` | dollar amount | `5` | Per-run USD budget (`--max-budget-usd`), clamped to the account ceiling |
| `reproduce-update-level-<N>` | level number | latest for the stage | Pins a specific update level |
| `reproduce-update-stage-<s>` | `staging`/`uat`/`live` | `live` | Selects the update stage |

### workflow_dispatch inputs

| Input | Required | Falls back to |
| --- | --- | --- |
| `issue_number` | Yes | — |
| `model` | No | issue's `reproduce-mode-*` label, then default |
| `cost` | No | issue's `reproduce-max-cost-*` label, then default |
| `update_level` | No | issue's `reproduce-update-level-*` label, then latest |
| `update_state` | No | issue's `reproduce-update-stage-*` label, then `live` |

Product and version are always read from the issue's identity label, even on dispatch.

### Trigger label

| Label | Effect |
| --- | --- |
| `needs-repro` | Launches a run from the label path. **Must be applied last**, after the config labels. (Not needed for `workflow_dispatch`.) |

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

| Label / input | Resolved model string |
| --- | --- |
| (none) | `claude-sonnet-4-6` |
| `reproduce-mode-opus-4-8` | `claude-opus-4-8` |
| `reproduce-mode-claude-opus-4-8` | `claude-opus-4-8` |

The handler prepends `claude-` if the value omits it, so both short and full forms
work — for the label and the `workflow_dispatch` `model` input alike.

## Security model

- **Credentials are never given to the agent.** S3 (OIDC role), WSO2 update
  credentials, and the skills-repo token are injected only into the deterministic
  preparation steps. The agent step receives the Anthropic key and a prepared
  product directory — nothing else.
- **Deterministic preparation.** Download and update are plain scripts, not agent
  actions, so the environment is reproducible and auditable independent of the
  model.

## Cost model

Three layers cap spend:

- **Per run:** `reproduce-max-cost-<n>` (or the dispatch `cost` input) →
  `--max-budget-usd`. The agent halts when it reaches the dollar ceiling for that
  single run (default `$5`).
- **Policy ceiling:** the requested budget is clamped to
  `REPRO_MAX_BUDGET_CEILING` (default `$25`), so neither a label nor a dispatch
  input can push a single run past policy.
- **Account backstop:** the API key comes from a dedicated Console workspace with
  a monthly spend limit, capping total spend across all runs regardless of label
  activity.

Model choice scales cost intentionally — Sonnet is the default, Opus is opt-in per
run via `reproduce-mode-*` for genuinely hard reproductions.
