import { assertEquals } from "@std/assert";
import {
  type ChangelogEntry,
  debianFormat,
  extractChangelogType,
  getReleaseType,
  getUrgencyLevel,
  githubFormat,
  jsonFormat,
  readConfig,
  rfc2822Date,
  rpmFormat,
  validateIso8601Date,
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

function withConfigEnv(env: Record<string, string>, fn: () => void): void {
  const keys = [
    ...Object.keys(BASE_CONFIG_ENV),
    "GNOSISVPN_CHANGELOG_FORMAT",
    "GNOSISVPN_PACKAGE_BRANCH",
  ];
  const saved = keys.map((key) => [key, Deno.env.get(key)] as const);
  try {
    for (const key of keys) Deno.env.delete(key);
    for (const [key, value] of Object.entries({ ...BASE_CONFIG_ENV, ...env })) {
      Deno.env.set(key, value);
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
