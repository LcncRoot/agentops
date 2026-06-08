#!/usr/bin/env bash
# hook-helpers.sh — Shared utilities for AgentOps hooks
# Source this from any hook that needs structured failure output.
#
# Required before sourcing:
#   ROOT must be set (git rev-parse --show-toplevel or pwd fallback)
#
# Provides:
#   write_failure TYPE COMMAND EXIT_CODE DETAILS
#     Writes structured JSON to $ROOT/.agents/ao/last-failure.json
#     Callers should also echo human-readable message to stderr.
#
#   check_hook_failure_budget HOOK_NAME
#     Tracks consecutive failures per hook. Returns 1 (skip hook) when
#     MAX_CONSECUTIVE_HOOK_FAILURES (default 3, override via
#     AGENTOPS_HOOK_FAILURE_CAP) is exceeded. Call record_hook_success
#     on success to reset the counter.

# BEADS_DOLT_SERVER_PORT default — allows bd invocations to find the Dolt server without manual export
# Override per-shell with `export BEADS_DOLT_SERVER_PORT=<port>` before invoking hooks/scripts.
export BEADS_DOLT_SERVER_PORT="${BEADS_DOLT_SERVER_PORT:-3307}"

# --- Hook failure budget ---
# Caps consecutive failures per hook to prevent runaway loops.
# Inspired by Claude Code's MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES pattern.
MAX_CONSECUTIVE_HOOK_FAILURES="${AGENTOPS_HOOK_FAILURE_CAP:-3}"

# check_hook_failure_budget HOOK_NAME
# Returns 0 if hook may run, 1 if budget exhausted (caller should skip).
check_hook_failure_budget() {
    local hook_name="$1"
    # Don't count when hooks are globally disabled
    [[ "${AGENTOPS_HOOKS_DISABLED:-}" == "1" ]] && return 0

    local state_dir="${AO_AGENTS_DIR:-${ROOT:-.}/.agents}/ao"
    local counter_file="$state_dir/.hook-failures-${hook_name}"
    mkdir -p "$state_dir" 2>/dev/null || return 0

    local count=0
    [[ -f "$counter_file" ]] && count=$(cat "$counter_file" 2>/dev/null || echo 0)

    if [[ "$count" -ge "$MAX_CONSECUTIVE_HOOK_FAILURES" ]]; then
        echo "HOOK DISABLED: $hook_name failed $count consecutive times (cap=$MAX_CONSECUTIVE_HOOK_FAILURES). Set AGENTOPS_HOOK_FAILURE_CAP to adjust." >&2
        return 1
    fi
    return 0
}

# record_hook_failure HOOK_NAME
# Increments the consecutive failure counter for a hook.
record_hook_failure() {
    local hook_name="$1"
    [[ "${AGENTOPS_HOOKS_DISABLED:-}" == "1" ]] && return 0

    local state_dir="${AO_AGENTS_DIR:-${ROOT:-.}/.agents}/ao"
    local counter_file="$state_dir/.hook-failures-${hook_name}"
    mkdir -p "$state_dir" 2>/dev/null || return 0

    local count=0
    [[ -f "$counter_file" ]] && count=$(cat "$counter_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "$count" > "$counter_file" 2>/dev/null || true

    if [[ "$count" -ge "$MAX_CONSECUTIVE_HOOK_FAILURES" ]]; then
        echo "WARNING: $hook_name has failed $count consecutive times. Hook will be disabled on next invocation." >&2
    fi
}

# record_hook_success HOOK_NAME
# Resets the consecutive failure counter on success.
record_hook_success() {
    local hook_name="$1"
    local state_dir="${AO_AGENTS_DIR:-${ROOT:-.}/.agents}/ao"
    local counter_file="$state_dir/.hook-failures-${hook_name}"
    rm -f "$counter_file" 2>/dev/null || true
}

# Guard: ROOT must be set
if [[ -z "${ROOT:-}" ]]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P 2>/dev/null || printf '%s' "$ROOT")"
fi

agentops_resolve_real_home() {
    local candidate="${ARISTON_HOME:-}"

    if [[ -z "$candidate" || ! -d "$candidate" ]]; then
        candidate="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
    fi
    if [[ -z "$candidate" || ! -d "$candidate" ]]; then
        candidate="${HOME:-}"
    fi
    printf '%s' "$candidate"
}

AGENTOPS_REAL_HOME="${AGENTOPS_REAL_HOME:-$(agentops_resolve_real_home)}"
export AGENTOPS_REAL_HOME

if [[ -f "$AGENTOPS_REAL_HOME/.agents/env.sh" ]]; then
  # shellcheck source=/home/dand/.agents/env.sh
  . "$AGENTOPS_REAL_HOME/.agents/env.sh"
fi

agentops_run_with_real_home() {
    HOME="$AGENTOPS_REAL_HOME" "$@"
}

