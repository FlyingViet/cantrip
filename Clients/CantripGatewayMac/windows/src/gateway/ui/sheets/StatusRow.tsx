// One status row, as the Mac's MCP Servers and Backends settings draw them: the name, an optional
// tag, the state as text (toned, never color alone) and the row's buttons, then its details. The section is named for assistive technology.
import type { ComponentChildren, JSX } from "preact";

export function StatusRow(props: {
  name: string;
  /** The row's accessible name (the name by default). */
  label?: string;
  kind?: string;
  status: { text: string; tone: string };
  actions?: ComponentChildren;
  children?: ComponentChildren;
}): JSX.Element {
  return (
    <section class="mcp-server" aria-label={props.label ?? props.name}>
      <div class="mcp-head">
        <strong>{props.name}</strong>
        {props.kind !== undefined && <span class="sh-secondary">{props.kind}</span>}
        <span class={`mcp-status ${props.status.tone}`}>{props.status.text}</span>
        {props.actions}
      </div>
      {props.children}
    </section>
  );
}
