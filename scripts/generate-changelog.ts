#!/usr/bin/env -S deno run --allow-env --allow-net=api.github.com --allow-read --allow-write=./build

// Generate Release Notes
//
// This script generates comprehensive release notes by aggregating changes from:
// - gnosis_vpn-client repository (merged PRs between dates)
// - gnosis_vpn-app repository (merged PRs between dates)
// - gnosis_vpn-toolkit repository (merged PRs between dates)
// - gnosis_vpn Installer repository (merged PRs since last release)
//
// Example:
//   GNOSISVPN_PREVIOUS_PACKAGE_VERSION=0.56.4 \
//   GNOSISVPN_PACKAGE_VERSION=0.56.5 \
//   GNOSISVPN_PREVIOUS_CLIENT_VERSION=0.54.4 \
//   GNOSISVPN_CLIENT_VERSION=0.56.1 \
//   GNOSISVPN_PREVIOUS_APP_VERSION=0.5.0 \
//   GNOSISVPN_APP_VERSION=0.6.1 \
//   GNOSISVPN_PREVIOUS_TOOLKIT_VERSION=1.2.2 \
//   GNOSISVPN_TOOLKIT_VERSION=1.2.3 \
//   GNOSISVPN_CHANGELOG_FORMAT=zulip \
//   GH_TOKEN=... \
//   ./scripts/generate-changelog.ts
//
// The four GNOSISVPN_PREVIOUS_* variables are optional off the stable channel: unset or empty means
// "this line has never built before", and that component contributes no entries. See readPreviousVersion().
//
// Client and app PRs are aggregated from the branch carrying the line being built, chosen by comparing
// the version being built against COMPONENT_VERSION_BOUNDARY (see componentBranch). That variable and
// COMPONENT_V4_BRANCH are required and come from scripts/config.sh via the build's step outputs.

// --- Types ---

interface RepoConfig {
  repo: string;
  label: string;
  // PR `base=` filter. The installer repo is overridable via GNOSISVPN_PACKAGE_BRANCH
  // so close-release on a release branch only includes installer PRs that targeted that
  // branch; client and app follow their version's line via componentBranch(); the toolkit
  // is not split between lines and always reads main.
  branch: string;
  // null when this line has never built before; select_previous_version() in
  // scripts/resolve-build-versions.sh emits an empty value on purpose to say so.
  previousVersion: string | null;
  currentVersion: string;
  allowMissingRelease: boolean;
}

export interface Config {
  repositories: RepoConfig[];
  format: "zulip" | "github" | "debian" | "json" | "rpm";
  channel: Channel;
  ghApiMaxAttempts: number;
  ghToken: string;
}

/** Release channel a build is published to. */
export type Channel = "stable" | "snapshot" | "experimental";

/** Artifact paths per channel; keep in sync with build_gcs_url() and pool_subpath_for_channel(). */
export const CHANNEL_PATHS: Record<Channel, { debPool: string; macDir: string }> = {
  stable: { debPool: "pool/main", macDir: "stable" },
  snapshot: { debPool: "pool/snapshot", macDir: "latest" },
  experimental: { debPool: "pool/experimental", macDir: "experimental" },
};

export interface ChangelogEntry {
  repository: string;
  id: string;
  title: string;
  author: string;
  labels: string;
  state: string;
  date: string;
  changelog_type: string;
  component: string;
}

interface GitHubPR {
  number: number;
  title: string;
  // Present on the list and detail endpoints; a backport names its source PR here.
  body: string | null;
  state: string;
  merged_at: string | null;
  user: { login: string };
  labels: { name: string }[];
}

interface GitHubCommit {
  commit: {
    committer: {
      date: string;
    };
  };
}

interface GitHubRelease {
  created_at: string;
  tag_name: string;
}

// --- Logging ---

function log(level: string, message: string): void {
  console.error(`[${level}] ${message}`);
}

// --- Date Validation ---

export function validateIso8601Date(dateString: string): boolean {
  if (!dateString) return false;

  const iso8601Regex = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
  if (!iso8601Regex.test(dateString)) return false;

  const parsed = Date.parse(dateString);
  if (isNaN(parsed)) return false;

  return true;
}