# Source the canonical state-path resolver (lib/ao-paths.sh from soc-irg1.1).
# The resolver exports AO_AGENTS_DIR (and friends) honoring AO_HOME /
# CLAUDE_PLUGIN_DATA / repo-root precedence. Guard the source so a missing
# resolver file does NOT fail closed — fall back to the legacy ${ROOT}/.agents
# layout. This keeps the hook surface backwards-compatible during migration.
if [[ -z "${AO_AGENTS_DIR:-}" ]]; then
  if [[ -x "${ROOT}/lib/ao-paths.sh" ]]; then
    eval "$("${ROOT}/lib/ao-paths.sh" 2>/dev/null)" 2>/dev/null || true
  elif [[ -f "${ROOT}/lib/ao-paths.sh" ]]; then
    eval "$(bash "${ROOT}/lib/ao-paths.sh" 2>/dev/null)" 2>/dev/null || true
  fi
fi

# Path constants — prefer the resolver, fall back to the legacy layout when the
# resolver could not be sourced (e.g. detached install, missing file).
_HOOK_HELPERS_ERROR_LOG_DIR="${AO_AGENTS_DIR:-${ROOT}/.agents}/ao"
_HOOK_PACKET_ROOT="${AO_AGENTS_DIR:-${ROOT}/.agents}/ao/packets"
_HOOK_PACKET_PENDING_DIR="${_HOOK_PACKET_ROOT}/pending"
_EVIDENCE_ONLY_CLOSURE_DIR="${AO_COUNCIL_DIR:-${AO_AGENTS_DIR:-${ROOT}/.agents}/council}/evidence-only-closures"
_EVIDENCE_ONLY_CLOSURE_RELEASE_DIR="${AO_AGENTS_DIR:-${ROOT}/.agents}/releases/evidence-only-closures"

to_repo_relative_path() {
    local abs="$1"
    local repo="${ROOT%/}"
    case "$abs" in
        "$repo"/*) printf '.%s\n' "${abs#"$repo"}" ;;
        *) printf '%s\n' "$abs" ;;
    esac
}

write_failure() {
    local type="$1"
    local command="$2"
    local exit_code="$3"
    local details="$4"

    mkdir -p "$_HOOK_HELPERS_ERROR_LOG_DIR" 2>/dev/null

    local task_subject="unknown"
    if [[ -n "${INPUT:-}" ]] && command -v jq >/dev/null 2>&1; then
        task_subject=$(echo "$INPUT" | jq -r '.subject // "unknown"' 2>/dev/null) || true
        [[ -z "$task_subject" || "$task_subject" == "null" ]] && task_subject="unknown"
    fi

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --argjson schema_version 1 \
            --arg ts "$ts" \
            --arg type "$type" \
            --arg command "$command" \
            --argjson exit_code "$exit_code" \
            --arg task_subject "$task_subject" \
            --arg details "$details" \
            '{schema_version:$schema_version,ts:$ts,type:$type,command:$command,exit_code:$exit_code,task_subject:$task_subject,details:$details}' \
            > "$_HOOK_HELPERS_ERROR_LOG_DIR/last-failure.json" 2>/dev/null
    else
        local escaped_command escaped_subject escaped_details
        escaped_command=$(json_escape_value "$command")
        escaped_subject=$(json_escape_value "$task_subject")
        escaped_details=$(json_escape_value "$details")

        printf '{"schema_version":1,"ts":"%s","type":"%s","command":"%s","exit_code":%d,"task_subject":"%s","details":"%s"}\n' \
            "$ts" "$type" "$escaped_command" "$exit_code" "$escaped_subject" "$escaped_details" \
            > "$_HOOK_HELPERS_ERROR_LOG_DIR/last-failure.json" 2>/dev/null
    fi
}

# validate_restricted_cmd CMD [CONTEXT]
# Shared command validation: metachar block + bare-name guard + strict allowlist.
# Returns 0 if safe, 1 if blocked (message on stderr).
# Callers run the command themselves after validation passes.
validate_restricted_cmd() {
    local cmd="$1"
    local context="${2:-command}"

    # Block shell metacharacters and control chars
    if [[ "$cmd" == *$'\n'* ]] || [[ "$cmd" =~ [\;\|\&\`\$\(\)\<\>\'\"\\\] ]]; then
        echo "VALIDATION BLOCKED: shell metacharacters not allowed in $context" >&2
        return 1
    fi

    local -a _vrc_parts
    read -ra _vrc_parts <<< "$cmd"
    local binary="${_vrc_parts[0]}"

    # Binary must be a bare name (no path separators)
    if [[ "$binary" == */* ]]; then
        echo "VALIDATION BLOCKED: binary must be a bare name, not a path" >&2
        return 1
    fi

    # Strict allowlist
    local allowed="go pytest npm make"
    local found=0
    for a in $allowed; do
        [ "$binary" = "$a" ] && { found=1; break; }
    done
    if [ "$found" -ne 1 ]; then
        echo "VALIDATION BLOCKED: command '$binary' not in allowlist ($allowed)" >&2
        return 1
    fi

    return 0
}

