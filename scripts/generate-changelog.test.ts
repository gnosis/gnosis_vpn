import { assertEquals } from "@std/assert";
import {
  type ChangelogEntry,
  collectChangelogEntries,
  COMPONENT_V4_BRANCH,
  COMPONENT_VERSION_BOUNDARY,
  componentBranch,
  type Config,
  debianFormat,
  extractChangelogType,
  getReleaseType,
  getUrgencyLevel,
  githubFormat,
  jsonFormat,
  parseBackport,
  readConfig,
  rfc2822Date,
  rpmFormat,
  validateIso8601Date,
  versionCore,
  versionCoreLt,
  zulipFormat,
} from "./generate-changelog.ts";

function makeEntry(overrides: Partial<ChangelogEntry> = {}): ChangelogEntry {
  return {
    repository: overrides.repository ?? "gnosis/gnosis_vpn",
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

// --- zulipFormat ---

Deno.test("zulipFormat formats snapshot entries and download links", () => {
  const output = zulipFormat(
    [
      {
        id: "123",
        title: "fix(cli): improve login flow",
        author: "octocat",
        repository: "gnosis/gnosis_vpn-client",
        component: "cli",
      } as ChangelogEntry,
    ],
    "2026.05.14+build.143052",
    "0.56.1",
    "0.6.1",
    "1.2.3",
  );

  if (
    !output.includes("A new snapshot build is available for testing with the following new content:\n\n")
  ) {
    throw new Error("zulipFormat output is missing the snapshot intro");
  }

  if (
    !output.includes(
      "**Snapshot version:** 2026.05.14+build.143052\n**Client version:** 0.56.1, **App version:** 0.6.1, **Toolkit version:** 1.2.3\n\n- [#123]",
    )
  ) {
    throw new Error("zulipFormat output is missing the version block above the listed changes");
  }

  if (
    !output.includes(
      "- [#123](https://github.com/gnosis/gnosis_vpn-client/pull/123) [cli] fix(cli): improve login flow by octocat\n",
    )
  ) {
    throw new Error("zulipFormat output is missing the expected PR line");
  }

  if (
    !output.includes(
      "[Mac](https://download.gnosisvpn.io/macos/latest/gnosisvpn_2026.05.14-build.143052_arm64.pkg)",
    )
  ) {
    throw new Error("zulipFormat output is missing the versioned Mac download link");
  }

  if (
    !output.includes(
      "[Debian x86_64](https://download.gnosisvpn.io/linux/apt/pool/snapshot/g/gnosisvpn/gnosisvpn_2026.05.14+build.143052_amd64.deb)",
    )
  ) {
    throw new Error("zulipFormat output is missing the Debian x86_64 apt-pool link");
  }

  if (
    !output.includes(
      "[Debian aarch64](https://download.gnosisvpn.io/linux/apt/pool/snapshot/g/gnosisvpn/gnosisvpn_2026.05.14+build.143052_arm64.deb)",
    )
  ) {
    throw new Error("zulipFormat output is missing the Debian aarch64 apt-pool link");
  }
});

Deno.test("zulipFormat formats experimental builds with experimental paths", () => {
  const output = zulipFormat(
    [
      {
        id: "42",
        title: "feat(pix): add strategy",
        author: "octocat",
        repository: "gnosis/gnosis_vpn-client",
        component: "cli",
      } as ChangelogEntry,
    ],
    "2026.09.09+build.020000.experimental",
    "0.100.1",
    "0.100.0",
    "1.2.3",
    "experimental",
  );

  if (
    !output.includes("A new experimental build is available for testing with the following new content:\n\n")
  ) {
    throw new Error("zulipFormat output is missing the experimental intro");
  }

  if (!output.includes("**Experimental version:** 2026.09.09+build.020000.experimental\n")) {
    throw new Error("zulipFormat output is missing the experimental version label");
  }

  if (
    !output.includes(
      "[Mac](https://download.gnosisvpn.io/macos/experimental/gnosisvpn_2026.09.09-build.020000.experimental_arm64.pkg)",
    )
  ) {
    throw new Error("zulipFormat output is missing the experimental Mac download link");
  }

  if (
    !output.includes(
      "[Debian x86_64](https://download.gnosisvpn.io/linux/apt/pool/experimental/g/gnosisvpn/gnosisvpn_2026.09.09+build.020000.experimental_amd64.deb)",
    )
  ) {
    throw new Error("zulipFormat output is missing the experimental Debian x86_64 apt-pool link");
  }

  if (output.includes("pool/snapshot") || output.includes("macos/latest")) {
    throw new Error("zulipFormat leaked snapshot paths into an experimental build");
  }
});

Deno.test("zulipFormat defaults to the snapshot channel", () => {
  const withDefault = zulipFormat([], "2026.05.14+build.143052", "0.56.1", "0.6.1", "1.2.3");
  const withExplicit = zulipFormat(
    [],
    "2026.05.14+build.143052",
    "0.56.1",
    "0.6.1",
    "1.2.3",
    "snapshot",
  );
  assertEquals(withDefault, withExplicit);
});

// --- githubFormat ---

Deno.test("githubFormat - produces expected markdown sections", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({
      changelog_type: "feat",
      title: "add login",
      component: "Client",
      id: "1",
      author: "alice",
    }),
    makeEntry({
      changelog_type: "fix",
      title: "fix crash",
      component: "App",
      id: "2",
      author: "bob",
    }),
    makeEntry({
      changelog_type: "refactor",
      title: "clean up utils",
      component: "Installer",
      id: "3",
      author: "charlie",
    }),
    makeEntry({
      changelog_type: "ci",
      title: "update CI",
      component: "Client",
      id: "4",
      author: "dave",
    }),
    makeEntry({
      changelog_type: "docs",
      title: "update docs",
      component: "Client",
      id: "5",
      author: "eve",
    }),
    makeEntry({
      changelog_type: "other",
      title: "misc change",
      component: "App",
      id: "6",
      author: "frank",
    }),
  ];

  const result = githubFormat(entries, "0.54.4", "0.56.1", "0.5.0", "0.6.1", "1.2.3", "1.4.2");

  assertEquals(result.includes("## What's Changed"), true);
  assertEquals(result.includes("### New Features"), true);
  assertEquals(result.includes("### Fixes"), true);
  assertEquals(result.includes("### Refactor"), true);
  assertEquals(result.includes("### Automation"), true);
  assertEquals(result.includes("### Documentation"), true);
  assertEquals(result.includes("### Other"), true);
  assertEquals(
    result.includes(
      "[Client] add login by @alice in [gnosis/gnosis_vpn#1](https://github.com/gnosis/gnosis_vpn/pull/1)",
    ),
    true,
  );
  assertEquals(
    result.includes("[App] fix crash by @bob in [gnosis/gnosis_vpn#2](https://github.com/gnosis/gnosis_vpn/pull/2)"),
    true,
  );
  assertEquals(result.includes("GnosisVPN Client"), true);
  assertEquals(result.includes("GnosisVPN App"), true);
  assertEquals(
    result.includes(
      "- **[GnosisVPN Toolkit](https://github.com/gnosis/gnosis_vpn-toolkit)**: Updated from [v1.2.3](https://github.com/gnosis/gnosis_vpn-toolkit/releases/tag/v1.2.3) to [v1.4.2](https://github.com/gnosis/gnosis_vpn-toolkit/releases/tag/v1.4.2)",
    ),
    true,
  );
});

