import { render } from "preact";
import { bridge } from "./bridge";
import "./styles/app.css";
import { App } from "./ui/App";

document.documentElement.classList.add(`platform-${bridge.platform}`);
render(<App />, document.getElementById("app")!);
