mod add;
mod clean;
mod delete;
mod entries;
mod git;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "wt-core",
    version,
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
    }
}
