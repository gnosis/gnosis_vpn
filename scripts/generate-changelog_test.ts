import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  type ChangelogEntry,
  debianFormat,
  extractChangelogType,
  getReleaseType,
  getUrgencyLevel,
  githubFormat,
  jsonFormat,
  rfc2822Date,
  rpmFormat,
  validateIso8601Date,
} from "./generate-changelog.ts";

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
  // Each content line (not header/footer) should be <= 80 chars
  for (const line of lines) {
    if (line.startsWith("  * ")) {
      assertEquals(line.length <= 80, true, `Line exceeds 80 chars: "${line}" (${line.length})`);
    }
  }
});

Deno.test("debianFormat - contains RFC 2822 date", () => {
  const entries: ChangelogEntry[] = [makeEntry({})];
  const result = debianFormat(entries, "1.2.3");
  // RFC 2822 date ends with +0000
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

  // Should have 2 header lines (grouped by date+author)
  const headerLines = result.split("\n").filter((l) => l.startsWith("* "));
  assertEquals(headerLines.length, 2);

  // Should have 3 entry lines
  const entryLines = result.split("\n").filter((l) => l.startsWith("- "));
  assertEquals(entryLines.length, 3);
});

Deno.test("rpmFormat - title prefix stripping", () => {
  const entries: ChangelogEntry[] = [
    makeEntry({ title: "feat(ui): add button", changelog_type: "feat", component: "Client", id: "10" }),
  ];
  const result = rpmFormat(entries, "1.0.0");
  assertEquals(result.includes("add button in #10"), true);
  // Should not contain the original prefix
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

// --- Helper ---

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