// Component versions carry the exact registry tag, which may or may not be
// v-prefixed; this normalizes to the v-prefixed form without doubling the "v".
function vTag(version: string): string {
  return `${version}`.startsWith("v") ? `${version}` : `v${version}`;
}

// --- Release Lines ---

// COMPONENT_VERSION_BOUNDARY and COMPONENT_V4_BRANCH are defined once in scripts/config.sh and
// reach this script through the environment: resolve-build-versions.sh splits the lines on them
// when it picks the client and app versions, publishes both as step outputs, and the workflows
// pass those along. They are required here on purpose — a default would be a second copy that a
// config.sh edit leaves behind, and the build would resolve one line while these notes aggregate
// the other's branch.

// Mirrors version_core() in scripts/common.sh: drop a leading "v" and any "+build" metadata.
// Returns null for anything without a numeric x.y.z core, e.g. a date-based snapshot version.
export function versionCore(version: string): [number, number, number] | null {
  const core = `${version}`.replace(/^v/, "").split("+")[0];
  const match = core.match(/^(\d+)\.(\d+)\.(\d+)$/);
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null;
}

/** version < boundary, compared on the numeric core. Mirrors version_core_lt() in scripts/common.sh. */
export function versionCoreLt(version: string, boundary: string): boolean {
  const a = versionCore(version);
  const b = versionCore(boundary);
  if (!a || !b) return false;
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] < b[i];
  }
  return false;
}

/**
 * Base branch to aggregate a client/app component's PRs from.
 *
 * The two lines are split by the boundary exactly as resolve-build-versions.sh splits them:
 * the v4 line sits below it on its own release branch, the v5 line at or above it on main.
 * Reading a v4 build's PRs from main would credit it with v5 changes it does not contain.
 * A version with no numeric core falls back to main, the branch everything else builds from.
 */
export function componentBranch(version: string, boundary: string, v4Branch: string): string {
  return versionCoreLt(version, boundary) ? v4Branch : "main";
}

// --- GitHub API Client ---

async function ghApiCall(
  config: Config,
  repo: string,
  endpoint: string,
  allowNotFound = false,
): Promise<unknown> {
  let attempt = 1;
  let delay = 2000;

  while (attempt <= config.ghApiMaxAttempts) {
    log(
      "DEBUG",
      `GitHub API call attempt ${attempt}/${config.ghApiMaxAttempts}: /repos/${repo}${endpoint}`,
    );

    try {
      const response = await fetch(
        `https://api.github.com/repos/${repo}${endpoint}`,
        {
          headers: {
            Accept: "application/vnd.github+json",
            Authorization: `Bearer ${config.ghToken}`,
            "X-GitHub-Api-Version": "2022-11-28",
          },
        },
      );

      if (response.status === 429 || response.status === 403) {
        const body = await response.text();
        if (
          response.status === 429 ||
          /rate limit|throttle|too many requests/i.test(body)
        ) {
          if (attempt >= config.ghApiMaxAttempts) {
            log(
              "ERROR",
              `GitHub API throttled after ${config.ghApiMaxAttempts} attempts. Rate limit exceeded.`,
            );
            log("ERROR", `Endpoint: /repos/${repo}${endpoint}`);
            log("ERROR", `Last error: ${body}`);
            Deno.exit(1);
          }
          log(
            "WARN",
            `GitHub API throttled (attempt ${attempt}/${config.ghApiMaxAttempts}). Retrying in ${delay / 1000}s...`,
          );
          await new Promise((resolve) => setTimeout(resolve, delay));
          delay *= 2;
          attempt++;
          continue;
        }
      }

      if (response.status === 404 && allowNotFound) {
        log(
          "WARN",
          `GitHub API returned 404 for optional request /repos/${repo}${endpoint}; treating as not found and continuing with fallback behavior.`,
        );
        return null;
      }

      if (!response.ok) {
        const body = await response.text();
        log("ERROR", `GitHub API request failed (${response.status}): ${body}`);
        log("ERROR", `Endpoint: /repos/${repo}${endpoint}`);
        Deno.exit(1);
      }

      return await response.json();
    } catch (error) {
      log("ERROR", `GitHub API request failed: ${error}`);
      log("ERROR", `Endpoint: /repos/${repo}${endpoint}`);
      Deno.exit(1);
    }
  }

  log(
    "ERROR",
    `GitHub API call failed after ${config.ghApiMaxAttempts} attempts`,
  );
  Deno.exit(1);
}

