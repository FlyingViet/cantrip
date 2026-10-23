// Markdown for replies: a Preact port of the host web client's renderer (same rules, same
// cantrip-preview:// image handling), so Windows shows exactly what the Mac's clients show.
import type { ComponentChildren, JSX } from "preact";
import { bridge } from "../../bridge";

export interface PreviewImage {
  id: string;
  altText?: string;
}

/** Resolves cantrip-preview://image/<id> references inside one message. */
export interface InlineImages {
  sessionID: string;
  images: Map<string, PreviewImage>;
  render(image: PreviewImage, alt: string): JSX.Element;
  link(image: PreviewImage, children: ComponentChildren): JSX.Element;
}

export function safeURL(raw: string, image = false): string | null {
  try {
    const url = new URL(raw);
    if (url.protocol === "https:" || url.protocol === "http:" || (!image && url.protocol === "mailto:")) return url.href;
  } catch { /* not a URL */ }
  return null;
}

function ExternalLink(props: { href: string; children: ComponentChildren }): JSX.Element {
  return (
    <a href={props.href} title={props.href} onClick={(event) => { event.preventDefault(); bridge.openExternal(props.href); }}>
      {props.children}
    </a>
  );
}

const PREVIEW = "cantrip-preview://image/";

export function inline(source: string, images: InlineImages | null, key = "i"): ComponentChildren[] {
  source = source.replace(/<br\s*\/?\s*>/gi, "\n");
  const out: ComponentChildren[] = [];
  let cursor = 0;
  let plain = "";
  let n = 0;
  const id = () => `${key}.${n++}`;
  const flush = () => { if (plain) { out.push(plain); plain = ""; } };
  const paired = (marker: string, wrap: (children: ComponentChildren[], k: string) => JSX.Element): boolean => {
    const end = source.indexOf(marker, cursor + marker.length);
    if (end < 0 || end === cursor + marker.length) return false;
    flush();
    const k = id();
    out.push(wrap(inline(source.slice(cursor + marker.length, end), images, k), k));
    cursor = end + marker.length;
    return true;
  };
  while (cursor < source.length) {
    const char = source[cursor];
    if (char === "\\" && cursor + 1 < source.length && /[\\`*_{}[\]()#+\-.!~|<>]/.test(source[cursor + 1])) {
      plain += source[cursor + 1];
      cursor += 2;
      continue;
    }
    if (char === "`") {
      const end = source.indexOf("`", cursor + 1);
      if (end >= 0) {
        flush();
        out.push(<code key={id()}>{source.slice(cursor + 1, end)}</code>);
        cursor = end + 1;
        continue;
      }
    }
    const rest = source.slice(cursor);
    const image = char === "!" ? rest.match(/^!\[([^\]]*)\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)/) : null;
    if (image) {
      flush();
      const preview = images && image[2].startsWith(PREVIEW) ? images.images.get(image[2].slice(PREVIEW.length)) : undefined;
      const url = /^https?:\/\//i.test(image[2]) ? safeURL(image[2], true) : null;
      if (preview && images) out.push(<span key={id()} class="md-image-block">{images.render(preview, image[1] || preview.altText || "Generated image")}</span>);
      else if (url) out.push(<img key={id()} class="md-remote-image" alt={image[1]} src={url} loading="lazy" />);
      // Mac file paths are not served; show the description instead of a broken image.
      else out.push(<span key={id()} class="image-unavailable">{image[1] ? `Image on the Mac: ${image[1]}` : "Image on the Mac"}</span>);
      cursor += image[0].length;
      continue;
    }
    const link = char === "[" ? rest.match(/^\[([^\]]+)\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)/) : null;
    if (link) {
      const preview = images && link[2].startsWith(PREVIEW) ? images.images.get(link[2].slice(PREVIEW.length)) : undefined;
      if (preview && images) {
        flush();
        const k = id();
        out.push(<span key={k}>{images.link(preview, inline(link[1], images, k))}</span>);
        cursor += link[0].length;
        continue;
      }
      const url = safeURL(link[2]);
      if (url) {
        flush();
        const k = id();
        out.push(<ExternalLink key={k} href={url}>{inline(link[1], images, k)}</ExternalLink>);
        cursor += link[0].length;
        continue;
      }
    }
    const auto = char === "<" ? rest.match(/^<(https?:\/\/[^ >]+|mailto:[^ >]+)>/) : null;
    const autoURL = auto && safeURL(auto[1]);
    if (auto && autoURL) {
      flush();
      out.push(<ExternalLink key={id()} href={autoURL}>{auto[1]}</ExternalLink>);
      cursor += auto[0].length;
      continue;
    }
    const bare = (char === "h" && (cursor === 0 || /[\s(]/.test(source[cursor - 1]))) ? rest.match(/^https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"]/) : null;
    const bareURL = bare && safeURL(bare[0]);
    if (bare && bareURL) {
      flush();
      out.push(<ExternalLink key={id()} href={bareURL}>{bare[0]}</ExternalLink>);
      cursor += bare[0].length;
      continue;
    }
    if (source.startsWith("**", cursor) && paired("**", (c, k) => <strong key={k}>{c}</strong>)) continue;
    if (source.startsWith("__", cursor) && paired("__", (c, k) => <strong key={k}>{c}</strong>)) continue;
    if (source.startsWith("~~", cursor) && paired("~~", (c, k) => <del key={k}>{c}</del>)) continue;
    if (char === "*" && source[cursor + 1] !== " " && paired("*", (c, k) => <em key={k}>{c}</em>)) continue;
    if (char === "_" && (cursor === 0 || /\W/.test(source[cursor - 1])) && paired("_", (c, k) => <em key={k}>{c}</em>)) continue;
    if (char === "\n") {
      flush();
      out.push(<br key={id()} />);
      cursor++;
      continue;
    }
    plain += char;
    cursor++;
  }
  flush();
  return out;
}

function listLine(line: string): { indent: number; ordered: boolean; start: number; text: string; task?: boolean } | null {
  const match = line.match(/^(\s*)([-*+]|\d+[.)])\s+(.+)$/);
  if (!match) return null;
  const task = match[3].match(/^\[([ xX])\]\s+(.*)$/);
  return {
    indent: Math.floor(match[1].length / 2), ordered: /^\d/.test(match[2]), start: parseInt(match[2], 10) || 1,
    text: task ? task[2] : match[3], task: task ? task[1] !== " " : undefined,
  };
}

