#!/usr/bin/env python3
# ==========================================
# rm-docs-html.py
# ==========================================
# Turns a Markdown guide (RM_MODULE_ENGINE_README.md by default) into the
# browser page RM ships beside it: a contents rail on the left, a filter
# box, a light/dark switch, copy buttons on code blocks, and section
# numbers that become links ("section 4.1" jumps to 4.1). The .md stays
# the only file anyone edits; run this whenever it changes.
#
# USAGE
#   python rm-docs-html.py                      README beside this script
#   python rm-docs-html.py GUIDE.md             writes GUIDE.html beside it
#   python rm-docs-html.py GUIDE.md OUT.html    writes OUT.html
#   --kicker TEXT     the small line above the title in the rail
#   --subtitle TEXT   the line under the title in the rail
#
# Standard library only, so it runs on any Python 3.8 or later with
# nothing to install.
#
# WHAT IT UNDERSTANDS
# The Markdown the RM guides are written in, and nothing more exotic:
#   # Title                 the page title (the first one only)
#   ## N. Title             a numbered chapter: id sec-N
#   ## Appendix X: Title    a lettered chapter: id appendix-x
#   ## Title                an unnumbered chapter
#   ### N.M Title           a numbered section: id sec-N-M
#   ### Title, #### Title   unnumbered headings
#   ```lang ... ```         code blocks, with a copy button
#   | a | b |               tables, header row and --- row required
#   - item, 1. item         lists, nested by indentation
#   > text                  block quotes
#   ---                     a rule; before a chapter it separates chapters
#   `code` **bold** *italic* [text](link)
#
# A "## Contents" chapter is left out: the rail is the contents. Links
# written as GitHub anchors (#4-the-materials-file) are pointed at the
# ids this page uses, so the .md reads correctly on GitHub and here.
#
# The look (CSS) and the behaviour (JS) are the page's own, kept below
# as they are. Change them there and every regenerated page follows.
# ==========================================

import argparse
import html
import re
import sys
from pathlib import Path


# ==========================================
# SETTINGS
# ==========================================
# The file looked for when no input is given: beside this script first,
# then in the current folder.
DEFAULT_INPUT = 'RM_MODULE_ENGINE_README.md'

# The two lines in the rail's head around the title. The title itself is
# the Markdown's first "# " heading.
DEFAULT_KICKER = 'Refinish Metal'
DEFAULT_SUBTITLE = 'Adding content to Dwarf Fortress at runtime'

# Chapters dropped from the page, by heading text (lower case). The rail
# replaces a Markdown contents list.
SKIPPED_CHAPTERS = {'contents'}


# ==========================================
# HEADING IDS
# ==========================================
# Two id schemes meet here. The page uses sec-N / sec-N-M for numbered
# headings, so a section number is its own address. The .md is written
# for GitHub, whose anchors are slugs of the heading text. Every heading
# is filed under both, and every link is rewritten to the page's id.

PLACEHOLDER = '\x00'   # brackets stashed inline pieces; never in text


def plain_text(md):
    """A heading's text with its Markdown taken off, for slugs and the rail."""
    s = re.sub(r'`([^`]*)`', r'\1', md)                    # code spans
    s = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', s)          # links
    s = re.sub(r'\*\*(.+?)\*\*', r'\1', s)                  # bold
    s = re.sub(r'(?<![*\w])\*(?=\S)(.+?)(?<=\S)\*(?![*\w])', r'\1', s)  # italic
    return s.strip()


def github_slug(text, taken):
    """GitHub's heading anchor: lower case, punctuation dropped, spaces to
    hyphens, -1, -2 ... added when the same slug comes up again."""
    base = re.sub(r'[^\w\- ]', '', plain_text(text).lower()).replace(' ', '-')
    slug, n = base, 0
    while slug in taken:
        n += 1
        slug = '%s-%d' % (base, n)
    taken.add(slug)
    return slug


# ==========================================
# INLINE MARKDOWN
# ==========================================
# Order matters. Code spans and links are cut out first and parked as
# placeholders, so nothing inside them is touched; the rest is escaped,
# then bold, italic and section cross-references are marked; the parked
# pieces go back last.

class Context:
    """What the inline renderer needs to know about the whole document."""
    def __init__(self):
        self.slug_to_id = {}   # GitHub anchor or page id -> page id
        self.xref = {}         # "4", "4.1", "A" -> page id
        self.warnings = []


