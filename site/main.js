// Tend's website: the download button's state and the copy button.
// Without this script, the download button links to GitHub Releases.

const REPO = "https://github.com/schaffernation/tend";
const DMG = REPO + "/releases/latest/download/Tend.dmg";
const SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle";

// Reads a Sparkle field from an <item>: an element in Sparkle 2's feeds, or an
// attribute of <enclosure> in older ones.
function field(item, name) {
  const element = item.getElementsByTagNameNS(SPARKLE, name)[0];
  if (element && element.textContent.trim()) return element.textContent.trim();
  const enclosure = item.getElementsByTagName("enclosure")[0];
  const value = enclosure && enclosure.getAttributeNS(SPARKLE, name);
  return value ? value.trim() : "";
}

function compareVersions(a, b) {
  const x = a.split(/[^0-9]+/).filter(Boolean).map(Number);
  const y = b.split(/[^0-9]+/).filter(Boolean).map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] || 0) - (y[i] || 0);
    if (d) return d;
  }
  return 0;
}

// Returns {version, minimumSystemVersion} for the newest item in the feed,
// or null if the feed has none. The newest has the highest sparkle:version,
// whatever the items' order.
function newestRelease(xml) {
  const doc = new DOMParser().parseFromString(xml, "application/xml");
  if (doc.getElementsByTagName("parsererror").length) return null;
  let newest = null;
  for (const item of doc.getElementsByTagName("item")) {
    const build = field(item, "version");
    if (!build) continue;
    if (!newest || compareVersions(build, newest.build) > 0) {
      newest = {
        build,
        version: field(item, "shortVersionString") || build,
        minimumSystemVersion: field(item, "minimumSystemVersion"),
      };
    }
  }
  return newest;
}

// "14.0" becomes "macOS 14 or later", and "14.2" becomes "macOS 14.2 or later".
function macOSLabel(minimum) {
  const version = minimum.replace(/(\.0)+$/, "");
  return /^[0-9.]+$/.test(version) ? `macOS ${version} or later` : "";
}

function showRelease(release) {
  const get = document.getElementById("get");
  const link = document.getElementById("download");
  const label = document.getElementById("download-label");
  if (release) {
    link.href = DMG;
    label.textContent = `Download Tend ${release.version}`;
    document.getElementById("release-version").textContent = `Version ${release.version}`;
    const macos = macOSLabel(release.minimumSystemVersion);
    if (macos) document.getElementById("release-macos").textContent = macos;
    get.dataset.release = "released";
  } else {
    link.href = REPO;
    label.textContent = "Follow Tend on GitHub";
    get.dataset.release = "unreleased";
  }
}

async function checkRelease() {
  let release = null;
  try {
    const response = await fetch("appcast.xml", { cache: "no-cache" });
    if (response.ok) release = newestRelease(await response.text());
  } catch {
    // No feed, or no network: treat it as not released.
  }
  showRelease(release);
}

function setUpCopy() {
  const button = document.getElementById("copy");
  const command = document.getElementById("brew-command");
  const text = button.querySelector(".copy-text");
  const status = document.getElementById("copy-status");
  let timer;

  button.hidden = false;
  button.addEventListener("click", async () => {
    clearTimeout(timer);
    try {
      await navigator.clipboard.writeText(command.textContent);
      text.textContent = "Copied";
      button.classList.add("is-copied");
      status.textContent = "Copied the command.";
    } catch {
      // The clipboard isn't available, like on an insecure connection.
      // Select the command so that you can copy it with Command-C.
      const range = document.createRange();
      range.selectNodeContents(command);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      status.textContent = "Selected the command. Press Command-C to copy it.";
    }
    timer = setTimeout(() => {
      text.textContent = "Copy";
      button.classList.remove("is-copied");
      status.textContent = "";
    }, 2000);
  });
}

setUpCopy();
checkRelease();