Deno.test("githubFormat - toolkit-only update renders component updates", () => {
  const result = githubFormat([], "1.0.0", "1.0.0", "1.0.0", "1.0.0", "1.2.3", "1.4.2");
  assertEquals(result.includes("component updates"), true);
  assertEquals(
    result.includes(
      "- **[GnosisVPN Toolkit](https://github.com/gnosis/gnosis_vpn-toolkit)**: Updated from [v1.2.3](https://github.com/gnosis/gnosis_vpn-toolkit/releases/tag/v1.2.3) to [v1.4.2](https://github.com/gnosis/gnosis_vpn-toolkit/releases/tag/v1.4.2)",
    ),
    true,
  );
});

Deno.test("githubFormat - no component updates when versions match", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({ changelog_type: "feat", title: "something" }),
  ];
  const result = githubFormat(entries, "1.0.0", "1.0.0", "1.0.0", "1.0.0", "1.4.2", "1.4.2");
  assertEquals(result.includes("component updates"), false);
});

Deno.test("githubFormat - v-prefix format flip is not a component update", () => {
  const result = githubFormat([], "1.0.0", "v1.0.0", "v1.0.0", "1.0.0", "1.4.2", "v1.4.2");
  assertEquals(result.includes("component updates"), false);
});

Deno.test("githubFormat - v-prefixed versions render a single v", () => {
  const result = githubFormat([], "1.0.0", "1.0.0", "1.0.0", "1.0.0", "v1.2.3", "v1.4.2");
  assertEquals(
    result.includes(
      "- **[GnosisVPN Toolkit](https://github.com/gnosis/gnosis_vpn-toolkit)**: Updated from [v1.2.3](https://github.com/gnosis/gnosis_vpn-toolkit/releases/tag/v1.2.3) to [v1.4.2](https://github.com/gnosis/gnosis_vpn-toolkit/releases/tag/v1.4.2)",
    ),
    true,
  );
  assertEquals(result.includes("vv"), false);
});