def render_inline(text, ctx, xrefs=True, _parked=None):
    # A link's label is rendered by a nested call that shares this call's
    # parking list, because the label can already hold a parked code span.
    # Only the outermost call puts the parked pieces back.
    outer = _parked is None
    parked = [] if outer else _parked

    def park(fragment):
        parked.append(fragment)
        return '%s%d%s' % (PLACEHOLDER, len(parked) - 1, PLACEHOLDER)

    # Code spans: any run of backticks, closed by the same run. Content is
    # escaped and otherwise left exactly as written.
    def code_span(m):
        body = m.group(2)
        if body.startswith(' ') and body.endswith(' ') and body.strip():
            body = body[1:-1]
        return park('<code>%s</code>' % html.escape(body, quote=False))
    text = re.sub(r'(`+)(.+?)\1', code_span, text, flags=re.S)

    # Links. An in-page anchor is pointed at the page's own id.
    def link(m):
        label, target = m.group(1), m.group(2).strip()
        if target.startswith('#'):
            key = target[1:]
            if key in ctx.slug_to_id:
                target = '#' + ctx.slug_to_id[key]
            else:
                ctx.warnings.append('link to an anchor no heading has: %s' % target)
        inner = render_inline(label, ctx, xrefs=False, _parked=parked)
        return park('<a href="%s">%s</a>' % (html.escape(target, quote=True), inner))
    text = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', link, text)

    # Everything left is plain text: escape it (quotes stay as written).
    text = html.escape(text, quote=False)

    text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text, flags=re.S)
    text = re.sub(r'(?<![*\w])\*(?=\S)(.+?)(?<=\S)\*(?![*\w])',
                  r'<em>\1</em>', text, flags=re.S)

    # Cross-references: "section 4.1", "Section 7", "see 6.7",
    # "Appendix A". Only the number becomes a link, and only when that
    # section exists, so prose numbers ("150 bars") are never caught.
    if xrefs and ctx.xref:
        def xlink(m):
            word, num = m.group(1), m.group(2)
            target = ctx.xref.get(num)
            if not target:
                return m.group(0)
            return '%s %s' % (word, park('<a class="xref" href="#%s">%s</a>' % (target, num)))
        text = re.sub(r'\b([Ss]ections?)\s+(\d+(?:\.\d+)?)\b', xlink, text)
        text = re.sub(r'\b(see)\s+(\d+\.\d+)\b', xlink, text)
        text = re.sub(r'\b(Appendix)\s+([A-Z])\b', xlink, text)

    # Put the parked pieces back. Repeated, because a parked link can
    # itself hold a parked code span.
    if not outer:
        return text
    for _ in range(3):
        if PLACEHOLDER not in text:
            break
        text = re.sub(PLACEHOLDER + r'(\d+)' + PLACEHOLDER,
                      lambda m: parked[int(m.group(1))], text)
    return text


# ==========================================
# BLOCK PATTERNS
# ==========================================
HEADING_RE = re.compile(r'^(#{1,6})\s+(.*?)\s*#*\s*$')
FENCE_RE = re.compile(r'^\s*```\s*([\w+-]*)\s*$')
HR_RE = re.compile(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$')
LIST_RE = re.compile(r'^( *)([-*+]|\d+\.)(\s+)(.*)$')
TABLE_SEP_RE = re.compile(r'^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?\s*$')
QUOTE_RE = re.compile(r'^\s*>\s?(.*)$')

NUMBERED_H2_RE = re.compile(r'^(\d+)\.\s+(.*)$')
APPENDIX_H2_RE = re.compile(r'^Appendix\s+([A-Z])\s*:\s*(.*)$')
NUMBERED_H3_RE = re.compile(r'^(\d+)\.(\d+)\s+(.*)$')


def starts_block(lines, i):
    """True when line i opens something other than a paragraph."""
    line = lines[i]
    if HEADING_RE.match(line) or FENCE_RE.match(line) or QUOTE_RE.match(line):
        return True
    if LIST_RE.match(line) or HR_RE.match(line):
        return True
    return is_table_start(lines, i)


def is_table_start(lines, i):
    return ('|' in lines[i] and i + 1 < len(lines)
            and TABLE_SEP_RE.match(lines[i + 1]) is not None)


def split_row(line):
    """A table row's cells. Pipes inside code spans and escaped pipes (\\|)
    belong to the cell."""
    s = line.strip()
    if s.startswith('|'):
        s = s[1:]
    if s.endswith('|') and not s.endswith('\\|'):
        s = s[:-1]
    cells, cur, in_code, i = [], '', False, 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s) and s[i + 1] == '|':
            cur += '|'
            i += 2
            continue
        if c == '`':
            in_code = not in_code
        if c == '|' and not in_code:
            cells.append(cur.strip())
            cur = ''
        else:
            cur += c
        i += 1
    cells.append(cur.strip())
    return cells


# ==========================================
# BLOCK RENDERERS
# ==========================================
def render_code(lang, body_lines):
    lang = lang.lower()
    cls = ('language-%s' % lang) if lang else ''
    body = html.escape('\n'.join(body_lines), quote=False)
    return ('<div class="code" data-lang="%s"><button class="copy" type="button">copy</button>'
            '<pre><code class="%s">%s\n</code></pre></div>' % (lang or 'text', cls, body))


def render_table(lines, i, ctx):
    """Header row, alignment row, body rows. Returns (html, next line)."""
    head = split_row(lines[i])
    aligns = []
    for cell in split_row(lines[i + 1]):
        cell = cell.strip()
        if cell.startswith(':') and cell.endswith(':'):
            aligns.append('center')
        elif cell.endswith(':'):
            aligns.append('right')
        else:
            aligns.append(None)
    i += 2
    rows = []
    while i < len(lines) and lines[i].strip() and '|' in lines[i]:
        rows.append(split_row(lines[i]))
        i += 1

    def cell(tag, text, n):
        align = aligns[n] if n < len(aligns) else None
        style = ' style="text-align:%s"' % align if align else ''
        return '<%s%s>%s</%s>' % (tag, style, render_inline(text, ctx), tag)

    out = ['<div class="table-scroll"><table>', '<thead>', '<tr>']
    out += [cell('th', c, n) for n, c in enumerate(head)]
    out += ['</tr>', '</thead>', '<tbody>']
    for r in rows:
        r = (r + [''] * len(head))[:len(head)]   # pad or trim to the header
        out.append('<tr>')
        out += [cell('td', c, n) for n, c in enumerate(r)]
        out.append('</tr>')
    out += ['</tbody>', '</table></div>']
    return '\n'.join(out), i