# json_escape_value — Escape a string for safe use as a JSON string value.
# Handles: backslashes, double quotes, newlines, tabs, carriage returns.
# Usage: ESCAPED=$(json_escape_value "$RAW_VALUE")
json_escape_value() {
    local value="${1:-}"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

# timeout_run SECONDS COMMAND [ARGS...]
# Uses GNU timeout if available, falls back to gtimeout (macOS coreutils),
# and finally runs without timeout to preserve fail-open hook behavior.
timeout_run() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$seconds" "$@"
    else
        "$@"
    fi
}

# try_managed_hook_backend HOOK_NAME INPUT
# Delegates complex hook behavior to `ao hooks run` when the installed ao
# binary supports it. Returns 0 only when the backend ran successfully. Callers
# should keep a shell fallback for older installed binaries and direct script
# tests.
try_managed_hook_backend() {
    local hook_name="$1"
    local input="${2:-}"

    [[ "${AGENTOPS_MANAGED_HOOK_BACKEND_DISABLED:-}" == "1" ]] && return 1
    command -v ao >/dev/null 2>&1 || return 1

    timeout_run "${AGENTOPS_MANAGED_HOOK_BACKEND_TIMEOUT:-3}" ao hooks run --help 2>/dev/null \
        | grep -q "Run a managed AgentOps hook backend" || return 1

    printf '%s' "$input" \
        | timeout_run "${AGENTOPS_MANAGED_HOOK_BACKEND_TIMEOUT:-3}" ao hooks run "$hook_name" 2>/dev/null
}

# emit_hook_context EVENT_NAME CONTEXT
# Writes the hookSpecificOutput/additionalContext JSON shape used by Claude and
# Codex hook runtimes.
emit_hook_context() {
    local event_name="$1"
    local context_text="$2"

    if command -v jq >/dev/null 2>&1; then
        jq -n --arg event "$event_name" --arg ctx "$context_text" \
            '{"hookSpecificOutput":{"hookEventName":$event,"additionalContext":$ctx}}'
    else
        local safe_msg
        safe_msg=$(json_escape_value "$context_text")
        printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' \
            "$event_name" "$safe_msg"
    fi
}

# redact_sensitive_diff — Scrub secret-like values from diff previews.
redact_sensitive_diff() {
    local secret_name='[A-Za-z0-9_-]*([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt])[A-Za-z0-9_-]*'
    local assign_prefix="((${secret_name})[[:space:]]*[:=][[:space:]]*)"
    local auth_prefix='(([Aa]uthorization|AUTHORIZATION)[[:space:]]*:[[:space:]]*([Bb]earer|[Bb]asic)[[:space:]]+)'
    sed -E \
        -e "s/${assign_prefix}\"[^\"]*\"/\\1[REDACTED]/g" \
        -e "s/${assign_prefix}'[^']*'/\\1[REDACTED]/g" \
        -e 's/(([A-Za-z0-9_-]*([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt])[A-Za-z0-9_-]*)[[:space:]]*[:=][[:space:]]*)`[^`]*`/\1[REDACTED]/g' \
        -e "s/${assign_prefix}[^[:space:]\"'\`]+/\\1[REDACTED]/g" \
        -e "s/${auth_prefix}\"[^\"]*\"/\\1[REDACTED]/g" \
        -e "s/${auth_prefix}'[^']*'/\\1[REDACTED]/g" \
        -e 's/(([Aa]uthorization|AUTHORIZATION)[[:space:]]*:[[:space:]]*([Bb]earer|[Bb]asic)[[:space:]]+)`[^`]*`/\1[REDACTED]/g' \
        -e "s/${auth_prefix}[^[:space:]\"'\`]+/\\1[REDACTED]/g"
}

# hash_text — Stable content fingerprint without retaining raw content.
hash_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    else
        printf '%s' "$1" | cksum | awk '{print $1 ":" $2}'
    fi
}

# session_trim_lookup_text TEXT
# Normalize handoff/goal text for startup lookups.
session_trim_lookup_text() {
    printf '%s' "${1:-}" \
        | tr '\n' ' ' \
        | tr -s '[:space:]' ' ' \
        | sed 's/^ //; s/ $//'
}