Deno.test("githubFormat - a missing previous version renders no component update", () => {
  // The experimental line before its first build: nothing to compare against.
  const result = githubFormat([], null, "0.100.1", null, "0.100.0", null, "1.4.2");
  assertEquals(result.includes("component updates"), false);
  // vTag(null) would have produced "[v](.../releases/tag/v)".
  assertEquals(result.includes("releases/tag/v)"), false);
  assertEquals(result.includes("[v]"), false);
});

Deno.test("githubFormat - a missing previous version does not hide the other components", () => {
  const result = githubFormat([], null, "0.100.1", "1.0.0", "1.0.0", "1.2.3", "1.4.2");
  assertEquals(result.includes("component updates"), true);
  assertEquals(result.includes("GnosisVPN Toolkit"), true);
  assertEquals(result.includes("GnosisVPN Client"), false);
  assertEquals(result.includes("GnosisVPN App"), false);
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
      assertEquals(
        line.length <= 80,
        true,
        `Line exceeds 80 chars: "${line}" (${line.length})`,
      );
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

Deno.test("debianFormat - a stanza with no entries carries a placeholder change line", () => {
  const result = debianFormat([], "1.2.3");
  assertEquals(result.includes("  * No recorded changes since the previous build."), true);
});

// --- rpmFormat ---

Deno.test("rpmFormat - grouping by date and author", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({
      date: "2024-01-15",
      author: "alice",
      title: "feat(ui): first change",
      changelog_type: "feat",
      component: "Client",
      id: "1",
    }),
    makeEntry({
      date: "2024-01-15",
      author: "alice",
      title: "fix(core): second change",
      changelog_type: "fix",
      component: "Client",
      id: "2",
    }),
    makeEntry({
      date: "2024-01-14",
      author: "bob",
      title: "refactor(api): third change",
      changelog_type: "refactor",
      component: "App",
      id: "3",
    }),
  ];

  const result = rpmFormat(entries, "1.2.3");

  const headerLines = result.split("\n").filter((l) => l.startsWith("* "));
  assertEquals(headerLines.length, 2);

  const entryLines = result.split("\n").filter((l) => l.startsWith("- "));
  assertEquals(entryLines.length, 3);
});

