#!/usr/bin/env bash
# md_to_telegram_html.sh — Convert standard Markdown to Telegram-compatible HTML.
# Reads from stdin, writes to stdout.  Zero external dependencies (pure awk).
#
# Supported conversions:
#   **bold** / __bold__   →  <b>bold</b>
#   *italic* / _italic_   →  <i>italic</i>
#   ~~strike~~             →  <s>strike</s>
#   `inline code`          →  <code>inline code</code>
#   ```lang\n...\n```      →  <pre><code class="language-lang">...</code></pre>
#   [text](url)            →  <a href="url">text</a>
#   > blockquote           →  <blockquote>...</blockquote>
#   # heading              →  <b>heading</b>
#   &, <, > in text        →  &amp; &lt; &gt;
set -euo pipefail

exec awk '
BEGIN { in_code = 0; code_lang = ""; code_buf = "" ; in_bq = 0; bq_buf = "" }

# ── fenced code blocks ──────────────────────────────────────────────
/^```/ {
  if (!in_code) {
    # opening fence — grab optional language tag
    lang = $0
    sub(/^```[[:space:]]*/, "", lang)
    sub(/[[:space:]]*$/, "", lang)
    code_lang = lang
    code_buf = ""
    in_code = 1
    next
  } else {
    # closing fence — emit <pre><code>
    code_buf = escape_html(code_buf)
    # strip leading newline if present
    sub(/^\n/, "", code_buf)
    if (code_lang != "") {
      printf "<pre><code class=\"language-%s\">%s</code></pre>\n", code_lang, code_buf
    } else {
      printf "<pre><code>%s</code></pre>\n", code_buf
    }
    in_code = 0
    code_lang = ""
    code_buf = ""
    next
  }
}

in_code {
  if (code_buf == "") {
    code_buf = $0
  } else {
    code_buf = code_buf "\n" $0
  }
  next
}

# ── blockquotes  ────────────────────────────────────────────────────
/^>[[:space:]]?/ {
  line = $0
  sub(/^>[[:space:]]?/, "", line)
  if (in_bq) {
    bq_buf = bq_buf "\n" line
  } else {
    in_bq = 1
    bq_buf = line
  }
  next
}

# If we were in a blockquote and this line is not a quote line, flush it
in_bq {
  flush_bq()
}

# ── headings → bold ─────────────────────────────────────────────────
/^#{1,6}[[:space:]]/ {
  line = $0
  sub(/^#{1,6}[[:space:]]+/, "", line)
  sub(/[[:space:]]+#{1,6}[[:space:]]*$/, "", line)  # trailing # markers
  line = convert_inline(escape_html(line))
  print "<b>" line "</b>"
  next
}

# ── regular lines ───────────────────────────────────────────────────
{
  line = convert_inline(escape_html($0))
  print line
}

END {
  if (in_bq) flush_bq()
  # Handle unclosed code fence gracefully
  if (in_code) {
    code_buf = escape_html(code_buf)
    sub(/^\n/, "", code_buf)
    if (code_lang != "") {
      printf "<pre><code class=\"language-%s\">%s</code></pre>\n", code_lang, code_buf
    } else {
      printf "<pre><code>%s</code></pre>\n", code_buf
    }
  }
}

function flush_bq() {
  bq_buf_esc = escape_html(bq_buf)
  bq_buf_esc = convert_inline(bq_buf_esc)
  print "<blockquote>" bq_buf_esc "</blockquote>"
  in_bq = 0
  bq_buf = ""
}

function escape_html(s,    amp) {
  # & must be escaped first; use split/join to avoid awk gsub & back-reference issues
  amp = "\\&amp;"
  gsub(/&/, amp, s)
  gsub(/</, "\\&lt;", s)
  gsub(/>/, "\\&gt;", s)
  return s
}

function convert_inline(s,    out, rest, pre, code_content, link_text, link_url, idx) {
  # Process inline code first (`...`) to protect contents from further conversion
  out = ""
  rest = s
  while (match(rest, /`[^`]+`/)) {
    pre = substr(rest, 1, RSTART - 1)
    code_content = substr(rest, RSTART + 1, RLENGTH - 2)
    rest = substr(rest, RSTART + RLENGTH)
    # Convert non-code portion
    out = out convert_formatting(pre) "<code>" code_content "</code>"
  }
  out = out convert_formatting(rest)
  return out
}

function convert_formatting(s) {
  # Links: [text](url) — process before bold/italic to avoid conflicts with underscores in URLs
  while (match(s, /\[([^\]]+)\]\(([^)]+)\)/)) {
    link_text = substr(s, RSTART + 1)
    sub(/\].*/, "", link_text)
    link_url = substr(s, RSTART)
    sub(/.*\]\(/, "", link_url)
    sub(/\).*/, "", link_url)
    # Unescape HTML entities in URL that we escaped earlier
    gsub(/&amp;/, "\\&", link_url)
    gsub(/&lt;/, "<", link_url)
    gsub(/&gt;/, ">", link_url)
    s = substr(s, 1, RSTART - 1) "<a href=\"" link_url "\">" link_text "</a>" substr(s, RSTART + RLENGTH)
  }

  # Bold: **text** (process before italic to avoid conflicts)
  while (match(s, /\*\*[^*]+\*\*/)) {
    s = substr(s, 1, RSTART - 1) "<b>" substr(s, RSTART + 2, RLENGTH - 4) "</b>" substr(s, RSTART + RLENGTH)
  }

  # Bold: __text__ (process before italic _)
  while (match(s, /__[^_]+__/)) {
    s = substr(s, 1, RSTART - 1) "<b>" substr(s, RSTART + 2, RLENGTH - 4) "</b>" substr(s, RSTART + RLENGTH)
  }

  # Italic: *text* (single star, not preceded by another star)
  while (match(s, /\*[^*]+\*/)) {
    s = substr(s, 1, RSTART - 1) "<i>" substr(s, RSTART + 1, RLENGTH - 2) "</i>" substr(s, RSTART + RLENGTH)
  }

  # Italic: _text_ (single underscore)
  while (match(s, /_[^_]+_/)) {
    s = substr(s, 1, RSTART - 1) "<i>" substr(s, RSTART + 1, RLENGTH - 2) "</i>" substr(s, RSTART + RLENGTH)
  }

  # Strikethrough: ~~text~~
  while (match(s, /~~[^~]+~~/)) {
    s = substr(s, 1, RSTART - 1) "<s>" substr(s, RSTART + 2, RLENGTH - 4) "</s>" substr(s, RSTART + RLENGTH)
  }

  return s
}
'
