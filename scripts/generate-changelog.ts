#!/usr/bin/env -S deno run --allow-env --allow-net=api.github.com --allow-read --allow-write=./build

// Generate Release Notes
//
// This script generates comprehensive release notes by aggregating changes from:
// - gnosis_vpn-client repository (merged PRs between dates)
// - gnosis_vpn-app repository (merged PRs between dates)
// - gnosis_vpn Installer repository (merged PRs since last release)
//
// Example:
//   GNOSISVPN_PACKAGE_VERSION=0.56.5 \
//   GNOSISVPN_PREVIOUS_CLI_VERSION=0.54.4 \
//   GNOSISVPN_CLI_VERSION=0.56.1 \
//   GNOSISVPN_PREVIOUS_APP_VERSION=0.5.0 \
//   GNOSISVPN_APP_VERSION=0.6.1 \
//   GNOSISVPN_CHANGELOG_FORMAT=github \
//   GH_TOKEN=... \
//   ./scripts/generate-changelog.ts

// --- Types ---

interface Config {
  packageVersion: string;
  previousCliVersion: string;
  currentCliVersion: string;
  previousAppVersion: string;
  currentAppVersion: string;
  format: "github" | "debian" | "json" | "rpm";
  branch: string;
  ghApiMaxAttempts: number;
  ghToken: string;
}

export interface ChangelogEntry {
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

  const iso8601Regex =
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
  if (!iso8601Regex.test(dateString)) return false;

  const parsed = Date.parse(dateString);
  if (isNaN(parsed)) return false;

  return true;
}

// --- GitHub API Client ---

async function ghApiCall(
  config: Config,
  repo: string,
  endpoint: string,
): Promise<unknown> {
  let attempt = 1;
  let delay = 2000;

  while (attempt <= config.ghApiMaxAttempts) {
    log("DEBUG", `GitHub API call attempt ${attempt}/${config.ghApiMaxAttempts}: /repos/${repo}${endpoint}`);

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
            log("ERROR", `GitHub API throttled after ${config.ghApiMaxAttempts} attempts. Rate limit exceeded.`);
            log("ERROR", `Endpoint: /repos/${repo}${endpoint}`);
            log("ERROR", `Last error: ${body}`);
            Deno.exit(1);
          }
          log("WARN", `GitHub API throttled (attempt ${attempt}/${config.ghApiMaxAttempts}). Retrying in ${delay / 1000}s...`);
          await new Promise((resolve) => setTimeout(resolve, delay));
          delay *= 2;
          attempt++;
          continue;
        }
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

  log("ERROR", `GitHub API call failed after ${config.ghApiMaxAttempts} attempts`);
  Deno.exit(1);
}

// --- Release Date Fetcher ---

async function getReleaseDate(
  config: Config,
  repo: string,
  tag: string,
): Promise<string> {
  log("DEBUG", `Fetching release date for ${repo}/${tag}`);
  const release = (await ghApiCall(config, repo, `/releases/tags/${tag}`)) as GitHubRelease;
  const date = release.created_at;

  if (!validateIso8601Date(date)) {
    log("ERROR", `Invalid or empty release date for ${repo}/${tag}: '${date}'`);
    log("ERROR", "Expected ISO8601 timestamp format (e.g., 2024-01-15T10:30:00Z)");
    Deno.exit(1);
  }

  return date;
}

// --- Last Release Tag ---

