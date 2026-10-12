// raspi-provision: a single invoke-from-anywhere binary that builds provisioned
// raspberry pi os images. it embeds the framework tree (overlay/toolbox/tests/
// depends) at compile time, extracts it per run, and execs the bash/guestfish
// engine -- the binary is a launcher, not a reimplementation. a project is just
// a directory holding customize.env plus an optional overlay/ tree (runtime-path
// layout; files under boot/firmware/ go to the FAT partition) and depends/
// package lists, both of which layer on top of the bundled base.

use clap::{Parser, Subcommand};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

// the framework tree, tarred at build time (build.rs) to preserve file modes.
static FRAMEWORK_TAR: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/framework.tar"));

// provisioning defaults; override any of these in customize.env or the process env.
const DEFAULTS: &[(&str, &str)] = &[
    ("CUSTOM_HOSTNAME", "empusa"),
    ("CUSTOM_USERNAME", "empusa"),
    ("CUSTOM_PASSWORD", "empusa05"),
    ("OVERLAY", ""),
    ("MOUNT_DEVICE", "/dev/sda"),
    ("ADDRESS", "10.55.0.1"),
    ("OTA_WAIT_SECONDS", "60"),
    ("PERSIST_SIZE_MIB", "128"),
    ("PERSIST_ALIGN_MIB", "1024"),
    ("BAKE_DEPENDS", "1"),
    ("IMAGE_RASPIOS", "./images/raspios-lite.img.xz"),
    ("IMAGE_RASPIOS_SOURCE", "https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"),
];

// an image path with this extension is gzip-compressed; any other is raw.
const GZIP_EXTENSION: &str = "gz";

// where `ota` leaves the writer on the device: in ram, like all it runs from
// once the card is being replaced.
const OTA_WRITER: &str = "/run/raspi-provision-ota-write";
// seconds one attempt to reach the device may take, and between attempts
const OTA_PROBE_SECONDS: u64 = 3;
// the base image's shared connections (overlay/etc/NetworkManager): rndis,
// ethernet, hotspot. a device answers at each whatever ADDRESS says.
const SHARED_ADDRESSES: [&str; 3] = ["10.55.0.1", "10.55.1.1", "10.55.2.1"];
// take the key of a host ssh has none for, and still refuse one that changed.
// a flashed device has new keys and `flash` and `ota` forget its old ones, so
// the first command after either would otherwise stop to ask.
const SSH_ACCEPT_NEW: [&str; 2] = ["-o", "StrictHostKeyChecking=accept-new"];

// where `ota` leaves toolbox/write-image, which the ota writer runs
const OTA_WRITE_IMAGE: &str = "/run/raspi-provision-write-image";
// what toolbox/build-image leaves at the head of an image whose initramfs
// adopts a persist partition it did not make. an image without it is from
// before that, and would lay the old system's changes over its own root.
const KEEP_MAGIC: &[u8] = b"raspi-provision keep 1";
const SECTOR: u64 = 512;
// the third of an mbr's four primary partition entries, sixteen bytes each,
// and within one the first sector and the count, both little-endian u32
const PERSIST_ENTRY: usize = 446 + 2 * 16;
const ENTRY_START: usize = 8;
const ENTRY_SECTORS: usize = 12;
const PERSIST_LABEL: &str = "persist";

const INIT_CUSTOMIZE_ENV: &str = "\
# raspi-provision project config. uncomment and edit to override the defaults;
# every key here is exported to the build and to the maintain commands.

#CUSTOM_HOSTNAME=myhost
#CUSTOM_USERNAME=myuser
# password must be at least 8 bytes for the hotspot to work
#CUSTOM_PASSWORD=mypassword

# overlay root: persist (changes survive) or tmpfs (clean slate each boot).
# leave unset for a plain writable image.
#OVERLAY=persist

# install depends/ packages into the image at build time (needs internet, apt-get
# and qemu-system-aarch64 on the build host). 0 leaves them to `update`.
#BAKE_DEPENDS=1

# the sdcard device that `raspi-provision flash` writes -- destructive, mind it.
#MOUNT_DEVICE=/dev/sda

# address of a running device for the maintain commands (ssh, update, ...).
#ADDRESS=10.55.0.1
";

const INIT_DEPENDS_BASE: &str = "\
# packages installed by `raspi-provision update`, one per line; # starts a comment.
# organize by purpose across multiple files, e.g. depends/portal, depends/vpn.

