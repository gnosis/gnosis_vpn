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

interface ChangelogEntry {
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

function validateIso8601Date(dateString: string): boolean {
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

function extractChangelogType(title: string): string {
  if (!title.includes(":")) return "other";
  const prefix = title.split(":")[0].split("(")[0].trim().toLowerCase();
  return prefix || "other";
}

// --- Format Functions ---

function githubFormat(
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

function getReleaseType(
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

function getUrgencyLevel(version: string): string {
  const parts = version.split(".");
  const patchPart = parts[2] || "0";
  const patchNumber = parseInt(patchPart.split("-")[0], 10);

  if (version.includes("-rc.") || patchNumber === 0) {
    return "optional";
  }
  return "medium";
}

function rfc2822Date(date: Date): string {
  return date.toUTCString().replace("GMT", "+0000");
}

function debianFormat(
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

function jsonFormat(entries: ChangelogEntry[]): string {
  return JSON.stringify(entries);
}

function rpmFormat(
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

// --- Tests ---

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

function makeEntry(overrides: Partial<ChangelogEntry> = {}): ChangelogEntry {
  return {
    id: overrides.id ?? "1",
    title: overrides.title ?? "test title",
    author: overrides.author ?? "testuser",
    labels: overrides.labels ?? "",
    state: overrides.state ?? "closed",
    date: overrides.date ?? "2024-01-15",
    changelog_type: overrides.changelog_type ?? "other",
    component: overrides.component ?? "Client",
  };
}

// --- validateIso8601Date ---

Deno.test("validateIso8601Date - valid timestamps", () => {
  assertEquals(validateIso8601Date("2024-01-15T10:30:00Z"), true);
  assertEquals(validateIso8601Date("2024-12-31T23:59:59Z"), true);
  assertEquals(validateIso8601Date("2024-01-01T00:00:00+00:00"), true);
  assertEquals(validateIso8601Date("2024-06-15T12:00:00-05:00"), true);
});

Deno.test("validateIso8601Date - fractional seconds", () => {
  assertEquals(validateIso8601Date("2024-01-15T10:30:00.000Z"), true);
  assertEquals(validateIso8601Date("2024-01-15T10:30:00.123456Z"), true);
  assertEquals(validateIso8601Date("2024-01-15T10:30:00.1Z"), true);
});

Deno.test("validateIso8601Date - invalid strings", () => {
  assertEquals(validateIso8601Date(""), false);
  assertEquals(validateIso8601Date("not-a-date"), false);
  assertEquals(validateIso8601Date("2024-01-15"), false);
  assertEquals(validateIso8601Date("2024-01-15T10:30:00"), false);
  assertEquals(validateIso8601Date("Jan 15, 2024"), false);
});

// --- extractChangelogType ---

Deno.test("extractChangelogType - conventional commit titles", () => {
  assertEquals(extractChangelogType("feat: add new button"), "feat");
  assertEquals(extractChangelogType("fix(auth): resolve login issue"), "fix");
  assertEquals(extractChangelogType("refactor: clean up code"), "refactor");
  assertEquals(extractChangelogType("ci: update pipeline"), "ci");
  assertEquals(extractChangelogType("docs: update readme"), "docs");
  assertEquals(extractChangelogType("chore(deps): bump version"), "chore");
});

Deno.test("extractChangelogType - no colon defaults to other", () => {
  assertEquals(extractChangelogType("update readme file"), "other");
  assertEquals(extractChangelogType("bump version"), "other");
});

Deno.test("extractChangelogType - edge cases", () => {
  assertEquals(extractChangelogType("FEAT: uppercase type"), "feat");
  assertEquals(extractChangelogType("Fix: capitalized type"), "fix");
  assertEquals(extractChangelogType(": empty prefix"), "other");
});

// --- getReleaseType ---

Deno.test("getReleaseType - stable release", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({ labels: "enhancement" }),
  ];
  assertEquals(getReleaseType(entries, "1.2.3"), "stable");
});

Deno.test("getReleaseType - unstable due to rc version", () => {
  assertEquals(getReleaseType([], "1.2.0-rc.1"), "unstable");
});

Deno.test("getReleaseType - unstable due to x.y.0 version", () => {
  assertEquals(getReleaseType([], "1.2.0"), "unstable");
});

Deno.test("getReleaseType - unstable due to breaking label", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({ labels: "breaking" }),
  ];
  assertEquals(getReleaseType(entries, "1.2.3"), "unstable");
});

Deno.test("getReleaseType - unstable due to experimental label", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({ labels: "experimental" }),
  ];
  assertEquals(getReleaseType(entries, "1.2.3"), "unstable");
});

// --- getUrgencyLevel ---

Deno.test("getUrgencyLevel - optional for rc versions", () => {
  assertEquals(getUrgencyLevel("1.2.0-rc.1"), "optional");
});

Deno.test("getUrgencyLevel - optional for x.y.0 versions", () => {
  assertEquals(getUrgencyLevel("1.2.0"), "optional");
});

Deno.test("getUrgencyLevel - medium for stable patches", () => {
  assertEquals(getUrgencyLevel("1.2.3"), "medium");
  assertEquals(getUrgencyLevel("0.5.1"), "medium");
});

