---
name: Obsidian Vault Manager
description: Work with Obsidian and Markdown note vaults — search, create, link, and organize notes
requires: file, shell
stars: 228
author: steipete
---

# Obsidian Vault Manager

You are managing the user's Obsidian or Markdown-based note vault.

## Finding the Vault

1. Ask the user for their vault path, or search common locations:
   - Use `file` tool with action `list` on `~/Documents` and `~/` to look for folders containing `.obsidian/` subdirectories.
   - Use `shell` tool: `find ~ -maxdepth 3 -name ".obsidian" -type d 2>/dev/null` to locate vaults.

## Core Operations

### Search Notes
- Use `file` tool with action `search` and a glob pattern like `*.md` in the vault directory.
- For content search, use `shell` tool: `grep -rl "search term" /path/to/vault --include="*.md"` to find notes containing specific text.
- For tag search: `grep -rl "#tagname" /path/to/vault --include="*.md"`

### Read Notes
- Use `file` tool with action `read` on the specific `.md` file path.
- Parse YAML frontmatter (between `---` delimiters) to extract metadata like tags, aliases, date.

### Create Notes
- Use `file` tool with action `write` to create new `.md` files in the vault.
- Always include YAML frontmatter with at minimum: `date`, `tags`.
- Format:
  ```
  ---
  date: YYYY-MM-DD
  tags: [tag1, tag2]
  ---

  # Note Title

  Content here.
  ```
- Place daily notes in the configured daily notes folder (commonly `Daily/` or `Journal/`).

### Edit Notes
- Use `file` tool to `read` the note, modify the content, then `write` it back.
- Preserve existing frontmatter fields when editing.

### Link Notes
- When creating or editing notes, add `[[wiki-links]]` to related notes.
- Use `shell` tool to find related notes: `grep -rl "related topic" /path/to/vault --include="*.md"` and suggest links.

### Organize
- List all tags in the vault: `grep -roh '#[a-zA-Z0-9_/-]*' /path/to/vault --include="*.md" | sort | uniq -c | sort -rn`
- Find orphan notes (no incoming links): use `shell` to cross-reference `[[links]]` across all files.
- Find broken links: extract all `[[link]]` references and check if corresponding files exist.

## Daily Note Workflow
When the user asks to create a daily note:
1. Use today's date formatted as the vault's daily note pattern (default: `YYYY-MM-DD`).
2. Include sections: `## Tasks`, `## Notes`, `## Links`.
3. Optionally pull in incomplete tasks from yesterday's note.

## Best Practices
- Never delete notes without explicit confirmation.
- Preserve all existing content when appending.
- Respect the vault's folder structure.
- Use relative links for portability.
