#!/usr/bin/env bash
# Publish :jido_watch to Hex (susu organisation).
#
# Usage:
#   ./scripts/publish.sh <major|minor|patch|current>
#
# Behaviour:
#   - Reads/bumps @version in mix.exs.
#   - Calls `mix hex.publish` against the susu organisation (organisation
#     is set in the package config in mix.exs, so the CLI does not need a
#     --organization flag).
#   - On success: commits the version bump, tags jido-watch-v<version>,
#     and pushes commit + tag to origin.
#   - On failure: reverts the version bump in the working tree so no
#     dangling bump is left for trunk-sync to commit.
#
# Auth:
#   - Uses HEX_API_KEY if set; otherwise SUSU_HEX_PUBLISHER. Refuses to
#     fall back to OTP (so non-interactive publishes do not get prompted).
#   - Runs `mix hex.user whoami --organization susu` to verify the key
#     belongs to a member of the susu org before touching anything.
#   - Isolates HEX_HOME so a cached oauth_token in ~/.hex/hex.config
#     cannot take precedence over the API key.
#
# Env knobs:
#   DRY_RUN=1                 — skip auth, skip publish, skip git ops.
#                               Still bumps the version locally so you can
#                               diff mix.exs, then rolls back on EXIT.
#   PUBLISH_HEX_PUBLISH_CMD   — override the publish command
#                               (default: mix hex.publish --yes).
#   PUBLISH_HEX_WHOAMI_CMD    — override the auth check command
#                               (default: mix hex.user whoami --organization susu).
#   PUBLISH_SKIP_PUSH=1       — commit + tag locally but do not push.

set -Eeuo pipefail

level="${1:-}"
if [[ -z "$level" || ! "$level" =~ ^(major|minor|patch|current)$ ]]; then
  echo "Usage: $0 <major|minor|patch|current>" >&2
  exit 1
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
mix_file="$project_root/mix.exs"
package_name="jido-watch"

if [[ -z "${DRY_RUN:-}" ]]; then
  : "${HEX_API_KEY:=${SUSU_HEX_PUBLISHER:-}}"
  if [[ -z "$HEX_API_KEY" ]]; then
    echo "Error: neither HEX_API_KEY nor SUSU_HEX_PUBLISHER is set — refusing to publish (would fall back to OTP)." >&2
    exit 1
  fi
  export HEX_API_KEY

  HEX_HOME="$(mktemp -d "${TMPDIR:-/tmp}/hex-home.XXXXXX")"
  export HEX_HOME
  trap 'rm -rf "$HEX_HOME"' EXIT

  whoami_cmd="${PUBLISH_HEX_WHOAMI_CMD:-mix hex.user whoami --organization susu}"
  if ! (cd "$project_root" && $whoami_cmd) </dev/null >/dev/null 2>&1; then
    echo "Error: Hex rejected the API key for the susu organisation (whoami failed). Regenerate via 'mix hex.user key generate --key-name susu-publish' from an account that belongs to susu, then re-export SUSU_HEX_PUBLISHER." >&2
    exit 1
  fi
fi

read_version() {
  FILE="$mix_file" node -e '
const fs = require("fs");
const src = fs.readFileSync(process.env.FILE, "utf8");
const m = src.match(/@version\s+"([^"]+)"/);
if (!m) { process.stderr.write("no @version in " + process.env.FILE + "\n"); process.exit(1); }
process.stdout.write(m[1]);
'
}

write_version() {
  FILE="$mix_file" V="$1" node -e '
const fs = require("fs");
const src = fs.readFileSync(process.env.FILE, "utf8");
const next = src.replace(/(@version\s+)"[^"]+"/, (_, p1) => p1 + "\"" + process.env.V + "\"");
fs.writeFileSync(process.env.FILE, next);
'
}

bump_version() {
  OLD="$1" KIND="$2" node -e '
const [maj, min, pat] = process.env.OLD.split(".").map(Number);
const k = process.env.KIND;
let v;
if (k === "major") v = [maj + 1, 0, 0];
else if (k === "minor") v = [maj, min + 1, 0];
else v = [maj, min, pat + 1];
process.stdout.write(v.join("."));
'
}

old_version=$(read_version)

rollback_version() {
  cd "$project_root"
  echo "Rolling back $mix_file to $old_version..." >&2
  write_version "$old_version"
}

if [[ "$level" != "current" ]]; then
  new_version=$(bump_version "$old_version" "$level")
  write_version "$new_version"
else
  new_version="$old_version"
fi
version="$new_version"
tag="${package_name}-v${version}"

if [[ "$level" == "current" ]]; then
  echo "Publishing current Hex version $version (no bump)"
else
  echo "Bumped $mix_file: $old_version -> $version"
fi

if [[ -n "${DRY_RUN:-}" ]]; then
  echo "DRY_RUN=1 — skipping mix hex.publish and git operations."
  if [[ "$level" != "current" ]]; then
    # Restore the bumped version so the operator can diff what would have shipped,
    # then revert on EXIT.
    trap 'rollback_version' EXIT
  fi
  exit 0
fi

publish_cmd="${PUBLISH_HEX_PUBLISH_CMD:-mix hex.publish --yes}"

# Only the bump can leave a dangling change — `current` mode doesn't touch the file.
[[ "$level" != "current" ]] && trap rollback_version ERR

(cd "$project_root" && $publish_cmd)

[[ "$level" != "current" ]] && trap - ERR

if [[ "$level" != "current" ]]; then
  if git -C "$project_root" diff --quiet HEAD -- "$mix_file"; then
    echo "mix.exs already at $version in HEAD — no commit needed."
  else
    git -C "$project_root" commit --only "$mix_file" -m "${package_name}-v${version}"
  fi
fi

if git -C "$project_root" rev-parse "$tag" >/dev/null 2>&1; then
  echo "Tag $tag already exists — skipping tag."
else
  git -C "$project_root" tag "$tag"
fi

if [[ -z "${PUBLISH_SKIP_PUSH:-}" ]]; then
  branch="$(git -C "$project_root" rev-parse --abbrev-ref HEAD)"
  if ! git -C "$project_root" push origin "$branch" "$tag"; then
    echo "Warning: push failed. Local commit + tag are in place; trunk-sync's next push (or a manual 'git push --follow-tags') will carry them." >&2
  fi
else
  echo "PUBLISH_SKIP_PUSH=1 — leaving commit + tag local. Push manually with: git push --follow-tags"
fi

echo "Published ${tag} to Hex (susu organisation)."
