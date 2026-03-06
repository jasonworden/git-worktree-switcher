# git-worktree-switcher

Quickly switch between git worktrees using fzf.

Type `wt` to get a fuzzy-searchable list of your worktrees. Select one to `cd` into it.

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
wt          # opens fzf with all worktrees
wt<tab>     # tab-completes worktree paths
```
