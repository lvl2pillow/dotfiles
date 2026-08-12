SRC="$HOME/.agents/AGENTS.md"
if [ ! -f "$SRC" ]; then
    exit 0
fi

# pi: symlink global AGENTS.md
if command -v pi &>/dev/null; then
    mkdir -p "$HOME/.pi/agent"
    ln -sfn "$SRC" "$HOME/.pi/agent/AGENTS.md"
    echo "Linked $HOME/.pi/agent/AGENTS.md -> ~/.agents/AGENTS.md"
fi

# claude: symlink global CLAUDE.md + skills
if command -v claude &>/dev/null; then
    mkdir -p "$HOME/.claude"
    ln -sfn "$SRC" "$HOME/.claude/CLAUDE.md"
    echo "Linked $HOME/.claude/CLAUDE.md -> ~/.agents/AGENTS.md"

    ln -sfn "$HOME/.agents/skills" "$HOME/.claude/skills"
    echo "Linked $HOME/.claude/skills -> ~/.agents/skills"
fi

# codex: symlink global AGENTS.md
if command -v codex &>/dev/null; then
    mkdir -p "$HOME/.codex"
    ln -sfn "$SRC" "$HOME/.codex/AGENTS.md"
    echo "Linked $HOME/.codex/AGENTS.md -> ~/.agents/AGENTS.md"
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
