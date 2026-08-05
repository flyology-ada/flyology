#!/usr/bin/env node

import {
  lstat,
  mkdir,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, join, normalize, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import {
  requireConsistentRunMetadata,
  validateRunMetadata,
} from "./websocket-run-provenance.mjs";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const inputRoot = resolve(process.argv[2] || join(projectRoot, "build/autobahn"));
const outputRoot = resolve(
  process.argv[3] || join(projectRoot, "website/reports/websocket")
);
const expectedOutput = resolve(projectRoot, "website/reports/websocket");

const fromExpectedOutput = relative(expectedOutput, outputRoot);
if (
  fromExpectedOutput === ".." ||
  fromExpectedOutput.startsWith(".." + sep)
) {
  console.error(`refusing output outside WebSocket reports: ${outputRoot}`);
  process.exit(2);
}

const profiles = [
  {
    slug: "core-lightweight",
    title: "Core, lightweight task",
    lane: "Lightweight task",
    comparisonLabel: "Lightweight / ws",
    kind: "core",
    invocationProfile: "core",
    invocationLane: "lightweight",
    config: "tests/autobahn/fuzzingclient.json",
    transportMode: "plain",
    transport: "Plain ws://",
    scope: "RFC-focused",
    summary:
      "The framing profile through a lightweight task on a shared event loop.",
  },
  {
    slug: "core-native",
    title: "Core, native task",
    lane: "Native task",
    comparisonLabel: "Native / ws",
    kind: "core",
    invocationProfile: "core",
    invocationLane: "native",
    config: "tests/autobahn/fuzzingclient-native.json",
    transportMode: "plain",
    transport: "Plain ws://",
    scope: "RFC-focused",
    summary:
      "The same framing profile through an ordinary native Ada task.",
  },
  {
    slug: "core-lightweight-wss",
    title: "Core over WSS, lightweight task",
    lane: "Lightweight task",
    comparisonLabel: "Lightweight / wss",
    kind: "core-tls",
    invocationProfile: "core-wss",
    invocationLane: "lightweight",
    config: "tests/autobahn/fuzzingclient-wss.json",
    transportMode: "tls",
    transport: "WSS",
    scope: "RFC-focused over TLS",
    summary:
      "The framing profile after a nonblocking OpenSSL server handshake.",
  },
  {
    slug: "core-native-wss",
    title: "Core over WSS, native task",
    lane: "Native task",
    comparisonLabel: "Native / wss",
    kind: "core-tls",
    invocationProfile: "core-wss",
    invocationLane: "native",
    config: "tests/autobahn/fuzzingclient-wss-native.json",
    transportMode: "tls",
    transport: "WSS",
    scope: "RFC-focused over TLS",
    summary:
      "The same secure framing profile through an ordinary native task.",
  },
  {
    slug: "limits-lightweight",
    title: "Limits, lightweight task",
    lane: "Lightweight task",
    kind: "limits",
    invocationProfile: "limits",
    invocationLane: "lightweight",
    config: "tests/autobahn/fuzzingclient-limits.json",
    transportMode: "plain",
    transport: "Plain ws://",
    scope: "Section 9.1–9.6 limits",
    summary:
      "Boundary probes with the adapter explicitly configured for 16 MiB.",
  },
  {
    slug: "limits-native",
    title: "Limits, native task",
    lane: "Native task",
    kind: "limits",
    invocationProfile: "limits",
    invocationLane: "native",
    config: "tests/autobahn/fuzzingclient-limits-native.json",
    transportMode: "plain",
    transport: "Plain ws://",
    scope: "Section 9.1–9.6 limits",
    summary:
      "The same configured message-boundary profile through a native task.",
  },
  {
    slug: "compression-lightweight",
    title: "Compression, lightweight task",
    lane: "Lightweight task",
    comparisonLabel: "Lightweight / deflate",
    kind: "compression",
    invocationProfile: "compression",
    invocationLane: "lightweight",
    config: "tests/autobahn/fuzzingclient-compression.json",
    transportMode: "plain",
    transport: "Plain ws:// with permessage-deflate",
    scope: "RFC 7692 sections 12–13",
    summary:
      "Compressed messages and extension negotiation through a lightweight task.",
  },
  {
    slug: "compression-native",
    title: "Compression, native task",
    lane: "Native task",
    comparisonLabel: "Native / deflate",
    kind: "compression",
    invocationProfile: "compression",
    invocationLane: "native",
    config: "tests/autobahn/fuzzingclient-compression-native.json",
    transportMode: "plain",
    transport: "Plain ws:// with permessage-deflate",
    scope: "RFC 7692 sections 12–13",
    summary:
      "The same compression and negotiation profile through a native task.",
  },
  {
    slug: "compression-lightweight-wss",
    title: "Compression over WSS, lightweight task",
    lane: "Lightweight task",
    comparisonLabel: "Lightweight / wss",
    kind: "compression",
    invocationProfile: "compression-wss",
    invocationLane: "lightweight",
    config: "tests/autobahn/fuzzingclient-compression-wss.json",
    transportMode: "tls",
    transport: "WSS with permessage-deflate",
    scope: "RFC 7692 sections 12–13 over TLS",
    summary:
      "The compression profile after a nonblocking OpenSSL server handshake.",
  },
  {
    slug: "compression-native-wss",
    title: "Compression over WSS, native task",
    lane: "Native task",
    comparisonLabel: "Native / wss",
    kind: "compression",
    invocationProfile: "compression-wss",
    invocationLane: "native",
    config: "tests/autobahn/fuzzingclient-compression-wss-native.json",
    transportMode: "tls",
    transport: "WSS with permessage-deflate",
    scope: "RFC 7692 sections 12–13 over TLS",
    summary:
      "The same secure compression profile through an ordinary native task.",
  },
  {
    slug: "performance-lightweight",
    title: "Performance, lightweight task",
    lane: "Lightweight task",
    comparisonLabel: "Lightweight / ws",
    kind: "performance",
    invocationProfile: "performance",
    invocationLane: "lightweight",
    config: "tests/autobahn/fuzzingclient-performance.json",
    transportMode: "plain",
    transport: "Plain ws://",
    scope: "Section 9.7–9.8 timing",
    summary:
      "Twelve sequential echo timing probes across text and binary payloads.",
  },
  {
    slug: "performance-native",
    title: "Performance, native task",
    lane: "Native task",
    comparisonLabel: "Native / ws",
    kind: "performance",
    invocationProfile: "performance",
    invocationLane: "native",
    config: "tests/autobahn/fuzzingclient-performance-native.json",
    transportMode: "plain",
    transport: "Plain ws://",
    scope: "Section 9.7–9.8 timing",
    summary:
      "The same twelve sequential echo timing probes through a native task.",
  },
  {
    slug: "performance-lightweight-wss",
    title: "Performance over WSS, lightweight task",
    lane: "Lightweight task",
    comparisonLabel: "Lightweight / wss",
    kind: "performance",
    invocationProfile: "performance-wss",
    invocationLane: "lightweight",
    config: "tests/autobahn/fuzzingclient-performance-wss.json",
    transportMode: "tls",
    transport: "WSS",
    scope: "Section 9.7–9.8 timing over TLS",
    summary:
      "The timing probes after a nonblocking OpenSSL server handshake.",
  },
  {
    slug: "performance-native-wss",
    title: "Performance over WSS, native task",
    lane: "Native task",
    comparisonLabel: "Native / wss",
    kind: "performance",
    invocationProfile: "performance-wss",
    invocationLane: "native",
    config: "tests/autobahn/fuzzingclient-performance-wss-native.json",
    transportMode: "tls",
    transport: "WSS",
    scope: "Section 9.7–9.8 timing over TLS",
    summary:
      "The same secure timing profile through an ordinary native task.",
  },
];

function requireEqual(actual, expected, context) {
  if (actual !== expected) {
    throw new Error(
      `${context}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
    );
  }
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function plainText(value) {
  return String(value ?? "")
    .replace(/<br\s*\/?\s*>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", '"')
    .replaceAll("&#39;", "'")
    .replace(/\r/g, "")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function richText(value) {
  return escapeHTML(plainText(value)).replace(/\n/g, "<br>");
}

function shortDescription(value) {
  const text = plainText(value).split("\n", 1)[0];
  return text.length <= 150 ? text : text.slice(0, 147).trimEnd() + "…";
}

function compareCaseIds(left, right) {
  const a = left.id.split(".").map(Number);
  const b = right.id.split(".").map(Number);
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const difference = (a[index] ?? -1) - (b[index] ?? -1);
    if (difference !== 0) return difference;
  }
  return 0;
}

function statusKey(value) {
  return String(value || "UNKNOWN").toLowerCase().replace(/[^a-z]+/g, "-");
}

function statusLabel(value) {
  return {
    OK: "OK",
    "NON-STRICT": "Non-strict",
    INFORMATIONAL: "Informational",
    FAILED: "Failed",
  }[value] || value;
}

function countStatuses(cases) {
  const counts = { OK: 0, "NON-STRICT": 0, INFORMATIONAL: 0, FAILED: 0 };
  for (const item of cases) counts[item.behavior] = (counts[item.behavior] || 0) + 1;
  return counts;
}

const acceptedVerdicts = new Set(["OK", "NON-STRICT", "INFORMATIONAL"]);

function requirePassingVerdicts(profile, cases) {
  const failures = [];
  for (const item of cases) {
    if (!acceptedVerdicts.has(item.behavior)) {
      failures.push(`${item.id} behavior=${item.behavior || "MISSING"}`);
    }
    if (!acceptedVerdicts.has(item.behaviorClose)) {
      failures.push(
        `${item.id} behaviorClose=${item.behaviorClose || "MISSING"}`
      );
    }
  }
  if (failures.length) {
    throw new Error(
      `${profile.slug} contains failed Autobahn verdicts: ${failures.join(", ")}`
    );
  }
}

function performanceCase(item) {
  const match = plainText(item.description).match(
    /Send (\d+) (text|binary) messages of payload size (\d+)/i
  );
  if (!match) throw new Error(`cannot read performance metadata for case ${item.id}`);
  const roundTrips = Number(match[1]);
  const payloadBytes = Number(match[3]);
  const durationMs = Number(item.duration);
  return {
    id: item.id,
    kind: match[2].toLowerCase(),
    roundTrips,
    payloadBytes,
    durationMs,
    meanRoundTripMs: durationMs / roundTrips,
    roundTripsPerSecond: (roundTrips * 1000) / durationMs,
  };
}

function performanceData(profile) {
  const points = profile.cases.map(performanceCase);
  return {
    points,
    roundTrips: points.reduce((sum, point) => sum + point.roundTrips, 0),
    minimumMs: Math.min(...points.map((point) => point.durationMs)),
    maximumMs: Math.max(...points.map((point) => point.durationMs)),
  };
}

function closeCode(value) {
  return value === null || value === undefined ? "Not recorded" : String(value);
}

function reportDate(cases, runMetadata) {
  const capturedAt = runMetadata?.capturedAt;
  if (capturedAt) {
    const captured = new Date(capturedAt);
    return {
      iso: capturedAt.slice(0, 10),
      display: new Intl.DateTimeFormat("en", {
        day: "numeric",
        month: "long",
        year: "numeric",
        timeZone: "UTC",
      }).format(captured),
    };
  }
  const started = cases.map((item) => item.started).filter(Boolean).sort()[0];
  if (!started) return { iso: "2026-08-04", display: "4 August 2026" };
  const date = new Date(started);
  return {
    iso: date.toISOString().slice(0, 10),
    display: new Intl.DateTimeFormat("en", {
      day: "numeric",
      month: "long",
      year: "numeric",
      timeZone: "UTC",
    }).format(date),
  };
}

async function loadProfile(profile) {
  const directory = join(inputRoot, profile.slug);
  let runMetadata;
  try {
    runMetadata = JSON.parse(
      await readFile(join(directory, "run-metadata.json"), "utf8")
    );
  } catch (error) {
    throw new Error(
      `${profile.slug} lacks readable run-metadata.json: ${error.message}`
    );
  }
  validateRunMetadata(
    runMetadata,
    {
      name: profile.invocationProfile,
      lane: profile.invocationLane,
      report: profile.slug,
      config: profile.config,
      transport: profile.transportMode,
    },
    `${profile.slug} run metadata`
  );
  const files = (await readdir(directory)).filter((file) => /_case_.*\.json$/.test(file));
  const cases = [];
  for (const file of files) {
    const item = JSON.parse(await readFile(join(directory, file), "utf8"));
    if (!item.id || !item.behavior) throw new Error(`malformed Autobahn case: ${file}`);
    cases.push(item);
  }
  cases.sort(compareCaseIds);
  if (!cases.length) throw new Error(`no Autobahn cases found in ${directory}`);
  requirePassingVerdicts(profile, cases);
  const transport =
    runMetadata.transport === "tls"
      ? `WSS via ${runMetadata.tls.version}${
          profile.kind === "compression" ? " with permessage-deflate" : ""
        }`
      : profile.transport;
  const loaded = {
    ...profile,
    transport,
    cases,
    counts: countStatuses(cases),
    date: reportDate(cases, runMetadata),
    runMetadata,
  };
  if (profile.kind !== "performance") return loaded;
  return {
    ...loaded,
    performance: performanceData(loaded),
  };
}

function documentHead({ title, description, canonical, depth }) {
  const prefix = "../".repeat(depth);
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="${escapeHTML(description)}">
    <meta name="theme-color" content="#17213d">
    <title>${escapeHTML(title)} · Flyology</title>
    <link rel="canonical" href="${escapeHTML(canonical)}">
    <link rel="icon" href="${prefix}assets/brand/flyology-primary-icon.svg" type="image/svg+xml">
    <link rel="stylesheet" href="${prefix}assets/styles/site.css">
    <script src="${prefix}assets/scripts/ada-highlight.js"></script>
    <script src="${prefix}assets/scripts/site.js"></script>
  </head>`;
}

function siteHeader(depth) {
  const prefix = "../".repeat(depth);
  return `  <body>
    <a class="skip-link" href="#main">Skip to content</a>
    <header class="site-header">
      <nav class="site-nav" aria-label="Primary navigation">
        <a class="brand" href="${prefix}" aria-label="Flyology home">
          <img src="${prefix}assets/brand/flyology-mark-transparent.svg" alt="">
          <span>Flyology</span>
        </a>
        <ul class="nav-links" data-nav-links>
          <li><a href="${prefix}">Overview</a></li>
          <li><a href="${prefix}guide/">Guide</a></li>
          <li><a href="${prefix}architecture/">Architecture</a></li>
          <li><a href="${prefix}journal/" aria-current="page">Journal</a></li>
          <li><a href="${prefix}api/">API</a></li>
          <li>
            <details class="nav-dropdown" data-nav-dropdown>
              <summary>Ecosystem <svg aria-hidden="true" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5"><path d="m2.5 4.5 3.5 3 3.5-3"/></svg></summary>
              <ul class="nav-dropdown-menu"><li><a href="https://postgres.flyology.org/">Postgres</a></li></ul>
            </details>
          </li>
          <li><a href="https://github.com/flyology-ada/flyology">GitHub</a></li>
        </ul>
        <div class="nav-tools">
          <button class="icon-button" type="button" data-theme-toggle>
            <span class="visually-hidden" data-theme-label>Change theme</span>
            <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v2.2M12 18.8V21M3 12h2.2M18.8 12H21M5.64 5.64 7.2 7.2M16.8 16.8l1.56 1.56M18.36 5.64 16.8 7.2M7.2 16.8l-1.56 1.56"/><circle cx="12" cy="12" r="4"/></svg>
          </button>
          <button class="menu-button" type="button" data-menu-toggle aria-expanded="false" aria-label="Toggle navigation">
            <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 7h16M4 12h16M4 17h16"/></svg>
          </button>
        </div>
      </nav>
    </header>`;
}

function siteFooter(depth) {
  const prefix = "../".repeat(depth);
  return `    <footer class="site-footer">
      <div class="footer-inner">
        <span>Flyology is experimental. This dated report bundle records a bounded conformance campaign.</span>
        <div class="footer-links"><a href="${prefix}journal/">Journal</a><a href="${prefix}guide/http/">HTTP guide</a><a href="${prefix}architecture/">Architecture</a><a href="${prefix}api/">API reference</a></div>
      </div>
    </footer>
  </body>
</html>
`;
}

function statusLegend(counts) {
  return ["OK", "NON-STRICT", "INFORMATIONAL", "FAILED"]
    .filter((status) => counts[status])
    .map(
      (status) =>
        `<span class="report-status report-status-${statusKey(status)}"><strong>${counts[status]}</strong> ${statusLabel(status)}</span>`
    )
    .join("\n              ");
}

function compactStatus(counts) {
  return ["OK", "NON-STRICT", "INFORMATIONAL", "FAILED"]
    .filter((status) => counts[status])
    .map(
      (status) =>
        `<span class="is-${statusKey(status)}"><strong>${counts[status]}</strong> ${statusLabel(status)}</span>`
    )
    .join("");
}

function profileVariant(profile) {
  const secure = profile.transport.startsWith("WSS");
  return `            <a class="report-profile-variant" href="${profile.slug}/">
              <span class="report-variant-name"><strong>${escapeHTML(profile.lane)}</strong><span>${secure ? "WSS" : "WS"}</span></span>
              <span class="report-variant-status">${compactStatus(profile.counts)}</span>
              <span class="report-variant-total">${profile.cases.length} cases</span>
              <span class="report-variant-arrow" aria-hidden="true">→</span>
            </a>`;
}

function profileGroup(group, index) {
  return `        <section class="report-profile-group" aria-labelledby="profile-group-${group.key}">
          <header>
            <span class="report-profile-number">0${index + 1}</span>
            <div>
              <p>${escapeHTML(group.scope)}</p>
              <h3 id="profile-group-${group.key}">${escapeHTML(group.title)}</h3>
              <p>${escapeHTML(group.description)}</p>
            </div>
          </header>
          <div class="report-profile-variants">
${group.profiles.map(profileVariant).join("\n")}
          </div>
        </section>`;
}

function overallPage(loaded, provenance) {
  const date = loaded[0].date;
  const limits = loaded.find((profile) => profile.kind === "limits");
  const performanceProfiles = loaded.filter((profile) => profile.kind === "performance");
  const performanceCases = performanceProfiles.reduce(
    (sum, profile) => sum + profile.cases.length,
    0
  );
  const performanceRoundTrips = performanceProfiles.reduce(
    (sum, profile) => sum + profile.performance.roundTrips,
    0
  );
  const coreProfiles = loaded.filter((profile) =>
    profile.kind === "core" || profile.kind === "core-tls"
  );
  const compressionProfiles = loaded.filter(
    (profile) => profile.kind === "compression"
  );
  const compressionCases = compressionProfiles.reduce(
    (sum, profile) => sum + profile.cases.length,
    0
  );
  const profileGroups = [
    {
      key: "core",
      title: "Core framing",
      scope: "RFC 6455",
      description:
        "Framing, fragmentation, control frames, close handling, masking, lengths, and UTF-8 behavior.",
      profiles: coreProfiles,
    },
    {
      key: "limits",
      title: "Message limits",
      scope: "Sections 9.1–9.6",
      description:
        "Text, binary, fragmentation, and chopped delivery from 64 KiB through the configured 16 MiB maximum.",
      profiles: loaded.filter((profile) => profile.kind === "limits"),
    },
    {
      key: "compression",
      title: "Compression",
      scope: "RFC 7692 · Sections 12–13",
      description:
        "permessage-deflate negotiation and compressed messages across both task lanes and transports.",
      profiles: compressionProfiles,
    },
    {
      key: "performance",
      title: "Timing observations",
      scope: "Sections 9.7–9.8",
      description:
        "Release/-O3 loopback echo observations across six text and binary payload sizes.",
      profiles: performanceProfiles,
    },
  ];
  return `${documentHead({
    title: "WebSocket conformance",
    description: "Dated Autobahn framing, compression, limits, WSS, and timing results for Flyology WebSockets.",
    canonical: "https://flyology.org/reports/websocket/",
    depth: 2,
  })}
${siteHeader(2)}
    <main id="main" class="page-shell report-page">
      <header class="report-hero">
        <div>
          <ol class="breadcrumb" aria-label="Breadcrumb"><li><a href="../../">Flyology</a></li><li><a href="../../journal/">Journal</a></li><li aria-current="page">WebSocket conformance</li></ol>
          <p class="eyebrow">Protocol evidence · ${escapeHTML(date.display)}</p>
          <h1>WebSocket framing, case by case.</h1>
        </div>
        <div class="report-hero-copy">
          <p>Autobahn exercised the same public server API through both task lanes and through the OpenSSL-backed WSS transport. Separate runs cover configurable boundaries, RFC 7692 compression, and echo timings by lane and transport.</p>
          <dl class="report-run-meta">
            <div><dt>Suite</dt><dd>Autobahn ${escapeHTML(provenance.autobahn.suiteVersion)}</dd></div>
            <div><dt>Revision</dt><dd>${escapeHTML(provenance.source.revision.slice(0, 12))}</dd></div>
            <div><dt>Transport</dt><dd>ws:// + wss://</dd></div>
          </dl>
        </div>
      </header>

      <section class="report-finding" aria-labelledby="finding-title">
        <div>
          <p class="report-section-index">01 / RESULT</p>
          <h2 id="finding-title">No core framing failures in either lane or over TLS.</h2>
        </div>
        <div class="report-lane-comparison" aria-label="Core profile comparison">
          ${coreProfiles.map((profile) => `<div class="report-lane-row"><span>${escapeHTML(profile.comparisonLabel)}</span><span class="report-segments" aria-hidden="true"><i class="is-ok" style="--segment: ${profile.counts.OK}"></i><i class="is-non-strict" style="--segment: ${profile.counts["NON-STRICT"]}"></i><i class="is-informational" style="--segment: ${profile.counts.INFORMATIONAL}"></i></span><strong>${profile.cases.length} cases</strong></div>`).join("\n          ")}
          <div class="report-lane-legend">${statusLegend(loaded[0].counts)}</div>
        </div>
      </section>

      <section class="report-profiles" aria-labelledby="profiles-title">
        <div class="report-section-heading">
          <p class="report-section-index">02 / PROFILES</p>
          <h2 id="profiles-title">Four test families.</h2>
          <p>Choose a lane and transport within each family. Every variation retains its individual verdicts and normalized JSON.</p>
        </div>
${profileGroups.map(profileGroup).join("\n")}
      </section>

      <section class="report-compression" aria-labelledby="compression-title">
        <div>
          <p class="report-section-index">03 / COMPRESSION</p>
          <h2 id="compression-title">${compressionCases.toLocaleString("en-US")} compressed-message and negotiation cases.</h2>
        </div>
        <div>
          <p>Flyology explicitly opts into <code>permessage-deflate</code> with no context takeover in either direction. The pure-Ada decoder accepts stored, fixed-Huffman, and dynamic-Huffman DEFLATE blocks while enforcing the configured decompressed message limit.</p>
          <div class="report-lane-comparison" aria-label="Compression profile comparison">
            ${compressionProfiles.map((profile) => `<div class="report-lane-row"><span>${escapeHTML(profile.comparisonLabel || profile.lane)}</span><span class="report-segments" aria-hidden="true"><i class="is-ok" style="--segment: ${profile.counts.OK}"></i></span><strong>${profile.cases.length} cases</strong></div>`).join("\n            ")}
          </div>
        </div>
      </section>

      <section class="report-performance" aria-labelledby="performance-title">
        <div>
          <p class="report-section-index">04 / TIMING</p>
          <h2 id="performance-title">${performanceRoundTrips.toLocaleString("en-US")} sequential echoes across lanes and transports.</h2>
        </div>
        <div>
          <p>All ${performanceCases} section 9.7–9.8 timing probes passed. Every lane and transport variation completed 1,000 sequential round trips at each text and binary payload size from a recorded Alire release build with <code>-O3</code>.</p>
          <p>These loopback observations include case setup and close work. They are recorded for regression comparison, not as a portable throughput or latency claim.</p>
          <nav class="report-performance-links" aria-label="Performance profiles">
            ${performanceProfiles.map((profile) => `<a href="${profile.slug}/"><span>${escapeHTML(profile.comparisonLabel || profile.lane)}</span><strong>${profile.performance.minimumMs}–${profile.performance.maximumMs} ms</strong></a>`).join("\n            ")}
          </nav>
        </div>
      </section>

      <section class="report-boundary" aria-labelledby="boundary-title">
        <div>
          <p class="report-section-index">05 / BOUNDARY</p>
          <h2 id="boundary-title">The limit is application policy.</h2>
        </div>
        <div>
          <p>All ${limits.cases.length} boundary and chunking cases pass from 64 KiB through 16 MiB. The adapter explicitly selects the 16 MiB supported maximum; ordinary calls retain Flyology's 1 MiB default.</p>
          <p>Core framing, compression, and timing were repeated over <code>wss://</code> in both lanes. The message-limit campaign used loopback <code>ws://</code>.</p>
        </div>
      </section>
    </main>
${siteFooter(2)}`;
}

function caseRow(item) {
  const search = [item.id, item.behavior, plainText(item.description), plainText(item.expectation)]
    .join(" ")
    .toLowerCase();
  return `          <li class="report-case" data-case data-status="${statusKey(item.behavior)}" data-search="${escapeHTML(search)}">
            <details>
              <summary>
                <span class="report-case-id">${escapeHTML(item.id)}</span>
                <span class="report-case-title">${escapeHTML(shortDescription(item.description))}</span>
                <span class="report-verdict report-verdict-${statusKey(item.behavior)}">${escapeHTML(statusLabel(item.behavior))}</span>
                <span class="report-case-toggle" aria-hidden="true">+</span>
              </summary>
              <div class="report-case-detail">
                <div><h3>Expected</h3><p>${richText(item.expectation)}</p></div>
                <div><h3>Observed</h3><p>${richText(item.result)}</p><p>${richText(item.resultClose)}</p></div>
                <dl>
                  <div><dt>Remote close</dt><dd>${escapeHTML(closeCode(item.remoteCloseCode))}</dd></div>
                  <div><dt>Local close</dt><dd>${escapeHTML(closeCode(item.localCloseCode))}</dd></div>
                  <div><dt>Clean close</dt><dd>${item.wasClean ? "Yes" : "No"}</dd></div>
                  <div><dt>Duration</dt><dd>${escapeHTML(String(item.duration ?? 0))} ms</dd></div>
                </dl>
              </div>
            </details>
          </li>`;
}

function performanceSummary(profile) {
  if (profile.kind !== "performance") return "";
  const environment = profile.runMetadata.environment;
  const toolchain = profile.runMetadata.toolchain;
  const maximum = profile.performance.maximumMs;
  const rows = profile.performance.points
    .map((point) => {
      const width = Math.max(3, (point.durationMs / maximum) * 100).toFixed(2);
      return `              <tr>
                <th scope="row">${escapeHTML(point.id)}</th>
                <td>${escapeHTML(point.kind)}</td>
                <td>${point.payloadBytes.toLocaleString("en-US")} B</td>
                <td><span class="report-duration"><i style="--duration: ${width}%"></i><strong>${point.durationMs} ms</strong></span></td>
                <td>${point.meanRoundTripMs.toFixed(3)} ms</td>
                <td>${Math.round(point.roundTripsPerSecond).toLocaleString("en-US")}/s</td>
              </tr>`;
    })
    .join("\n");
  return `
      <section class="report-performance-detail" aria-labelledby="timing-title">
        <div class="report-case-intro">
          <div>
            <p class="report-section-index">TIMING OBSERVATIONS</p>
            <h2 id="timing-title">${profile.performance.roundTrips.toLocaleString("en-US")} loopback round trips.</h2>
          </div>
          <p>Derived means divide Autobahn's complete case duration by 1,000 sequential echoes. They are useful for comparing like-for-like runs on this host, but include setup and close overhead.</p>
        </div>
        <div class="report-table-scroll" tabindex="0" aria-label="Autobahn performance observations">
          <table class="report-performance-table">
            <thead><tr><th>Case</th><th>Data</th><th>Payload</th><th>Case duration</th><th>Derived mean</th><th>Echo rate</th></tr></thead>
            <tbody>
${rows}
            </tbody>
          </table>
        </div>
      </section>

      <section class="report-equipment" aria-labelledby="equipment-title">
        <div>
          <p class="report-section-index">TEST EQUIPMENT</p>
          <h2 id="equipment-title">One host, recorded with the observation.</h2>
        </div>
        <dl>
          <div><dt>Processor</dt><dd>${escapeHTML(environment.cpu.model)}, ${environment.cpu.logicalCount} logical CPUs</dd></div>
          <div><dt>Memory</dt><dd>${(environment.memoryBytes / 1_073_741_824).toFixed(1)} GiB</dd></div>
          <div><dt>System</dt><dd>${escapeHTML(environment.os.platform)} ${escapeHTML(environment.os.release)}, ${escapeHTML(environment.os.architecture)}</dd></div>
          <div><dt>Toolchain</dt><dd>${escapeHTML(toolchain.gnat)}, ${escapeHTML(toolchain.alire)}</dd></div>
          <div><dt>Build</dt><dd>${escapeHTML(profile.runMetadata.build.libraryProfileSource)}, ${escapeHTML(profile.runMetadata.build.libraryOptimization)} library and ${escapeHTML(profile.runMetadata.build.harnessOptimization)} harness</dd></div>
          <div><dt>Test client</dt><dd>Autobahn ${escapeHTML(profile.runMetadata.autobahn.suiteVersion)}, ${escapeHTML(profile.runMetadata.autobahn.platform)}, <code>${escapeHTML(profile.runMetadata.autobahn.imageDigest.slice(0, 19))}…</code></dd></div>
          ${profile.runMetadata.tls ? `<div><dt>TLS</dt><dd>${escapeHTML(profile.runMetadata.tls.provider)}, ${escapeHTML(profile.runMetadata.tls.version)}; module digests recorded in JSON</dd></div>` : ""}
          <div><dt>Privacy</dt><dd>Hostname and filesystem paths intentionally omitted.</dd></div>
        </dl>
      </section>`;
}

function profilePage(profile, provenance) {
  const resultHeading = {
    limits: "Every configured boundary probe passes.",
    compression: "Every compression and negotiation probe passes.",
    performance: "Every timing probe completed in the suite deadline.",
  }[profile.kind] || "The profile has no failed verdicts.";
  const resultCopy = {
    limits:
      "The adapter opts into Flyology's 16 MiB supported maximum. The public API keeps a 1 MiB default unless the application selects a larger message limit.",
    compression:
      "The adapter explicitly enables permessage-deflate with no context takeover. Decoded payloads remain subject to the configured message and shared ingress limits.",
    performance:
      "The cases record one loopback observation across six payload sizes for text and binary messages. They do not define a performance threshold.",
  }[profile.kind] || "Four non-strict cases defer invalid UTF-8 rejection until the fragmented message is complete. Autobahn accepts that timing. Three further cases are informational.";
  return `${documentHead({
    title: profile.title,
    description: `${profile.title}: ${profile.cases.length} Autobahn WebSocket case results for Flyology.`,
    canonical: `https://flyology.org/reports/websocket/${profile.slug}/`,
    depth: 3,
  })}
${siteHeader(3)}
    <main id="main" class="page-shell report-page report-profile-page">
      <header class="report-profile-hero">
        <div>
          <ol class="breadcrumb" aria-label="Breadcrumb"><li><a href="../../../">Flyology</a></li><li><a href="../">WebSocket conformance</a></li><li aria-current="page">${escapeHTML(profile.title)}</li></ol>
          <p class="eyebrow">${escapeHTML(profile.scope)} · ${escapeHTML(profile.date.display)}</p>
          <h1>${escapeHTML(profile.title)}.</h1>
        </div>
        <div>
          <p class="article-summary">${escapeHTML(resultHeading)} ${escapeHTML(resultCopy)}</p>
          <div class="report-status-line">${statusLegend(profile.counts)}</div>
        </div>
      </header>

${performanceSummary(profile)}

      <section class="report-case-browser" data-case-filter>
        <div class="report-case-intro">
          <div>
            <p class="report-section-index">CASE RECORD</p>
            <h2>${profile.cases.length} cases, in suite order.</h2>
          </div>
          <div class="report-case-actions">
            <a href="cases.json" download>Download normalized JSON</a>
            <a href="../">All profiles</a>
          </div>
        </div>
        <div class="report-filter-bar">
          <label>Find a case<input type="search" data-case-search placeholder="Case ID or description" autocomplete="off"></label>
          <label>Verdict<select data-case-status><option value="all">All verdicts</option>${Object.entries(profile.counts).filter(([, count]) => count).map(([status]) => `<option value="${statusKey(status)}">${escapeHTML(statusLabel(status))}</option>`).join("")}</select></label>
          <p data-case-count aria-live="polite">Showing all ${profile.cases.length} cases</p>
        </div>
        <ol class="report-case-list">
${profile.cases.map(caseRow).join("\n")}
        </ol>
        <p class="report-empty" data-case-empty hidden>No cases match this filter.</p>
      </section>

      <aside class="report-method" aria-label="Report method">
        <strong>Reproducible input</strong>
        <p>Autobahn ${escapeHTML(provenance.autobahn.suiteVersion)}, container <code>${escapeHTML(provenance.autobahn.imageDigest.slice(0, 19))}…</code>, Flyology revision <code>${escapeHTML(provenance.source.revision)}</code>, ${escapeHTML(profile.transport)}. Recorded from the ${escapeHTML(profile.runMetadata.build.libraryProfileSource)} configuration with ${escapeHTML(profile.runMetadata.build.libraryOptimization)} for the library and ${escapeHTML(profile.runMetadata.build.harnessOptimization)} for the harness. Wire logs remain in local generated output and are not published.</p>
      </aside>
    </main>
${siteFooter(3)}`;
}

function normalizedCases(profile) {
  return profile.cases.map((item) => {
    const normalized = {
      id: item.id,
      verdict: item.behavior,
      closeVerdict: item.behaviorClose,
      description: plainText(item.description),
      expectation: plainText(item.expectation),
      result: plainText(item.result),
      closeResult: plainText(item.resultClose),
      remoteCloseCode: item.remoteCloseCode,
      localCloseCode: item.localCloseCode,
      cleanClose: Boolean(item.wasClean),
      durationMs: item.duration,
    };
    if (profile.kind !== "performance") return normalized;
    const timing = performanceCase(item);
    return {
      ...normalized,
      roundTrips: timing.roundTrips,
      payloadBytes: timing.payloadBytes,
      meanRoundTripMs: Number(timing.meanRoundTripMs.toFixed(6)),
      roundTripsPerSecond: Number(timing.roundTripsPerSecond.toFixed(3)),
    };
  });
}

function inside(root, path) {
  const fromRoot = relative(root, path);
  return fromRoot === "" || (fromRoot !== ".." && !fromRoot.startsWith(`..${sep}`));
}

async function pathType(path) {
  try {
    return await lstat(path);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

async function requireSafeDirectory(path, label, allowMissing = false) {
  const value = await pathType(path);
  if (!value && allowMissing) return false;
  if (!value) throw new Error(`${label} does not exist: ${path}`);
  if (value.isSymbolicLink() || !value.isDirectory()) {
    throw new Error(`${label} must be an ordinary directory: ${path}`);
  }
  return true;
}

async function removeSafeDirectory(path, label) {
  if (!(await requireSafeDirectory(path, label, true))) return;
  await rm(path, { recursive: true });
}

async function requireSafePublicationTargets(stageRoot, backupRoot) {
  const parent = dirname(outputRoot);
  await requireSafeDirectory(parent, "publication parent");
  if ((await realpath(parent)) !== parent) {
    throw new Error(`publication parent traverses a symbolic link: ${parent}`);
  }
  await requireSafeDirectory(outputRoot, "publication output", true);
  await requireSafeDirectory(stageRoot, "publication stage", true);
  await requireSafeDirectory(backupRoot, "publication backup", true);
}

async function walkBundle(root, directory = root) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) {
      throw new Error(`published bundle contains a symbolic link: ${relative(root, path)}`);
    }
    if (entry.isDirectory()) files.push(...(await walkBundle(root, path)));
    else if (entry.isFile()) files.push(relative(root, path).split(sep).join("/"));
    else throw new Error(`published bundle contains a special file: ${relative(root, path)}`);
  }
  return files.sort();
}

function htmlIds(html) {
  return new Set(
    Array.from(
      html.matchAll(/\s(?:id|name)=(?:"([^"]+)"|'([^']+)'|([^\s>]+))/gi),
      (match) => match[1] || match[2] || match[3]
    )
  );
}

function localReferences(html) {
  return Array.from(
    html.matchAll(/\s(?:href|src)=(?:"([^"]+)"|'([^']+)'|([^\s>]+))/gi),
    (match) => match[1] || match[2] || match[3]
  ).filter(
    (value) =>
      !/^(?:[a-z]+:|\/\/)/i.test(value) &&
      !value.startsWith("data:") &&
      !value.startsWith("javascript:")
  );
}

async function resolvePublishedLink(stageRoot, sourceRelative, reference) {
  const websiteRoot = resolve(projectRoot, "website");
  const virtualSource = join(expectedOutput, sourceRelative);
  const [rawPath, fragment] = reference.split("#", 2);
  const decoded = decodeURIComponent(rawPath || "");
  const virtualTarget = decoded
    ? normalize(resolve(dirname(virtualSource), decoded))
    : virtualSource;
  if (!inside(websiteRoot, virtualTarget)) {
    throw new Error(`${sourceRelative}: link escapes the website: ${reference}`);
  }

  const apiRoot = join(websiteRoot, "api");
  if (inside(apiRoot, virtualTarget)) return;

  let actualTarget;
  if (inside(expectedOutput, virtualTarget)) {
    actualTarget = join(stageRoot, relative(expectedOutput, virtualTarget));
  } else {
    const brandRoot = join(websiteRoot, "assets/brand");
    actualTarget = inside(brandRoot, virtualTarget)
      ? join(projectRoot, "assets/brand", relative(brandRoot, virtualTarget))
      : virtualTarget;
  }

  let info;
  try {
    info = await stat(actualTarget);
    if (info.isDirectory()) {
      actualTarget = join(actualTarget, "index.html");
      info = await stat(actualTarget);
    }
  } catch {
    throw new Error(`${sourceRelative}: missing link target: ${reference}`);
  }
  if (!info.isFile()) {
    throw new Error(`${sourceRelative}: link target is not a file: ${reference}`);
  }
  if (fragment && actualTarget.endsWith(".html")) {
    const targetHtml = await readFile(actualTarget, "utf8");
    if (!htmlIds(targetHtml).has(decodeURIComponent(fragment))) {
      throw new Error(`${sourceRelative}: missing link fragment: ${reference}`);
    }
  }
}

async function verifyBundle(root, loaded, provenance) {
  const expectedFiles = [".publication-manifest.json", "index.html"];
  for (const profile of profiles) {
    expectedFiles.push(`${profile.slug}/cases.json`, `${profile.slug}/index.html`);
  }
  expectedFiles.sort();
  const actualFiles = await walkBundle(root);
  if (JSON.stringify(actualFiles) !== JSON.stringify(expectedFiles)) {
    throw new Error(
      `published bundle file set is incomplete: expected ${JSON.stringify(expectedFiles)}, ` +
        `got ${JSON.stringify(actualFiles)}`
    );
  }

  const manifest = JSON.parse(
    await readFile(join(root, ".publication-manifest.json"), "utf8")
  );
  requireEqual(manifest.schema, 1, "publication manifest schema");
  requireEqual(manifest.revision, provenance.source.revision, "publication revision");
  requireEqual(
    JSON.stringify(manifest.profiles),
    JSON.stringify(profiles.map((profile) => profile.slug)),
    "publication profile list"
  );

  for (const profile of loaded) {
    const casesPath = join(root, profile.slug, "cases.json");
    const published = JSON.parse(await readFile(casesPath, "utf8"));
    requireEqual(published.generatedFrom, profile.slug, `${profile.slug} generatedFrom`);
    requireEqual(published.revision, profile.runMetadata.source.revision, `${profile.slug} revision`);
    validateRunMetadata(
      published.runMetadata,
      {
        name: profile.invocationProfile,
        lane: profile.invocationLane,
        report: profile.slug,
        config: profile.config,
        transport: profile.transportMode,
      },
      `${profile.slug} published run metadata`
    );
    if (!Array.isArray(published.cases) || published.cases.length !== profile.cases.length) {
      throw new Error(`${profile.slug} published case count is inconsistent`);
    }
  }

  for (const path of actualFiles.filter((path) => path.endsWith(".html"))) {
    const html = await readFile(join(root, path), "utf8");
    if (!/<html\b[^>]*\blang="en"/i.test(html)) {
      throw new Error(`${path}: missing html lang`);
    }
    if (!/<meta\b[^>]*\bname="viewport"/i.test(html)) {
      throw new Error(`${path}: missing viewport metadata`);
    }
    for (const reference of localReferences(html)) {
      await resolvePublishedLink(root, path, reference);
    }
  }
}

function injectFailure(point) {
  if (process.env.FLYOLOGY_WEBSOCKET_PUBLISH_FAIL === point) {
    throw new Error(`forced WebSocket publication failure at ${point}`);
  }
}

async function renderBundle(root, loaded, provenance) {
  await mkdir(root);
  injectFailure("render");
  await writeFile(join(root, "index.html"), overallPage(loaded, provenance));
  injectFailure("write");

  for (const profile of loaded) {
    const directory = join(root, profile.slug);
    await mkdir(directory);
    await writeFile(join(directory, "index.html"), profilePage(profile, provenance));
    await writeFile(
      join(directory, "cases.json"),
      JSON.stringify(
        {
          generatedFrom: basename(join(inputRoot, profile.slug)),
          suite: `Autobahn ${provenance.autobahn.suiteVersion}`,
          imageDigest: provenance.autobahn.imageDigest,
          revision: provenance.source.revision,
          profile: profile.title,
          transport: profile.transport,
          date: profile.date.iso,
          runMetadata: profile.runMetadata,
          cases: normalizedCases(profile),
        },
        null,
        2
      ) + "\n"
    );
  }
  await writeFile(
    join(root, ".publication-manifest.json"),
    JSON.stringify(
      {
        schema: 1,
        revision: provenance.source.revision,
        profiles: profiles.map((profile) => profile.slug),
      },
      null,
      2
    ) + "\n"
  );
}

async function publishBundle(loaded, provenance) {
  const parent = dirname(outputRoot);
  const name = basename(outputRoot);
  const stageRoot = join(parent, `.${name}.publish-stage`);
  const backupRoot = join(parent, `.${name}.publish-backup`);
  await requireSafePublicationTargets(stageRoot, backupRoot);

  const backupExists = await requireSafeDirectory(
    backupRoot,
    "stale publication backup",
    true
  );
  const outputExists = await requireSafeDirectory(
    outputRoot,
    "publication output",
    true
  );
  if (backupExists && !outputExists) {
    await rename(backupRoot, outputRoot);
  } else if (backupExists) {
    try {
      await verifyBundle(outputRoot, loaded, provenance);
    } catch (error) {
      throw new Error(
        `refusing to remove stale publication backup because the live bundle ` +
          `cannot be verified: ${error.message}`
      );
    }
    await removeSafeDirectory(backupRoot, "stale publication backup");
  }
  await removeSafeDirectory(stageRoot, "stale publication stage");

  let backedUp = false;
  let published = false;
  try {
    await renderBundle(stageRoot, loaded, provenance);
    injectFailure("verify");
    await verifyBundle(stageRoot, loaded, provenance);

    if (await requireSafeDirectory(outputRoot, "publication output", true)) {
      await rename(outputRoot, backupRoot);
      backedUp = true;
    }
    injectFailure("swap-after-backup");
    await rename(stageRoot, outputRoot);
    published = true;
    injectFailure("swap-after-publish");
    if (backedUp) {
      await removeSafeDirectory(backupRoot, "publication backup");
      backedUp = false;
    }
  } catch (error) {
    const rollbackErrors = [];
    try {
      if (published) await removeSafeDirectory(outputRoot, "failed publication output");
      if (backedUp) {
        await rename(backupRoot, outputRoot);
        backedUp = false;
      }
    } catch (rollbackError) {
      rollbackErrors.push(rollbackError);
    }
    try {
      await removeSafeDirectory(stageRoot, "failed publication stage");
    } catch (cleanupError) {
      rollbackErrors.push(cleanupError);
    }
    if (rollbackErrors.length) {
      throw new AggregateError(
        [error, ...rollbackErrors],
        "WebSocket publication failed and rollback was incomplete"
      );
    }
    throw error;
  }
}

const loaded = [];
for (const profile of profiles) loaded.push(await loadProfile(profile));
const provenance = requireConsistentRunMetadata(
  loaded.map((profile) => ({
    report: profile.slug,
    metadata: profile.runMetadata,
  }))
);

await publishBundle(loaded, provenance);

console.log(
  `Published ${loaded.reduce((sum, profile) => sum + profile.cases.length, 0)} case records to ${outputRoot}`
);
