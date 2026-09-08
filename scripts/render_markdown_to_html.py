#!/usr/bin/env python3
"""
render_markdown_to_html.py

Processes Markdown files:
1. Adds trailing double spaces to lines that break within paragraphs/lists so they render properly.
2. Converts Markdown to standalone, publication-quality HTML files with:
   - GitHub-style CSS and dark/light mode support
   - MathJax support for LaTeX math formulas
   - Responsive floating Table of Contents / Index (sticky sidebar with ScrollSpy active section highlight)
"""

import os
import re
import html
import sys

def add_trailing_double_spaces(md_content):
    """
    Adds two spaces to the end of lines that wrap to the next line,
    excluding code blocks, headings, empty lines, table rows, and horizontal rules.
    """
    lines = md_content.split('\n')
    processed_lines = []
    in_code_block = False
    
    for i, line in enumerate(lines):
        stripped = line.strip()
        
        # Track fenced code blocks
        if stripped.startswith('```'):
            in_code_block = not in_code_block
            processed_lines.append(line.rstrip())
            continue
            
        if in_code_block:
            processed_lines.append(line)
            continue
            
        # Skip empty lines, headings, horizontal rules, and table rows
        if (not stripped or 
            stripped.startswith('#') or 
            stripped in ('---', '***', '___') or 
            (stripped.startswith('|') and stripped.endswith('|'))):
            processed_lines.append(line.rstrip())
            continue
            
        # Add trailing double spaces if not already ending in 2+ spaces
        r_stripped = line.rstrip()
        processed_lines.append(r_stripped + '  ')
        
    return '\n'.join(processed_lines)


