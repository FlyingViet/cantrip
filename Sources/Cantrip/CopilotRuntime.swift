import Foundation

enum CopilotRuntime {
    /// `code` on the error (and on the bridge's `failure`) when `copilot --version` never answered.
    static let probeTimeoutCode = "COPILOT_PROBE_TIMEOUT"

    // Resolve the SDK and native runtime from the same installed CLI version.
    // In particular, a custom CLI path must never silently use another install.
    static let discoveryScript = #"""
    import { existsSync, realpathSync, openSync, readSync, closeSync, statSync, readdirSync,
      readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
    import { execFileSync } from 'node:child_process';
    import { homedir, loadavg, cpus } from 'node:os';
    import { join, dirname, isAbsolute } from 'node:path';
    import { pathToFileURL, fileURLToPath } from 'node:url';

    // `copilot --version` starts the whole CLI, which takes many seconds on a Mac that's swapping.
    // A slow first try warms it up, so one longer retry follows before giving up.
    const copilotProbeTimeouts = [20000, 25000];
    const copilotRuntimeCache = join(homedir(), '.cache', 'Cantrip', 'copilot-runtime.json');

    function isMachO(path) {
      let fd;
      try {
        fd = openSync(path, 'r');
        const magic = Buffer.alloc(4);
        if (readSync(fd, magic, 0, 4, 0) !== 4) return false;
        return ['cffaedfe', 'cefaedfe', 'cafebabe', 'bebafeca'].includes(magic.toString('hex'));
      } catch { return false; }
      finally { if (fd !== undefined) closeSync(fd); }
    }

    function copilotFileStamp(path) {
      try {
        const stat = statSync(path);
        return [path, stat.size, stat.mtimeMs, stat.ino];
      } catch { return [path, null]; }
    }

    // Everything that decides which version `command` runs: the file itself, the native binary the
    // npm loader starts, and the self-updated versions Copilot picks the newest of (its package
    // roots, in its own order; a version counts once its extraction finished).
    function copilotInstallFingerprint(command, root) {
      const env = process.env, platform = `${process.platform}-${process.arch}`;
      const roots = [
        env.COPILOT_PKG_CACHE_HOME && join(env.COPILOT_PKG_CACHE_HOME, 'pkg'),
        env.COPILOT_CACHE_HOME && join(env.COPILOT_CACHE_HOME, 'pkg'),
        join(homedir(), 'Library', 'Caches', 'copilot', 'pkg'),
        join(env.XDG_CACHE_HOME || join(homedir(), '.cache'), 'copilot', 'pkg'),
        env.COPILOT_HOME && join(env.COPILOT_HOME, 'pkg'),
        join(homedir(), '.copilot', 'pkg')
      ].filter(Boolean);
      const versions = [...new Set(roots)].map(pkg => {
        const directory = join(pkg, platform);
        try {
          return [directory, readdirSync(directory)
            .filter(name => existsSync(join(directory, name, '.extraction-complete'))).sort()];
        } catch { return [directory, null]; }
      });
      return JSON.stringify({
        command, cli: copilotFileStamp(realpathSync(command)),
        native: copilotFileStamp(join(root, 'node_modules', '@github', `copilot-${platform}`, 'copilot')),
        versions, autoUpdate: env.COPILOT_AUTO_UPDATE ?? null
      });
    }

    function readCopilotRuntimeCache() {
      try {
        const cache = JSON.parse(readFileSync(copilotRuntimeCache, 'utf8'));
        return cache && typeof cache === 'object' && !Array.isArray(cache) ? cache : {};
      } catch { return {}; }
    }

    // Best effort: a cache that can't be written only means the next start probes again.
    function saveCopilotRuntime(command, entry) {
      try {
        const cache = readCopilotRuntimeCache();
        delete cache[command];
        cache[command] = entry;
        for (const old of Object.keys(cache).slice(0, -8)) delete cache[old];
        mkdirSync(dirname(copilotRuntimeCache), { recursive: true });
        const temporary = `${copilotRuntimeCache}.${process.pid}.tmp`;
        writeFileSync(temporary, JSON.stringify(cache), { mode: 0o600 });
        renameSync(temporary, copilotRuntimeCache);
      } catch {}
    }

    function cachedCopilotRuntime(command, fingerprint) {
      const entry = readCopilotRuntimeCache()[command];
      if (entry?.fingerprint !== fingerprint || typeof entry.sdk !== 'string' || typeof entry.runtime !== 'string') return null;
      try {
        if (!existsSync(fileURLToPath(entry.sdk)) || !existsSync(entry.runtime)) return null;
      } catch { return null; }
      return { sdk: entry.sdk, runtime: entry.runtime, version: entry.version, cached: true };
    }

    function probeCopilotVersion(command) {
      let waited = 0;
      for (const timeout of copilotProbeTimeouts) {
        try {
          return execFileSync(command, ['--version'], {
            encoding: 'utf8', timeout, stdio: ['ignore', 'pipe', 'ignore']
          });
        } catch (error) {
          if (error?.code !== 'ETIMEDOUT') throw error;
          waited += timeout;
        }
      }
      const seconds = Math.round(waited / 1000), load = loadavg()[0], cores = cpus().length || 1;
      const error = new Error(load > cores
        ? `Copilot CLI didn't answer within ${seconds} s; the Mac looks overloaded (load average ${Math.round(load)} on ${cores} cores). Close simulators or other heavy apps, then send again.`
        : `Copilot CLI didn't answer within ${seconds} s. Check that \`${command} --version\` works in Terminal, then send again.`);
      error.code = 'COPILOT_PROBE_TIMEOUT';
      throw error;
    }

    function resolveCopilotRuntime(configured = 'copilot') {
      const command = isAbsolute(configured) ? configured
        : (process.env.PATH ?? '').split(':').filter(Boolean)
            .map(directory => join(directory, configured)).find(path => existsSync(path));
      if (!command || !existsSync(command)) throw new Error('Copilot CLI not found. Check its path in Settings.');
      const root = dirname(realpathSync(command));
      // The answer holds until the install changes (an update, a reinstall, a new self-update).
      const fingerprint = copilotInstallFingerprint(command, root);
      const cached = cachedCopilotRuntime(command, fingerprint);
      if (cached) return cached;
      const version = probeCopilotVersion(command).match(/(?:Copilot CLI|copilot)\s+(\d+\.\d+\.\d+)/i)?.[1];
      if (!version) throw new Error('Cannot identify the configured Copilot CLI version.');
      const roots = [root, dirname(root),
        join(homedir(), 'Library/Caches/copilot/pkg', `darwin-${process.arch}`, version)];
      const matched = roots.find(directory => existsSync(join(directory, 'copilot-sdk/index.js'))
        && existsSync(join(directory, 'prebuilds', `darwin-${process.arch}`, 'copilot-runtime')));
      if (!matched) throw new Error('Update Copilot CLI: its matching SDK/runtime is unavailable.');
      // Every Copilot process Cantrip starts runs the signed CLI binary (npm or native
      // install), whose path survives Copilot's self-updates. The per-version prebuilt
      // runtime moves with each update, so Keychain items it saves (sign-in, MCP OAuth)
      // belong to a path that's gone after the next one. It's only a fallback.
      const cli = [realpathSync(command),
        join(root, 'node_modules', '@github', `copilot-darwin-${process.arch}`, 'copilot')]
        .find(isMachO);
      const paths = {
        sdk: pathToFileURL(join(matched, 'copilot-sdk/index.js')).href,
        runtime: cli ?? join(matched, 'prebuilds', `darwin-${process.arch}`, 'copilot-runtime')
      };
      saveCopilotRuntime(command, { fingerprint, version, ...paths });
      return { ...paths, version, cached: false };
    }
    """#
}
