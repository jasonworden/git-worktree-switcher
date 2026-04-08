mod add;
mod clean;
mod config;
mod delete;
mod entries;
mod git;
mod unified;

use clap::{Parser, Subcommand};

fn long_version() -> &'static str {
    concat!(env!("CARGO_PKG_VERSION"), " (", env!("WT_GIT_SHA"), ")")
}

#[derive(Parser)]
#[command(
    name = "wt-core",
    version = long_version(),
    about = "Fast git worktree manager (core binary)"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// List all worktrees as TSV: branch, relative_path, absolute_path
    Entries,

    /// Picker lines: branch, rel, abs, staleness (one `git`/batch pass for zsh fzf)
    Picker,

    /// Print the absolute path of the main worktree
    MainWorktree,

    /// Print the branch name of the main worktree
    DefaultBranch,

    /// Create a new worktree (and branch if needed), prints target path
    Add {
        /// Branch name for the new worktree
        branch: String,
    },

    /// Remove a worktree by absolute path
    Delete {
        /// Absolute path to the worktree to remove
        path: String,
    },

    /// Quick local-only staleness check: prints "safe", "warn", or nothing
    QuickStatus {
        /// Branch name to check
        branch: String,
        /// Absolute path to the worktree
        path: String,
        /// Default branch name (optional, auto-detected if omitted)
        default_branch: Option<String>,
    },

    /// Full staleness analysis for all worktrees (TSV output)
    CleanCheck {
        /// Enable GitHub PR merge detection
        #[arg(long)]
        gh: bool,
    },

    /// Check if gh CLI is installed and authenticated
    GhAvailable,

    /// Print branch names for tab completion
    Completions,

    /// Unified worktree view with progressive loading
    Unified {
        /// Local-only mode (fast, no network)
        #[arg(long)]
        local: bool,

        /// Remote mode (fetch + GitHub API)
        #[arg(long)]
        remote: bool,

        /// Preview mode: show detail for a single worktree
        #[arg(long)]
        preview: Option<String>,

        /// List available branches for plant mode
        #[arg(long)]
        branches: bool,

        /// Output format: tsv (default), browse, uproot
        #[arg(long, default_value = "tsv")]
        format: String,
    },
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Entries => entries::run(),

        Commands::Picker => entries::run_picker(),

        Commands::MainWorktree => {
            if let Some(path) = git::main_worktree() {
                println!("{}", path.display());
            }
        }

        Commands::DefaultBranch => {
            if let Some(branch) = git::default_branch() {
                println!("{branch}");
            }
        }

        Commands::Add { branch } => {
            if let Err(e) = add::run(&branch) {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }

        Commands::Delete { path } => {
            if let Err(e) = delete::run(&path) {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }

        Commands::QuickStatus {
            branch,
            path,
            default_branch,
        } => {
            clean::run_quick_status(&branch, &path, default_branch.as_deref());
        }

        Commands::CleanCheck { gh } => {
            clean::run_clean_check(gh);
        }

        Commands::GhAvailable => {
            if !git::gh_available() {
                std::process::exit(1);
            }
        }

        Commands::Completions => {
            clean::run_completions();
        }

        Commands::Unified {
            local: _,
            remote,
            preview,
            branches,
            format,
        } => {
            if let Some(path) = preview {
                unified::run_preview(&path);
            } else if branches {
                unified::run_branches();
            } else if remote {
                unified::run_remote_formatted(&format);
            } else {
                unified::run_local_formatted(&format);
            }
        }
    }
}
