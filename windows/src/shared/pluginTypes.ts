export interface PluginPanelManifest {
  html: string;
  title?: string;
  capabilities?: string[];
}

export interface PluginDataSourceManifest {
  command: string;
  args?: string[];
  timeoutSeconds?: number;
}

export interface PluginMcpServerManifest {
  command: string;
  args?: string[];
  env?: Record<string, string>;
}

export interface PluginManifest {
  name: string;
  version?: string;
  description?: string;
  panel?: PluginPanelManifest;
  dataSources?: Record<string, PluginDataSourceManifest>;
  mcpServers?: Record<string, PluginMcpServerManifest>;
}

export interface PluginSummary {
  id: string;
  name: string;
  version?: string;
  description?: string;
  manifestHash: string;
  enabled: boolean;
  approved: boolean;
  active: boolean;
  hasPanel: boolean;
  panelTitle?: string;
  capabilities: string[];
  capabilitySummary: string[];
}

export interface PluginMcpSnapshot {
  configPath: string;
  servers: Record<string, PluginMcpServerManifest>;
}

export interface PluginBridgeApi {
  sendPrompt(text: string): void;
  log(text: string): void;
  openURL(url: string): void;
  requestData(
    name: string,
    payload?: Record<string, unknown>,
  ): Promise<Record<string, unknown>>;
  runAction(name: string): Promise<unknown>;
}