session_read_codex_thread_name() {
    local home_dir index_path session_id thread_name

    session_id="$(session_trim_lookup_text "${CODEX_THREAD_ID:-}")"
    [ -n "$session_id" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    if [ -n "${CODEX_HOME:-}" ] && [ -f "${CODEX_HOME}/session_index.jsonl" ]; then
        index_path="${CODEX_HOME}/session_index.jsonl"
    elif [ -f "${AGENTOPS_REAL_HOME}/.codex/session_index.jsonl" ]; then
        index_path="${AGENTOPS_REAL_HOME}/.codex/session_index.jsonl"
    else
        home_dir="${HOME:-}"
        [ -n "$home_dir" ] || return 0
        index_path="$home_dir/.codex/session_index.jsonl"
        [ -f "$index_path" ] || return 0
    fi

    thread_name=$(
        jq -r --arg id "$session_id" '
            select(.id == $id)
            | .thread_name // empty
        ' "$index_path" 2>/dev/null | tail -n 1
    ) || true
    thread_name="$(session_trim_lookup_text "$thread_name")"
    [ -n "$thread_name" ] || return 0
    printf '%s' "$thread_name"
}

session_runtime_default_query() {
    local thread_name repo_name

    if [ -n "${AGENTOPS_SESSION_LOOKUP_QUERY:-}" ]; then
        session_trim_lookup_text "$AGENTOPS_SESSION_LOOKUP_QUERY"
        return 0
    fi

    thread_name="$(session_read_codex_thread_name)"
    if [ -n "$thread_name" ]; then
        printf '%s' "$thread_name"
        return 0
    fi

    repo_name="$(basename "${ROOT:-.}")"
    repo_name="$(session_trim_lookup_text "$repo_name")"
    if [ -n "$repo_name" ] && [ "$repo_name" != "." ]; then
        printf '%s' "$repo_name"
        return 0
    fi
    return 0
}

# session_resolve_startup_context_mode
# Returns factory or manual. Legacy inject env opts into manual mode.
session_resolve_startup_context_mode() {
    local mode
    if [ "${AGENTOPS_STARTUP_LEGACY_INJECT:-}" = "1" ]; then
        printf 'manual'
        return 0
    fi

    mode=$(printf '%s' "${AGENTOPS_STARTUP_CONTEXT_MODE:-factory}" | tr '[:upper:]' '[:lower:]')
    case "$mode" in
        ""|factory)
            printf 'factory'
            ;;
        manual|lean|legacy)
            printf 'manual'
            ;;
        *)
            printf 'factory'
            ;;
    esac
}

# session_derive_lookup_query HANDOFF_GOAL HANDOFF_SUMMARY
# Environment override wins, then handoff goal, then handoff summary.
session_derive_lookup_query() {
    local handoff_goal="${1:-}"
    local handoff_summary="${2:-}"

    if [ -n "${AGENTOPS_SESSION_LOOKUP_QUERY:-}" ]; then
        session_trim_lookup_text "$AGENTOPS_SESSION_LOOKUP_QUERY"
        return 0
    fi
    if [ -n "$handoff_goal" ]; then
        session_trim_lookup_text "$handoff_goal"
        return 0
    fi
    if [ -n "$handoff_summary" ]; then
        session_trim_lookup_text "$handoff_summary"
        return 0
    fi
    session_runtime_default_query
    return 0
}

# session_build_factory_briefing GOAL
# Builds a briefing path with ao knowledge brief when the CLI and jq are present.
session_build_factory_briefing() {
    local goal="$1"
    local output path

    [ -n "$goal" ] || return 0
    command -v ao >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0

    output=$(timeout_run 8 agentops_run_with_real_home ao knowledge brief --json --goal "$goal" 2>/dev/null) || return 0
    [ -n "$output" ] || return 0

    path=$(printf '%s' "$output" | jq -r '.output_path // empty' 2>/dev/null)
    path=$(session_trim_lookup_text "$path")
    [ -n "$path" ] || return 0
    [ -f "$path" ] || return 0
    printf '%s' "$path"
}

session_extract_cm_text() {
    local raw="$1"
    local text=""

    if command -v jq >/dev/null 2>&1; then
        text=$(printf '%s' "$raw" | jq -r '.summary // .briefing // .content // .text // .message // .artifacts[0].body // .artifacts[0].content // .artifacts[0].text // .candidates[0].body // .candidates[0].content // .items[0].body // .items[0].content // empty' 2>/dev/null) || true
    fi

    text=$(session_trim_lookup_text "$text")
    printf '%s' "$text"
}