// --- Version Date Fetcher ---

async function getVersionDate(
  config: Config,
  repo: string,
  version: string,
  allowMissingRelease: boolean,
): Promise<string> {
  log("DEBUG", `Fetching version date for ${repo} ${version}`);
  let date = "";
  if (`${version}`.includes("+pr.")) {
    log("DEBUG", `Getting version date from PR number in version string`);
    const prNumber = version.split("+pr.")[1];
    const pr = (await ghApiCall(config, repo, `/pulls/${prNumber}`)) as GitHubPR;
    if (pr.merged_at) {
      date = pr.merged_at;
    } else {
      log(
        "ERROR",
        `PR #${prNumber} for ${repo} is not merged. Cannot determine version date.`,
      );
      Deno.exit(1);
    }
  } else if (`${version}`.includes("+commit.")) {
    log("DEBUG", `Getting version date from commit hash in version string`);
    const commitHash = version.split("+commit.")[1];
    const commit = (await ghApiCall(config, repo, `/commits/${commitHash}`)) as GitHubCommit;
    date = commit.commit.committer.date;
  } else if (/^v?\d+\.\d+\.\d+$/.test(`${version}`)) {
    log("DEBUG", `Getting version date from release tag`);
    const tag = vTag(`${version}`);
    const release = (await ghApiCall(config, repo, `/releases/tags/${tag}`, allowMissingRelease)) as
      | GitHubRelease
      | null;
    // Release may not exist yet if this is the currentVersion being created in this workflow run.
    date = release?.created_at ?? new Date().toISOString();
  } else {
    date = new Date().toISOString();
  }

  if (!validateIso8601Date(date)) {
    log("ERROR", `Invalid or empty version date for ${repo}/${version}: '${date}'`);
    log(
      "ERROR",
      "Expected ISO8601 timestamp format (e.g., 2024-01-15T10:30:00Z)",
    );
    Deno.exit(1);
  }

  return date;
}

// --- Backports ---

// A backport lands on a release branch under a generated title that buries the original
// conventional-commit type ("[Backport release/hoprdv4] fix(core): ...") or drops it entirely
// ("Backport 793 to release/hoprdv4"), and is authored by the bot that opened it. Left alone,
// every backported change is filed under "Other" and credited to a bot, which is most of a
// release line that ships by backporting. Both forms name their source PR, so the entry takes
// the source's type, title and author; the link stays on the PR that landed on this line.
const BACKPORT_TITLE_PREFIX = /^\[Backport [^\]]*\]\s*(.+)$/i;
const BACKPORT_TITLE_NUMBER = /^Backport #?(\d+) to \S+/i;
const BACKPORT_BODY_SOURCE = /Backport of #(\d+)/i;

export interface BackportRef {
  /** The original title, when the generated one still carries it; null otherwise. */
  title: string | null;
  /** The PR this was backported from; null when neither title nor body names one. */
  sourceNumber: number | null;
}

/** Recognizes both generated backport title shapes. Returns null when the PR is not a backport. */
export function parseBackport(title: string, body: string | null): BackportRef | null {
  const prefixed = title.match(BACKPORT_TITLE_PREFIX);
  const numbered = title.match(BACKPORT_TITLE_NUMBER);
  if (!prefixed && !numbered) return null;

  const source = numbered?.[1] ?? body?.match(BACKPORT_BODY_SOURCE)?.[1];
  return {
    title: prefixed?.[1] ?? null,
    sourceNumber: source ? Number(source) : null,
  };
}

/**
 * The title and author a backport should be credited with.
 *
 * The source PR is the authority: the generated title is a copy taken when the backport was
 * opened, and the action truncates long ones. It is only used when the source cannot be read.
 */