def parse_inline_elements(text):
    """
    Parses inline markdown: math, code spans, images, links, bold, italics, and line breaks.
    Uses safe non-alphanumeric sentinels to avoid collision with formatting regex.
    """
    code_spans = []
    def save_code(match):
        idx = len(code_spans)
        code_spans.append(html.escape(match.group(1)))
        return f"\x00CODE{idx}\x00"
    text = re.sub(r'`([^`]+)`', save_code, text)
    
    math_spans = []
    def save_math(match):
        idx = len(math_spans)
        math_spans.append(match.group(0))
        return f"\x00MATH{idx}\x00"
    text = re.sub(r'(?<!\\)\$([^\$]+?)\$', save_math, text)
    
    # Images: ![alt](url)
    text = re.sub(r'!\[(.*?)\]\((.*?)\)', r'<img src="\2" alt="\1" style="max-width: 100%; height: auto; vertical-align: middle;" />', text)
    
    # Links: [text](url)
    def format_link(match):
        link_text = match.group(1)
        href = match.group(2)
        if href.endswith('.md'):
            href = href[:-3] + '.html'
        return f'<a href="{html.escape(href)}">{link_text}</a>'
    text = re.sub(r'\[(.*?)\]\((.*?)\)', format_link, text)
    
    # Bold & Italic (using standard GFM boundaries)
    text = re.sub(r'\*\*\*(.*?)\*\*\*', r'<strong><em>\1</em></strong>', text)
    text = re.sub(r'\*\*(.*?)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'__(.*?)__', r'<strong>\1</strong>', text)
    text = re.sub(r'(?<!\w)\*([^\*]+)\*(?!\w)', r'<em>\1</em>', text)
    text = re.sub(r'(?<!\w)_([^_]+)_(?!\w)', r'<em>\1</em>', text)
    
    # Hard break for trailing double spaces
    if text.endswith('  '):
        text = text[:-2] + '<br />'
        
    # Restore code
    for idx, code_content in enumerate(code_spans):
        text = text.replace(f"\x00CODE{idx}\x00", f'<code>{code_content}</code>')
        
    # Restore math
    for idx, math_content in enumerate(math_spans):
        text = text.replace(f"\x00MATH{idx}\x00", math_content)
        
    return text


def convert_markdown_to_html(md_content, title="Documentation"):
    """
    Converts full markdown document to HTML with GitHub styling and a floating Table of Contents.
    """
    lines = md_content.split('\n')
    html_out = []
    headings = []
    seen_ids = set()
    
    i = 0
    n = len(lines)
    
    in_list = False
    list_type = None  # 'ul' or 'ol'
    in_blockquote = False
    
    while i < n:
        line = lines[i]
        stripped = line.strip()
        
        # 1. Blank line -> close open lists and blockquotes
        if not stripped:
            if in_list:
                html_out.append(f"</{list_type}>")
                in_list = False
                list_type = None
            if in_blockquote:
                html_out.append("</blockquote>")
                in_blockquote = False
            i += 1
            continue
            
        # 2. Math display block: $$ ... $$
        if stripped.startswith('$$'):
            if in_list:
                html_out.append(f"</{list_type}>")
                in_list = False
            if in_blockquote:
                html_out.append("</blockquote>")
                in_blockquote = False
                
            math_lines = [line]
            if stripped == '$$' or (stripped.startswith('$$') and not (len(stripped) > 2 and stripped.endswith('$$'))):
                i += 1
                while i < n and not lines[i].strip().endswith('$$'):
                    math_lines.append(lines[i])
                    i += 1
                if i < n:
                    math_lines.append(lines[i])
            html_out.append(f'<div class="math-display">\n' + '\n'.join(math_lines) + '\n</div>')
            i += 1
            continue
            
        # 3. Fenced Code Block: ```lang ... ```
        if stripped.startswith('```'):
            if in_list:
                html_out.append(f"</{list_type}>")
                in_list = False
            if in_blockquote:
                html_out.append("</blockquote>")
                in_blockquote = False
                
            lang = stripped[3:].strip()
            code_lines = []
            i += 1
            while i < n and not lines[i].strip().startswith('```'):
                code_lines.append(lines[i])
                i += 1
                
            code_text = html.escape('\n'.join(code_lines))
            lang_class = f' class="language-{lang}"' if lang else ''
            html_out.append(f'<pre><code{lang_class}>{code_text}</code></pre>')
            i += 1
            continue
            
        # 4. Horizontal Rule
        if stripped in ('---', '***', '___'):
            if in_list:
                html_out.append(f"</{list_type}>")
                in_list = False
            if in_blockquote:
                html_out.append("</blockquote>")
                in_blockquote = False
            html_out.append('<hr />')
            i += 1
            continue
            
        # 5. Headings: #, ##, ###, ####
        heading_match = re.match(r'^(#{1,6})\s+(.*)$', stripped)
        if heading_match:
            if in_list:
                html_out.append(f"</{list_type}>")
                in_list = False
            if in_blockquote:
                html_out.append("</blockquote>")
                in_blockquote = False
                
            level = len(heading_match.group(1))
            heading_text = heading_match.group(2)
            
            # Clean anchor id
            clean_text = re.sub(r'[*_`]', '', heading_text).strip()
            anchor_id = re.sub(r'[^a-zA-Z0-9\-_]', '', clean_text.lower().replace(' ', '-'))
            if not anchor_id:
                anchor_id = f"section-{len(headings) + 1}"
            base_id = anchor_id
            counter = 1
            while anchor_id in seen_ids:
                anchor_id = f"{base_id}-{counter}"
                counter += 1
            seen_ids.add(anchor_id)
            
            if level in (1, 2, 3, 4):
                headings.append({
                    'level': level,
                    'title': clean_text,
                    'id': anchor_id
                })
                
            html_out.append(f'<h{level} id="{anchor_id}">{parse_inline_elements(heading_text)}</h{level}>')
            i += 1
            continue
            
        # 6. Table: | ... |
        if stripped.startswith('|') and stripped.endswith('|'):
            if in_list:
                html_out.append(f"</{list_type}>")
                in_list = False
            if in_blockquote:
                html_out.append("</blockquote>")
                in_blockquote = False
                
            table_lines = []
            while i < n and lines[i].strip().startswith('|') and lines[i].strip().endswith('|'):
                table_lines.append(lines[i].strip())
                i += 1
                
            if len(table_lines) >= 2 and re.match(r'^\|[\s:\-\|]+\|$', table_lines[1]):
                header_cells = [c.strip() for c in table_lines[0][1:-1].split('|')]
                align_cells = [c.strip() for c in table_lines[1][1:-1].split('|')]
                
                alignments = []
                for ac in align_cells:
                    if ac.startswith(':') and ac.endswith(':'):
                        alignments.append('center')
                    elif ac.endswith(':'):
                        alignments.append('right')
                    else:
                        alignments.append('left')
                        
                table_html = ['<table>', '<thead>', '<tr>']
                for idx, hc in enumerate(header_cells):
                    align = alignments[idx] if idx < len(alignments) else 'left'
                    table_html.append(f'<th style="text-align: {align};">{parse_inline_elements(hc)}</th>')
                table_html.extend(['</tr>', '</thead>', '<tbody>'])
                
                for row_line in table_lines[2:]:
                    row_cells = [c.strip() for c in row_line[1:-1].split('|')]
                    table_html.append('<tr>')
                    for idx, rc in enumerate(row_cells):
                        align = alignments[idx] if idx < len(alignments) else 'left'
                        table_html.append(f'<td style="text-align: {align};">{parse_inline_elements(rc)}</td>')
                    table_html.append('</tr>')
                    
                table_html.extend(['</tbody>', '</table>'])
                html_out.append('\n'.join(table_html))
            else:
                for tl in table_lines:
                    html_out.append(f'<p>{parse_inline_elements(tl)}</p>')
            continue
            
        # 7. Blockquote: > ...
        if stripped.startswith('>'):
            if in_list:
                html_out.append(f"</{list_type}>")
                in_list = False
            if not in_blockquote:
                html_out.append('<blockquote>')
                in_blockquote = True
                
            quote_text = stripped[1:].strip()
            html_out.append(f'<p>{parse_inline_elements(quote_text)}</p>')
            i += 1
            continue
            
        # 8. Unordered List: * or -
        ul_match = re.match(r'^(\*|-)\s+(.*)$', stripped)
        if ul_match:
            if in_blockquote:
                html_out.append("</blockquote>")
                in_blockquote = False
            if not in_list or list_type != 'ul':
                if in_list:
                    html_out.append(f"</{list_type}>")
                html_out.append('<ul>')
                in_list = True
                list_type = 'ul'
                
            item_text = ul_match.group(2)
            html_out.append(f'<li>{parse_inline_elements(item_text)}</li>')
            i += 1
            continue
            
        # 9. Ordered List: 1. or 2.
        ol_match = re.match(r'^(\d+)\.\s+(.*)$', stripped)
        if ol_match:
            if in_blockquote:
                html_out.append("</blockquote>")
                in_blockquote = False
            if not in_list or list_type != 'ol':
                if in_list:
                    html_out.append(f"</{list_type}>")
                html_out.append('<ol>')
                in_list = True
                list_type = 'ol'
                
            item_text = ol_match.group(2)
            html_out.append(f'<li>{parse_inline_elements(item_text)}</li>')
            i += 1
            continue
            
        # 10. Regular Paragraph
        if in_list:
            html_out.append(f"</{list_type}>")
            in_list = False
        if in_blockquote:
            html_out.append("</blockquote>")
            in_blockquote = False
            
        para_lines = []
        while i < n and lines[i].strip() and not lines[i].strip().startswith(('#', '```', '---', '***', '___', '|', '>', '* ', '- ', '1. ', '2. ', '3. ', '$$')):
            para_lines.append(lines[i])
            i += 1
            
        para_content = ' '.join([parse_inline_elements(pl) for pl in para_lines])
        html_out.append(f'<p>{para_content}</p>')
        
    # Close any trailing open tags
    if in_list:
        html_out.append(f"</{list_type}>")
    if in_blockquote:
        html_out.append("</blockquote>")
        
    body_content = '\n'.join(html_out)
    
    # Build Floating Table of Contents / Index
    toc_items = []
    for h in headings:
        # Indent and style based on level
        item_class = f"toc-item toc-h{h['level']}"
        title_escaped = html.escape(h['title'])
        toc_items.append(f'<li class="{item_class}"><a href="#{h["id"]}">{title_escaped}</a></li>')
        
    toc_html = ""
    if toc_items:
        toc_html = f"""
    <aside class="floating-toc" id="floating-toc" aria-label="Table of contents">
        <div class="toc-header">
            <span class="toc-title">Index</span>
        </div>
        <ul class="toc-list">
            {'\n            '.join(toc_items)}
        </ul>
        <div class="toc-footer">
            <a href="#top" class="back-to-top">↑ Back to Top</a>
        </div>
    </aside>"""

    # Full HTML Template with GitHub styling, responsive floating TOC, and MathJax
    full_html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{html.escape(title)}</title>
    <!-- MathJax for LaTeX Math Formulas -->
    <script>
    MathJax = {{
      tex: {{
        inlineMath: [['$', '$']],
        displayMath: [['$$', '$$']]
      }}
    }};
    </script>
    <script id="MathJax-script" async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"></script>
    <style>
        :root {{
            --color-canvas-default: #ffffff;
            --color-canvas-subtle: #f6f8fa;
            --color-border-default: #d0d7de;
            --color-border-muted: #d8dee4;
            --color-fg-default: #1f2328;
            --color-fg-muted: #656d76;
            --color-accent-fg: #0969da;
            --color-neutral-muted: rgba(175, 184, 193, 0.2);
        }}
        @media (prefers-color-scheme: dark) {{
            :root {{
                --color-canvas-default: #0d1117;
                --color-canvas-subtle: #161b22;
                --color-border-default: #30363d;
                --color-border-muted: #21262d;
                --color-fg-default: #e6edf3;
                --color-fg-muted: #848d97;
                --color-accent-fg: #4493f8;
                --color-neutral-muted: rgba(110, 118, 129, 0.4);
            }}
        }}
        html {{
            scroll-behavior: smooth;
        }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
            font-size: 16px;
            line-height: 1.6;
            color: var(--color-fg-default);
            background-color: var(--color-canvas-default);
            margin: 0;
            padding: 0;
        }}
        .page-container {{
            display: flex;
            justify-content: center;
            align-items: flex-start;
            gap: 28px;
            max-width: 1380px;
            margin: 0 auto;
            padding: 24px 20px;
            box-sizing: border-box;
        }}
        /* Floating Index / TOC Sidebar */
        .floating-toc {{
            position: sticky;
            top: 24px;
            width: 280px;
            min-width: 240px;
            max-height: calc(100vh - 48px);
            overflow-y: auto;
            padding: 18px 16px;
            background-color: var(--color-canvas-subtle);
            border: 1px solid var(--color-border-default);
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0, 0, 0, 0.04);
            font-size: 13px;
            line-height: 1.45;
            flex-shrink: 0;
            box-sizing: border-box;
        }}
        .toc-header {{
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding-bottom: 8px;
            margin-bottom: 10px;
            border-bottom: 1px solid var(--color-border-muted);
        }}
        .toc-title {{
            font-weight: 700;
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: var(--color-fg-muted);
        }}
        .toc-list {{
            list-style: none;
            padding: 0;
            margin: 0;
        }}
        .toc-item {{
            margin: 3px 0;
        }}
        .toc-item.toc-h1 {{
            font-weight: 700;
            margin-top: 8px;
        }}
        .toc-item.toc-h2 {{
            font-weight: 600;
            padding-left: 6px;
        }}
        .toc-item.toc-h3 {{
            font-weight: 400;
            padding-left: 16px;
            font-size: 12.5px;
        }}
        .toc-item.toc-h4 {{
            font-weight: 400;
            padding-left: 24px;
            font-size: 12px;
        }}
        .toc-item a {{
            color: var(--color-fg-muted);
            text-decoration: none;
            display: block;
            padding: 4px 6px;
            border-radius: 4px;
            transition: all 0.15s ease-in-out;
            word-break: break-word;
        }}
        .toc-item a:hover {{
            color: var(--color-accent-fg);
            background-color: var(--color-neutral-muted);
        }}
        .toc-item a.active {{
            color: var(--color-accent-fg);
            font-weight: 600;
            background-color: var(--color-neutral-muted);
            border-left: 3px solid var(--color-accent-fg);
            padding-left: 6px;
        }}
        .toc-footer {{
            margin-top: 14px;
            padding-top: 10px;
            border-top: 1px solid var(--color-border-muted);
            font-size: 12px;
        }}
        .back-to-top {{
            color: var(--color-fg-muted);
            text-decoration: none;
            display: inline-flex;
            align-items: center;
            gap: 4px;
        }}
        .back-to-top:hover {{
            color: var(--color-accent-fg);
            text-decoration: underline;
        }}
        /* Main Document Body */
        .markdown-body {{
            flex: 1;
            min-width: 0;
            max-width: 960px;
            padding: 36px 44px;
            border: 1px solid var(--color-border-default);
            border-radius: 8px;
            background-color: var(--color-canvas-default);
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.05);
            box-sizing: border-box;
        }}
        h1, h2, h3, h4, h5, h6 {{
            margin-top: 24px;
            margin-bottom: 16px;
            font-weight: 600;
            line-height: 1.25;
            color: var(--color-fg-default);
            scroll-margin-top: 30px;
        }}
        h1 {{
            font-size: 2em;
            padding-bottom: 0.3em;
            border-bottom: 1px solid var(--color-border-muted);
        }}
        h2 {{
            font-size: 1.5em;
            padding-bottom: 0.3em;
            border-bottom: 1px solid var(--color-border-muted);
        }}
        h3 {{ font-size: 1.25em; }}
        h4 {{ font-size: 1em; }}
        p, blockquote, ul, ol, dl, table, pre, details {{
            margin-top: 0;
            margin-bottom: 16px;
        }}
        a {{
            color: var(--color-accent-fg);
            text-decoration: none;
        }}
        a:hover {{
            text-decoration: underline;
        }}
        hr {{
            height: 0.25em;
            padding: 0;
            margin: 24px 0;
            background-color: var(--color-border-default);
            border: 0;
        }}
        blockquote {{
            padding: 0 1em;
            color: var(--color-fg-muted);
            border-left: 0.25em solid var(--color-border-default);
        }}
        ul, ol {{
            padding-left: 2em;
        }}
        li + li {{
            margin-top: 0.25em;
        }}
        code {{
            padding: 0.2em 0.4em;
            margin: 0;
            font-size: 85%;
            white-space: break-spaces;
            background-color: var(--color-neutral-muted);
            border-radius: 6px;
            font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
        }}
        pre {{
            padding: 16px;
            overflow: auto;
            font-size: 85%;
            line-height: 1.45;
            background-color: var(--color-canvas-subtle);
            border-radius: 6px;
            border: 1px solid var(--color-border-muted);
        }}
        pre code {{
            display: inline;
            padding: 0;
            margin: 0;
            overflow: visible;
            line-height: inherit;
            word-wrap: normal;
            background-color: transparent;
            border: 0;
            font-size: 100%;
            white-space: pre;
        }}
        table {{
            border-spacing: 0;
            border-collapse: collapse;
            display: block;
            width: max-content;
            max-width: 100%;
            overflow: auto;
            margin-bottom: 16px;
        }}
        table th, table td {{
            padding: 8px 14px;
            border: 1px solid var(--color-border-default);
        }}
        table th {{
            font-weight: 600;
            background-color: var(--color-canvas-subtle);
        }}
        table tr:nth-child(2n) {{
            background-color: var(--color-canvas-subtle);
        }}
        .math-display {{
            overflow-x: auto;
            margin: 16px 0;
            text-align: center;
        }}
        img {{
            border-style: none;
            vertical-align: middle;
        }}
        /* Responsive Breakpoints */
        @media (max-width: 1024px) {{
            .page-container {{
                flex-direction: column;
                padding: 12px;
            }}
            .floating-toc {{
                position: relative;
                top: 0;
                width: 100%;
                max-height: none;
                margin-bottom: 20px;
            }}
            .markdown-body {{
                max-width: 100%;
                padding: 24px 20px;
            }}
        }}
    </style>