def render_list(lines, i, ctx):
    """One list, its nested lists inside its items. Items run on through
    lines indented past the marker; a blank line ends the list unless the
    next text is another item or an indented continuation."""
    first = LIST_RE.match(lines[i])
    indent = len(first.group(1))
    ordered = first.group(2)[-1] == '.'
    tag = 'ol' if ordered else 'ul'
    start = int(first.group(2)[:-1]) if ordered else 1
    out = ['<%s%s>' % (tag, ' start="%d"' % start if ordered and start != 1 else '')]

    while i < len(lines):
        m = LIST_RE.match(lines[i])
        if not m or len(m.group(1)) != indent or (m.group(2)[-1] == '.') != ordered:
            break
        text = [m.group(4)]
        children = []
        i += 1
        while i < len(lines):
            line = lines[i]
            if not line.strip():
                j = i
                while j < len(lines) and not lines[j].strip():
                    j += 1
                if j < len(lines):
                    nxt = LIST_RE.match(lines[j])
                    same = (nxt and len(nxt.group(1)) == indent
                            and (nxt.group(2)[-1] == '.') == ordered)
                    deeper = len(lines[j]) - len(lines[j].lstrip(' ')) > indent
                    if same:
                        i = j
                        break
                    if deeper and not nxt:
                        text.append('')
                        i = j
                        continue
                    if deeper and nxt:
                        i = j
                        continue
                i = j
                break
            nested = LIST_RE.match(line)
            if nested and len(nested.group(1)) > indent:
                child, i = render_list(lines, i, ctx)
                children.append(child)
                continue
            if nested or len(line) - len(line.lstrip(' ')) <= indent:
                break
            text.append(line.strip())
            i += 1
        # Paragraph breaks inside an item become <p>s; one paragraph stays bare.
        paras = '\n'.join(text).split('\n\n')
        if len(paras) > 1:
            body = ''.join('<p>%s</p>' % render_inline(p, ctx) for p in paras)
        else:
            body = render_inline(paras[0], ctx)
        out.append('<li>%s%s</li>' % (body, ''.join(children)))
        if i < len(lines) and not lines[i].strip():
            break
    out.append('</%s>' % tag)
    return '\n'.join(out), i


def render_blocks(lines, ctx, page):
    """Everything below a heading level that the page tracks: paragraphs,
    code, tables, lists, quotes, rules. Headings are handed to the page."""
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue

        h = HEADING_RE.match(line)
        if h:
            page.heading(len(h.group(1)), h.group(2), ctx)
            i += 1
            continue

        f = FENCE_RE.match(line)
        if f:
            body = []
            i += 1
            while i < len(lines) and not re.match(r'^\s*```\s*$', lines[i]):
                body.append(lines[i])
                i += 1
            if i >= len(lines):
                ctx.warnings.append('a code block is never closed')
            page.add(render_code(f.group(1), body))
            i += 1
            continue

        if is_table_start(lines, i):
            block, i = render_table(lines, i, ctx)
            page.add(block)
            continue

        if HR_RE.match(line):
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            nxt = HEADING_RE.match(lines[j]) if j < len(lines) else None
            page.rule(before_chapter=(j >= len(lines) or (nxt and len(nxt.group(1)) == 2)))
            i += 1
            continue

        if LIST_RE.match(line):
            block, i = render_list(lines, i, ctx)
            page.add(block)
            continue

        q = QUOTE_RE.match(line)
        if q:
            inner = []
            while i < len(lines) and QUOTE_RE.match(lines[i]):
                inner.append(QUOTE_RE.match(lines[i]).group(1))
                i += 1
            paras = '\n'.join(inner).split('\n\n')
            page.add('<blockquote>%s</blockquote>' % ''.join(
                '<p>%s</p>' % render_inline(p, ctx) for p in paras if p.strip()))
            continue

        # A paragraph: every line up to a blank one or the start of a block.
        para = [line]
        i += 1
        while i < len(lines) and lines[i].strip() and not starts_block(lines, i):
            para.append(lines[i])
            i += 1
        page.add('<p>%s</p>' % render_inline('\n'.join(para), ctx))


# ==========================================
# THE PAGE
# ==========================================
# Collects the article and the rail as the blocks arrive. Each "## "
# heading opens a <section class="chapter">; the filter box shows and
# hides whole chapters, so everything under a chapter heading must sit
# inside its section.