#vim
#git
";

const INIT_GITIGNORE: &str = "/images/\n.build-*\n";

#[derive(Parser)]
#[command(name = "raspi-provision", version, about = "build provisioned raspberry pi os images")]
struct Cli {
    /// run as if started in DIR (the project dir) instead of the current directory
    #[arg(short = 'C', long = "directory", value_name = "DIR", global = true)]
    directory: Option<PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// scaffold a new project (customize.env, overlay/, depends/) in DIR
    Init { dir: Option<PathBuf> },
    /// download the upstream raspios image into ./images
    Download,
    /// build a provisioned image from customize.env + ./overlay
    Image {
        /// where to write it (default ./images/<hostname>.img.gz); gzip-compressed if it ends in .gz
        path: Option<PathBuf>,
    },
    /// write a built image to the card (sudo dd, oflag=direct), keeping its persist partition if it has one
    Flash {
        /// the image to write, gzip-compressed if it ends in .gz (default: the one `image` builds)
        path: Option<PathBuf>,
        /// replace the persist partition too: home, identity and saved networks start over
        #[arg(long)]
        wipe: bool,
    },
    /// bake an ssh public key into ./overlay (default ~/.ssh/id_rsa.pub)
    Authorize { keyfile: Option<PathBuf> },
    /// push ./overlay, install depends, and apt full-upgrade a running device
    Update,
    /// write a built image to the card of a running device over ssh, keeping its persist partition, and restart it
    Ota {
        /// the image to write, gzip-compressed if it ends in .gz (default: the one `image` builds)
        path: Option<PathBuf>,
        /// replace the persist partition too: home, identity and saved networks start over
        #[arg(long)]
        wipe: bool,
    },
    /// open an interactive ssh session to the device
    Ssh {
        /// connect as root instead of the configured user
        #[arg(long)]
        root: bool,
    },
    /// bring up a shared connection on the device (ethernet|hotspot|rndis or an id)
    Network { connection: String },
    /// choose a network connection interactively (nmtui) on the device
    Nmtui,
    /// attach to (or create) a shared screen session on the device
    Screen {
        /// connect as root instead of the configured user
        #[arg(long)]
        root: bool,
    },
    /// factory-reset the device on its next boot
    FactoryReset,
    /// commit the live tmpfs overlay to persist on the device
    OverlayCommit,
    /// reboot the device
    Reboot,
    /// power off the device
    Poweroff,
}

type Config = BTreeMap<String, String>;
type R = Result<(), String>;

fn main() {
    let cli = Cli::parse();
    // every project path (customize.env, overlay/, depends/, images/) is relative,
    // so chdir once up front rather than threading a base dir through each command.
    if let Some(dir) = &cli.directory {
        if let Err(e) = std::env::set_current_dir(dir) {
            eprintln!("raspi-provision: {}: {e}", dir.display());
            std::process::exit(1);
        }
    }
    let r = match cli.cmd {
        Cmd::Init { dir } => init(dir.unwrap_or_else(|| PathBuf::from("."))),
        Cmd::Download => download(),
        Cmd::Image { path } => image(path),
        Cmd::Flash { path, wipe } => flash(path, wipe),
        Cmd::Authorize { keyfile } => authorize(keyfile),
        Cmd::Update => update(),
        Cmd::Ota { path, wipe } => ota(path, wipe),
        Cmd::Ssh { root } => run(ssh_cmd(&config(), root, false, &[])),
        Cmd::Network { connection } => network(connection),
        Cmd::Nmtui => run(ssh_cmd(&config(), true, true, &["nmtui"])),
        Cmd::Screen { root } => run(ssh_cmd(&config(), root, true, &["screen", "-x", "-R", "-S", "control"])),
        Cmd::FactoryReset => device(&["/usr/local/sbin/factory-reset"]),
        Cmd::OverlayCommit => device(&["/usr/local/sbin/overlay-commit"]),
        Cmd::Reboot => device(&["reboot"]),
        Cmd::Poweroff => device(&["poweroff"]),
    };
    if let Err(e) = r {
        eprintln!("raspi-provision: {e}");
        std::process::exit(1);
    }
}

// ---- config ---------------------------------------------------------------

