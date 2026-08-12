#!/bin/bash
set -euo pipefail

SRC="$HOME/.agents/AGENTS.md"
if [ ! -f "$SRC" ]; then
    exit 0
fi

# pi: symlink global AGENTS.md
if command -v pi &>/dev/null; then
    mkdir -p "$HOME/.pi/agent"
    if [ ! -e "$HOME/.pi/agent/AGENTS.md" ]; then
        ln -s "$SRC" "$HOME/.pi/agent/AGENTS.md"
        echo "Linked $HOME/.pi/agent/AGENTS.md -> ~/.agents/AGENTS.md"
    fi
fi

# claude: symlink global CLAUDE.md + skills
if command -v claude &>/dev/null; then
    mkdir -p "$HOME/.claude"
    if [ ! -e "$HOME/.claude/CLAUDE.md" ]; then
        ln -s "$SRC" "$HOME/.claude/CLAUDE.md"
        echo "Linked $HOME/.claude/CLAUDE.md -> ~/.agents/AGENTS.md"
    fi

    if [ ! -e "$HOME/.claude/skills" ]; then
        ln -s "$HOME/.agents/skills" "$HOME/.claude/skills"
        echo "Linked $HOME/.claude/skills -> ~/.agents/skills"
    fi
fi

# codex: symlink global AGENTS.md
if command -v codex &>/dev/null; then
    mkdir -p "$HOME/.codex"
    if [ ! -e "$HOME/.codex/AGENTS.md" ]; then
        ln -s "$SRC" "$HOME/.codex/AGENTS.md"
        echo "Linked $HOME/.codex/AGENTS.md -> ~/.agents/AGENTS.md"
    fi
fi

# cursor: write rules file with frontmatter + content
if command -v cursor &>/dev/null; then
    mkdir -p "$HOME/.cursor/rules"
    {
        printf '%s\n' '---'
        printf '%s\n' 'description: Global AGENTS.md'
        printf '%s\n' 'alwaysApply: true'
        printf '%s\n' '---'
        cat "$SRC"
    } > "$HOME/.cursor/rules/AGENTS.mdc"
    echo "Wrote $HOME/.cursor/rules/AGENTS.mdc (frontmatter + ~/.agents/AGENTS.md)"
fi