async function resolveBackport(
  config: Config,
  repoName: string,
  pr: GitHubPR,
): Promise<{ title: string; author: string }> {
  const backport = parseBackport(pr.title, pr.body);
  if (!backport) return { title: pr.title, author: pr.user.login };

  // Nothing to look up: keep whatever the generated title carried, and the bot as author.
  const fallback = { title: backport.title ?? pr.title, author: pr.user.login };
  if (backport.sourceNumber === null) {
    log("WARN", `${repoName}#${pr.number} reads as a backport but names no source PR.`);
    return fallback;
  }

  // Source PRs live in the same repo, on the line this was backported from. A deleted or
  // otherwise unreachable one must not fail the release: fall back instead.
  const source = (await ghApiCall(
    config,
    repoName,
    `/pulls/${backport.sourceNumber}`,
    true,
  )) as GitHubPR | null;
  if (!source) {
    log("WARN", `${repoName}#${pr.number}: backport source #${backport.sourceNumber} not found.`);
    return fallback;
  }

  return { title: source.title, author: source.user.login };
}

// --- PR Fetcher ---

async function fetchMergedPRs(
  config: Config,
  repoName: string,
  startDate: string,
  endDate: string,
  component: string,
  branch: string,
): Promise<ChangelogEntry[]> {
  if (!startDate || !endDate || startDate === endDate) {
    return [];
  }

  log(
    "INFO",
    `Fetching PRs for ${component} (branch: ${branch}) between ${startDate} and ${endDate}...`,
  );

  const prs = (await ghApiCall(
    config,
    repoName,
    `/pulls?state=closed&base=${branch}&sort=updated&direction=desc&per_page=100`,
  )) as GitHubPR[];

  const entries: ChangelogEntry[] = [];

  for (const pr of prs) {
    if (!pr.merged_at) continue;
    if (pr.merged_at <= startDate || pr.merged_at > endDate) continue;

    const labels = pr.labels.map((l) => l.name).join(", ");
    const state = pr.state.toLowerCase();
    const mergedDate = pr.merged_at.split("T")[0] ||
      new Date().toISOString().split("T")[0];
    const { title, author } = await resolveBackport(config, repoName, pr);
    const changelogType = extractChangelogType(title);

    log(
      "DEBUG",
      `Processing PR: id=${pr.number}, title=${title}, author=${author}, labels=${labels}, merged_at=${mergedDate}, type=${changelogType}, component=${component}`,
    );

    entries.push({
      repository: repoName,
      id: String(pr.number),
      title,
      author,
      labels,
      state,
      date: mergedDate,
      changelog_type: changelogType,
      component,
    });
  }

  return entries;
}

// --- Changelog Type Extractor ---

export function extractChangelogType(title: string): string {
  if (!title.includes(":")) return "other";
  const prefix = title.split(":")[0].split("(")[0].trim().toLowerCase();
  return prefix || "other";
}

// --- Format Functions ---

export function zulipFormat(
  entries: ChangelogEntry[],
  packageVersion: string,
  clientVersion: string,
  appVersion: string,
  toolkitVersion: string,
  channel: Channel = "snapshot",
): string {
  const channelLabel = `${channel.charAt(0).toUpperCase()}${channel.slice(1)}`;
  let content = `A new ${channel} build is available for testing with the following new content:\n\n`;

  content += `**${channelLabel} version:** ${packageVersion}\n`;
  content +=
    `**Client version:** ${clientVersion}, **App version:** ${appVersion}, **Toolkit version:** ${toolkitVersion}\n\n`;

  for (const entry of entries) {
    content +=
      `- [#${entry.id}](https://github.com/${entry.repository}/pull/${entry.id}) [${entry.component}] ${entry.title} by ${entry.author}\n`;
  }
  content += "\nDownload links:";
  // macOS .pkg filenames substitute '-' for '+' in the version slug for
  // Artifact Registry compatibility (see build-binary.yaml::prepare_files).
  const macFileSlug = packageVersion.replaceAll("+", "-");
  // .debs live in their channel's pool under gnosisvpn_<version>_<arch>.deb, with the build's literal version.
  const paths = CHANNEL_PATHS[channel];
  const debPool = `https://download.gnosisvpn.io/linux/apt/${paths.debPool}/g/gnosisvpn`;
  content += ` [Mac](https://download.gnosisvpn.io/macos/${paths.macDir}/gnosisvpn_${macFileSlug}_arm64.pkg) |`;
  content += ` [Debian x86_64](${debPool}/gnosisvpn_${packageVersion}_amd64.deb) |`;
  content += ` [Debian aarch64](${debPool}/gnosisvpn_${packageVersion}_arm64.deb)\n`;
  return content;
}