// merge built-in defaults with ./customize.env (KEY=VALUE, # comments), then let
// matching process-env vars win (so the test harness can pass CUSTOM_* / OVERLAY).
fn config() -> Config {
    let mut c: Config = DEFAULTS.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    if let Ok(text) = fs::read_to_string("customize.env") {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some((k, v)) = line.split_once('=') {
                c.insert(k.trim().to_string(), v.trim().to_string());
            }
        }
    }
    for (k, _) in DEFAULTS {
        if let Ok(v) = std::env::var(k) {
            c.insert(k.to_string(), v);
        }
    }
    c
}

// where `image` writes when no path is given: named after the hostname, compressed.
fn image_path(c: &Config) -> PathBuf {
    PathBuf::from(format!("./images/{}.img.{GZIP_EXTENSION}", c["CUSTOM_HOSTNAME"]))
}

// the image `flash` writes when no path is given: the compressed build, or a raw
// one beside it (from `image images/<hostname>.img`, or an older version).
fn built_image(c: &Config) -> PathBuf {
    let gz = image_path(c);
    let raw = gz.with_extension("");
    if !gz.exists() && raw.exists() { raw } else { gz }
}

fn is_gzip(path: &Path) -> bool {
    path.extension().is_some_and(|e| e == GZIP_EXTENSION)
}

// the ordered layer list for an overlay dir: bundled base then the project's own.
fn layer_list(fw: &Path, name: &str) -> String {
    let mut layers = vec![fw.join(name).to_string_lossy().into_owned()];
    let project = PathBuf::from(name);
    if project.is_dir() {
        let abs = project.canonicalize().unwrap_or(project);
        layers.push(abs.to_string_lossy().into_owned());
    }
    layers.join(" ")
}

fn home_dir() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

// ---- framework extraction -------------------------------------------------

// extract the embedded framework tarball into a fresh temp dir and return it.
// per-run extraction keeps the binary self-contained with no stale cache.
fn extract_framework() -> Result<PathBuf, String> {
    let dir = std::env::temp_dir().join(format!("raspi-provision-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut child = Command::new("tar")
        .args(["-x", "-C"])
        .arg(&dir)
        .args(["-f", "-"])
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|e| format!("tar: {e}"))?;
    child.stdin.take().unwrap().write_all(FRAMEWORK_TAR).map_err(|e| e.to_string())?;
    if !child.wait().map_err(|e| e.to_string())?.success() {
        return Err("failed to extract framework".into());
    }
    Ok(dir)
}

// the union of package names across all files in the given depends dirs (later
// dirs and files add to the set), skipping blank lines and # comments.
fn read_depends(dirs: &[PathBuf]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for dir in dirs {
        let mut files: Vec<PathBuf> = match fs::read_dir(dir) {
            Ok(e) => e.flatten().map(|x| x.path()).filter(|p| p.is_file()).collect(),
            Err(_) => continue,
        };
        files.sort();
        for f in files {
            let text = fs::read_to_string(&f).unwrap_or_default();
            for line in text.lines() {
                let pkg = line.split('#').next().unwrap_or("").trim();
                if !pkg.is_empty() && seen.insert(pkg.to_string()) {
                    out.push(pkg.to_string());
                }
            }
        }
    }
    out
}

// the bundled base package lists, then the project's own.
fn depends(fw: &Path) -> Vec<String> {
    read_depends(&[fw.join("depends"), PathBuf::from("depends")])
}

// ---- build / flash --------------------------------------------------------

fn init(dir: PathBuf) -> R {
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    write_if_absent(&dir.join("customize.env"), INIT_CUSTOMIZE_ENV)?;
    write_if_absent(&dir.join(".gitignore"), INIT_GITIGNORE)?;
    fs::create_dir_all(dir.join("overlay")).map_err(|e| e.to_string())?;
    write_if_absent(&dir.join("overlay/.gitkeep"), "")?;
    fs::create_dir_all(dir.join("depends")).map_err(|e| e.to_string())?;
    write_if_absent(&dir.join("depends/base"), INIT_DEPENDS_BASE)?;
    println!("initialized raspi-provision project in {}", dir.display());
    println!("next: edit customize.env, add files under overlay/ (runtime paths), then `raspi-provision image`");
    Ok(())
}

fn download() -> R {
    let c = config();
    fs::create_dir_all("images").map_err(|e| e.to_string())?;
    let mut cmd = Command::new("curl");
    cmd.args(["-fL", "-o", &c["IMAGE_RASPIOS"], &c["IMAGE_RASPIOS_SOURCE"]]);
    run(cmd)
}

fn image(path: Option<PathBuf>) -> R {
    let c = config();
    if !Path::new(&c["IMAGE_RASPIOS"]).exists() {
        return Err(format!("upstream image not found: {} (run: raspi-provision download)", c["IMAGE_RASPIOS"]));
    }
    let fw = extract_framework()?;
    let mut cmd = Command::new(fw.join("toolbox/build-image"));
    cmd.arg(&c["IMAGE_RASPIOS"]).arg(path.unwrap_or_else(|| image_path(&c))).arg(&c["OVERLAY"]);
    for (k, v) in &c {
        cmd.env(k, v);
    }
    cmd.env("OVERLAY_LAYERS", layer_list(&fw, "overlay"));
    cmd.env("DEPENDS", depends(&fw).join(" "));
    run(cmd)
}

// the image `flash` and `ota` write: the one named, or the one `image` built.
fn image_to_write(c: &Config, path: Option<PathBuf>) -> Result<PathBuf, String> {
    let path = path.unwrap_or_else(|| built_image(c));
    if path.exists() {
        Ok(path)
    } else {
        Err(format!("built image not found: {} (run: raspi-provision image)", path.display()))
    }
}

// the first sector of an image, which holds its partition table
fn image_head(path: &Path) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let mut head = vec![0; SECTOR as usize];
    let whole = |r: std::io::Result<()>| r.map_err(|e| format!("{}: {e}", path.display()));
    if !is_gzip(path) {
        whole(fs::File::open(path).and_then(|mut file| file.read_exact(&mut head)))?;
        return Ok(head);
    }
    let mut gzip = Command::new("gzip").arg("-dc").arg(path).stdout(Stdio::piped()).stderr(Stdio::null()).spawn();
    let read = gzip.as_mut().map_err(|e| format!("gzip: {e}"))?.stdout.take().unwrap().read_exact(&mut head);
    // one sector was all that was wanted of it
    let mut gzip = gzip.unwrap();
    let _ = gzip.kill();
    let _ = gzip.wait();
    whole(read)?;
    Ok(head)
}