</head>
<body>
    <div class="page-container" id="top">
{toc_html}
        <article class="markdown-body">
{body_content}
        </article>
    </div>

    <!-- ScrollSpy Script to Highlight Active TOC Item -->
    <script>
    document.addEventListener('DOMContentLoaded', () => {{
        const tocLinks = document.querySelectorAll('.floating-toc a[href^="#"]');
        const sections = [];
        
        tocLinks.forEach(link => {{
            const id = link.getAttribute('href').slice(1);
            if (id === 'top') return;
            const target = document.getElementById(id);
            if (target) {{
                sections.push({{ id, target, link }});
            }}
        }});

        function updateActiveLink() {{
            const scrollPosition = window.scrollY + 100;
            let activeSection = null;

            for (let i = 0; i < sections.length; i++) {{
                const section = sections[i];
                const top = section.target.getBoundingClientRect().top + window.scrollY;
                if (top <= scrollPosition) {{
                    activeSection = section;
                }} else {{
                    break;
                }}
            }}

            sections.forEach(s => s.link.classList.remove('active'));
            if (activeSection) {{
                activeSection.link.classList.add('active');
                const toc = document.getElementById('floating-toc');
                if (toc && window.innerWidth > 1024) {{
                    const linkTop = activeSection.link.offsetTop;
                    const tocHeight = toc.clientHeight;
                    if (linkTop > toc.scrollTop + tocHeight - 50 || linkTop < toc.scrollTop + 50) {{
                        toc.scrollTop = linkTop - tocHeight / 2;
                    }}
                }}
            }}
        }}

        window.addEventListener('scroll', updateActiveLink, {{ passive: true }});
        updateActiveLink();
    }});
    </script>
</body>
</html>
"""
    return full_html


if __name__ == "__main__":
    target_names = sys.argv[1:] if len(sys.argv) > 1 else ["README", "GUIDE", "GEMINI", "strategy_prompt"]
    for name in target_names:
        base = name.replace(".md", "").replace(".html", "")
        md_path = f"{base}.md"
        html_path = f"{base}.html"
        if os.path.exists(md_path):
            with open(md_path, "r", encoding="utf-8") as f:
                content = f.read()
            html_out = convert_markdown_to_html(content, title=f"{base} - Scientific Data Tracking")
            with open(html_path, "w", encoding="utf-8") as f:
                f.write(html_out)
            print(f"Generated {html_path} with floating index")
