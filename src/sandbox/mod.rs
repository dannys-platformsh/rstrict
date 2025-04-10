use anyhow::{anyhow, Result};
use landlock::{
    Access, AccessFs, AccessNet, BitFlags, NetPort, PathBeneath, PathFd, Ruleset, RulesetAttr,
    RulesetCreatedAttr, RulesetStatus, ABI,
};
use log::{debug, error, info};
use std::fs;
use std::path::PathBuf;

#[derive(Debug)]
pub struct Config {
    pub read_only_paths: Vec<PathBuf>,
    pub read_write_paths: Vec<PathBuf>,
    pub read_only_executable_paths: Vec<PathBuf>,
    pub read_write_executable_paths: Vec<PathBuf>,
    pub bind_tcp_ports: Vec<u16>,
    pub connect_tcp_ports: Vec<u16>,
    pub best_effort: bool,
    pub unrestricted_filesystem: bool,
    pub unrestricted_network: bool,
}

impl Config {
    pub fn new() -> Self {
        Self {
            read_only_paths: Vec::new(),
            read_write_paths: Vec::new(),
            read_only_executable_paths: Vec::new(),
            read_write_executable_paths: Vec::new(),
            bind_tcp_ports: Vec::new(),
            connect_tcp_ports: Vec::new(),
            best_effort: false,
            unrestricted_filesystem: false,
            unrestricted_network: false,
        }
    }
}

// Check if a path is a directory
fn is_directory(path: &PathBuf) -> bool {
    fs::metadata(path).map(|m| m.is_dir()).unwrap_or(false)
}

