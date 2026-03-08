# git-worktree-switcher

Quickly switch between git worktrees using fzf.

Type `wt` to get a fuzzy-searchable list of your worktrees. Select one to `cd` into it.

![demo](demo.png)

## Prerequisites

- [fzf](https://github.com/junegunn/fzf)

## Installation

### zinit

```zsh
zinit light wicksipedia/git-worktree-switcher
zinit cdreplay -q  # replay completions (needed for tab completion)
```

### Oh My Zsh

Clone into your custom plugins directory:

```zsh
git clone https://github.com/wicksipedia/git-worktree-switcher.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/git-worktree-switcher
```

Then add to your plugins list in `.zshrc`:

```zsh
plugins=(... git-worktree-switcher)
```

### Antigen

```zsh
antigen bundle wicksipedia/git-worktree-switcher
```

### Manual

Source the plugin file in your `.zshrc`:

```zsh
source /path/to/git-worktree-switcher.plugin.zsh
```

## Usage

```
wt              # opens fzf picker
wt <path>       # cd directly to a worktree
wt add <name>   # create a new worktree (and branch if needed)
wt<tab>         # tab-complete worktree paths and subcommands
wt add <tab>    # tab-complete branch names
```

### fzf keybindings

| Key | Action |
|-----|--------|
| `enter` | Switch to selected worktree |
| `ctrl-a` | Create a new worktree (prompts for branch name, offers to open in editor) |
| `ctrl-o` | Open in editor (`$WT_OPENER`, default: `code`) |
| `ctrl-x` | Delete selected worktree (with confirmation) |

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `WT_OPENER` | `code` | Editor command used by `ctrl-o` |

### Local development

```zsh
source ~/path/to/git-worktree-switcher/git-worktree-switcher.plugin.zsh
```