async function getLastReleaseTag(config: Config): Promise<string | null> {
  log("DEBUG", "Fetching last release tag for gnosis/gnosis_vpn");
  try {
    const releases = (await ghApiCall(
      config,
      "gnosis/gnosis_vpn",
      "/releases?per_page=1",
    )) as GitHubRelease[];
    if (releases.length === 0) return null;
    return releases[0].tag_name;
  } catch {
    log("WARN", "Could not fetch release list");
    return null;
  }
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

  log("INFO", `Fetching PRs for ${component} (branch: ${branch}) between ${startDate} and ${endDate}...`);

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
    const mergedDate = pr.merged_at.split("T")[0] || new Date().toISOString().split("T")[0];
    const changelogType = extractChangelogType(pr.title);

    log("DEBUG", `Processing PR: id=${pr.number}, title=${pr.title}, author=${pr.user.login}, labels=${labels}, merged_at=${mergedDate}, type=${changelogType}, component=${component}`);

    entries.push({
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

export function githubFormat(
  entries: ChangelogEntry[],
  previousCliVersion: string,
  currentCliVersion: string,
  previousAppVersion: string,
  currentAppVersion: string,
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
    const line = `- [${entry.component}] ${entry.title} by @${entry.author} in #${entry.id}`;
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

  if (previousCliVersion !== currentCliVersion || previousAppVersion !== currentAppVersion) {
    content += "\nThis release contains the following component updates:\n\n";
    if (previousCliVersion !== currentCliVersion) {
      content += `- **[GnosisVPN Client](https://github.com/gnosis/gnosis_vpn-client)**: Updated from [v${previousCliVersion}](https://github.com/gnosis/gnosis_vpn-client/releases/tag/v${previousCliVersion}) to [v${currentCliVersion}](https://github.com/gnosis/gnosis_vpn-client/releases/tag/v${currentCliVersion})\n`;
    }
    if (previousAppVersion !== currentAppVersion) {
      content += `- **[GnosisVPN App](https://github.com/gnosis/gnosis_vpn-app)**: Updated from [v${previousAppVersion}](https://github.com/gnosis/gnosis_vpn-app/releases/tag/v${previousAppVersion}) to [v${currentAppVersion}](https://github.com/gnosis/gnosis_vpn-app/releases/tag/v${currentAppVersion})\n`;
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
    const entryLine = `  * ${entry.title} by @${entry.author} in #${entry.id}\n`;

    if (entryLine.length <= 80) {
      changelog += entryLine;
    } else {
      // Truncate title to fit within 80 characters
      // (entryLine.length - title.length) = overhead
      // Subtract 3 for the "..." that will be appended
      let maxTitleLength = 80 - (entryLine.length - entry.title.length) - 3;
      if (maxTitleLength < 1) maxTitleLength = 1;
      const truncatedTitle = entry.title.substring(0, maxTitleLength);
      changelog += `  * ${truncatedTitle}... by @${entry.author} in #${entry.id}\n`;
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

function readConfig(): Config {
  const ghToken = Deno.env.get("GH_TOKEN");
  if (!ghToken) {
    console.error("Error: GH_TOKEN is required");
    Deno.exit(1);
  }

  const previousCliVersion = Deno.env.get("GNOSISVPN_PREVIOUS_CLI_VERSION");
  if (!previousCliVersion) {
    console.error("Error: GNOSISVPN_PREVIOUS_CLI_VERSION is required");
    Deno.exit(1);
  }

  const currentCliVersion = Deno.env.get("GNOSISVPN_CLI_VERSION");
  if (!currentCliVersion) {
    console.error("Error: GNOSISVPN_CLI_VERSION is required");
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

  const format = Deno.env.get("GNOSISVPN_CHANGELOG_FORMAT") || "github";
  if (!["github", "debian", "json", "rpm"].includes(format)) {
    console.error(`Error: Unsupported format: ${format}`);
    console.error("Supported formats: github, debian, json, rpm");
    Deno.exit(1);
  }

  const now = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  const defaultVersion = `${now.getFullYear()}.${pad(now.getMonth() + 1)}.${pad(now.getDate())}+build.${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;

  return {
    packageVersion: Deno.env.get("GNOSISVPN_PACKAGE_VERSION") || defaultVersion,
    previousCliVersion,
    currentCliVersion,
    previousAppVersion,
    currentAppVersion,
    format: format as Config["format"],
    branch: Deno.env.get("GNOSISVPN_BRANCH") || "main",
    ghApiMaxAttempts: parseInt(Deno.env.get("GH_API_MAX_ATTEMPTS") || "6", 10),
    ghToken,
  };
}

// --- Main ---

async function main(): Promise<void> {
  const config = readConfig();

  console.error("Generating release notes...");
  console.error(`  Package version: v${config.packageVersion}`);
  console.error(`  Client: v${config.previousCliVersion} -> v${config.currentCliVersion}`);
  console.error(`  App: v${config.previousAppVersion} -> v${config.currentAppVersion}`);
  console.error(`  Format: ${config.format}`);
  console.error(`  Branch: ${config.branch}`);
  console.error("");

  let cliPreviousDate = "";
  let cliCurrentDate = "";
  let appPreviousDate = "";
  let appCurrentDate = "";

  // Fetch CLI dates if versions differ
  if (config.previousCliVersion !== config.currentCliVersion) {
    cliPreviousDate = await getReleaseDate(config, "gnosis/gnosis_vpn-client", `v${config.previousCliVersion}`);
    cliCurrentDate = await getReleaseDate(config, "gnosis/gnosis_vpn-client", `v${config.currentCliVersion}`);
    log("INFO", `CLI date range: ${cliPreviousDate} to ${cliCurrentDate}`);
  }

  // Fetch App dates if versions differ
  if (config.previousAppVersion !== config.currentAppVersion) {
    appPreviousDate = await getReleaseDate(config, "gnosis/gnosis_vpn-app", `v${config.previousAppVersion}`);
    appCurrentDate = await getReleaseDate(config, "gnosis/gnosis_vpn-app", `v${config.currentAppVersion}`);
    log("INFO", `App date range: ${appPreviousDate} to ${appCurrentDate}`);
  }

  // Get the last release tag for packaging repo
  const lastReleaseTag = await getLastReleaseTag(config);
  let pkgLastReleaseDate = "";

  if (lastReleaseTag) {
    pkgLastReleaseDate = await getReleaseDate(config, "gnosis/gnosis_vpn", lastReleaseTag);
    const pkgCurrentDate = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    log("INFO", `Installer date range: ${pkgLastReleaseDate} to ${pkgCurrentDate}`);
  }

  console.error("");

  // Fetch PRs from all repositories
  const allEntries: ChangelogEntry[] = [];

  if (cliPreviousDate && cliCurrentDate) {
    const entries = await fetchMergedPRs(config, "gnosis/gnosis_vpn-client", cliPreviousDate, cliCurrentDate, "Client", config.branch);
    allEntries.push(...entries);
  }

  if (appPreviousDate && appCurrentDate) {
    const entries = await fetchMergedPRs(config, "gnosis/gnosis_vpn-app", appPreviousDate, appCurrentDate, "App", config.branch);
    allEntries.push(...entries);
  }

  if (pkgLastReleaseDate) {
    const pkgCurrentDate = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    const entries = await fetchMergedPRs(config, "gnosis/gnosis_vpn", pkgLastReleaseDate, pkgCurrentDate, "Installer", config.branch);
    allEntries.push(...entries);
  }

  console.error("");
  console.error(`Fetched ${allEntries.length} PRs total`);
  console.error("");

  // Generate changelog content
  let content: string;
  switch (config.format) {
    case "github":
      content = githubFormat(
        allEntries,
        config.previousCliVersion,
        config.currentCliVersion,
        config.previousAppVersion,
        config.currentAppVersion,
      );
      break;
    case "debian":
      content = debianFormat(allEntries, config.packageVersion);
      break;
    case "json":
      content = jsonFormat(allEntries);
      break;
    case "rpm":
      content = rpmFormat(allEntries, config.packageVersion);
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

// Only run main when executed directly (not when imported for testing)
if (import.meta.main) {
  await main();
}