// --- githubFormat ---

Deno.test("githubFormat - produces expected markdown sections", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({ changelog_type: "feat", title: "add login", component: "Client", id: "1", author: "alice" }),
    makeEntry({ changelog_type: "fix", title: "fix crash", component: "App", id: "2", author: "bob" }),
    makeEntry({ changelog_type: "refactor", title: "clean up utils", component: "Installer", id: "3", author: "charlie" }),
    makeEntry({ changelog_type: "ci", title: "update CI", component: "Client", id: "4", author: "dave" }),
    makeEntry({ changelog_type: "docs", title: "update docs", component: "Client", id: "5", author: "eve" }),
    makeEntry({ changelog_type: "other", title: "misc change", component: "App", id: "6", author: "frank" }),
  ];

  const result = githubFormat(entries, "0.54.4", "0.56.1", "0.5.0", "0.6.1");

  assertEquals(result.includes("## What's Changed"), true);
  assertEquals(result.includes("### New Features"), true);
  assertEquals(result.includes("### Fixes"), true);
  assertEquals(result.includes("### Refactor"), true);
  assertEquals(result.includes("### Automation"), true);
  assertEquals(result.includes("### Documentation"), true);
  assertEquals(result.includes("### Other"), true);
  assertEquals(result.includes("[Client] add login by @alice in #1"), true);
  assertEquals(result.includes("[App] fix crash by @bob in #2"), true);
  assertEquals(result.includes("GnosisVPN Client"), true);
  assertEquals(result.includes("GnosisVPN App"), true);
});

Deno.test("githubFormat - no component updates when versions match", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({ changelog_type: "feat", title: "something" }),
  ];
  const result = githubFormat(entries, "1.0.0", "1.0.0", "1.0.0", "1.0.0");
  assertEquals(result.includes("component updates"), false);
});

// --- debianFormat ---

Deno.test("debianFormat - line truncation at 80 chars", () => {
  const longTitle = "a".repeat(200);
  const entries: ChangelogEntry[] = [
    makeEntry({ title: longTitle, author: "dev", id: "99" }),
  ];
  const result = debianFormat(entries, "1.2.3");
  const lines = result.split("\n");
  for (const line of lines) {
    if (line.startsWith("  * ")) {
      assertEquals(line.length <= 80, true, `Line exceeds 80 chars: "${line}" (${line.length})`);
    }
  }
});

Deno.test("debianFormat - contains RFC 2822 date", () => {
  const entries: ChangelogEntry[] = [makeEntry({})];
  const result = debianFormat(entries, "1.2.3");
  assertEquals(result.includes("+0000"), true);
});

Deno.test("debianFormat - contains version and distribution", () => {
  const entries: ChangelogEntry[] = [makeEntry({})];
  const result = debianFormat(entries, "1.2.3");
  assertEquals(result.includes("gnosisvpn (1.2.3)"), true);
  assertEquals(result.includes("urgency=medium"), true);
  assertEquals(result.includes("stable"), true);
});

// --- rpmFormat ---

Deno.test("rpmFormat - grouping by date and author", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({ date: "2024-01-15", author: "alice", title: "feat(ui): first change", changelog_type: "feat", component: "Client", id: "1" }),
    makeEntry({ date: "2024-01-15", author: "alice", title: "fix(core): second change", changelog_type: "fix", component: "Client", id: "2" }),
    makeEntry({ date: "2024-01-14", author: "bob", title: "refactor(api): third change", changelog_type: "refactor", component: "App", id: "3" }),
  ];

  const result = rpmFormat(entries, "1.2.3");

  const headerLines = result.split("\n").filter((l) => l.startsWith("* "));
  assertEquals(headerLines.length, 2);

  const entryLines = result.split("\n").filter((l) => l.startsWith("- "));
  assertEquals(entryLines.length, 3);
});

Deno.test("rpmFormat - title prefix stripping", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({ title: "feat(ui): add button", changelog_type: "feat", component: "Client", id: "10" }),
  ];
  const result = rpmFormat(entries, "1.0.0");
  assertEquals(result.includes("add button in #10"), true);
  assertEquals(result.includes("feat(ui): add button"), false);
});

// --- jsonFormat ---

Deno.test("jsonFormat - round-trips through JSON.parse", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({ id: "1", title: "test", author: "alice" }),
    makeEntry({ id: "2", title: "test2", author: "bob" }),
  ];
  const result = jsonFormat(entries);
  const parsed = JSON.parse(result);
  assertEquals(Array.isArray(parsed), true);
  assertEquals(parsed.length, 2);
  assertEquals(parsed[0].id, "1");
  assertEquals(parsed[1].author, "bob");
});

// --- rfc2822Date ---

Deno.test("rfc2822Date - formats with +0000 not GMT", () => {
  const date = new Date("2024-01-15T10:30:00Z");
  const result = rfc2822Date(date);
  assertEquals(result.includes("+0000"), true);
  assertEquals(result.includes("GMT"), false);
  assertEquals(result.includes("Mon, 15 Jan 2024"), true);
});