// the sector an image's persist partition starts at, if it has one and its
// initramfs can take over a persist partition it did not make
fn persist_start(head: &[u8]) -> Option<u64> {
    let field = |at: usize| u32::from_le_bytes(head[PERSIST_ENTRY + at..][..4].try_into().unwrap());
    (head.starts_with(KEEP_MAGIC) && field(ENTRY_SECTORS) > 0).then(|| u64::from(field(ENTRY_START)))
}

// what `blkid` is asked of a card: the label of the filesystem at this sector.
// a card that has a persist partition exactly where the image would put its
// own answers `persist`, and that partition can be left as it is.
fn label_probe(card: &str, sector: u64) -> String {
    format!("blkid -p -O {} -o value -s LABEL {card}", sector * SECTOR)
}

fn is_persist(probe: std::io::Result<std::process::Output>) -> bool {
    probe.is_ok_and(|out| String::from_utf8_lossy(&out.stdout).trim() == PERSIST_LABEL)
}

// what toolbox/write-image is told: keep the persist partition from this
// sector on, or replace the whole card. kept unless asked otherwise, when the
// image allows it and `has_persist` finds one on the card at that sector.
fn write_mode(path: &Path, wipe: bool, has_persist: impl FnOnce(u64) -> bool) -> Result<Option<u64>, String> {
    let start = if wipe { None } else { persist_start(&image_head(path)?) };
    let kept = start.filter(|&sector| has_persist(sector));
    match kept {
        Some(_) => println!("keeping the persist partition: home, identity and saved networks stay (--wipe replaces them)"),
        None if wipe => println!("replacing the whole card, the persist partition with it"),
        None => println!("no persist partition to keep where this image has its own: replacing the whole card"),
    }
    Ok(kept)
}

fn mode_arguments(kept: Option<u64>) -> String {
    kept.map_or("wipe".to_string(), |sector| format!("keep {sector}"))
}