session_run_optional_cm_context() {
    local root="$1"
    local query="$2"
    local raw raw_path briefing_path summary

    [ "${AGENTOPS_CM_DISABLED:-0}" = "1" ] && return 0
    query=$(session_trim_lookup_text "$query")
    [ -n "$query" ] || return 0
    command -v cm >/dev/null 2>&1 || return 0

    raw=$(timeout_run 12 agentops_run_with_real_home cm context "$query" --json 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0

    raw_path="$root/.agents/ao/context/cm-context.json"
    briefing_path="$root/.agents/briefings/cm-context.md"
    mkdir -p "$(dirname "$raw_path")" "$(dirname "$briefing_path")" 2>/dev/null || return 0
    printf '%s\n' "$raw" > "$raw_path" 2>/dev/null || return 0

    summary=$(session_extract_cm_text "$raw")
    [ -n "$summary" ] || summary="CM returned JSON, but no summary-like text was detected."

    {
        printf '# CM Context\n\n'
        printf -- '- Query: %s\n' "$query"
        printf -- '- Raw artifact: %s\n' "$raw_path"
        printf -- '- Source: `cm context --json`\n\n'
        printf '## Summary\n'
        printf -- '- %s\n' "$summary"
    } > "$briefing_path" 2>/dev/null || true
}

session_find_recent_runtime_transcript() {
    local line home_root

    home_root="${AGENTOPS_REAL_HOME:-${HOME:-}}"

    if [ -n "${AGENTOPS_CM_TRANSCRIPT_PATH:-}" ] && [ -f "${AGENTOPS_CM_TRANSCRIPT_PATH:-}" ]; then
        printf '%s\n' "${AGENTOPS_CM_TRANSCRIPT_PATH:-}"
        return 0
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "${line#*$'\t'}"
        return 0
    done < <(
        {
            [ -d "$home_root/.claude/sessions" ] && find "$home_root/.claude/sessions" -type f -printf '%T@\t%p\n' 2>/dev/null
            [ -d "$home_root/.claude/projects" ] && find "$home_root/.claude/projects" -type f -printf '%T@\t%p\n' 2>/dev/null
        } | sort -nr
    )
}

session_run_optional_cm_reflection() {
    local root="$1"
    local transcript_path="${2:-}"
    local raw provenance_dir provenance_path pending_path summary title ts

    [ "${AGENTOPS_CM_DISABLED:-0}" = "1" ] && return 0
    command -v cm >/dev/null 2>&1 || return 0

    if [ -z "$transcript_path" ]; then
        transcript_path="$(session_find_recent_runtime_transcript)"
    fi
    [ -n "$transcript_path" ] || return 0
    [ -f "$transcript_path" ] || return 0

    raw=$(timeout_run 15 agentops_run_with_real_home cm onboard read "$transcript_path" --template --json 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0

    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    provenance_dir="$root/.agents/ao/provenance/cm"
    provenance_path="$provenance_dir/${ts}-reflection.json"
    pending_path="$root/.agents/knowledge/pending/$(date -u +%Y-%m-%d)-cm-reflection-1.md"
    mkdir -p "$provenance_dir" "$(dirname "$pending_path")" 2>/dev/null || return 0
    printf '%s\n' "$raw" > "$provenance_path" 2>/dev/null || return 0

    summary=$(session_extract_cm_text "$raw")
    [ -n "$summary" ] || summary="$(session_trim_lookup_text "$raw")"
    [ -n "$summary" ] || return 0

    title="CM Reflection"
    if command -v jq >/dev/null 2>&1; then
        title=$(printf '%s' "$raw" | jq -r '.artifacts[0].title // .candidates[0].title // .items[0].title // .title // .name // "CM Reflection"' 2>/dev/null) || title="CM Reflection"
    fi
    title=$(session_trim_lookup_text "$title")
    [ -n "$title" ] || title="CM Reflection"

    {
        printf -- '---\n'
        printf 'date: %s\n' "$(date -u +%Y-%m-%d)"
        printf 'type: learning\n'
        printf 'source: cm-reflection\n'
        printf 'provenance_path: %s\n' "$provenance_path"
        printf 'transcript_path: %s\n' "$transcript_path"
        printf -- '---\n\n'
        printf '# %s\n\n' "$title"
        printf '%s\n' "$summary"
    } > "$pending_path" 2>/dev/null || true
}

# session_write_environment_manifest ROOT AO_DIR
# Writes .agents/ao/environment.json for diagnostics and recovery.
session_write_environment_manifest() {
    local root="$1"
    local ao_dir="$2"
    local env_file="$ao_dir/environment.json"
    local tmp_file git_branch head_sha git_dirty tools_json manifest_json

    git_branch="$(git -C "$root" branch --show-current 2>/dev/null || echo "")"
    head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo "")"
    if git -C "$root" diff --quiet 2>/dev/null && git -C "$root" diff --cached --quiet 2>/dev/null; then
        if [ -z "$(git -C "$root" ls-files --others --exclude-standard 2>/dev/null)" ]; then
            git_dirty=false
        else
            git_dirty=true
        fi
    else
        git_dirty=true
    fi

    if command -v jq &>/dev/null; then
        tools_json=$(jq -n \
            --arg ao "$(command -v ao 2>/dev/null || true)" \
            --arg git "$(command -v git 2>/dev/null || true)" \
            --arg jqbin "$(command -v jq 2>/dev/null || true)" '
            {
                ao: ($ao != ""),
                git: ($git != ""),
                jq: ($jqbin != "")
            }
        ')
        manifest_json=$(jq -n \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg os "$(uname -s 2>/dev/null || echo unknown)" \
            --arg arch "$(uname -m 2>/dev/null || echo unknown)" \
            --arg root "$root" \
            --arg branch "$git_branch" \
            --arg head_sha "$head_sha" \
            --argjson git_dirty "$git_dirty" \
            --argjson tools "$tools_json" '
            {
                timestamp: $ts,
                platform: {
                    os: $os,
                    arch: $arch
                },
                tools: $tools,
                git: {
                    repo_root: $root,
                    branch: $branch,
                    head_sha: $head_sha,
                    dirty: $git_dirty
                }
            }
        ')
        tmp_file="${env_file}.tmp"
        printf '%s\n' "$manifest_json" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$env_file" 2>/dev/null || true
    fi
}

# read_hook_input — Read stdin and extract last_assistant_message.
# Sets global variables: INPUT, LAST_ASSISTANT_MSG
# Usage: call at top of hook script, then use $LAST_ASSISTANT_MSG
read_hook_input() {
    INPUT=$(cat)
    LAST_ASSISTANT_MSG=""
    if [[ -n "$INPUT" ]]; then
        if command -v jq >/dev/null 2>&1; then
            LAST_ASSISTANT_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null) || true
        fi
        # Fallback without jq
        if [[ -z "$LAST_ASSISTANT_MSG" ]] && [[ -n "$INPUT" ]]; then
            LAST_ASSISTANT_MSG=$(echo "$INPUT" | grep -o '"last_assistant_message"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
                | sed 's/.*"last_assistant_message"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null) || true
        fi
    fi
}

# validate_memory_packet_file — shallow schema check for memory-packet v1.
# Returns 0 if valid, non-zero otherwise.
validate_memory_packet_file() {
    local packet_file="$1"
    [[ -f "$packet_file" ]] || return 1

    if command -v jq >/dev/null 2>&1; then
        jq -e '
            .schema_version == 1 and
            (.packet_id | type == "string" and length > 0) and
            (.packet_type | type == "string" and length > 0) and
            (.created_at | type == "string" and length > 0) and
            (.source_hook | type == "string" and length > 0) and
            (.session_id | type == "string" and length > 0) and
            (.payload | type == "object")
        ' "$packet_file" >/dev/null 2>&1
        return $?
    fi

    # Fallback (no jq): coarse key-presence checks.
    grep -q '"schema_version"' "$packet_file" &&
        grep -q '"packet_id"' "$packet_file" &&
        grep -q '"packet_type"' "$packet_file" &&
        grep -q '"created_at"' "$packet_file" &&
        grep -q '"source_hook"' "$packet_file" &&
        grep -q '"session_id"' "$packet_file" &&
        grep -q '"payload"' "$packet_file"
}

# validate_evidence_only_closure_packet_file — shallow schema check for
# evidence-only-closure v1 artifacts.
validate_evidence_only_closure_packet_file() {
    local packet_file="$1"
    [[ -f "$packet_file" ]] || return 1

    if command -v jq >/dev/null 2>&1; then
        jq -e '
            .schema_version == 1 and
            (.artifact_id | type == "string" and length > 0) and
            (.target_id | type == "string" and length > 0) and
            (.target_type | type == "string" and length > 0) and
            (.created_at | type == "string" and length > 0) and
            (.producer | type == "string" and length > 0) and
            (.evidence_mode | IN("commit", "staged", "worktree")) and
            (.validation_commands | type == "array" and length > 0) and
            all(.validation_commands[]; type == "string" and length > 0) and
            (.repo_state | type == "object") and
            (.repo_state.repo_root | type == "string" and length > 0) and
            (.repo_state.git_branch | type == "string") and
            (.repo_state.git_dirty | type == "boolean") and
            (.repo_state.head_sha | type == "string") and
            (.repo_state.modified_files | type == "array") and
            all(.repo_state.modified_files[]; type == "string") and
            (.repo_state.staged_files | type == "array") and
            all(.repo_state.staged_files[]; type == "string") and
            (.repo_state.unstaged_files | type == "array") and
            all(.repo_state.unstaged_files[]; type == "string") and
            (.repo_state.untracked_files | type == "array") and
            all(.repo_state.untracked_files[]; type == "string") and
            (.evidence | type == "object") and
            (.evidence.summary | type == "string" and length > 0) and
            (.evidence.artifacts | type == "array" and length > 0) and
            all(.evidence.artifacts[]; type == "string") and
            (.evidence.notes | type == "array") and
            all(.evidence.notes[]; type == "string")
        ' "$packet_file" >/dev/null 2>&1
        return $?
    fi

    grep -q '"schema_version"' "$packet_file" &&
        grep -q '"artifact_id"' "$packet_file" &&
        grep -q '"target_id"' "$packet_file" &&
        grep -q '"target_type"' "$packet_file" &&
        grep -q '"created_at"' "$packet_file" &&
        grep -q '"producer"' "$packet_file" &&
        grep -q '"evidence_mode"' "$packet_file" &&
        grep -q '"validation_commands"' "$packet_file" &&
        grep -q '"repo_state"' "$packet_file" &&
        grep -q '"evidence"' "$packet_file"
}

# write_memory_packet TYPE SOURCE PAYLOAD_JSON [HANDOFF_FILE]
# Emits a v1 memory packet under .agents/ao/packets/pending and prints packet path.
write_memory_packet() {
    local packet_type="$1"
    local source_hook="$2"
    local payload_json="$3"
    local handoff_file="${4:-}"

    mkdir -p "$_HOOK_PACKET_PENDING_DIR" 2>/dev/null || return 1

    local created_at safe_ts packet_id packet_file session_id
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    safe_ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo "unknown")
    session_id="${CLAUDE_SESSION_ID:-unknown}"
    packet_id="${safe_ts}-${packet_type}-$$"
    packet_file="${_HOOK_PACKET_PENDING_DIR}/${packet_id}.json"

    if command -v jq >/dev/null 2>&1; then
        if [[ -z "$payload_json" ]] || ! echo "$payload_json" | jq -e . >/dev/null 2>&1; then
            payload_json='{}'
        fi

        if [[ -n "$handoff_file" ]]; then
            jq -n \
                --argjson schema_version 1 \
                --arg packet_id "$packet_id" \
                --arg packet_type "$packet_type" \
                --arg created_at "$created_at" \
                --arg source_hook "$source_hook" \
                --arg session_id "$session_id" \
                --arg handoff_file "$handoff_file" \
                --argjson payload "$payload_json" \
                '{
                    schema_version: $schema_version,
                    packet_id: $packet_id,
                    packet_type: $packet_type,
                    created_at: $created_at,
                    source_hook: $source_hook,
                    session_id: $session_id,
                    handoff_file: $handoff_file,
                    payload: $payload
                }' > "$packet_file" 2>/dev/null || return 1
        else
            jq -n \
                --argjson schema_version 1 \
                --arg packet_id "$packet_id" \
                --arg packet_type "$packet_type" \
                --arg created_at "$created_at" \
                --arg source_hook "$source_hook" \
                --arg session_id "$session_id" \
                --argjson payload "$payload_json" \
                '{
                    schema_version: $schema_version,
                    packet_id: $packet_id,
                    packet_type: $packet_type,
                    created_at: $created_at,
                    source_hook: $source_hook,
                    session_id: $session_id,
                    payload: $payload
                }' > "$packet_file" 2>/dev/null || return 1
        fi
    else
        local esc_payload esc_handoff
        esc_payload=$(json_escape_value "$payload_json")
        esc_handoff=$(json_escape_value "$handoff_file")
        if [[ -n "$handoff_file" ]]; then
            printf '{"schema_version":1,"packet_id":"%s","packet_type":"%s","created_at":"%s","source_hook":"%s","session_id":"%s","handoff_file":"%s","payload":{"raw":"%s"}}\n' \
                "$packet_id" "$packet_type" "$created_at" "$source_hook" "$session_id" "$esc_handoff" "$esc_payload" \
                > "$packet_file" 2>/dev/null || return 1
        else
            printf '{"schema_version":1,"packet_id":"%s","packet_type":"%s","created_at":"%s","source_hook":"%s","session_id":"%s","payload":{"raw":"%s"}}\n' \
                "$packet_id" "$packet_type" "$created_at" "$source_hook" "$session_id" "$esc_payload" \
                > "$packet_file" 2>/dev/null || return 1
        fi
    fi

    if ! validate_memory_packet_file "$packet_file"; then
        rm -f "$packet_file" 2>/dev/null || true
        return 1
    fi

    printf '%s\n' "$packet_file"
    return 0
}

