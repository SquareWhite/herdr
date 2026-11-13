//! Build identity helpers.

pub const BASE_VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn channel() -> &'static str {
    non_empty(option_env!("HERDR_BUILD_CHANNEL")).unwrap_or("stable")
}

pub fn build_id() -> Option<&'static str> {
    non_empty(option_env!("HERDR_BUILD_ID"))
}

/// Semver build metadata that marks a fork build, set in build.rs.
pub fn fork_build() -> Option<&'static str> {
    non_empty(option_env!("HERDR_FORK_BUILD"))
}

/// The reported version: the release version plus any fork build metadata.
pub fn version() -> String {
    match fork_build() {
        Some(fork) => format!("{}+{fork}", release_version()),
        None => release_version(),
    }
}

/// The upstream release this build is based on, without fork build metadata.
/// Release notes and announcements from the update manifest key on it.
pub fn release_version() -> String {
    match channel() {
        "stable" => BASE_VERSION.to_string(),
        channel => match build_id() {
            Some(build_id) => format!("{BASE_VERSION}-{channel}.{build_id}"),
            None => format!("{BASE_VERSION}-{channel}"),
        },
    }
}

pub fn is_preview() -> bool {
    channel() == "preview"
}

fn non_empty(value: Option<&'static str>) -> Option<&'static str> {
    value.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn stable_version_defaults_to_cargo_version() {
        assert!(!super::version().is_empty());
    }

    #[test]
    fn fork_build_appends_build_metadata() {
        let fork = super::fork_build().expect("fork builds set HERDR_FORK_BUILD");
        assert_eq!(
            super::version(),
            format!("{}+{fork}", super::release_version())
        );
    }
}