fn flash(path: Option<PathBuf>, wipe: bool) -> R {
    let c = config();
    let path = image_to_write(&c, path)?;
    let fw = extract_framework()?;
    let (img, dev, writer) = (path.display(), &c["MOUNT_DEVICE"], fw.join("toolbox/write-image"));
    let kept = write_mode(&path, wipe, |sector| {
        is_persist(Command::new("sudo").args(label_probe(dev, sector).split(' ')).output())
    })?;
    // a compressed image is decompressed on the way to the card
    let read = if is_gzip(&path) { "gzip -dc" } else { "cat" };
    // unmount any mounted partitions, then hand the image to the writer
    let script = format!(
        "sudo umount {dev}?* 2>/dev/null; {read} '{img}' | sudo bash '{}' '{dev}' {} && sudo sync",
        writer.display(),
        mode_arguments(kept)
    );
    // pipefail, so an image that does not decompress fails the flash
    let mut cmd = Command::new("bash");
    cmd.args(["-o", "pipefail", "-c"]).arg(script);
    run(cmd)?;
    // the host keys are on the persist partition, and stay with it
    if kept.is_none() {
        forget_host_keys(&c);
    }
    Ok(())
}

// drop this user's saved ssh host keys for the device, under every name it
// answers to: a freshly written image makes new keys on its first boot, and
// ssh refuses a host whose key changed. the next command takes the new one
// (SSH_ACCEPT_NEW). ssh-keygen keeps the old file beside known_hosts.
fn forget_host_keys(c: &Config) {
    let hostname = &c["CUSTOM_HOSTNAME"];
    let names = [c["ADDRESS"].clone(), hostname.clone(), format!("{hostname}.local")];
    let names: BTreeSet<&str> = names.iter().map(String::as_str).chain(SHARED_ADDRESSES).collect();
    for name in &names {
        let mut keygen = Command::new("ssh-keygen");
        keygen.args(["-R", name]).stdout(Stdio::null()).stderr(Stdio::null());
        // nothing to forget, or no known_hosts at all, is as good
        let _ = keygen.status();
    }
    println!("forgot the saved ssh host keys of {}", names.into_iter().collect::<Vec<_>>().join(" "));
}

fn authorize(keyfile: Option<PathBuf>) -> R {
    let key = keyfile.unwrap_or_else(|| home_dir().join(".ssh/id_rsa.pub"));
    let pubkey = fs::read_to_string(&key).map_err(|e| format!("{}: {e}", key.display()))?;
    // bake into the project overlay so the next image build includes it; the home
    // dir name does not matter (build-image maps overlay/home/* to the baked user).
    for d in ["overlay/root/.ssh", "overlay/home/user/.ssh"] {
        fs::create_dir_all(d).map_err(|e| e.to_string())?;
        fs::write(format!("{d}/authorized_keys"), &pubkey).map_err(|e| e.to_string())?;
    }
    println!("authorized {} into ./overlay (root + home/user)", key.display());
    Ok(())
}

// ---- maintain (over ssh) --------------------------------------------------

fn update() -> R {
    let c = config();
    let fw = extract_framework()?;
    let target = format!("root@{}", c["ADDRESS"]);
    // push the project overlay (the FAT firmware partition is left alone; reflash
    // for config.txt/cmdline changes), refresh apt lists so neither install nor
    // upgrade works from stale indexes, then install depends and upgrade.
    if Path::new("overlay").is_dir() {
        let mut rsync = Command::new("rsync");
        rsync.args(["-e", &format!("ssh {}", SSH_ACCEPT_NEW.join(" "))])
            .args(["-rlptD", "--exclude=/boot/firmware", "--exclude=.gitkeep", "overlay/"])
            .arg(format!("{target}:/"));
        run(rsync)?;
    }
    run(ssh_cmd(&c, true, false, &["apt-get", "update"]))?;
    let pkgs = depends(&fw);
    if !pkgs.is_empty() {
        let mut apt = ssh_cmd(&c, true, false, &["apt-get", "-y", "install"]);
        apt.args(&pkgs);
        run(apt)?;
    }
    run(ssh_cmd(&c, true, false, &["apt-get", "-y", "full-upgrade", "--autoremove", "--purge"]))
}

// wait until the device answers ssh, for OTA_WAIT_SECONDS at most. a device
// asked a moment ago to bring a network up, as one that has just given its
// usb port back to usb networking was, takes seconds to appear, and the host
// seconds more to get an address from it. what ssh said of the last attempt
// goes with the failure: a device that is up and refused, over a host key
// that changed with its last flash, say, reads otherwise as one that is down.
fn wait_for_device(c: &Config) -> R {
    let limit: u64 = c["OTA_WAIT_SECONDS"].parse().map_err(|_| "OTA_WAIT_SECONDS is not a number of seconds")?;
    let start = std::time::Instant::now();
    loop {
        let mut probe = Command::new("ssh");
        probe.args(SSH_ACCEPT_NEW).arg("-o").arg(format!("ConnectTimeout={OTA_PROBE_SECONDS}"));
        probe.arg(format!("root@{}", c["ADDRESS"])).arg("true");
        let answer = probe.output().map_err(|e| format!("ssh: {e}"))?;
        if answer.status.success() {
            return Ok(());
        }
        if start.elapsed().as_secs() >= limit {
            let said = String::from_utf8_lossy(&answer.stderr);
            return Err(format!("no answer from {} over ssh in {limit}s. ssh said:\n{}", c["ADDRESS"], said.trim_end()));
        }
        std::thread::sleep(std::time::Duration::from_secs(OTA_PROBE_SECONDS));
    }
}

