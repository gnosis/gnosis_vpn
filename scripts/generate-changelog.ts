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

// --- Types ---

interface RepoConfig {
  repo: string;
  label: string;
  // PR `base=` filter. Defaults to "main"; the installer repo is overridable
  // via GNOSISVPN_PACKAGE_BRANCH so close-release on a release branch only includes
  // installer PRs that targeted that branch.
  branch: string;
  previousVersion: string;
  currentVersion: string;
  allowMissingRelease: boolean;
}

export interface Config {
  repositories: RepoConfig[];
  format: "zulip" | "github" | "debian" | "json" | "rpm";
  ghApiMaxAttempts: number;
  ghToken: string;
}

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
    const changelogType = extractChangelogType(pr.title);

    log(
      "DEBUG",
      `Processing PR: id=${pr.number}, title=${pr.title}, author=${pr.user.login}, labels=${labels}, merged_at=${mergedDate}, type=${changelogType}, component=${component}`,
    );

    entries.push({
      repository: repoName,
      id: String(pr.number),
      title: pr.title,
      author: pr.user.login,
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
): string {
  let content = "A new snapshot build is available for testing with the following new content:\n\n";

  content += `**Snapshot version:** ${packageVersion}\n`;
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
  // Debian .debs live in the snapshot APT pool under their versioned filenames
  // (gnosisvpn_<version>_<arch>.deb); the version is the literal padded value
  // emitted by the build (see linux/nfpm-template.yaml version_schema: none).
  const debPool = "https://download.gnosisvpn.io/linux/apt/pool/snapshot/g/gnosisvpn";
  content += ` [Mac](https://download.gnosisvpn.io/macos/latest/gnosisvpn_${macFileSlug}_arm64.pkg) |`;
  content += ` [Debian x86_64](${debPool}/gnosisvpn_${packageVersion}_amd64.deb) |`;
  content += ` [Debian aarch64](${debPool}/gnosisvpn_${packageVersion}_arm64.deb)\n`;
  return content;
}

export function githubFormat(
  entries: ChangelogEntry[],
  previousCliVersion: string,
  currentCliVersion: string,
  previousAppVersion: string,
  currentAppVersion: string,
  previousToolkitVersion: string,
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
  // stored previous-version variables doesn't report a component update.
  const cliUpdated = vTag(previousCliVersion) !== vTag(currentCliVersion);
  const appUpdated = vTag(previousAppVersion) !== vTag(currentAppVersion);
  const toolkitUpdated = vTag(previousToolkitVersion) !== vTag(currentToolkitVersion);

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

export function readConfig(): Config {
  const ghToken = Deno.env.get("GH_TOKEN");
  if (!ghToken) {
    console.error("Error: GH_TOKEN is required");
    Deno.exit(1);
  }

  const previousPackageVersion = Deno.env.get("GNOSISVPN_PREVIOUS_PACKAGE_VERSION");
  if (!previousPackageVersion) {
    console.error("Error: GNOSISVPN_PREVIOUS_PACKAGE_VERSION is required");
    Deno.exit(1);
  }

  const currentPackageVersion = Deno.env.get("GNOSISVPN_PACKAGE_VERSION");
  if (!currentPackageVersion) {
    console.error("Error: GNOSISVPN_PACKAGE_VERSION is required");
    Deno.exit(1);
  }

  const previousCliVersion = Deno.env.get("GNOSISVPN_PREVIOUS_CLIENT_VERSION");
  if (!previousCliVersion) {
    console.error("Error: GNOSISVPN_PREVIOUS_CLIENT_VERSION is required");
    Deno.exit(1);
  }

  const currentCliVersion = Deno.env.get("GNOSISVPN_CLIENT_VERSION");
  if (!currentCliVersion) {
    console.error("Error: GNOSISVPN_CLIENT_VERSION is required");
    Deno.exit(1);
  }

  const previousAppVersion = Deno.env.get("GNOSISVPN_PREVIOUS_APP_VERSION");
  if (!previousAppVersion) {
    console.error("Error: GNOSISVPN_PREVIOUS_APP_VERSION is required");
    Deno.exit(1);
  }

  const currentAppVersion = Deno.env.get("GNOSISVPN_APP_VERSION");
  if (!currentAppVersion) {
    console.error("Error: GNOSISVPN_APP_VERSION is required");
    Deno.exit(1);
  }

  const previousToolkitVersion = Deno.env.get("GNOSISVPN_PREVIOUS_TOOLKIT_VERSION");
  if (!previousToolkitVersion) {
    console.error("Error: GNOSISVPN_PREVIOUS_TOOLKIT_VERSION is required");
    Deno.exit(1);
  }

  const currentToolkitVersion = Deno.env.get("GNOSISVPN_TOOLKIT_VERSION");
  if (!currentToolkitVersion) {
    console.error("Error: GNOSISVPN_TOOLKIT_VERSION is required");
    Deno.exit(1);
  }

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
        branch: "main",
        previousVersion: previousCliVersion,
        currentVersion: currentCliVersion,
        allowMissingRelease: false,
      },
      {
        repo: "gnosis/gnosis_vpn-app",
        label: "App",
        branch: "main",
        previousVersion: previousAppVersion,
        currentVersion: currentAppVersion,
        allowMissingRelease: false,
      },
      {
        repo: "gnosis/gnosis_vpn-toolkit",
        label: "Toolkit",
        branch: "main",
        previousVersion: previousToolkitVersion,
        currentVersion: currentToolkitVersion,
        allowMissingRelease: false,
      },
    ],
    format: format as Config["format"],
    ghApiMaxAttempts: parseInt(Deno.env.get("GH_API_MAX_ATTEMPTS") || "6", 10),
    ghToken,
  };
}

// --- Main ---

async function main(): Promise<void> {
  const config = readConfig();

  console.error("Generating release notes...");
  for (const { label, previousVersion, currentVersion, branch } of config.repositories) {
    console.error(`  ${label}: ${previousVersion} -> ${currentVersion} (base: ${branch})`);
  }
  console.error(`  Format: ${config.format}`);
  console.error("");

  // Fetch PRs from all repositories
  const allEntries: ChangelogEntry[] = [];

  for (const { repo, label, branch, previousVersion, currentVersion, allowMissingRelease } of config.repositories) {
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
