#!/usr/bin/env bash
#
# prepare-product.sh
#
# Extract a WSO2 product pack, apply updates via the WSO2 Update Tool, and leave
# the updated product under $GITHUB_WORKSPACE/product so the Claude agent (whose
# file/Bash tools are scoped to the workspace) can reproduce against it.
#
# The S3 download is handled by the workflow; this script only receives the
# local zip path.
#
# Usage:
#   prepare-product.sh <path-to-pack.zip>
#
# Environment:
#   WSO2_UPDATE_USER / WSO2_UPDATE_PASS  (required) update.wso2.com credentials
#   UPDATE_LEVEL                         (optional) pin a specific update level number
#   UPDATE_STATE                         (optional) staging | uat | live   (default: live)
#   GITHUB_WORKSPACE                     (set automatically by GitHub Actions)
#   GITHUB_OUTPUT                        (set automatically; receives product_home)
#
set -euo pipefail

PACK_PATH="${1:?usage: prepare-product.sh <pack.zip>}"
LEVEL="${UPDATE_LEVEL:-}"
LEVEL_STATE="${UPDATE_STATE:-live}"
: "${WSO2_UPDATE_USER:?set WSO2_UPDATE_USER}"
: "${WSO2_UPDATE_PASS:?set WSO2_UPDATE_PASS}"

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"

[[ -f "$PACK_PATH" ]] || { echo "pack not found: $PACK_PATH" >&2; exit 1; }

# ── extract into the workspace (NOT /tmp) so the agent can reach it ───────────
EXTRACT_ROOT="${WORKSPACE}/product"
rm -rf "$EXTRACT_ROOT"
mkdir -p "$EXTRACT_ROOT"
echo "Extracting $PACK_PATH -> $EXTRACT_ROOT"
unzip -q "$PACK_PATH" -d "$EXTRACT_ROOT"

# ── locate product home (the directory that contains bin/) ────────────────────
PRODUCT_HOME="$(dirname "$(find "$EXTRACT_ROOT" -type d -name bin | head -1)")"
if [[ -z "$PRODUCT_HOME" || ! -d "$PRODUCT_HOME/bin" ]]; then
  echo "could not locate product home under $EXTRACT_ROOT" >&2
  exit 1
fi
BIN_DIR="$PRODUCT_HOME/bin"
echo "Product home: $PRODUCT_HOME"

# ── ensure the update tool ────────────────────────────────────────────────────
# Glob for the platform binary instead of hardcoding an OS/arch name. The runner
# is Linux, so update_tool_setup.sh fetches wso2update_linux*, but we never have
# to name it.
find_tool() { find "$BIN_DIR" -maxdepth 1 -type f -name 'wso2update_*' ! -name '*.sh' | head -1; }
UPDATE_TOOL="$(find_tool || true)"
if [[ -z "$UPDATE_TOOL" ]]; then
  echo "Update tool missing; running update_tool_setup.sh"
  (cd "$BIN_DIR" && sh ./update_tool_setup.sh)
  UPDATE_TOOL="$(find_tool || true)"
fi
[[ -z "$UPDATE_TOOL" ]] && { echo "update tool not found after setup" >&2; exit 1; }
echo "Update tool: $UPDATE_TOOL"

# ── map the lead-facing lifecycle label to the WSO2 update level state ────────
#   staging -> TESTING      uat -> VERIFYING      live -> production (no override)
case "${LEVEL_STATE,,}" in
  staging) export WSO2_UPDATES_UPDATE_LEVEL_STATE=TESTING ;;
  uat)     export WSO2_UPDATES_UPDATE_LEVEL_STATE=VERIFYING ;;
  live)    ;;  # production — no override
  *) echo "unknown update state '$LEVEL_STATE' (use: staging | uat | live)" >&2; exit 1 ;;
esac

# ── build update-tool args ────────────────────────────────────────────────────
ARGS=(--username "$WSO2_UPDATE_USER" --password "$WSO2_UPDATE_PASS")
[[ -n "$LEVEL" ]] && ARGS+=(--level "$LEVEL")

run_update() { (cd "$BIN_DIR" && "$UPDATE_TOOL" "${ARGS[@]}"); }

# ── run, retrying once if the tool self-updates and asks to re-run ────────────
echo "Updating product (state=${LEVEL_STATE}, level=${LEVEL:-<latest>})"
if ! out="$(run_update 2>&1 | tee /dev/stderr; exit "${PIPESTATUS[0]}")"; then
  if echo "$out" | grep -qi "client has been updated.*re-run"; then
    echo "Update tool self-updated; re-running..."
    run_update
  else
    echo "Update failed." >&2
    exit 1
  fi
fi

echo "Done. PRODUCT_HOME=$PRODUCT_HOME"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "product_home=$PRODUCT_HOME" >> "$GITHUB_OUTPUT"