Deno.test("rpmFormat - title prefix stripping", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({
      title: "feat(ui): add button",
      changelog_type: "feat",
      component: "Client",
      id: "10",
    }),
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

// --- versionCore / versionCoreLt / componentBranch ---

Deno.test("versionCore - strips a leading v and build metadata", () => {
  assertEquals(versionCore("0.96.2"), [0, 96, 2]);
  assertEquals(versionCore("v0.96.2"), [0, 96, 2]);
  assertEquals(versionCore("0.96.2+pr.638"), [0, 96, 2]);
  assertEquals(versionCore("0.101.0+commit.abc1234"), [0, 101, 0]);
});

Deno.test("versionCore - rejects versions with no numeric core", () => {
  assertEquals(versionCore("0.96"), null);
  assertEquals(versionCore("0.96.2-rc.1"), null);
  assertEquals(versionCore(""), null);
});

Deno.test("versionCore - a date-based version reads as an ordinary core", () => {
  // Only package versions look like this; reading as a huge version keeps them off the v4 line anyway.
  assertEquals(versionCore("2026.09.17+build.120000"), [2026, 9, 17]);
});

Deno.test("versionCoreLt - compares numerically, not lexically", () => {
  // The whole split hinges on this: "0.96.2" sorts after "0.100.0" as a string.
  assertEquals(versionCoreLt("0.96.2", "0.100.0"), true);
  assertEquals(versionCoreLt("0.100.0", "0.100.0"), false);
  assertEquals(versionCoreLt("0.101.3", "0.100.0"), false);
  assertEquals(versionCoreLt("0.99.99", "0.100.0"), true);
});

Deno.test("versionCoreLt - an unparseable version is not below the boundary", () => {
  assertEquals(versionCoreLt("2026.09.17+build.120000", "0.100.0"), false);
  assertEquals(versionCoreLt("0.96.2", "not-a-version"), false);
});

Deno.test("componentBranch - v4 versions read the v4 branch, v5 versions read main", () => {
  assertEquals(componentBranch("0.96.2"), "release/hoprdv4");
  assertEquals(componentBranch("0.35.5"), "release/hoprdv4");
  assertEquals(componentBranch("0.100.0"), "main");
  assertEquals(componentBranch("0.101.0"), "main");
});

Deno.test("componentBranch - registry build metadata does not change the line", () => {
  assertEquals(componentBranch("0.96.2+pr.638"), "release/hoprdv4");
  assertEquals(componentBranch("v0.101.0+commit.abc1234"), "main");
});

Deno.test("componentBranch - a version with no numeric core falls back to main", () => {
  assertEquals(componentBranch(""), "main");
});

Deno.test("the line split matches config/channels.sh", () => {
  // The build resolves versions with config/channels.sh; a boundary moved there must move here too.
  const configSh = Deno.readTextFileSync(new URL("../config/channels.sh", import.meta.url));
  const boundary = configSh.match(/^COMPONENT_VERSION_BOUNDARY="([^"]+)"$/m)?.[1];
  assertEquals(boundary, COMPONENT_VERSION_BOUNDARY);
  assertEquals(COMPONENT_V4_BRANCH, "release/hoprdv4");
});

// --- parseBackport ---

Deno.test("parseBackport - the generated prefix form carries the original title", () => {
  const result = parseBackport(
    "[Backport release/hoprdv4] fix(connection): make SURB ramping configurable (GNO-780)",
    "# Description\nBackport of #810 to `release/hoprdv4`.",
  );
  assertEquals(result?.title, "fix(connection): make SURB ramping configurable (GNO-780)");
  assertEquals(result?.sourceNumber, 810);
});

Deno.test("parseBackport - the numbered form carries only the source PR", () => {
  const result = parseBackport("Backport 793 to release/hoprdv4", null);
  assertEquals(result?.title, null);
  assertEquals(result?.sourceNumber, 793);
});

Deno.test("parseBackport - a prefixed title without a resolvable body keeps its title", () => {
  const result = parseBackport("[Backport release/hoprdv4] feat(ui): improve light theme", null);
  assertEquals(result?.title, "feat(ui): improve light theme");
  assertEquals(result?.sourceNumber, null);
});

Deno.test("parseBackport - ordinary PRs are not backports", () => {
  assertEquals(parseBackport("fix: backport of the 0.101 ui changes", null), null);
  assertEquals(parseBackport("feat(ui): improve light theme", "Backport of #123"), null);
});

Deno.test("extractChangelogType - a resolved backport title classifies as its own type", () => {
  const generated = "[Backport release/hoprdv4] fix(core): report reconnecting state";
  // The generated prefix yields a type githubFormat has no section for, which is what filed backports under "Other".
  assertEquals(extractChangelogType(generated), "[backport release/hoprdv4] fix");
  assertEquals(extractChangelogType(parseBackport(generated, null)!.title!), "fix");
});

// --- readConfig ---