# write_evidence_only_closure_packet_to_dir TARGET_ID TARGET_TYPE PRODUCER
#   EVIDENCE_MODE VALIDATION_COMMANDS_JSON REPO_STATE_JSON EVIDENCE_JSON OUTPUT_DIR
# Emits a v1 evidence-only closure packet into the requested directory and
# prints the artifact path.
write_evidence_only_closure_packet_to_dir() {
    local target_id="$1"
    local target_type="$2"
    local producer="$3"
    local evidence_mode="$4"
    local validation_commands_json="$5"
    local repo_state_json="$6"
    local evidence_json="$7"
    local output_dir="$8"

    command -v jq >/dev/null 2>&1 || return 1
    mkdir -p "$output_dir" 2>/dev/null || return 1

    [[ -n "$target_id" ]] || return 1
    [[ -n "$target_type" ]] || return 1
    [[ -n "$producer" ]] || return 1
    [[ -n "$output_dir" ]] || return 1
    case "$evidence_mode" in
        commit|staged|worktree) ;;
        *) return 1 ;;
    esac

    echo "$validation_commands_json" | jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' >/dev/null 2>&1 || return 1
    echo "$repo_state_json" | jq -e '
        type == "object" and
        (.repo_root | type == "string" and length > 0) and
        (.git_branch | type == "string") and
        (.git_dirty | type == "boolean") and
        (.head_sha | type == "string") and
        (.modified_files | type == "array") and
        all(.modified_files[]; type == "string") and
        (.staged_files | type == "array") and
        all(.staged_files[]; type == "string") and
        (.unstaged_files | type == "array") and
        all(.unstaged_files[]; type == "string") and
        (.untracked_files | type == "array") and
        all(.untracked_files[]; type == "string")
    ' >/dev/null 2>&1 || return 1
    echo "$evidence_json" | jq -e '
        type == "object" and
        (.summary | type == "string" and length > 0) and
        (.artifacts | type == "array") and
        all(.artifacts[]; type == "string") and
        (.notes | type == "array") and
        all(.notes[]; type == "string")
    ' >/dev/null 2>&1 || return 1

    local created_at safe_target artifact_id artifact_file
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    safe_target="${target_id//\//_}"
    artifact_id="evidence-only-closure-${safe_target}"
    artifact_file="${output_dir}/${safe_target}.json"

    jq -n \
        --arg schema "../../../schemas/evidence-only-closure.v1.schema.json" \
        --argjson schema_version 1 \
        --arg artifact_id "$artifact_id" \
        --arg target_id "$target_id" \
        --arg target_type "$target_type" \
        --arg created_at "$created_at" \
        --arg producer "$producer" \
        --arg evidence_mode "$evidence_mode" \
        --argjson validation_commands "$validation_commands_json" \
        --argjson repo_state "$repo_state_json" \
        --argjson evidence "$evidence_json" \
        '{
            "$schema": $schema,
            schema_version: $schema_version,
            artifact_id: $artifact_id,
            target_id: $target_id,
            target_type: $target_type,
            created_at: $created_at,
            producer: $producer,
            evidence_mode: $evidence_mode,
            validation_commands: $validation_commands,
            repo_state: $repo_state,
            evidence: $evidence
        }' > "$artifact_file" 2>/dev/null || return 1

    if ! validate_evidence_only_closure_packet_file "$artifact_file"; then
        rm -f "$artifact_file" 2>/dev/null || true
        return 1
    fi

    printf '%s\n' "$artifact_file"
    return 0
}