class Page:
    def __init__(self, headings):
        self.headings = headings   # pre-pass results, in document order
        self.cursor = 0
        self.title = None
        self.article = []
        self.rail = []
        self.in_chapter = False
        self.skipping = False
        self.subnav = []

    def add(self, fragment):
        if not self.skipping:
            self.article.append(fragment)

    def close_chapter(self):
        if self.in_chapter:
            self.article.append('</section>')
            self.in_chapter = False
        if self.subnav:
            self.rail.append('<div class="nav-sub">\n%s\n</div>' % '\n'.join(self.subnav))
            self.subnav = []

    def rule(self, before_chapter):
        if self.skipping:
            # The rule after a skipped chapter goes with it.
            if before_chapter:
                self.skipping = False
            return
        if before_chapter:
            self.close_chapter()
        self.article.append('<hr>')

    def heading(self, level, md, ctx):
        info = self.headings[self.cursor]
        self.cursor += 1
        if level == 1:
            if self.title is None:
                self.title = plain_text(md)
                return
        if level == 2:
            self.close_chapter()
            self.skipping = info['skip']
            if self.skipping:
                return
            self.in_chapter = True
            hid, num = info['id'], info['num']
            text = render_inline(info['text'], ctx, xrefs=False)
            nav_n = num if num else '&middot;'
            nav_cls = 'nav-h2' if num else 'nav-h2 unnumbered'
            self.rail.append('<a class="%s" href="#%s" data-target="%s"><span class="n">%s</span>'
                             '<span class="t">%s</span></a>'
                             % (nav_cls, hid, hid, nav_n, html.escape(plain_text(info['text']), quote=False)))
            num_attr = ' data-num="%s"' % num if num else ''
            num_span = '<span class="h-num">%s</span>' % num if num else ''
            self.article.append(
                '<section class="chapter"><h2 id="%s"%s><a class="anchor" href="#%s" '
                'aria-label="Link to this section">#</a>%s<span class="h-text">%s</span></h2>'
                % (hid, num_attr, hid, num_span, text))
            return
        if self.skipping:
            return
        hid, num = info['id'], info['num']
        text = render_inline(info['text'], ctx, xrefs=False)
        if level == 3:
            nav_n = num if num else '&middot;'
            nav_cls = 'nav-h3' if num else 'nav-h3 unnumbered'
            self.subnav.append('<a class="%s" href="#%s" data-target="%s"><span class="n">%s</span>'
                               '<span class="t">%s</span></a>'
                               % (nav_cls, hid, hid, nav_n, html.escape(plain_text(info['text']), quote=False)))
            if num:
                self.add('<h3 id="%s" data-num="%s"><a class="anchor" href="#%s" '
                         'aria-label="Link to this section">#</a><span class="h-num">%s</span>'
                         '<span class="h-text">%s</span></h3>' % (hid, num, hid, num, text))
            else:
                self.add('<h3 id="%s"><a class="anchor" href="#%s" '
                         'aria-label="Link to this heading">#</a>%s</h3>' % (hid, hid, text))
            return
        self.add('<h%d id="%s">%s</h%d>' % (level, hid, text, level))