// replace the card of a running device with a built image. the device runs
// toolbox/ota-write, handed over first so that a device flashed before `ota`
// existed takes it too. the image always travels as gzip: the writer then
// fails on a stream that was cut short, where a raw one would pass as whole.
fn ota(path: Option<PathBuf>, wipe: bool) -> R {
    let c = config();
    let path = image_to_write(&c, path)?;
    wait_for_device(&c)?;
    // the card is the disk the device's boot partition is on, as ota-write finds it
    let card = "/dev/$(lsblk -no pkname \"$(blkid -L bootfs)\")";
    let kept = write_mode(&path, wipe, |sector| {
        is_persist(ssh_cmd(&c, true, false, &[&label_probe(card, sector)]).stderr(Stdio::null()).output())
    })?;
    send_image(&c, &path, kept)?;
    if kept.is_none() {
        forget_host_keys(&c);
    }
    Ok(())
}

// hand the device a script from toolbox/, to run from its ram
fn push_script(c: &Config, fw: &Path, name: &str, place: &str) -> R {
    let script = fs::File::open(fw.join("toolbox").join(name)).map_err(|e| format!("{name}: {e}"))?;
    let mut push = ssh_cmd(c, true, false, &["cat", ">", place]);
    push.stdin(script);
    run(push)
}

fn send_image(c: &Config, path: &Path, kept: Option<u64>) -> R {
    let fw = extract_framework()?;
    push_script(c, &fw, "write-image", OTA_WRITE_IMAGE)?;
    push_script(c, &fw, "ota-write", OTA_WRITER)?;
    let mut write = ssh_cmd(c, true, false, &["bash", OTA_WRITER, OTA_WRITE_IMAGE, &mode_arguments(kept)]);
    let image = fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if is_gzip(path) {
        write.stdin(image);
        return run(write);
    }
    let mut gzip = Command::new("gzip");
    let mut gzip = gzip.arg("-1c").stdin(image).stdout(Stdio::piped()).spawn().map_err(|e| format!("gzip: {e}"))?;
    write.stdin(gzip.stdout.take().unwrap());
    let written = run(write);
    match gzip.wait() {
        Ok(s) if s.success() => written,
        _ => Err(format!("gzip failed on {}", path.display())),
    }
}

fn network(connection: String) -> R {
    // accept short names (ethernet|hotspot|rndis) or a full connection id.
    let name = match connection.as_str() {
        "ethernet" | "hotspot" | "rndis" => format!("shared-{connection}"),
        _ => connection,
    };
    run(ssh_cmd(&config(), true, false, &["nmcli", "connection", "up", &name]))
}

fn device(remote: &[&str]) -> R {
    run(ssh_cmd(&config(), true, false, remote))
}

fn ssh_cmd(c: &Config, root: bool, tty: bool, remote: &[&str]) -> Command {
    let user = if root { "root" } else { c["CUSTOM_USERNAME"].as_str() };
    let mut cmd = Command::new("ssh");
    cmd.args(SSH_ACCEPT_NEW);
    if tty {
        cmd.arg("-t");
    }
    cmd.arg(format!("{user}@{}", c["ADDRESS"]));
    cmd.args(remote);
    cmd
}

// ---- helpers --------------------------------------------------------------

fn write_if_absent(path: &Path, content: &str) -> R {
    if path.exists() {
        return Ok(());
    }
    fs::write(path, content).map_err(|e| format!("{}: {e}", path.display()))
}

fn run(mut cmd: Command) -> R {
    let prog = cmd.get_program().to_string_lossy().into_owned();
    match cmd.status() {
        Ok(s) if s.success() => Ok(()),
        Ok(s) => Err(format!("{prog} exited with {s}")),
        Err(e) => Err(format!("{prog}: {e}")),
    }
}
