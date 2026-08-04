(function (global) {
  "use strict";

  const keywords = new Set(
    "abort abs abstract accept access aliased all and array at begin body case constant declare delay delta digits do else elsif end entry exception exit for function generic goto if in interface is limited loop mod new not null of or others out overriding package parallel pragma private procedure protected raise range record rem renames requeue return reverse select separate some subtype synchronized tagged task terminate then type until use when while with xor"
      .split(" ")
  );
  const sqlKeywords = new Set(
    "all and as asc between by case cast create cross delete desc distinct else end exists false from full group having in inner insert into is join left like limit not null offset on or order outer returning right select set show table then true union update values when where with"
      .split(" ")
  );
  const tokenPattern = /--[^\n]*|"(?:[^"]|"")*"|'(?:[^']|'')'|\b[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+\b|'[A-Za-z][A-Za-z0-9_]*|\b\d[\d_]*(?:#[0-9A-Fa-f_.]+#|\.\d[\d_]*)?(?:[Ee][+-]?\d[\d_]*)?\b|=>|:=|\.\.|<>|<=|>=|\/=|\*\*|\b[A-Za-z][A-Za-z0-9_]*\b/g;
  const sqlTokenPattern = /--[^\n]*|'(?:[^']|'')*'|"(?:[^"]|"")*"|\b\d+(?:\.\d+)?\b|<>|<=|>=|!=|=|<|>|\*|[(),;.]|\b[A-Za-z_][A-Za-z0-9_$]*\b/g;

  function escapeHtml(value) {
    return value
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;");
  }

  function tokenClass(token) {
    if (token.startsWith("--")) return "token-comment";
    if (token.startsWith('"') || /^'.*'$/.test(token)) return "token-string";
    if (token.startsWith("'")) return "token-attribute";
    if (/^\d/.test(token)) return "token-number";
    if (token.includes(".")) return token === ".." ? "token-operator" : "token-type";
    if (keywords.has(token.toLowerCase())) return "token-keyword";
    if (/^(true|false)$/i.test(token)) return "token-number";
    if (/^[A-Za-z]/.test(token)) return "";
    return "token-operator";
  }

  function highlight(code) {
    if (code.dataset.adaHighlighted === "true") return;

    const source = code.textContent;
    let result = "";
    let previousIndex = 0;

    source.replace(tokenPattern, function (token, offset) {
      const className = tokenClass(token);
      result += escapeHtml(source.slice(previousIndex, offset));
      result += className
        ? '<span class="' + className + '">' + escapeHtml(token) + "</span>"
        : escapeHtml(token);
      previousIndex = offset + token.length;
      return token;
    });

    result += escapeHtml(source.slice(previousIndex));
    code.innerHTML = result;
    code.dataset.adaHighlighted = "true";
  }

  function highlightAll(selector) {
    document.querySelectorAll(selector).forEach(highlight);
  }

  function sqlTokenClass(token) {
    if (token.startsWith("--")) return "token-comment";
    if (token.startsWith("'")) return "token-string";
    if (token.startsWith('"')) return "token-attribute";
    if (/^\d/.test(token)) return "token-number";
    if (sqlKeywords.has(token.toLowerCase())) return "token-keyword";
    if (/^(<>|<=|>=|!=|=|<|>|\*|[(),;.])$/.test(token)) {
      return "token-operator";
    }
    return "";
  }

  function highlightSQL(code) {
    if (code.dataset.sqlHighlighted === "true") return;

    const source = code.textContent;
    let result = "";
    let previousIndex = 0;

    source.replace(sqlTokenPattern, function (token, offset) {
      const className = sqlTokenClass(token);
      result += escapeHtml(source.slice(previousIndex, offset));
      result += className
        ? '<span class="' + className + '">' + escapeHtml(token) + "</span>"
        : escapeHtml(token);
      previousIndex = offset + token.length;
      return token;
    });

    result += escapeHtml(source.slice(previousIndex));
    code.innerHTML = result;
    code.dataset.sqlHighlighted = "true";
  }

  function highlightAllSQL(selector) {
    document.querySelectorAll(selector).forEach(highlightSQL);
  }

  global.FlyologyAda = Object.freeze({
    highlight: highlight,
    highlightAll: highlightAll,
    highlightSQL: highlightSQL,
    highlightAllSQL: highlightAllSQL
  });
})(window);
