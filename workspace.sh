#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=${XDG_STATE_HOME:-"$HOME/.local/state"}/agent-manager/workspaces

usage() {
    printf 'Usage:\n' >&2
    printf '  workspace.sh create --task NAME --cwd PATH --vcs VCS --setup MODE\n' >&2
    printf '  workspace.sh remove --cwd PATH\n' >&2
    exit 2
}

arc_wt() {
    if command -v arc-wt >/dev/null 2>&1; then
        arc-wt "$@"
    else
        ya tool arc-wt "$@"
    fi
}

task_slug() {
    local task=$1
    local identity=${2:-$task}
    local safe=${task,,}
    local digest

    safe=${safe//[^a-z0-9._-]/-}
    while [[ "$safe" == *--* ]]; do
        safe=${safe//--/-}
    done
    safe=${safe#-}
    safe=${safe%-}
    [[ -n "$safe" ]] || safe=task
    safe=${safe:0:36}
    digest=$(printf '%s' "$identity" | sha256sum)
    digest=${digest%% *}
    printf '%s-%s\n' "$safe" "${digest:0:10}"
}

write_metadata() {
    local entry_dir=$1
    local task=$2
    local worktree_name=$3
    local lease_owner=$4
    local root=$5
    local agent_cwd=$6

    mkdir -p "$entry_dir"
    printf '%s\n' "$task" >"$entry_dir/task"
    printf '%s\n' "$worktree_name" >"$entry_dir/worktree-name"
    printf '%s\n' "$lease_owner" >"$entry_dir/lease-owner"
    printf '%s\n' "$root" >"$entry_dir/root"
    printf '%s\n' "$agent_cwd" >"$entry_dir/agent-cwd"
}

configure_workspace() {
    local agent_cwd=$1
    local requested_setup=$2
    local setup=$requested_setup
    local marker=$3

    if [[ "$setup" == auto ]]; then
        if [[ -f "$agent_cwd/aisuite.yaml" ]]; then
            setup=aisuite-codex
        else
            setup=none
        fi
    fi

    case "$setup" in
        none)
            ;;
        aisuite-codex)
            if [[ ! -f "$marker" ]] || [[ "$(<"$marker")" != "$setup" ]]; then
                printf 'Configuring Codex with AISuite in %s\n' "$agent_cwd" >&2
                (
                    cd "$agent_cwd"
                    ya tool aisuite codex . >&2
                )
                printf '%s\n' "$setup" >"$marker"
            fi
            ;;
        *)
            printf 'Unsupported workspace setup mode: %s\n' "$requested_setup" >&2
            exit 2
            ;;
    esac
}