# write_evidence_only_closure_packet TARGET_ID TARGET_TYPE PRODUCER
#   EVIDENCE_MODE VALIDATION_COMMANDS_JSON REPO_STATE_JSON EVIDENCE_JSON
# Emits a v1 evidence-only closure packet under
# .agents/council/evidence-only-closures and a durable tracked copy under
# .agents/releases/evidence-only-closures. Prints the council artifact path.
write_evidence_only_closure_packet() {
    local target_id="$1"
    local target_type="$2"
    local producer="$3"
    local evidence_mode="$4"
    local validation_commands_json="$5"
    local repo_state_json="$6"
    local evidence_json="$7"
    local local_artifact release_artifact

    local_artifact="$(
        write_evidence_only_closure_packet_to_dir \
            "$target_id" \
            "$target_type" \
            "$producer" \
            "$evidence_mode" \
            "$validation_commands_json" \
            "$repo_state_json" \
            "$evidence_json" \
            "$_EVIDENCE_ONLY_CLOSURE_DIR"
    )" || return 1

    release_artifact="$(
        write_evidence_only_closure_packet_to_dir \
            "$target_id" \
            "$target_type" \
            "$producer" \
            "$evidence_mode" \
            "$validation_commands_json" \
            "$repo_state_json" \
            "$evidence_json" \
            "$_EVIDENCE_ONLY_CLOSURE_RELEASE_DIR"
    )" || {
        rm -f "$local_artifact" 2>/dev/null || true
        return 1
    }

    [[ -n "$release_artifact" ]] || {
        rm -f "$local_artifact" 2>/dev/null || true
        return 1
    }

    printf '%s\n' "$local_artifact"
    return 0
}

# _validate_restricted_cmd CMD ALLOWED...
# Validate a command is in an allowlist before executing.
# Usage: _validate_restricted_cmd "command_string" allowed_array
# Returns 1 if the command binary is not in the allowlist.
_validate_restricted_cmd() {
    local cmd="$1"
    shift
    local -a allowlist=("$@")
    local binary
    binary=$(echo "$cmd" | awk '{print $1}')
    for allowed in "${allowlist[@]}"; do
        if [[ "$binary" == "$allowed" ]]; then
            return 0
        fi
    done
    echo "BLOCKED: '$binary' not in allowlist: ${allowlist[*]}" >&2
    return 1
}
