//! The only OS-specific source-handle boundary. Sources are opened READ ONLY, never locked.
use agentbar_core::Result;
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    path::{Component, Path},
    time::UNIX_EPOCH,
};
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct FileIdentity {
    pub volume: u64,
    pub file_id: u64,
    pub created: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileSnapshot {
    pub identity: FileIdentity,
    pub size: u64,
    pub modified: u64,
}
pub fn modified(m: &fs::Metadata) -> u64 {
    m.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|t| t.as_nanos().min(u64::MAX as u128) as u64)
        .unwrap_or(0)
}
pub fn is_reparse(m: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        m.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        m.file_type().is_symlink()
    }
}
pub fn safe_path(path: &Path) -> Result<()> {
    if !path.is_absolute() || path.components().any(|x| matches!(x, Component::ParentDir)) {
        return Err("ABSOLUTE_SPECIFIC_ROOT_REQUIRED".into());
    }
    let raw = path.to_string_lossy().replace('\\', "/").to_lowercase();
    let verbatim_drive = raw
        .strip_prefix("//?/")
        .is_some_and(|p| p.len() >= 3 && p.as_bytes()[0].is_ascii_alphabetic() && &p[1..3] == ":/");
    if raw.starts_with("//") && !verbatim_drive {
        return Err("NETWORK_OR_DEVICE_SOURCE_DENIED".into());
    }
    if raw.contains("sharp_codex") || raw.contains("/windows/") || raw.contains("/program files/") {
        return Err("PROTECTED_SOURCE_DENIED".into());
    }
    // Check root-to-leaf before touching descendants of a possible junction.
    for p in path.ancestors().collect::<Vec<_>>().into_iter().rev() {
        match fs::symlink_metadata(p) {
            Ok(metadata) if is_reparse(&metadata) => return Err("REPARSE_SOURCE_DENIED".into()),
            Ok(_) => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(_) => return Err("SOURCE_ANCESTOR_PERMISSION_DENIED".into()),
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let drive = path
            .components()
            .next()
            .ok_or("INVALID_DRIVE")?
            .as_os_str()
            .to_string_lossy()
            .replace("\\\\?\\", "");
        let root = std::ffi::OsString::from(format!("{}\\", drive));
        let wide: Vec<u16> = root.encode_wide().chain(Some(0)).collect();
        if unsafe { GetDriveTypeW(wide.as_ptr()) } != 3 {
            return Err("NON_FIXED_DRIVE_DENIED".into());
        }
    }
    Ok(())
}
pub fn open_read(path: &Path) -> Result<(File, FileSnapshot)> {
    safe_path(path)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(7).custom_flags(0x00200000);
    }
    let file = options.open(path)?;
    let snapshot = snapshot(&file)?;
    Ok((file, snapshot))
}
pub fn snapshot(file: &File) -> Result<FileSnapshot> {
    let m = file.metadata()?;
    if !m.is_file() || is_reparse(&m) {
        return Err("REGULAR_NON_REPARSE_FILE_REQUIRED".into());
    }
    #[cfg(windows)]
    let identity = {
        use std::os::windows::io::AsRawHandle;
        let mut info = std::mem::MaybeUninit::<FileInfo>::zeroed();
        if unsafe { GetFileInformationByHandle(file.as_raw_handle(), info.as_mut_ptr()) } == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let i = unsafe { info.assume_init() };
        if i.attributes & 0x400 != 0 {
            return Err("REPARSE_HANDLE_DENIED".into());
        }
        FileIdentity {
            volume: i.volume as u64,
            file_id: ((i.index_high as u64) << 32) | i.index_low as u64,
            created: ((i.created.high as u64) << 32) | i.created.low as u64,
        }
    };
    #[cfg(unix)]
    let identity = {
        use std::os::unix::fs::MetadataExt;
        FileIdentity {
            volume: m.dev(),
            file_id: m.ino(),
            created: m
                .created()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|t| t.as_nanos().min(u64::MAX as u128) as u64)
                .unwrap_or(0),
        }
    };
    Ok(FileSnapshot {
        identity,
        size: m.len(),
        modified: modified(&m),
    })
}
#[cfg(windows)]
#[repr(C)]
struct FileTime {
    low: u32,
    high: u32,
}
#[cfg(windows)]
#[repr(C)]
struct FileInfo {
    attributes: u32,
    created: FileTime,
    access: FileTime,
    write: FileTime,
    volume: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
}
#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn GetFileInformationByHandle(handle: *mut std::ffi::c_void, info: *mut FileInfo) -> i32;
    fn GetDriveTypeW(root: *const u16) -> u32;
}