stop_app_server_toolkits() {
    local worktree_root=$1
    local proc_dir
    local cwd
    local command
    local parent_pid
    local parent_command
    local pid
    local -a stopped=()

    for proc_dir in /proc/[0-9]*; do
        cwd=$(readlink -f "$proc_dir/cwd" 2>/dev/null) || continue
        [[ "$cwd" == "$worktree_root" || "$cwd" == "$worktree_root/"* ]] || continue
        command=$(tr '\0' ' ' <"$proc_dir/cmdline" 2>/dev/null) || continue
        [[ "$command" == *"mcp-linux/toolkit/toolkit connect"* ]] || continue
        parent_pid=$(awk '$1 == "PPid:" { print $2 }' "$proc_dir/status" 2>/dev/null) || continue
        [[ "$parent_pid" =~ ^[0-9]+$ ]] || continue
        parent_command=$(tr '\0' ' ' <"/proc/$parent_pid/cmdline" 2>/dev/null) || continue
        [[ "$parent_command" == *"codex app-server"* ]] || continue

        pid=${proc_dir##*/}
        printf 'Stopping App Server toolkit %s holding %s\n' "$pid" "$worktree_root" >&2
        kill "$pid" 2>/dev/null || true
        stopped+=("$pid")
    done

    for _ in {1..20}; do
        local running=false
        for pid in "${stopped[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                running=true
                break
            fi
        done
        [[ "$running" == false ]] && return
        sleep 0.1
    done
}

create_workspace() {
    local task=""
    local source_cwd=""
    local vcs=none
    local setup=auto

    while (($#)); do
        case "$1" in
            --task) task=${2:-}; shift 2 ;;
            --cwd) source_cwd=${2:-}; shift 2 ;;
            --vcs) vcs=${2:-}; shift 2 ;;
            --setup) setup=${2:-}; shift 2 ;;
            *) usage ;;
        esac
    done

    [[ -n "$task" && -n "$source_cwd" ]] || usage
    [[ "$vcs" == arc || "$vcs" == none ]] || {
        printf 'Unsupported VCS: %s\n' "$vcs" >&2
        exit 2
    }
    source_cwd=$(cd "$source_cwd" && pwd -P)

    if [[ "$vcs" != arc ]]; then
        printf '%s\n' "$source_cwd"
        return
    fi

    local source_root
    source_root=$(cd "$source_cwd" && arc root)
    source_root=$(cd "$source_root" && pwd -P)
    local relative_cwd=${source_cwd#"$source_root"}
    if [[ "$relative_cwd" == "$source_cwd" ]]; then
        printf '%s is outside Arc root %s\n' "$source_cwd" "$source_root" >&2
        exit 1
    fi
    relative_cwd=${relative_cwd#/}

    local slug
    slug=$(task_slug "$task" "$source_root:$relative_cwd:$task")
    local entry_dir="$STATE_DIR/$slug"
    local worktree_name="agent-manager-$slug"
    local branch="am-$slug"
    local lease_owner="agent-manager:$slug"
    local worktree_root="$entry_dir/arcadia"
    local agent_cwd="$worktree_root"
    [[ -n "$relative_cwd" ]] && agent_cwd="$worktree_root/$relative_cwd"

    if [[ -f "$entry_dir/agent-cwd" ]] && [[ -d "$(<"$entry_dir/agent-cwd")" ]]; then
        agent_cwd=$(<"$entry_dir/agent-cwd")
        arc_wt lease renew "$worktree_name" --owner "$lease_owner" >&2
        configure_workspace "$agent_cwd" "$setup" "$entry_dir/setup"
        printf '%s\n' "$agent_cwd"
        return
    fi

    mkdir -p "$entry_dir"
    printf 'Creating Arc workspace %s from trunk\n' "$worktree_name" >&2
    (
        cd "$source_cwd"
        arc_wt add "$branch" \
            --name "$worktree_name" \
            --base trunk \
            --mode mount \
            --path "$worktree_root" \
            --lease-owner "$lease_owner" \
            --lease-reason "$task" >&2
    )

    [[ -d "$agent_cwd" ]] || {
        printf 'Workspace was created, but project path is missing: %s\n' "$agent_cwd" >&2
        printf 'Removing incomplete Arc workspace %s\n' "$worktree_name" >&2
        if arc_wt remove "$worktree_name" --lease-owner "$lease_owner" >&2; then
            rmdir "$entry_dir" 2>/dev/null || true
        else
            printf 'Failed to remove incomplete Arc workspace %s\n' "$worktree_name" >&2
        fi
        exit 1
    }
    write_metadata "$entry_dir" "$task" "$worktree_name" "$lease_owner" "$worktree_root" "$agent_cwd"
    configure_workspace "$agent_cwd" "$setup" "$entry_dir/setup"
    printf '%s\n' "$agent_cwd"
}

remove_workspace() {
    local agent_cwd=""
    while (($#)); do
        case "$1" in
            --cwd) agent_cwd=${2:-}; shift 2 ;;
            *) usage ;;
        esac
    done
    [[ -n "$agent_cwd" ]] || usage

    local metadata=""
    local candidate
    shopt -s nullglob
    for candidate in "$STATE_DIR"/*/agent-cwd; do
        if [[ "$(<"$candidate")" == "$agent_cwd" ]]; then
            metadata=${candidate%/agent-cwd}
            break
        fi
    done
    [[ -n "$metadata" ]] || return 0

    local worktree_name
    local lease_owner
    worktree_name=$(<"$metadata/worktree-name")
    lease_owner=$(<"$metadata/lease-owner")
    stop_app_server_toolkits "$(<"$metadata/root")"
    printf 'Removing Arc workspace %s\n' "$worktree_name" >&2
    arc_wt remove "$worktree_name" --lease-owner "$lease_owner" >&2
    rm -f "$metadata/task" "$metadata/worktree-name" "$metadata/lease-owner" \
        "$metadata/root" "$metadata/agent-cwd" "$metadata/setup"
    rmdir "$metadata" 2>/dev/null || true
}

command=${1:-}
shift || true
case "$command" in
    create) create_workspace "$@" ;;
    remove) remove_workspace "$@" ;;
    *) usage ;;
esac