const BASE_CONFIG_ENV: Record<string, string> = {
  GH_TOKEN: "test-token",
  GNOSISVPN_PREVIOUS_PACKAGE_VERSION: "0.56.4",
  GNOSISVPN_PACKAGE_VERSION: "0.56.5",
  GNOSISVPN_PREVIOUS_CLIENT_VERSION: "0.54.4",
  GNOSISVPN_CLIENT_VERSION: "0.56.1",
  GNOSISVPN_PREVIOUS_APP_VERSION: "0.5.0",
  GNOSISVPN_APP_VERSION: "0.6.1",
  GNOSISVPN_PREVIOUS_TOOLKIT_VERSION: "1.2.2",
  GNOSISVPN_TOOLKIT_VERSION: "1.2.3",
};

// A null value means "leave the variable unset"; an empty string is what GitHub Actions
// actually passes for a repository variable that was never written.
function withConfigEnv(env: Record<string, string | null>, fn: () => void): void {
  const keys = [
    ...Object.keys(BASE_CONFIG_ENV),
    "GNOSISVPN_CHANGELOG_FORMAT",
    "GNOSISVPN_PACKAGE_BRANCH",
    "GNOSISVPN_CHANNEL",
  ];
  const saved = keys.map((key) => [key, Deno.env.get(key)] as const);
  try {
    for (const key of keys) Deno.env.delete(key);
    for (const [key, value] of Object.entries({ ...BASE_CONFIG_ENV, ...env })) {
      if (value === null) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
    fn();
  } finally {
    for (const [key, value] of saved) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
}

Deno.test("readConfig - includes toolkit repository", () => {
  withConfigEnv({}, () => {
    const toolkit = readConfig().repositories.find((r) => r.label === "Toolkit");
    assertEquals(toolkit?.repo, "gnosis/gnosis_vpn-toolkit");
    assertEquals(toolkit?.previousVersion, "1.2.2");
    assertEquals(toolkit?.currentVersion, "1.2.3");
    assertEquals(toolkit?.branch, "main");
  });
});

Deno.test("readConfig - channel defaults to snapshot", () => {
  withConfigEnv({}, () => {
    assertEquals(readConfig().channel, "snapshot");
  });
});

Deno.test("readConfig - reads the experimental channel", () => {
  withConfigEnv({ GNOSISVPN_CHANNEL: "experimental" }, () => {
    assertEquals(readConfig().channel, "experimental");
  });
});

Deno.test("readConfig - an empty channel falls back to snapshot", () => {
  // pr/commit builds pass GNOSISVPN_CHANNEL="" since they are never published.
  withConfigEnv({ GNOSISVPN_CHANNEL: "" }, () => {
    assertEquals(readConfig().channel, "snapshot");
  });
});

Deno.test("readConfig - an empty previous version means no previous build", () => {
  // A repository variable that was never written arrives as an empty string, not as unset.
  withConfigEnv({ GNOSISVPN_PREVIOUS_CLIENT_VERSION: "", GNOSISVPN_CHANNEL: "experimental" }, () => {
    const repositories = readConfig().repositories;
    assertEquals(repositories.find((r) => r.label === "Client")?.previousVersion, null);
    assertEquals(repositories.find((r) => r.label === "Toolkit")?.previousVersion, "1.2.2");
  });
});

Deno.test("readConfig - an unset previous version means no previous build", () => {
  withConfigEnv({ GNOSISVPN_PREVIOUS_CLIENT_VERSION: null, GNOSISVPN_CHANNEL: "experimental" }, () => {
    assertEquals(readConfig().repositories.find((r) => r.label === "Client")?.previousVersion, null);
  });
});

Deno.test("readConfig - all four previous versions may be missing", () => {
  // The first build of a new release line, before update_experimental has written its variables.
  withConfigEnv({
    GNOSISVPN_PREVIOUS_PACKAGE_VERSION: "",
    GNOSISVPN_PREVIOUS_CLIENT_VERSION: "",
    GNOSISVPN_PREVIOUS_APP_VERSION: "",
    GNOSISVPN_PREVIOUS_TOOLKIT_VERSION: "",
    GNOSISVPN_CHANNEL: "experimental",
  }, () => {
    for (const repo of readConfig().repositories) {
      assertEquals(repo.previousVersion, null);
    }
  });
});

Deno.test("readConfig - a missing previous version is tolerated on the snapshot channel", () => {
  withConfigEnv({ GNOSISVPN_PREVIOUS_APP_VERSION: "" }, () => {
    assertEquals(readConfig().repositories.find((r) => r.label === "App")?.previousVersion, null);
  });
});

Deno.test("readConfig - a v4 client and app read their release branch", () => {
  withConfigEnv({ GNOSISVPN_CLIENT_VERSION: "0.96.2", GNOSISVPN_APP_VERSION: "0.35.5" }, () => {
    const repositories = readConfig().repositories;
    assertEquals(repositories.find((r) => r.label === "Client")?.branch, "release/hoprdv4");
    assertEquals(repositories.find((r) => r.label === "App")?.branch, "release/hoprdv4");
    assertEquals(repositories.find((r) => r.label === "Toolkit")?.branch, "main");
  });
});

Deno.test("readConfig - a v5 client and app read main", () => {
  withConfigEnv({ GNOSISVPN_CLIENT_VERSION: "0.101.0", GNOSISVPN_APP_VERSION: "0.100.3" }, () => {
    const repositories = readConfig().repositories;
    assertEquals(repositories.find((r) => r.label === "Client")?.branch, "main");
    assertEquals(repositories.find((r) => r.label === "App")?.branch, "main");
  });
});

Deno.test("readConfig - the two components are placed independently", () => {
  // Nothing forbids a build pairing a v5 client with an app that has not crossed yet.
  withConfigEnv({ GNOSISVPN_CLIENT_VERSION: "0.101.0", GNOSISVPN_APP_VERSION: "0.35.5" }, () => {
    const repositories = readConfig().repositories;
    assertEquals(repositories.find((r) => r.label === "Client")?.branch, "main");
    assertEquals(repositories.find((r) => r.label === "App")?.branch, "release/hoprdv4");
  });
});

async function withFetchMock(
  handler: (url: string) => Response,
  fn: (urls: string[]) => Promise<void>,
): Promise<void> {
  const originalFetch = globalThis.fetch;
  const urls: string[] = [];
  globalThis.fetch = ((input: RequestInfo | URL) => {
    const url = input instanceof Request ? input.url : String(input);
    urls.push(url);
    return Promise.resolve(handler(url));
  }) as typeof fetch;

  try {
    await fn(urls);
  } finally {
    globalThis.fetch = originalFetch;
  }
}

Deno.test("snapshot changelog includes a PR merged into the version PR's release branch", async () => {
  const config: Config = {
    repositories: [{
      repo: "gnosis/gnosis_vpn-client",
      label: "Client",
      branch: "main",
      previousVersion: "0.96.1+pr.800",
      currentVersion: "0.96.1+pr.801",
      allowMissingRelease: false,
    }],
    format: "zulip",
    channel: "snapshot",
    ghApiMaxAttempts: 1,
    ghToken: "test-token",
  };

  const originalConsoleError = console.error;
  console.error = () => {};
  try {
    await withFetchMock((url) => {
      if (url.endsWith("/pulls/800")) {
        return Response.json({ merged_at: "2026-09-14T15:00:00Z" });
      }
      if (url.endsWith("/pulls/801")) {
        return Response.json({
          merged_at: "2026-09-14T17:06:54Z",
          base: { ref: "release/hoprdv4" },
        });
      }
      if (url.includes("/pulls?")) {
        return Response.json([{
          number: 801,
          title: "chore(deps): bump edgli + hopr-lib to v4-line HEAD (reply-opener LRU fix)",
          state: "closed",
          merged_at: "2026-09-14T17:06:54Z",
          user: { login: "Teebor-Choka" },
          labels: [],
        }]);
      }
      throw new Error(`Unexpected GitHub API request: ${url}`);
    }, async (urls) => {
      const entries = await collectChangelogEntries(config);

      assertEquals(urls.some((url) => url.includes("base=release/hoprdv4")), true);
      assertEquals(entries.map((entry) => entry.id), ["801"]);

      const announcement = zulipFormat(
        entries,
        "2026.09.14+build.180352",
        "0.96.1+pr.801",
        "0.0.0",
        "0.0.0",
      );
      assertEquals(announcement.includes("[#801](https://github.com/gnosis/gnosis_vpn-client/pull/801)"), true);
    });
  } finally {
    console.error = originalConsoleError;
  }
});
