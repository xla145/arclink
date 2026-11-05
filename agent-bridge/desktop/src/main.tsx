import React from "react";
import ReactDOM from "react-dom/client";
import { App } from "./App";
import "./styles/panel.css";

async function mount() {
  const state = new URLSearchParams(window.location.search).get("preview");
  const preview = import.meta.env.DEV && state !== null;
  const api = preview
    ? (await import("./preview")).previewBridge(state)
    : undefined;
  ReactDOM.createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <App
        api={api}
        preview={preview}
        initialPairing={preview && state === "pairing"}
      />
    </React.StrictMode>,
  );
}
void mount();
