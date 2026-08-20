/*
 * termcast.js - replay an asciicast v2 recording without a third-party player.
 *
 * The flyology_bench examples emit a small, fixed subset of terminal control
 * sequences: SGR colour and weight, erase-line, cursor-up, and carriage
 * return. This player implements that subset exactly and ignores anything
 * else, so a recording is replayed rather than approximated.
 *
 * Markup:
 *   <figure class="termcast" data-cast="URL" data-title="caption"></figure>
 * The script builds the screen, controls, and status line itself.
 */
(function () {
  "use strict";

  var ESC = "\x1b";

  var SGR = {
    1: "tc-bold",
    2: "tc-dim",
    31: "tc-red",
    32: "tc-green",
    33: "tc-yellow",
    34: "tc-blue",
    35: "tc-magenta",
    36: "tc-cyan"
  };

  function Screen(columns, rows) {
    this.columns = columns;
    this.rows = rows;
    this.row = 0;
    this.column = 0;
    this.style = "";
    this.cells = [];
    for (var i = 0; i < rows; i += 1) {
      this.cells.push(this.blankRow());
    }
  }

  Screen.prototype.blankRow = function () {
    var row = new Array(this.columns);
    for (var i = 0; i < this.columns; i += 1) {
      row[i] = { text: " ", style: "" };
    }
    return row;
  };

  Screen.prototype.scroll = function () {
    this.cells.shift();
    this.cells.push(this.blankRow());
    this.row = this.rows - 1;
  };

  Screen.prototype.newline = function () {
    this.row += 1;
    if (this.row >= this.rows) {
      this.scroll();
    }
  };

  Screen.prototype.put = function (character) {
    if (this.column >= this.columns) {
      this.column = 0;
      this.newline();
    }
    this.cells[this.row][this.column] = { text: character, style: this.style };
    this.column += 1;
  };

  Screen.prototype.eraseLine = function () {
    this.cells[this.row] = this.blankRow();
  };

  Screen.prototype.cursorUp = function (count) {
    this.row = Math.max(0, this.row - count);
  };

  Screen.prototype.applySGR = function (parameters) {
    var classes = this.style ? this.style.split(" ") : [];
    parameters.forEach(function (value) {
      var code = parseInt(value, 10) || 0;
      if (code === 0) {
        classes = [];
        return;
      }
      var name = SGR[code];
      if (name && classes.indexOf(name) === -1) {
        classes.push(name);
      }
    });
    this.style = classes.join(" ");
  };

  Screen.prototype.write = function (text) {
    var index = 0;
    while (index < text.length) {
      var character = text.charAt(index);
      if (character === ESC && text.charAt(index + 1) === "[") {
        var match = /^\[([0-9;?]*)([A-Za-z])/.exec(text.slice(index + 1));
        if (match) {
          var parameters = match[1].split(";");
          var final = match[2];
          if (final === "m") {
            this.applySGR(parameters);
          } else if (final === "K") {
            this.eraseLine();
          } else if (final === "A") {
            this.cursorUp(parseInt(parameters[0], 10) || 1);
          }
          index += match[0].length + 1;
          continue;
        }
      }
      if (character === "\n") {
        this.newline();
      } else if (character === "\r") {
        this.column = 0;
      } else if (character === "\b") {
        this.column = Math.max(0, this.column - 1);
      } else if (character !== ESC) {
        this.put(character);
      }
      index += 1;
    }
  };

  function escapeHTML(text) {
    return text
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function wrap(text, style) {
    var escaped = escapeHTML(text);
    return style ? '<span class="' + style + '">' + escaped + "</span>" : escaped;
  }

  Screen.prototype.render = function () {
    var html = "";
    for (var r = 0; r < this.rows; r += 1) {
      var row = this.cells[r];
      var last = this.columns - 1;
      while (last >= 0 && row[last].text === " " && row[last].style === "") {
        last -= 1;
      }
      var line = "";
      var run = "";
      var runStyle = null;
      for (var c = 0; c <= last; c += 1) {
        var cell = row[c];
        if (runStyle === null) {
          runStyle = cell.style;
        }
        if (cell.style !== runStyle) {
          line += wrap(run, runStyle);
          run = "";
          runStyle = cell.style;
        }
        run += cell.text;
      }
      if (run) {
        line += wrap(run, runStyle);
      }
      html += line + "\n";
    }
    return html;
  };

  function parseCast(source) {
    var lines = source.split("\n").filter(function (line) {
      return line.trim() !== "";
    });
    var header = JSON.parse(lines[0]);
    var events = [];
    for (var i = 1; i < lines.length; i += 1) {
      var event = JSON.parse(lines[i]);
      if (event[1] === "o") {
        events.push({ time: event[0], data: event[2] });
      }
    }
    return { header: header, events: events };
  }

  function formatTime(seconds) {
    var whole = Math.floor(seconds);
    var tenths = Math.floor((seconds - whole) * 10);
    return whole + "." + tenths + "s";
  }

  function setup(figure) {
    var url = figure.getAttribute("data-cast");
    if (!url) {
      return;
    }

    var caption = document.createElement("figcaption");
    var label = document.createElement("span");
    label.textContent = figure.getAttribute("data-title") || "recording";
    var status = document.createElement("span");
    status.className = "termcast-status";
    status.textContent = "loading";
    caption.appendChild(label);
    caption.appendChild(status);

    var viewport = document.createElement("div");
    viewport.className = "termcast-viewport";
    viewport.setAttribute("tabindex", "0");
    viewport.setAttribute("aria-label", "Scrollable terminal recording");
    var screenNode = document.createElement("pre");
    viewport.appendChild(screenNode);

    var controls = document.createElement("div");
    controls.className = "termcast-controls";
    //  Two controls, two jobs: the toggle starts and suspends playback at
    //  wherever the recording currently sits, and restart returns to the
    //  beginning. Playing from the end restarts, as a media player does.
    var toggle = document.createElement("button");
    toggle.type = "button";
    toggle.className = "termcast-button";
    toggle.textContent = "Play";
    toggle.disabled = true;
    var restart = document.createElement("button");
    restart.type = "button";
    restart.className = "termcast-button";
    restart.textContent = "Restart";
    restart.disabled = true;
    var scrubber = document.createElement("input");
    scrubber.type = "range";
    scrubber.className = "termcast-scrubber";
    scrubber.min = "0";
    scrubber.max = "1000";
    scrubber.value = "0";
    scrubber.step = "1";
    scrubber.disabled = true;
    scrubber.setAttribute("aria-label", "Seek within the recording");
    controls.appendChild(toggle);
    controls.appendChild(restart);
    controls.appendChild(scrubber);

    figure.appendChild(caption);
    figure.appendChild(viewport);
    figure.appendChild(controls);

    fetch(url)
      .then(function (response) {
        if (!response.ok) {
          throw new Error("HTTP " + response.status);
        }
        return response.text();
      })
      .then(function (source) {
        start(parseCast(source));
      })
      .catch(function (error) {
        status.textContent = "unavailable";
        screenNode.textContent =
          "The recording could not be loaded (" + error.message + ").";
      });

    function start(cast) {
      var columns = cast.header.width || 100;
      var rows = cast.header.height || 24;
      var duration = cast.events.length
        ? cast.events[cast.events.length - 1].time
        : 0;

      screenNode.style.width = columns + "ch";
      screenNode.style.minHeight = rows + "lh";

      //  The examples emit a fixed-width report, so a wide recording would
      //  otherwise sit behind a long horizontal scroll. Shrink the type until
      //  the recording fits the column, but never below a readable floor;
      //  whatever still does not fit stays reachable by scrolling.
      var MINIMUM_FONT_PX = 9;
      var baseFontPx = parseFloat(window.getComputedStyle(screenNode).fontSize);

      function fit() {
        screenNode.style.fontSize = baseFontPx + "px";
        var probe = document.createElement("span");
        probe.textContent = "0000000000";
        probe.style.position = "absolute";
        probe.style.visibility = "hidden";
        probe.style.whiteSpace = "pre";
        screenNode.appendChild(probe);
        var characterWidth = probe.getBoundingClientRect().width / 10;
        screenNode.removeChild(probe);
        if (!characterWidth) {
          return;
        }
        var style = window.getComputedStyle(screenNode);
        var padding =
          parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
        var available = viewport.clientWidth - padding;
        var required = columns * characterWidth;
        if (required <= available) {
          return;
        }
        var scaled = baseFontPx * (available / required);
        screenNode.style.fontSize =
          Math.max(MINIMUM_FONT_PX, scaled).toFixed(2) + "px";
      }

      fit();
      window.addEventListener("resize", fit);

      var screen = new Screen(columns, rows);
      var cursor = 0;
      var playing = false;
      var elapsed = 0;
      var lastFrame = 0;
      var frameHandle = null;

      function paint() {
        screenNode.innerHTML = screen.render();
        status.textContent = formatTime(elapsed) + " / " + formatTime(duration);
        scrubber.value = String(
          duration > 0 ? Math.round((elapsed / duration) * 1000) : 0
        );
      }

      function rewind() {
        screen = new Screen(columns, rows);
        cursor = 0;
        elapsed = 0;
      }

      function seek(target) {
        if (target < elapsed) {
          rewind();
        }
        while (
          cursor < cast.events.length &&
          cast.events[cursor].time <= target
        ) {
          screen.write(cast.events[cursor].data);
          cursor += 1;
        }
        elapsed = target;
        paint();
      }

      function stop() {
        playing = false;
        toggle.textContent = "Play";
        if (frameHandle) {
          window.cancelAnimationFrame(frameHandle);
          frameHandle = null;
        }
      }

      function step(timestamp) {
        if (!playing) {
          return;
        }
        var delta = (timestamp - lastFrame) / 1000;
        lastFrame = timestamp;
        seek(Math.min(duration, elapsed + delta));
        if (elapsed >= duration) {
          stop();
          return;
        }
        frameHandle = window.requestAnimationFrame(step);
      }

      function play() {
        if (elapsed >= duration) {
          rewind();
          paint();
        }
        playing = true;
        toggle.textContent = "Pause";
        lastFrame = window.performance.now();
        frameHandle = window.requestAnimationFrame(step);
      }

      toggle.disabled = false;
      restart.disabled = false;
      scrubber.disabled = false;

      toggle.addEventListener("click", function () {
        if (playing) {
          stop();
        } else {
          play();
        }
      });

      restart.addEventListener("click", function () {
        stop();
        rewind();
        paint();
        play();
      });

      scrubber.addEventListener("input", function () {
        stop();
        seek((Number(scrubber.value) / 1000) * duration);
      });

      var reduced =
        window.matchMedia &&
        window.matchMedia("(prefers-reduced-motion: reduce)").matches;

      if (reduced || !window.IntersectionObserver) {
        seek(duration);
        return;
      }

      paint();
      var observer = new window.IntersectionObserver(
        function (entries) {
          entries.forEach(function (entry) {
            if (entry.isIntersecting && elapsed === 0 && !playing) {
              observer.disconnect();
              play();
            }
          });
        },
        { threshold: 0.3 }
      );
      observer.observe(figure);
    }
  }

  function init() {
    var figures = document.querySelectorAll(".termcast[data-cast]");
    Array.prototype.forEach.call(figures, setup);
  }

  //  Exposed so scripts/test-termcast.mjs can replay a cast headlessly and
  //  compare the resulting screen against the recorded program's own output.
  if (typeof module !== "undefined" && module.exports) {
    module.exports = { Screen: Screen, parseCast: parseCast };
  }

  if (typeof document === "undefined") {
    return;
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