export function githubFormat(
  entries: ChangelogEntry[],
  previousCliVersion: string | null,
  currentCliVersion: string,
  previousAppVersion: string | null,
  currentAppVersion: string,
  previousToolkitVersion: string | null,
  currentToolkitVersion: string,
): string {
  const sections: Record<string, string[]> = {
    "New Features": [],
    Fixes: [],
    Refactor: [],
    Automation: [],
    Documentation: [],
    Other: [],
  };

  for (const entry of entries) {
    const line =
      `- [${entry.component}] ${entry.title} by @${entry.author} in [${entry.repository}#${entry.id}](https://github.com/${entry.repository}/pull/${entry.id})`;
    switch (entry.changelog_type) {
      case "feat":
      case "feature":
        sections["New Features"].push(line);
        break;
      case "fix":
      case "bugfix":
        sections["Fixes"].push(line);
        break;
      case "refactor":
        sections["Refactor"].push(line);
        break;
      case "ci":
      case "cd":
      case "chore":
        sections["Automation"].push(line);
        break;
      case "docs":
      case "documentation":
        sections["Documentation"].push(line);
        break;
      default:
        sections["Other"].push(line);
        break;
    }
  }

  let content = "## What's Changed\n";

  // Compare and render via vTag so a pure "v"-prefix format change in the
  // stored previous-version variables doesn't report a component update. A null previous
  // version has nothing to compare against; vTag(null) would render a broken "[v](.../tag/v)" link.
  const cliUpdated = previousCliVersion !== null && vTag(previousCliVersion) !== vTag(currentCliVersion);
  const appUpdated = previousAppVersion !== null && vTag(previousAppVersion) !== vTag(currentAppVersion);
  const toolkitUpdated = previousToolkitVersion !== null &&
    vTag(previousToolkitVersion) !== vTag(currentToolkitVersion);

  if (cliUpdated || appUpdated || toolkitUpdated) {
    content += "\nThis release contains the following component updates:\n\n";
    if (cliUpdated) {
      content += `- **[GnosisVPN Client](https://github.com/gnosis/gnosis_vpn-client)**: Updated from [${
        vTag(previousCliVersion)
      }](https://github.com/gnosis/gnosis_vpn-client/releases/tag/${vTag(previousCliVersion)}) to [${
        vTag(currentCliVersion)
      }](https://github.com/gnosis/gnosis_vpn-client/releases/tag/${vTag(currentCliVersion)})\n`;
    }
    if (appUpdated) {
      content += `- **[GnosisVPN App](https://github.com/gnosis/gnosis_vpn-app)**: Updated from [${
        vTag(previousAppVersion)
      }](https://github.com/gnosis/gnosis_vpn-app/releases/tag/${vTag(previousAppVersion)}) to [${
        vTag(currentAppVersion)
      }](https://github.com/gnosis/gnosis_vpn-app/releases/tag/${vTag(currentAppVersion)})\n`;
    }
    if (toolkitUpdated) {
      content += `- **[GnosisVPN Toolkit](https://github.com/gnosis/gnosis_vpn-toolkit)**: Updated from [${
        vTag(previousToolkitVersion)
      }](https://github.com/gnosis/gnosis_vpn-toolkit/releases/tag/${vTag(previousToolkitVersion)}) to [${
        vTag(currentToolkitVersion)
      }](https://github.com/gnosis/gnosis_vpn-toolkit/releases/tag/${vTag(currentToolkitVersion)})\n`;
    }
    content += "\n";
  }

  for (const [sectionName, lines] of Object.entries(sections)) {
    if (lines.length > 0) {
      content += `\n### ${sectionName}\n\n`;
      content += lines.join("\n") + "\n";
      content += "\n";
    }
  }

  return content;
}

