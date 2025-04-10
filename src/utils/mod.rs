use std::env;

/// Process environment variables from CLI flags
///
/// This function processes strings in either of these formats:
/// - KEY=VALUE: Uses the provided value
/// - KEY: Takes the value from the current environment
///
/// Returns a vector of environment variables in the format KEY=VALUE
pub fn process_environment_vars(env_flags: &[String]) -> Vec<String> {
    let mut result = Vec::new();

    for env_flag in env_flags {
        // If the flag is just a key (no = sign), get the value from the current environment
        if !env_flag.contains('=') {
            if let Ok(val) = env::var(env_flag) {
                result.push(format!("{}={}", env_flag, val));
            }
        } else {
            // Flag already contains the value (KEY=VALUE format)
            result.push(env_flag.clone());
        }
    }

    result
}