def index_headings(lines, ctx):
    """First pass: every heading's id and number, so links and section
    references anywhere in the text can point forward as well as back."""
    taken, out, in_fence = set(), [], False
    for line in lines:
        if FENCE_RE.match(line) or re.match(r'^\s*```\s*$', line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = HEADING_RE.match(line)
        if not m:
            continue
        level, md = len(m.group(1)), m.group(2)
        slug = github_slug(md, taken)
        info = {'level': level, 'text': md, 'num': None, 'id': slug, 'skip': False}
        if level == 2:
            n = NUMBERED_H2_RE.match(md)
            a = APPENDIX_H2_RE.match(md)
            if n:
                info.update(num=n.group(1), text=n.group(2), id='sec-%s' % n.group(1))
            elif a:
                info.update(num=a.group(1), text=a.group(2)[:1].upper() + a.group(2)[1:],
                            id='appendix-%s' % a.group(1).lower())
            info['skip'] = plain_text(md).lower() in SKIPPED_CHAPTERS
        elif level == 3:
            n = NUMBERED_H3_RE.match(md)
            if n:
                info.update(num='%s.%s' % (n.group(1), n.group(2)), text=n.group(3),
                            id='sec-%s-%s' % (n.group(1), n.group(2)))
        ctx.slug_to_id[slug] = info['id']
        ctx.slug_to_id[info['id']] = info['id']
        if info['num'] and level in (2, 3) and not info['skip']:
            ctx.xref[info['num']] = info['id']
        out.append(info)
    return out


# ==========================================
# OUTPUT
# ==========================================
PAGE_TEMPLATE = '''<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<!-- Generated from {source} by rm-docs-html.py. Edit the .md and run the
     script again; changes made to this file are lost on the next run. -->
<style>
{css}
</style>
</head>
<body>

<aside class="rail" id="rail">
  <div class="rail-head">
    <span class="kicker">{kicker}</span>
    <h1>{title}</h1>
    <p>{subtitle}</p>
  </div>
  <nav class="rail-nav">
{nav}
  </nav>
</aside>

<main>
  <div class="toolbar">
    <button class="tool-btn rail-toggle" id="railToggle" type="button"
            aria-label="Toggle contents">Contents</button>
    <div class="search-wrap">
      <input id="search" type="search" autocomplete="off" spellcheck="false"
             placeholder="Filter the guide" aria-label="Filter the guide">
      <span class="kbd">/</span>
    </div>
    <span id="hits" role="status" aria-live="polite"></span>
    <button class="tool-btn" id="themeBtn" type="button">Dark</button>
  </div>

  <article id="doc">
{article}
  </article>
</main>

<script>
{js}
</script>
</body>
</html>
'''


def convert(md_text, source_name, kicker, subtitle):
    lines = md_text.replace('\r\n', '\n').replace('\r', '\n').lstrip('\ufeff').split('\n')
    ctx = Context()
    headings = index_headings(lines, ctx)
    page = Page(headings)
    render_blocks(lines, ctx, page)
    page.close_chapter()
    title = page.title or Path(source_name).stem
    out = PAGE_TEMPLATE.format(
        title=html.escape(title, quote=False),
        source=html.escape(source_name, quote=False),
        css=CSS, js=JS,
        kicker=html.escape(kicker, quote=False),
        subtitle=html.escape(subtitle, quote=False),
        nav='\n'.join(page.rail),
        article='\n'.join(page.article))
    stats = {'chapters': sum(1 for h in headings if h['level'] == 2 and not h['skip']),
             'headings': len(headings),
             'tables': out.count('<table>'),
             'code blocks': out.count('<div class="code"'),
             'cross-references': out.count('class="xref"')}
    return out, stats, ctx.warnings


def main(argv=None):
    ap = argparse.ArgumentParser(description='Write the HTML page for an RM Markdown guide.')
    ap.add_argument('input', nargs='?', help='the .md file (default: %s)' % DEFAULT_INPUT)
    ap.add_argument('output', nargs='?', help='the .html file (default: beside the input)')
    ap.add_argument('--kicker', default=DEFAULT_KICKER, help='line above the title in the rail')
    ap.add_argument('--subtitle', default=DEFAULT_SUBTITLE, help='line under the title in the rail')
    args = ap.parse_args(argv)

    # Find the input: as given, else beside this script, else here.
    if args.input:
        src = Path(args.input)
    else:
        here = Path(__file__).resolve().parent / DEFAULT_INPUT
        src = here if here.exists() else Path(DEFAULT_INPUT)
    if not src.exists():
        print('No such file: %s' % src, file=sys.stderr)
        return 1
    dst = Path(args.output) if args.output else src.with_suffix('.html')

    page, stats, warnings = convert(src.read_text(encoding='utf-8'), src.name,
                                    args.kicker, args.subtitle)
    with open(dst, 'w', encoding='utf-8', newline='\n') as f:
        f.write(page)

    print('Wrote %s from %s: %s.' % (dst, src.name,
          ', '.join('%d %s' % (v, k) for k, v in stats.items())))
    for w in dict.fromkeys(warnings):   # each warning once, in order
        print('  warning: %s' % w)
    return 0


# ==========================================
# THE PAGE'S LOOK AND BEHAVIOUR
# ==========================================
# Kept exactly as the hand-made page had them. CSS: the Dwarf Fortress
# palette, the rail, the code blocks, the tables. JS: the scroll spy that
# lights the rail, the filter box, the copy buttons, the theme switch and
# the mobile rail. Session-only: the page stores nothing.

CSS = r''':root {
  --paper:      #e6e7e2;
  --surface:    #f2f3ef;
  --surface-2:  #dcded7;
  --ink:        #16181a;
  --ink-soft:   #565c63;
  --ink-faint:  #858b91;
  --rule:       #c6c9c1;
  --rule-soft:  #d6d8d1;

  /* Dwarf Fortress 16-colour palette, used semantically */
  --df-cyan:    #00696b;
  --df-red:     #8c1010;
  --df-green:   #14631f;
  --df-brown:   #6f5d00;
  --df-blue:    #1b2a72;

  --mono: ui-monospace, "SFMono-Regular", "SF Mono", "Cascadia Mono",
          "Roboto Mono", Menlo, Consolas, "Liberation Mono", monospace;
  --body: "Iowan Old Style", "Palatino Linotype", Palatino, Charter,
          "Bitstream Charter", Georgia, "Times New Roman", serif;

  --rail: 300px;
  --measure: 74ch;
}

html[data-theme="dark"] {
  --paper:      #16181a;
  --surface:    #1e2124;
  --surface-2:  #2a2e32;
  --ink:        #e4e6e1;
  --ink-soft:   #a3a9ae;
  --ink-faint:  #767c82;
  --rule:       #343a3f;
  --rule-soft:  #272c30;

  --df-cyan:    #4fd6d8;
  --df-red:     #f08a7a;
  --df-green:   #79cc7f;
  --df-brown:   #d6bc4a;
  --df-blue:    #8fa8f5;
}

* { box-sizing: border-box; }

html { scroll-behavior: smooth; scroll-padding-top: 1.5rem; }
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
  * { animation: none !important; transition: none !important; }
}

body {
  margin: 0;
  background: var(--paper);
  color: var(--ink);
  font-family: var(--body);
  font-size: 17px;
  line-height: 1.65;
  -webkit-font-smoothing: antialiased;
}

/* ---------- LEFT RAIL ---------- */

.rail {
  position: fixed;
  top: 0; left: 0; bottom: 0;
  width: var(--rail);
  background: var(--surface);
  border-right: 1px solid var(--rule);
  display: flex;
  flex-direction: column;
  z-index: 20;
}

.rail-head {
  padding: 1.6rem 1.5rem 1.1rem;
  border-bottom: 1px solid var(--rule);
}

.rail-head .kicker {
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.18em;
  text-transform: uppercase;
  color: var(--df-cyan);
  display: block;
  margin-bottom: 0.5rem;
}

.rail-head h1 {
  font-family: var(--mono);
  font-size: 17px;
  font-weight: 700;
  letter-spacing: -0.01em;
  line-height: 1.3;
  margin: 0 0 0.45rem;
}

.rail-head p {
  margin: 0;
  font-family: var(--mono);
  font-size: 11.5px;
  line-height: 1.5;
  color: var(--ink-faint);
}

.rail-nav {
  flex: 1;
  overflow-y: auto;
  padding: 0.9rem 0 2.5rem;
  scrollbar-width: thin;
}

.rail-nav a {
  display: flex;
  gap: 0.7rem;
  text-decoration: none;
  color: var(--ink-soft);
  font-family: var(--mono);
  border-left: 2px solid transparent;
}

.nav-h2 {
  padding: 0.5rem 1.5rem 0.5rem 1.4rem;
  font-size: 13px;
  font-weight: 700;
  color: var(--ink) !important;
  margin-top: 0.35rem;
}

.nav-h3 {
  padding: 0.28rem 1.5rem 0.28rem 2.5rem;
  font-size: 12px;
}

.rail-nav a .n {
  color: var(--ink-faint);
  font-variant-numeric: tabular-nums;
  flex: none;
  min-width: 1.9em;
}

.nav-h2 .n { color: var(--df-cyan); }

.rail-nav a:hover {
  background: var(--surface-2);
  color: var(--ink) !important;
}

.rail-nav a.active {
  border-left-color: var(--df-cyan);
  background: var(--surface-2);
  color: var(--ink) !important;
}

.rail-nav a.active .n { color: var(--df-cyan); }

.rail-nav a.dim { opacity: 0.28; }

.rail-nav a.unnumbered .n { color: var(--ink-faint); opacity: 0.55; }

.nav-sub { margin-bottom: 0.2rem; }

/* ---------- TOOLBAR ---------- */

.toolbar {
  position: sticky;
  top: 0;
  z-index: 15;
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.8rem 0;
  margin-bottom: 1.5rem;
  background: linear-gradient(var(--paper) 72%, transparent);
}

.search-wrap { position: relative; flex: 1; max-width: 30rem; }

#search {
  width: 100%;
  font-family: var(--mono);
  font-size: 13px;
  color: var(--ink);
  background: var(--surface);
  border: 1px solid var(--rule);
  border-radius: 2px;
  padding: 0.55rem 3.6rem 0.55rem 0.75rem;
}

#search::placeholder { color: var(--ink-faint); }

#search:focus {
  outline: 2px solid var(--df-cyan);
  outline-offset: -1px;
}

.kbd {
  position: absolute;
  right: 0.5rem; top: 50%;
  transform: translateY(-50%);
  font-family: var(--mono);
  font-size: 10px;
  color: var(--ink-faint);
  border: 1px solid var(--rule);
  border-radius: 2px;
  padding: 0.1rem 0.32rem;
  pointer-events: none;
  background: var(--paper);
}

.tool-btn {
  font-family: var(--mono);
  font-size: 11px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--ink-soft);
  background: var(--surface);
  border: 1px solid var(--rule);
  border-radius: 2px;
  padding: 0.5rem 0.7rem;
  cursor: pointer;
}

.tool-btn:hover { color: var(--ink); border-color: var(--ink-faint); }
.tool-btn:focus-visible { outline: 2px solid var(--df-cyan); outline-offset: 1px; }

#hits {
  font-family: var(--mono);
  font-size: 11.5px;
  color: var(--ink-faint);
  white-space: nowrap;
}

/* ---------- MAIN ---------- */

main {
  margin-left: var(--rail);
  padding: 0 3.5rem 8rem;
  max-width: calc(var(--rail) + 62rem);
}

.chapter.hidden { display: none; }

article > hr {
  border: 0;
  border-top: 1px solid var(--rule-soft);
  margin: 3rem 0;
}

h2, h3 { position: relative; font-family: var(--mono); }

h2 {
  font-size: 26px;
  font-weight: 700;
  letter-spacing: -0.02em;
  line-height: 1.2;
  margin: 3.4rem 0 1.4rem;
  padding-bottom: 0.7rem;
  border-bottom: 2px solid var(--ink);
  display: flex;
  align-items: baseline;
  gap: 0.85rem;
}

h3 {
  font-size: 16.5px;
  font-weight: 700;
  letter-spacing: -0.01em;
  margin: 2.6rem 0 0.9rem;
  display: flex;
  align-items: baseline;
  gap: 0.7rem;
}

h2 .h-num {
  color: var(--df-cyan);
  font-variant-numeric: tabular-nums;
  flex: none;
}

h3 .h-num {
  color: var(--df-cyan);
  font-size: 13px;
  font-variant-numeric: tabular-nums;
  flex: none;
  min-width: 2.6em;
}

h4 {
  font-family: var(--mono);
  font-size: 14px;
  margin: 2rem 0 0.7rem;
}

.anchor {
  position: absolute;
  left: -1.5rem;
  color: var(--ink-faint);
  text-decoration: none;
  opacity: 0;
  font-weight: 400;
}

h2:hover .anchor, h3:hover .anchor,
.anchor:focus-visible { opacity: 1; }

p, li { max-width: var(--measure); }

p { margin: 0 0 1.1rem; }

ul, ol { padding-left: 1.3rem; margin: 0 0 1.2rem; }
li { margin-bottom: 0.5rem; }
li > p { margin-bottom: 0.5rem; }

strong { font-weight: 700; color: var(--ink); }

a { color: var(--df-cyan); text-decoration-thickness: 1px; text-underline-offset: 2px; }
a:hover { color: var(--ink); }

/* Cross-references: the reason this document is worth reading in a
   browser. Marked so they read as navigation, not emphasis. */
.xref {
  font-family: var(--mono);
  font-size: 0.88em;
  font-variant-numeric: tabular-nums;
  color: var(--df-cyan);
  text-decoration: none;
  border-bottom: 1px dashed currentColor;
  padding-bottom: 1px;
}

.xref:hover { color: var(--ink); border-bottom-style: solid; }

:target { animation: flash 1.4s ease-out; }
@keyframes flash {
  from { background: color-mix(in srgb, var(--df-cyan) 22%, transparent); }
  to   { background: transparent; }
}

/* ---------- CODE ---------- */

code {
  font-family: var(--mono);
  font-size: 0.855em;
  background: var(--surface-2);
  padding: 0.1em 0.34em;
  border-radius: 2px;
  word-break: break-word;
}

.code {
  position: relative;
  margin: 0 0 1.4rem;
  background: var(--surface);
  border: 1px solid var(--rule);
  border-left: 3px solid var(--df-blue);
  border-radius: 2px;
}

.code::before {
  content: attr(data-lang);
  position: absolute;
  top: 0.45rem; left: 0.85rem;
  font-family: var(--mono);
  font-size: 9.5px;
  letter-spacing: 0.16em;
  text-transform: uppercase;
  color: var(--ink-faint);
}

.code pre {
  margin: 0;
  padding: 2rem 1rem 1rem;
  overflow-x: auto;
}

.code code {
  background: none;
  padding: 0;
  font-size: 13px;
  line-height: 1.6;
  color: var(--ink);
}

.copy {
  position: absolute;
  top: 0.3rem; right: 0.35rem;
  font-family: var(--mono);
  font-size: 10px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--ink-faint);
  background: var(--surface);
  border: 1px solid var(--rule);
  border-radius: 2px;
  padding: 0.2rem 0.45rem;
  cursor: pointer;
  opacity: 0;
}

.code:hover .copy, .copy:focus-visible { opacity: 1; }
.copy:hover { color: var(--ink); border-color: var(--ink-faint); }
.copy.done { color: var(--df-green); border-color: var(--df-green); opacity: 1; }

/* ---------- TABLES ---------- */

.table-scroll { overflow-x: auto; margin: 0 0 1.5rem; }

table {
  border-collapse: collapse;
  font-family: var(--mono);
  font-size: 12.5px;
  line-height: 1.5;
  width: 100%;
  min-width: 32rem;
}

th {
  text-align: left;
  font-weight: 700;
  font-size: 10px;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  color: var(--ink-soft);
  border-bottom: 1.5px solid var(--ink);
  padding: 0.5rem 0.9rem 0.5rem 0;
  white-space: nowrap;
}

td {
  border-bottom: 1px solid var(--rule-soft);
  padding: 0.5rem 0.9rem 0.5rem 0;
  vertical-align: top;
}

tbody tr:hover td { background: var(--surface); }

td code { background: none; padding: 0; color: var(--df-blue); font-weight: 600; }

table td:first-child { white-space: nowrap; }

/* ---------- SEARCH HIGHLIGHT ---------- */

mark {
  background: color-mix(in srgb, var(--df-brown) 34%, transparent);
  color: inherit;
  border-radius: 1px;
  padding: 0 1px;
}

/* ---------- RESPONSIVE ---------- */

.rail-toggle { display: none; }

@media (max-width: 1080px) {
  :root { --rail: 260px; }
  main { padding: 0 2rem 6rem; }
}

@media (max-width: 860px) {
  .rail {
    transform: translateX(-100%);
    transition: transform 0.2s ease;
    width: 280px;
  }
  .rail.open { transform: none; box-shadow: 0 0 40px rgba(0,0,0,0.25); }
  main { margin-left: 0; padding: 0 1.15rem 5rem; }
  .rail-toggle { display: inline-block; }
  body { font-size: 16px; }
  h2 { font-size: 22px; }
  .toolbar { flex-wrap: wrap; }
  #hits { order: 3; width: 100%; }
}

/* ---------- PRINT ---------- */

@media print {
  .rail, .toolbar, .copy, .anchor { display: none !important; }
  main { margin: 0; padding: 0; max-width: none; }
  body { background: #fff; color: #000; font-size: 10.5pt; }
  .code { break-inside: avoid; }
  h2, h3 { break-after: avoid; }
  a { color: #000; }
}'''

JS = r'''(function () {
  "use strict";

  var doc      = document.getElementById('doc');
  var search   = document.getElementById('search');
  var hits     = document.getElementById('hits');
  var rail     = document.getElementById('rail');
  var navLinks = Array.prototype.slice.call(
                   document.querySelectorAll('.rail-nav a'));
  var chapters = Array.prototype.slice.call(
                   document.querySelectorAll('.chapter'));

  /* ---------- SCROLL SPY ----------
     Highlights the deepest heading currently at or above the reading
     line, so the rail always shows where you are.

     headings MUST be re-queried after any innerHTML rebuild. The filter
     replaces whole chapters, which detaches the old heading nodes, and a
     detached node reports offsetTop 0 -- every heading then compares as
     "above the line" and the spy locks onto the last section forever. */
  var headings = [];

  function refreshHeadings() {
    headings = Array.prototype.slice.call(doc.querySelectorAll('h2, h3'))
                 .filter(function (h) { return h.id; });
  }
  refreshHeadings();

  function spy() {
    if (search.value) return;
    var line = window.scrollY + 120;
    var current = null;
    for (var i = 0; i < headings.length; i++) {
      if (headings[i].offsetTop <= line) current = headings[i].id;
      else break;
    }
    navLinks.forEach(function (a) {
      a.classList.toggle('active', a.dataset.target === current);
    });
  }

  var ticking = false;
  window.addEventListener('scroll', function () {
    if (ticking) return;
    ticking = true;
    window.requestAnimationFrame(function () { spy(); ticking = false; });
  }, { passive: true });
  spy();

  /* ---------- FILTER ----------
     Hides whole chapters that do not match and marks every hit inside
     the ones that do. Restores the original markup on clear, so the
     document is never permanently altered. */
  var originals = chapters.map(function (c) { return c.innerHTML; });

  function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

  function clearFilter() {
    chapters.forEach(function (c, i) {
      c.innerHTML = originals[i];
      c.classList.remove('hidden');
    });
    navLinks.forEach(function (a) { a.classList.remove('dim'); });
    hits.textContent = '';
    refreshHeadings();
    wireCopy();
    spy();
  }

  function applyFilter(term) {
    var re = new RegExp(escapeRe(term), 'gi');
    var shown = 0, total = 0;
    var visibleIds = {};

    chapters.forEach(function (c, i) {
      c.innerHTML = originals[i];
      var text = c.textContent;
      var found = text.match(re);
      if (!found) {
        c.classList.add('hidden');
        return;
      }
      c.classList.remove('hidden');
      shown++;
      total += found.length;
      highlight(c, re);
      Array.prototype.forEach.call(c.querySelectorAll('h2, h3'),
        function (h) { visibleIds[h.id] = true; });
    });

    navLinks.forEach(function (a) {
      a.classList.remove('active');
      a.classList.toggle('dim', !visibleIds[a.dataset.target]);
    });

    hits.textContent = total
      ? total + ' match' + (total === 1 ? '' : 'es') +
        ' in ' + shown + ' section' + (shown === 1 ? '' : 's')
      : 'No matches';
    refreshHeadings();
    wireCopy();
  }

  /* Walks text nodes only, so highlighting can never break markup. */
  function highlight(root, re) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var nodes = [], n;
    while ((n = walker.nextNode())) {
      if (n.parentNode.nodeName === 'BUTTON') continue;
      if (re.test(n.nodeValue)) nodes.push(n);
      re.lastIndex = 0;
    }
    nodes.forEach(function (node) {
      var span = document.createElement('span');
      span.innerHTML = node.nodeValue.replace(/[&<>]/g, function (ch) {
        return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[ch];
      }).replace(re, '<mark>$&</mark>');
      node.parentNode.replaceChild(span, node);
    });
  }

  var timer;
  search.addEventListener('input', function () {
    clearTimeout(timer);
    var term = search.value.trim();
    timer = setTimeout(function () {
      if (term.length < 2) clearFilter();
      else applyFilter(term);
    }, 120);
  });

  /* ---------- KEYBOARD ---------- */
  document.addEventListener('keydown', function (e) {
    if (e.key === '/' && document.activeElement !== search) {
      e.preventDefault();
      search.focus();
      search.select();
    } else if (e.key === 'Escape' && document.activeElement === search) {
      search.value = '';
      clearFilter();
      search.blur();
    }
  });

  /* ---------- COPY BUTTONS ---------- */
  function wireCopy() {
    Array.prototype.forEach.call(doc.querySelectorAll('.copy'),
      function (btn) {
        if (btn.dataset.wired) return;
        btn.dataset.wired = '1';
        btn.addEventListener('click', function () {
          var code = btn.parentNode.querySelector('code');
          var text = code ? code.textContent : '';
          var done = function () {
            btn.textContent = 'copied';
            btn.classList.add('done');
            setTimeout(function () {
              btn.textContent = 'copy';
              btn.classList.remove('done');
            }, 1400);
          };
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(done, fallback);
          } else fallback();

          function fallback() {
            var ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            try { document.execCommand('copy'); done(); } catch (err) {}
            document.body.removeChild(ta);
          }
        });
      });
  }
  wireCopy();

  /* ---------- THEME ----------
     Session-only. No storage, so the file stays inert on disk. */
  var themeBtn = document.getElementById('themeBtn');
  themeBtn.addEventListener('click', function () {
    var dark = document.documentElement.dataset.theme === 'dark';
    document.documentElement.dataset.theme = dark ? 'light' : 'dark';
    themeBtn.textContent = dark ? 'Dark' : 'Light';
  });

  /* ---------- MOBILE RAIL ---------- */
  var toggle = document.getElementById('railToggle');
  toggle.addEventListener('click', function () { rail.classList.toggle('open'); });
  rail.addEventListener('click', function (e) {
    if (e.target.closest('a')) rail.classList.remove('open');
  });
})();'''


if __name__ == '__main__':
    sys.exit(main())
