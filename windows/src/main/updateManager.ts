import { app } from "electron";
import {
  autoUpdater,
  type ProgressInfo,
  type UpdateInfo,
} from "electron-updater";
import type { UpdateState } from "../shared/types";
import { sanitizeUpdateError } from "../shared/update";

type StateListener = (state: UpdateState) => void;

export class UpdateManager {
  private state: UpdateState = {
    status: app.isPackaged ? "idle" : "unsupported",
    currentVersion: app.getVersion(),
    message: app.isPackaged
      ? "Ready to check for updates."
      : "Updates are available in installed builds.",
  };
  private initialized = false;

  constructor(private readonly onState: StateListener) {}

  initialize(): void {
    if (this.initialized || !app.isPackaged) return;
    this.initialized = true;
    autoUpdater.autoDownload = false;
    autoUpdater.autoInstallOnAppQuit = true;
    autoUpdater.allowPrerelease = false;

    autoUpdater.on("checking-for-update", () => {
      this.setState({ status: "checking", message: "Checking for updates…" });
    });
    autoUpdater.on("update-available", (info: UpdateInfo) => {
      this.setState({
        status: "available",
        availableVersion: info.version,
        message: `Cantrip ${info.version} is available.`,
      });
    });
    autoUpdater.on("update-not-available", () => {
      this.setState({
        status: "up-to-date",
        message: `Cantrip ${app.getVersion()} is up to date.`,
      });
    });
    autoUpdater.on("download-progress", (progress: ProgressInfo) => {
      this.setState({
        status: "downloading",
        percent: Math.max(0, Math.min(100, progress.percent)),
        message: `Downloading ${Math.round(progress.percent)}%…`,
      });
    });
    autoUpdater.on("update-downloaded", (info: UpdateInfo) => {
      this.setState({
        status: "downloaded",
        availableVersion: info.version,
        percent: 100,
        message: `Cantrip ${info.version} is ready to install.`,
      });
    });
    autoUpdater.on("error", (error: Error) => {
      this.setState({
        status: "error",
        message: `Update failed: ${sanitizeUpdateError(error)}`,
      });
    });

    const timer = setTimeout(() => void this.check(), 15_000);
    timer.unref();
  }

  getState(): UpdateState {
    return { ...this.state };
  }

  async check(): Promise<UpdateState> {
    if (!app.isPackaged) return this.getState();
    if (["checking", "downloading"].includes(this.state.status)) {
      return this.getState();
    }
    try {
      await autoUpdater.checkForUpdates();
    } catch (error) {
      this.setState({
        status: "error",
        message: `Update check failed: ${sanitizeUpdateError(error)}`,
      });
    }
    return this.getState();
  }

  async download(): Promise<UpdateState> {
    if (this.state.status !== "available") return this.getState();
    this.setState({
      status: "downloading",
      percent: 0,
      message: "Starting download…",
    });
    try {
      await autoUpdater.downloadUpdate();
    } catch (error) {
      this.setState({
        status: "error",
        message: `Update download failed: ${sanitizeUpdateError(error)}`,
      });
    }
    return this.getState();
  }

  install(): { ok: boolean; error?: string } {
    if (this.state.status !== "downloaded") {
      return { ok: false, error: "No downloaded update is ready." };
    }
    setImmediate(() => autoUpdater.quitAndInstall(false, true));
    return { ok: true };
  }

  private setState(next: Omit<UpdateState, "currentVersion">): void {
    this.state = {
      currentVersion: app.getVersion(),
      ...next,
    };
    this.onState(this.getState());
  }
}
