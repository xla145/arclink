const origin = "https://download.classktv.com";
const architectures = {
  arm64: { platform: "darwin-aarch64", label: "下载 Apple 芯片版" },
  x64: { platform: "darwin-x86_64", label: "下载 Intel 版" },
};

function versionParts(version) {
  if (typeof version !== "string" || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version)) {
    throw new Error("Invalid stable release version");
  }
  return version.split(".").map(BigInt);
}

export function releaseDownloads(manifest, minimumVersion) {
  const version = manifest?.version;
  const parts = versionParts(version);
  const minimum = versionParts(minimumVersion);
  for (let index = 0; index < parts.length; index++) {
    if (parts[index] < minimum[index]) throw new Error("Stale release manifest");
    if (parts[index] > minimum[index]) break;
  }
  if (typeof manifest.notes !== "string" || !manifest.notes.trim()) {
    throw new Error("Missing release notes");
  }
  const downloads = {};
  for (const [arch, { platform, label }] of Object.entries(architectures)) {
    const item = manifest.platforms?.[platform];
    const base = `${origin}/releases/arclink-v${version}/ArcLink-macos-${arch}`;
    if (item?.url !== `${base}.app.tar.gz` || typeof item.signature !== "string" || !item.signature.trim()) {
      throw new Error("Invalid release platform");
    }
    downloads[arch] = { url: `${base}.dmg`, label };
  }
  return { version, downloads };
}

// Validate the entire response and all page hooks before changing any visible state.
export async function refreshDownloads(root = document, fetcher = fetch, timeoutMs = 5000) {
  const versions = [...root.querySelectorAll("[data-release-version]")];
  const buttons = Object.keys(architectures).map((arch) => ({
    arch,
    node: root.querySelector(`[data-download-arch="${arch}"]`),
  }));
  if (!versions.length || buttons.some(({ node }) => !node?.querySelector("[data-download-label]"))) return false;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetcher(`${origin}/latest.json`, {
      mode: "cors", credentials: "omit", cache: "no-store", signal: controller.signal,
    });
    if (!response.ok) throw new Error("Release manifest unavailable");
    const manifest = await response.json();
    // Check every rendered version so a mismatched template cannot cause a downgrade.
    const release = versions.map((node) => releaseDownloads(manifest, node.dataset.releaseVersion))[0];
    for (const { arch, node } of buttons) {
      node.href = release.downloads[arch].url;
      node.querySelector("[data-download-label]").textContent = release.downloads[arch].label;
    }
    for (const node of versions) {
      node.textContent = `v${release.version}`;
      node.dataset.releaseVersion = release.version;
    }
    return true;
  } catch {
    // Static links remain usable for offline, blocked, malformed or stale responses.
    return false;
  } finally {
    clearTimeout(timer);
  }
}