function tableCells(line: string): string[] {
  let text = line.trim();
  if (text.startsWith("|")) text = text.slice(1);
  if (text.endsWith("|")) text = text.slice(0, -1);
  return text.split("|").map((cell) => cell.trim());
}

function CodeBlock(props: { code: string; language: string }): JSX.Element {
  return (
    <div class="md-code">
      {props.language ? <div class="md-code-lang">{props.language}</div> : null}
      <button type="button" class="md-code-copy icon-btn" title="Copy code" aria-label="Copy code"
        onClick={() => void navigator.clipboard.writeText(props.code)}>
        <svg class="icon s14" viewBox="0 0 24 24" aria-hidden="true"><rect x="8" y="8" width="13" height="13" rx="2" /><path d="M4 16V5a2 2 0 0 1 2-2h11" /></svg>
      </button>
      <pre><code>{props.code}</code></pre>
    </div>
  );
}

export function Markdown(props: { text: string; images?: InlineImages | null; class?: string }): JSX.Element {
  return <div class={`prose selectable${props.class ? ` ${props.class}` : ""}`}>{blocks(props.text, props.images ?? null, "m")}</div>;
}

function blocks(source: string, images: InlineImages | null, key: string): ComponentChildren[] {
  const out: ComponentChildren[] = [];
  const lines = source.split("\n");
  let index = 0;
  let paragraph: string[] = [];
  let n = 0;
  const id = () => `${key}.${n++}`;
  const flush = () => {
    if (!paragraph.length) return;
    const k = id();
    // CommonMark (MarkdownUI on the Mac): a soft line break is a space; two trailing spaces or a
    // trailing backslash is a hard break.
    const text = paragraph.map((line, i) => {
      if (i === paragraph.length - 1) return line;
      if (/ {2,}$/.test(line)) return `${line.trimEnd()}\n`;
      if (/\\$/.test(line)) return `${line.slice(0, -1)}\n`;
      return `${line} `;
    }).join("");
    out.push(<p key={k}>{inline(text, images, k)}</p>);
    paragraph = [];
  };
  while (index < lines.length) {
    const line = lines[index];
    const trimmed = line.trim();
    if (!trimmed) { flush(); index++; continue; }
    const fence = trimmed.match(/^(```|~~~)\s*([\w+#.-]*)/);
    if (fence) {
      flush();
      index++;
      const code: string[] = [];
      while (index < lines.length && !lines[index].trim().startsWith(fence[1])) code.push(lines[index++]);
      if (index < lines.length) index++;
      out.push(<CodeBlock key={id()} code={code.join("\n")} language={fence[2] ?? ""} />);
      continue;
    }
    const heading = trimmed.match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (heading) {
      flush();
      const level = Math.min(3, heading[1].length);
      const k = id();
      const content = inline(heading[2], images, k);
      out.push(level === 1 ? <h1 key={k}>{content}</h1> : level === 2 ? <h2 key={k}>{content}</h2> : <h3 key={k}>{content}</h3>);
      index++;
      continue;
    }
    if (/^(---+|\*\*\*+|___+)$/.test(trimmed)) { flush(); out.push(<hr key={id()} />); index++; continue; }
    if (trimmed.startsWith(">")) {
      flush();
      const quoted: string[] = [];
      while (index < lines.length && lines[index].trim().startsWith(">")) quoted.push(lines[index++].trim().replace(/^>\s?/, ""));
      const k = id();
      out.push(<blockquote key={k}>{blocks(quoted.join("\n"), images, k)}</blockquote>);
      continue;
    }
    if (trimmed.includes("|") && index + 1 < lines.length && /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$/.test(lines[index + 1])) {
      flush();
      const k = id();
      const head = tableCells(line);
      index += 2;
      const rows: string[][] = [];
      while (index < lines.length && lines[index].includes("|") && lines[index].trim()) rows.push(tableCells(lines[index++]));
      out.push(
        <div key={k} class="md-table-wrap">
          <table>
            <thead><tr>{head.map((cell, c) => <th key={c}>{inline(cell, images, `${k}.h${c}`)}</th>)}</tr></thead>
            <tbody>{rows.map((row, r) => <tr key={r}>{row.map((cell, c) => <td key={c}>{inline(cell, images, `${k}.${r}.${c}`)}</td>)}</tr>)}</tbody>
          </table>
        </div>,
      );
      continue;
    }
    const item = listLine(line);
    if (item) {
      flush();
      const k = id();
      const entries: JSX.Element[] = [];
      while (index < lines.length) {
        const next = listLine(lines[index]);
        if (!next) {
          // A continuation line indented under the item joins it.
          if (lines[index].trim() && /^\s{2,}/.test(lines[index]) && entries.length) {
            index++;
            continue;
          }
          break;
        }
        if (next.ordered !== item.ordered && next.indent === 0) break;
        const ek = `${k}.${entries.length}`;
        entries.push(
          <li key={ek} style={next.indent ? { marginLeft: `${next.indent * 18}px` } : undefined} class={next.task !== undefined ? "task" : undefined}>
            {next.task !== undefined ? <input type="checkbox" class="checkbox" checked={next.task} disabled aria-label={next.task ? "Done" : "Not done"} /> : null}
            {inline(next.text, images, ek)}
          </li>,
        );
        index++;
      }
      out.push(item.ordered ? <ol key={k} start={item.start}>{entries}</ol> : <ul key={k}>{entries}</ul>);
      continue;
    }
    paragraph.push(line.replace(/^\s+/, ""));
    index++;
  }
  flush();
  return out;
}
