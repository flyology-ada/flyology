//  Check that termcast.js reproduces a recorded terminal session.
//
//  The player implements a small subset of terminal control sequences. This
//  test replays each published cast through that implementation and compares
//  the result against the recording's own bytes with escapes removed, so a
//  defect in the emulation shows up as differing text rather than as a
//  plausible-looking animation.

import { createRequire } from "node:module";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const { Screen, parseCast } = require(
  join(root, "website/assets/scripts/termcast.js")
);

const castDirectory = join(root, "website/assets/casts");
const casts = readdirSync(castDirectory).filter((name) =>
  name.endsWith(".cast")
);

if (casts.length === 0) {
  console.error("no casts found; run scripts/record-bench-cast.sh first");
  process.exit(1);
}

//  Reduce recorded bytes to the lines a terminal would finally hold, applying
//  only carriage-return and erase-line overwriting. This is an independent
//  path from the player: it never uses the Screen implementation.
function expectedLines(data) {
  const lines = [];
  let current = "";
  let column = 0;
  let index = 0;
  const ESC = "\x1b";
  while (index < data.length) {
    const character = data[index];
    if (character === ESC && data[index + 1] === "[") {
      const match = /^\[([0-9;?]*)([A-Za-z])/.exec(data.slice(index + 1));
      if (match) {
        if (match[2] === "K") {
          current = "";
          column = 0;
        } else if (match[2] === "A") {
          //  Cursor movement rewrites earlier rows; those cases are checked
          //  by the escape-coverage assertion instead of by text equality.
          return null;
        }
        index += match[0].length + 1;
        continue;
      }
    }
    if (character === "\n") {
      lines.push(current.replace(/\s+$/, ""));
      current = "";
      column = 0;
    } else if (character === "\r") {
      column = 0;
    } else if (character !== ESC) {
      current = current.slice(0, column) + character + current.slice(column + 1);
      column += 1;
    }
    index += 1;
  }
  if (current.trim() !== "") {
    lines.push(current.replace(/\s+$/, ""));
  }
  return lines;
}

//  Widest line the recording actually emitted, after carriage-return and
//  erase-line overwriting. A line wider than the recorded terminal wrapped
//  when it was captured, so the replay inherits the wrap and the reporter's
//  aligned columns break apart.
function widestLine(data) {
  let widest = 0;
  let current = "";
  let column = 0;
  let index = 0;
  const ESC = "\x1b";
  while (index < data.length) {
    const character = data[index];
    if (character === ESC && data[index + 1] === "[") {
      const match = /^\[([0-9;?]*)([A-Za-z])/.exec(data.slice(index + 1));
      if (match) {
        if (match[2] === "K") {
          current = "";
          column = 0;
        }
        index += match[0].length + 1;
        continue;
      }
    }
    if (character === "\n") {
      widest = Math.max(widest, current.replace(/\s+$/, "").length);
      current = "";
      column = 0;
    } else if (character === "\r") {
      column = 0;
    } else if (character !== ESC) {
      current = current.slice(0, column) + character + current.slice(column + 1);
      column += 1;
    }
    index += 1;
  }
  return Math.max(widest, current.replace(/\s+$/, "").length);
}

let failures = 0;

for (const name of casts) {
  const source = readFileSync(join(castDirectory, name), "utf8");
  const cast = parseCast(source);
  const data = cast.events.map((event) => event.data).join("");

  //  Every escape sequence in the recording must be one the player handles;
  //  an unhandled sequence would be silently dropped on screen.
  const handled = new Set(["m", "K", "A"]);
  const unhandled = new Set();
  for (const match of data.matchAll(/\x1b\[([0-9;?]*)([A-Za-z])/g)) {
    if (!handled.has(match[2])) {
      unhandled.add(match[0]);
    }
  }

  const screen = new Screen(cast.header.width, cast.header.height);
  for (const event of cast.events) {
    screen.write(event.data);
  }
  const rendered = screen
    .render()
    .replace(/<[^>]*>/g, "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .split("\n")
    .map((line) => line.replace(/\s+$/, ""));

  const expected = expectedLines(data);
  let verdict = "ok";
  const problems = [];

  if (unhandled.size > 0) {
    problems.push(`unhandled escapes: ${[...unhandled].join(" ")}`);
  }

  const widest = widestLine(data);
  if (widest > cast.header.width) {
    problems.push(
      `output wrapped: widest line is ${widest} columns, recorded at ` +
        `${cast.header.width}; re-record wider via scripts/record-bench-cast.sh`
    );
  }

  if (expected === null) {
    //  Cast repositions the cursor; verify the visible tail is non-empty and
    //  that the final frame holds the program's last emitted line.
    const lastLine = data
      .replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
      .split("\n")
      .map((line) => line.replace(/\s+$/, ""))
      .filter((line) => line.trim() !== "")
      .pop();
    if (lastLine && !rendered.some((line) => line.includes(lastLine.trim()))) {
      problems.push("final frame is missing the last recorded line");
    }
    verdict = "ok (cursor-addressed; tail checked)";
  } else {
    //  The screen holds the last `height` rows of an append-only stream. When
    //  the stream ends with a newline the cursor rests on a fresh blank row,
    //  so trailing blanks are dropped before aligning with the emitted lines.
    const visible = [...rendered];
    while (visible.length > 0 && visible[visible.length - 1] === "") {
      visible.pop();
    }
    if (visible.length > cast.header.height) {
      problems.push(`screen holds ${visible.length} rows, height is ${cast.header.height}`);
    }
    const tail = expected.slice(-visible.length);
    for (let i = 0; i < tail.length; i += 1) {
      if (visible[i] !== tail[i]) {
        problems.push(
          `row ${i} of ${tail.length} differs\n    expected: ${JSON.stringify(tail[i])}\n    rendered: ${JSON.stringify(visible[i])}`
        );
        break;
      }
    }
    if (problems.length === 0) {
      verdict = `ok (${tail.length} visible rows matched)`;
    }
  }

  if (problems.length > 0) {
    failures += 1;
    console.error(`FAIL ${name}`);
    problems.forEach((problem) => console.error(`  ${problem}`));
  } else {
    console.log(
      `ok   ${name}  ${cast.header.width}x${cast.header.height}  ` +
        `${cast.events.length} events  ${cast.events[cast.events.length - 1].time.toFixed(2)}s  ${verdict}`
    );
  }
}

process.exit(failures === 0 ? 0 : 1);
