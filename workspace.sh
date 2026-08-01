#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=${XDG_STATE_HOME:-"$HOME/.local/state"}/agent-manager/workspaces

usage() {
    printf 'Usage:\n' >&2
    printf '  workspace.sh create --task NAME --cwd PATH --vcs git|none\n' >&2
    printf '  workspace.sh remove --cwd PATH\n' >&2
    exit 2
}

canonical_dir() {
    (cd -- "$1" && pwd -P)
}

digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{ print $1 }'
    else
        printf '%s' "$1" | openssl dgst -sha256 | awk '{ print $NF }'
    fi
}

task_slug() {
    local task=$1
    local identity=${2:-$task}
    local safe
    local hash

    safe=$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]')
    safe=${safe//[^a-z0-9._-]/-}
    while [[ "$safe" == *..* ]]; do
        safe=${safe//../-}
    done
    while [[ "$safe" == *--* ]]; do
        safe=${safe//--/-}
    done
    safe=${safe#-}
    safe=${safe%-}
    safe=${safe#.}
    [[ -n "$safe" ]] || safe=task
    safe=$(printf '%s' "$safe" | cut -c 1-36)
    hash=$(digest "$identity")
    hash=$(printf '%s' "$hash" | cut -c 1-10)
    printf '%s-%s\n' "$safe" "$hash"
}

write_metadata() {
    local entry_dir=$1
    local task=$2
    local branch=$3
    local repository=$4
    local worktree_root=$5
    local agent_cwd=$6

    mkdir -p -- "$entry_dir"
    printf '%s\n' "$task" >"$entry_dir/task"
    printf '%s\n' "$branch" >"$entry_dir/branch"
    printf '%s\n' "$repository" >"$entry_dir/repository"
    printf '%s\n' "$worktree_root" >"$entry_dir/root"
    printf '%s\n' "$agent_cwd" >"$entry_dir/agent-cwd"
}

# Codex App Server toolkits can keep a deleted worktree busy on Linux. Stop
# only toolkit children of App Server processes whose cwd is inside our tree.
stop_app_server_toolkits() {
    local worktree_root=$1
    local proc_dir
    local cwd
    local command
    local parent_pid
    local parent_command
    local pid
    local -a stopped=()

    [[ -d /proc ]] || return 0
    shopt -s nullglob
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
        [[ "$running" == false ]] && return 0
        sleep 0.1
    done
}

create_workspace() {
    local task=""
    local source_cwd=""
    local vcs=none

    while (($#)); do
        case "$1" in
            --task) task=${2:-}; shift 2 ;;
            --cwd) source_cwd=${2:-}; shift 2 ;;
            --vcs) vcs=${2:-}; shift 2 ;;
            *) usage ;;
        esac
    done

    [[ -n "$task" && -n "$source_cwd" ]] || usage
    [[ "$vcs" == git || "$vcs" == none ]] || {
        printf 'Unsupported VCS: %s\n' "$vcs" >&2
        exit 2
    }
    source_cwd=$(canonical_dir "$source_cwd")

    if [[ "$vcs" == none ]]; then
        printf '%s\n' "$source_cwd"
        return
    fi

    local source_root
    source_root=$(git -C "$source_cwd" rev-parse --show-toplevel 2>/dev/null) || {
        printf '%s is not inside a Git repository\n' "$source_cwd" >&2
        exit 1
    }
    source_root=$(canonical_dir "$source_root")
    local relative_cwd=${source_cwd#"$source_root"}
    if [[ "$relative_cwd" == "$source_cwd" ]]; then
        printf '%s is outside Git root %s\n' "$source_cwd" "$source_root" >&2
        exit 1
    fi
    relative_cwd=${relative_cwd#/}

    local slug
    slug=$(task_slug "$task" "$source_root:$relative_cwd:$task")
    local entry_dir="$STATE_DIR/$slug"
    local branch="agent-manager/$slug"
    local worktree_root="$entry_dir/worktree"
    local agent_cwd="$worktree_root"
    [[ -n "$relative_cwd" ]] && agent_cwd="$worktree_root/$relative_cwd"

    if [[ -f "$entry_dir/agent-cwd" ]] && [[ -d "$(<"$entry_dir/agent-cwd")" ]]; then
        agent_cwd=$(<"$entry_dir/agent-cwd")
        if git -C "$agent_cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            printf '%s\n' "$agent_cwd"
            return
        fi
    fi

    if git -C "$source_root" show-ref --verify --quiet "refs/heads/$branch"; then
        printf 'Branch %s already exists but its managed worktree is unavailable.\n' "$branch" >&2
        printf 'Recover or delete that branch, then retry.\n' >&2
        exit 1
    fi

    mkdir -p -- "$entry_dir"
    printf 'Creating Git worktree %s on branch %s\n' "$worktree_root" "$branch" >&2
    if ! git -C "$source_root" worktree add -b "$branch" "$worktree_root" HEAD >&2; then
        rmdir "$entry_dir" 2>/dev/null || true
        exit 1
    fi

    if [[ ! -d "$agent_cwd" ]]; then
        printf 'Worktree was created, but project path is missing: %s\n' "$agent_cwd" >&2
        git -C "$source_root" worktree remove "$worktree_root" >&2 || true
        git -C "$source_root" branch -d "$branch" >&2 || true
        rmdir "$entry_dir" 2>/dev/null || true
        exit 1
    fi

    write_metadata "$entry_dir" "$task" "$branch" "$source_root" "$worktree_root" "$agent_cwd"
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

    local branch
    local repository
    local worktree_root
    branch=$(<"$metadata/branch")
    repository=$(<"$metadata/repository")
    worktree_root=$(<"$metadata/root")

    if [[ -n "$(git -C "$worktree_root" status --porcelain --untracked-files=all --ignored)" ]]; then
        printf 'Refusing to remove %s: the worktree has uncommitted changes.\n' "$worktree_root" >&2
        printf 'Commit, move, or discard them manually, including ignored files, then retry.\n' >&2
        exit 1
    fi
    local branch_is_ancestor=false
    if git -C "$repository" merge-base --is-ancestor "$branch" HEAD; then
        branch_is_ancestor=true
    else
        local merge_base
        local cherry_result
        merge_base=$(git -C "$repository" merge-base HEAD "$branch")
        cherry_result=$(git -C "$repository" cherry HEAD "$branch")
        if [[ -z "$cherry_result" ]] || \
            [[ -n "$(git -C "$repository" rev-list --merges "$merge_base..$branch")" ]] || \
            printf '%s\n' "$cherry_result" | grep -v '^-' >/dev/null; then
            printf 'Refusing to remove %s: branch %s has commits not integrated into the source checkout HEAD.\n' "$worktree_root" "$branch" >&2
            printf 'Merge or cherry-pick the work, then retry.\n' >&2
            exit 1
        fi
    fi

    stop_app_server_toolkits "$worktree_root"
    printf 'Removing Git worktree %s\n' "$worktree_root" >&2
    git -C "$repository" worktree remove "$worktree_root" >&2
    if [[ "$branch_is_ancestor" == true ]]; then
        git -C "$repository" branch -d "$branch" >&2
    else
        # All task patches have equivalent commits in HEAD, but Git's ancestry
        # check cannot see that after cherry-pick.
        git -C "$repository" branch -D "$branch" >&2
    fi
    rm -f -- "$metadata/task" "$metadata/branch" "$metadata/repository" \
        "$metadata/root" "$metadata/agent-cwd"
    rmdir "$metadata" 2>/dev/null || true
}

command=${1:-}
shift || true
case "$command" in
    create) create_workspace "$@" ;;
    remove) remove_workspace "$@" ;;
    *) usage ;;
esac