export function getReleaseType(
  entries: ChangelogEntry[],
  version: string,
): string {
  // Check for experimental or breaking labels
  for (const entry of entries) {
    if (/experimental|breaking/i.test(entry.labels)) {
      return "unstable";
    }
  }

  // Check if the version contains "-rc." or is the first release (x.y.0)
  if (version.includes("-rc.") || /^\d+\.\d+\.0$/.test(version)) {
    return "unstable";
  }

  return "stable";
}

export function getUrgencyLevel(version: string): string {
  const parts = version.split(".");
  const patchPart = parts[2] || "0";
  const patchNumber = parseInt(patchPart.split("-")[0], 10);

  if (version.includes("-rc.") || patchNumber === 0) {
    return "optional";
  }
  return "medium";
}

export function rfc2822Date(date: Date): string {
  return date.toUTCString().replace("GMT", "+0000");
}

export function debianFormat(
  entries: ChangelogEntry[],
  version: string,
): string {
  const distribution = getReleaseType(entries, version);
  const urgency = getUrgencyLevel(version);
  const maintainer = "GnosisVPN (Gnosis VPN) <tech@hoprnet.org>";
  const date = rfc2822Date(new Date());

  let changelog = `gnosisvpn (${version}) ${distribution}; urgency=${urgency}\n`;

  for (const entry of entries) {
    const ref = `${entry.repository}#${entry.id}`;
    const entryLine = `  * ${entry.title} by @${entry.author} in ${ref}\n`;

    if (entryLine.length <= 80) {
      changelog += entryLine;
    } else {
      // Truncate title to fit within 80 characters
      // (entryLine.length - title.length) = overhead
      // Subtract 3 for the "..." that will be appended
      let maxTitleLength = 80 - (entryLine.length - entry.title.length) - 3;
      if (maxTitleLength < 1) maxTitleLength = 1;
      const truncatedTitle = entry.title.substring(0, maxTitleLength);
      changelog += `  * ${truncatedTitle}... by @${entry.author} in ${ref}\n`;
    }
  }

  // A stanza with no change lines reads as a truncated file; say so explicitly instead.
  if (entries.length === 0) {
    changelog += "  * No recorded changes since the previous build.\n";
  }

  changelog += `\n -- ${maintainer}  ${date}\n`;

  return changelog;
}

export function jsonFormat(entries: ChangelogEntry[]): string {
  return JSON.stringify(entries);
}

export function rpmFormat(
  entries: ChangelogEntry[],
  version: string,
): string {
  // Sort entries by date and author (newest first)
  const sorted = [...entries].sort((a, b) => {
    const cmp = `${b.date}${b.author}`.localeCompare(`${a.date}${a.author}`);
    return cmp;
  });

  let changelog = "";
  let currentDate = "";
  let currentAuthor = "";

  for (const entry of sorted) {
    if (entry.date !== currentDate || entry.author !== currentAuthor) {
      currentDate = entry.date;
      currentAuthor = entry.author;
      changelog += `* ${entry.date} ${entry.author} - ${version}\n`;
    }

    // Remove the type(component): prefix from title if present
    const cleanTitle = entry.title.replace(/^.*\): /, "");
    changelog += `- [${entry.changelog_type}][${entry.component}] ${cleanTitle} in #${entry.id}\n`;
  }

  return changelog;
}

// --- File Writer ---

async function writeChangelog(content: string): Promise<void> {
  const scriptDir = new URL(".", import.meta.url).pathname;
  const buildDir = `${scriptDir}../build/changelog`;
  await Deno.mkdir(buildDir, { recursive: true });

  const filePath = `${buildDir}/changelog`;
  await Deno.writeTextFile(filePath, content);

  // Gzip the changelog
  const gzipPath = `${buildDir}/changelog.gz`;
  const input = new Blob([content]);
  const cs = new CompressionStream("gzip");
  const compressedStream = input.stream().pipeThrough(cs);
  const compressedData = await new Response(compressedStream).arrayBuffer();
  await Deno.writeFile(gzipPath, new Uint8Array(compressedData));
}

// --- Config Reader ---