pub fn apply(config: &Config) -> Result<()> {
    info!("Applying sandbox configuration");
    debug!("Sandbox config: {:?}", config);

    // Choose latest ABI version
    let abi = ABI::V5;

    // If we have no rules and no unrestricted access, apply default restrictive ruleset
    if config.read_only_paths.is_empty()
        && config.read_write_paths.is_empty()
        && config.read_only_executable_paths.is_empty()
        && config.read_write_executable_paths.is_empty()
        && config.bind_tcp_ports.is_empty()
        && config.connect_tcp_ports.is_empty()
        && !config.unrestricted_filesystem
        && !config.unrestricted_network
    {
        error!("No rules provided, applying default restrictive rules");

        // Create a ruleset with all restrictions
        let mut ruleset = Ruleset::default();

        // Handle filesystem access
        if !config.unrestricted_filesystem {
            ruleset = ruleset.handle_access(AccessFs::from_all(abi))?;
        }

        // Handle network access if supported
        if !config.unrestricted_network {
            ruleset = ruleset.handle_access(AccessNet::BindTcp)?;
            ruleset = ruleset.handle_access(AccessNet::ConnectTcp)?;
        }

        // Enforce the ruleset
        let status = ruleset.create()?.restrict_self()?;

        if status.ruleset == RulesetStatus::NotEnforced {
            info!("Landlock is not supported by the running kernel");
        } else {
            info!("Default restrictive rules applied successfully");
        }

        return Ok(());
    }

    // Create a new ruleset
    let mut ruleset = Ruleset::default();

    // Set up filesystem access if not unrestricted
    if !config.unrestricted_filesystem {
        ruleset = ruleset.handle_access(AccessFs::from_all(abi))?;
    } else {
        info!("Unrestricted filesystem access enabled");
    }

    // Set up network access if not unrestricted
    if !config.unrestricted_network {
        ruleset = ruleset.handle_access(AccessNet::BindTcp)?;
        ruleset = ruleset.handle_access(AccessNet::ConnectTcp)?;
    } else {
        info!("Unrestricted network access enabled");
    }

    // Create the ruleset
    let mut ruleset = ruleset.create()?;

    // Add filesystem rules if not unrestricted
    if !config.unrestricted_filesystem {
        // Process read-only executable paths
        for path in &config.read_only_executable_paths {
            if let Ok(path_fd) = PathFd::new(path) {
                debug!("Adding read-only executable path: {:?}", path);

                let mut access_fs = BitFlags::empty();
                access_fs |= AccessFs::ReadFile;
                access_fs |= AccessFs::Execute;

                if is_directory(path) {
                    access_fs |= AccessFs::ReadDir;
                }

                ruleset = ruleset.add_rule(PathBeneath::new(path_fd, access_fs))?;
            } else {
                error!("Failed to access path: {:?}", path);
                return Err(anyhow!("Failed to access path: {:?}", path));
            }
        }

        // Process read-write executable paths
        for path in &config.read_write_executable_paths {
            if let Ok(path_fd) = PathFd::new(path) {
                debug!("Adding read-write executable path: {:?}", path);

                let mut access_fs = BitFlags::empty();
                access_fs |= AccessFs::ReadFile;
                access_fs |= AccessFs::WriteFile;
                access_fs |= AccessFs::Execute;

                if is_directory(path) {
                    access_fs |= AccessFs::ReadDir;
                    access_fs |= AccessFs::RemoveDir;
                    access_fs |= AccessFs::RemoveFile;
                    access_fs |= AccessFs::MakeChar;
                    access_fs |= AccessFs::MakeDir;
                    access_fs |= AccessFs::MakeReg;
                    access_fs |= AccessFs::MakeSock;
                    access_fs |= AccessFs::MakeFifo;
                    access_fs |= AccessFs::MakeBlock;
                    access_fs |= AccessFs::MakeSym;
                }

                ruleset = ruleset.add_rule(PathBeneath::new(path_fd, access_fs))?;
            } else {
                error!("Failed to access path: {:?}", path);
                return Err(anyhow!("Failed to access path: {:?}", path));
            }
        }

        // Process read-only paths
        for path in &config.read_only_paths {
            if let Ok(path_fd) = PathFd::new(path) {
                debug!("Adding read-only path: {:?}", path);

                let mut access_fs = BitFlags::empty();
                access_fs |= AccessFs::ReadFile;

                if is_directory(path) {
                    access_fs |= AccessFs::ReadDir;
                }

                ruleset = ruleset.add_rule(PathBeneath::new(path_fd, access_fs))?;
            } else {
                error!("Failed to access path: {:?}", path);
                return Err(anyhow!("Failed to access path: {:?}", path));
            }
        }

        // Process read-write paths
        for path in &config.read_write_paths {
            if let Ok(path_fd) = PathFd::new(path) {
                debug!("Adding read-write path: {:?}", path);

                let mut access_fs = BitFlags::empty();
                access_fs |= AccessFs::ReadFile;
                access_fs |= AccessFs::WriteFile;

                if is_directory(path) {
                    access_fs |= AccessFs::ReadDir;
                    access_fs |= AccessFs::RemoveDir;
                    access_fs |= AccessFs::RemoveFile;
                    access_fs |= AccessFs::MakeChar;
                    access_fs |= AccessFs::MakeDir;
                    access_fs |= AccessFs::MakeReg;
                    access_fs |= AccessFs::MakeSock;
                    access_fs |= AccessFs::MakeFifo;
                    access_fs |= AccessFs::MakeBlock;
                    access_fs |= AccessFs::MakeSym;
                }

                ruleset = ruleset.add_rule(PathBeneath::new(path_fd, access_fs))?;
            } else {
                error!("Failed to access path: {:?}", path);
                return Err(anyhow!("Failed to access path: {:?}", path));
            }
        }
    }

    // Add network rules if not unrestricted
    if !config.unrestricted_network {
        // Process TCP bind ports
        for port in &config.bind_tcp_ports {
            debug!("Adding TCP bind port: {}", port);
            ruleset = ruleset.add_rule(NetPort::new(*port, AccessNet::BindTcp))?;
        }

        // Process TCP connect ports
        for port in &config.connect_tcp_ports {
            debug!("Adding TCP connect port: {}", port);
            ruleset = ruleset.add_rule(NetPort::new(*port, AccessNet::ConnectTcp))?;
        }
    }

    // Apply the ruleset
    let status = ruleset.restrict_self()?;

    if status.ruleset == RulesetStatus::NotEnforced {
        info!("Landlock is not supported by the running kernel");
    } else {
        info!("Landlock restrictions applied successfully");
    }

    Ok(())
}