// Unset or empty means "this line has never built before" — select_previous_version() in
// scripts/resolve-build-versions.sh emits an empty value on purpose, so an empty string must
// not be an error here. Stable is the exception: its variables are always set, so an empty one
// there is a mistake rather than a first build, and must not yield silently empty release notes.
function readPreviousVersion(envVar: string, component: string, channel: Channel): string | null {
  const value = Deno.env.get(envVar);
  if (value) return value;
  if (channel === "stable") {
    console.error(`Error: ${envVar} is required`);
    Deno.exit(1);
  }
  log("WARN", `${envVar} is unset or empty; treating it as "no previous ${component} build on this line"`);
  return null;
}

export function readConfig(): Config {
  const ghToken = Deno.env.get("GH_TOKEN");
  if (!ghToken) {
    console.error("Error: GH_TOKEN is required");
    Deno.exit(1);
  }

  // Channel for the download links; pr/commit builds pass an empty value and are never published.
  // Read before the versions: it decides whether a missing previous version is fatal.
  const channelName = Deno.env.get("GNOSISVPN_CHANNEL") || "snapshot";
  if (!["stable", "snapshot", "experimental"].includes(channelName)) {
    console.error(`Error: Unsupported channel: ${channelName}`);
    console.error("Supported channels: stable, snapshot, experimental");
    Deno.exit(1);
  }
  const channel = channelName as Channel;

  const previousPackageVersion = readPreviousVersion("GNOSISVPN_PREVIOUS_PACKAGE_VERSION", "Installer", channel);

  const currentPackageVersion = Deno.env.get("GNOSISVPN_PACKAGE_VERSION");
  if (!currentPackageVersion) {
    console.error("Error: GNOSISVPN_PACKAGE_VERSION is required");
    Deno.exit(1);
  }

  const previousCliVersion = readPreviousVersion("GNOSISVPN_PREVIOUS_CLIENT_VERSION", "Client", channel);

  const currentCliVersion = Deno.env.get("GNOSISVPN_CLIENT_VERSION");
  if (!currentCliVersion) {
    console.error("Error: GNOSISVPN_CLIENT_VERSION is required");
    Deno.exit(1);
  }

  const previousAppVersion = readPreviousVersion("GNOSISVPN_PREVIOUS_APP_VERSION", "App", channel);

  const currentAppVersion = Deno.env.get("GNOSISVPN_APP_VERSION");
  if (!currentAppVersion) {
    console.error("Error: GNOSISVPN_APP_VERSION is required");
    Deno.exit(1);
  }

  const previousToolkitVersion = readPreviousVersion("GNOSISVPN_PREVIOUS_TOOLKIT_VERSION", "Toolkit", channel);

  const currentToolkitVersion = Deno.env.get("GNOSISVPN_TOOLKIT_VERSION");
  if (!currentToolkitVersion) {
    console.error("Error: GNOSISVPN_TOOLKIT_VERSION is required");
    Deno.exit(1);
  }

  // Which line's branch the client and app PRs come from follows the versions being built,
  // so a v4 build reads the v4 branch and a v5 build reads main without any caller saying so.
  const boundary = Deno.env.get("COMPONENT_VERSION_BOUNDARY");
  if (!boundary) {
    console.error("Error: COMPONENT_VERSION_BOUNDARY is required");
    console.error("It is defined in scripts/config.sh; export it or pass it from the build's step outputs.");
    Deno.exit(1);
  }

  const v4Branch = Deno.env.get("COMPONENT_V4_BRANCH");
  if (!v4Branch) {
    console.error("Error: COMPONENT_V4_BRANCH is required");
    console.error("It is defined in scripts/config.sh; export it or pass it from the build's step outputs.");
    Deno.exit(1);
  }

  const clientBranch = componentBranch(currentCliVersion, boundary, v4Branch);
  const appBranch = componentBranch(currentAppVersion, boundary, v4Branch);

  const format = Deno.env.get("GNOSISVPN_CHANGELOG_FORMAT") || "github";
  if (!["zulip", "github", "debian", "json", "rpm"].includes(format)) {
    console.error(`Error: Unsupported format: ${format}`);
    console.error("Supported formats: zulip, github, debian, json, rpm");
    Deno.exit(1);
  }

  return {
    repositories: [
      {
        repo: "gnosis/gnosis_vpn",
        label: "Installer",
        branch: Deno.env.get("GNOSISVPN_PACKAGE_BRANCH") || "main",
        previousVersion: previousPackageVersion,
        currentVersion: currentPackageVersion,
        allowMissingRelease: true, // Allow missing release for installer since it may not be created yet
      },
      {
        repo: "gnosis/gnosis_vpn-client",
        label: "Client",
        branch: clientBranch,
        previousVersion: previousCliVersion,
        currentVersion: currentCliVersion,
        allowMissingRelease: false,
      },
      {
        repo: "gnosis/gnosis_vpn-app",
        label: "App",
        branch: appBranch,
        previousVersion: previousAppVersion,
        currentVersion: currentAppVersion,
        allowMissingRelease: false,
      },
      {
        repo: "gnosis/gnosis_vpn-toolkit",
        label: "Toolkit",
        // Shared by both lines, so it has no release branch to split off.
        branch: "main",
        previousVersion: previousToolkitVersion,
        currentVersion: currentToolkitVersion,
        allowMissingRelease: false,
      },
    ],
    format: format as Config["format"],
    channel,
    ghApiMaxAttempts: parseInt(Deno.env.get("GH_API_MAX_ATTEMPTS") || "6", 10),
    ghToken,
  };
}

// --- Main ---

async function main(): Promise<void> {
  const config = readConfig();

  console.error("Generating release notes...");
  for (const { label, previousVersion, currentVersion, branch } of config.repositories) {
    console.error(`  ${label}: ${previousVersion ?? "(none)"} -> ${currentVersion} (base: ${branch})`);
  }
  console.error(`  Format: ${config.format}`);
  console.error("");

  // Fetch PRs from all repositories
  const allEntries: ChangelogEntry[] = [];

  for (const { repo, label, branch, previousVersion, currentVersion, allowMissingRelease } of config.repositories) {
    if (previousVersion === null) {
      log("INFO", `${label}: no previous version on this line, skipping its PR range`);
      continue;
    }
    if (previousVersion === currentVersion) continue;

    const previousDate = await getVersionDate(config, repo, previousVersion, false);
    const currentDate = await getVersionDate(config, repo, currentVersion, allowMissingRelease);
    log("INFO", `${label} date range: ${previousDate} to ${currentDate}`);

    const entries = await fetchMergedPRs(config, repo, previousDate, currentDate, label, branch);
    allEntries.push(...entries);
  }

  console.error("");
  console.error(`Fetched ${allEntries.length} PRs total`);
  console.error("");

  // Generate changelog content
  let content: string;
  const cliRepo = config.repositories.find((r) => r.label === "Client")!;
  const appRepo = config.repositories.find((r) => r.label === "App")!;
  const packageRepo = config.repositories.find((r) => r.label === "Installer")!;
  const toolkitRepo = config.repositories.find((r) => r.label === "Toolkit")!;
  switch (config.format) {
    case "zulip":
      content = zulipFormat(
        allEntries,
        packageRepo.currentVersion,
        cliRepo.currentVersion,
        appRepo.currentVersion,
        toolkitRepo.currentVersion,
        config.channel,
      );
      break;
    case "github":
      content = githubFormat(
        allEntries,
        cliRepo.previousVersion,
        cliRepo.currentVersion,
        appRepo.previousVersion,
        appRepo.currentVersion,
        toolkitRepo.previousVersion,
        toolkitRepo.currentVersion,
      );
      break;
    case "debian":
      content = debianFormat(allEntries, packageRepo.currentVersion);
      break;
    case "json":
      content = jsonFormat(allEntries);
      break;
    case "rpm":
      content = rpmFormat(allEntries, packageRepo.currentVersion);
      break;
  }

  // Write changelog files
  await writeChangelog(content);

  // Display the generated notes (to stdout, matching bash behavior)
  console.log("==========================================");
  console.log(content);
  console.log("==========================================");
  console.log("Changelog saved to ./build/changelog/changelog");
  console.log("Compressed changelog saved to ./build/changelog/changelog.gz");
}

if (import.meta.main) {
  await main();
}
