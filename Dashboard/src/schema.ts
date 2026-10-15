/** API contract matches Shared/usage-event.schema.json and the Codable core. */
export type MetricState = 'known' | 'unknown' | 'unsupported' | 'not_available' | 'partial'
export type MetricName = 'input' | 'output' | 'cacheRead' | 'cacheWrite' | 'cachedOutput' | 'reasoning' | 'total'
export interface Metric { value?: number | null; state: MetricState }
export interface MetricAggregate extends Metric { knownEvents: number; totalEvents: number }
export interface Summary {
  uncachedInput?: MetricAggregate
  metrics: Record<MetricName, MetricAggregate>
  events: number; sessions: number; agents: number; projects: number; activeAgents: number; estimatedEvents: number
  cost?: number | null; currency?: string | null; costKnownEvents: number
}
export interface Project { id: string; name: string; path: string; detectionMethod: string; confidence: number }
export interface UsageEvent {
  id: string; timestamp: string; agentID: string; agentName: string
  provider?: string; model?: string; rawModelName?: string; sessionID?: string; workingDirectory?: string; project?: Project
  metrics: Record<MetricName, Metric>; cost?: number; currency?: string; costState: MetricState
  sourceType: string; sourcePath: string; sourceEventID: string; sourceLine: number; sourceOffset: number
  collectorID: string; collectorVersion: string; parserVersion: string; isEstimated: boolean; confidence: number; quality: string
  fingerprint: string; sourceMetadata: Record<string, string>; createdAt: string
}
export interface Group { id: string; name: string; path?: string; lastActivity?: string; models: string[]; agentIDs: string[]; projectIDs: string[]; summary: Summary }
export interface TimelinePoint { timestamp: string; end: string; summary: Summary }
export interface Overview {
  selected: Summary; today: Summary; sevenDays: Summary; thirtyDays: Summary; allTime: Summary; yesterday: Summary; changePercent?: number
  timeline: TimelinePoint[]; agentDistribution: Group[]; modelDistribution: Group[]; timeZone: string
}
export interface Detection { installed: boolean; evidence: string[]; sourceAvailable: boolean; version?: string; applicationPath?: string }
export interface SourceCoverage {
  status: string; scope: string; earliest?: string; latest?: string; records: number; completeHistoryVerified: boolean; notes: string[]; errors: string[]
  reconciliation?: { status: string; checkedAt: string; sourceCount: number; collectedCount: number; sourceTotal?: number; collectedTotal?: number; scope: string }
  traceEvidence?: { parserVersion: string; checkedAt: string; inspectedFiles: number; limited: boolean; mergedIntoTotals: boolean; samples: { sourcePath: string; traceID: string; sessionID?: string; models: string[]; totalTokens: number; callCount?: number }[] }
  historical?: { sourcePath: string; parserVersion: string; lastComputedDate?: string; startDate?: string; endDate?: string; reportedSessions?: number; models: { model: string; input: Metric; output: Metric; cacheRead: Metric; cacheWrite: Metric }[] }
}
export interface Collector {
  coverage?: SourceCoverage
  diagnostics?: { message: string; severity: 'info' | 'warning' | 'error' }[]
  presentationStatus?: string
  descriptor: { mode?: string; id: string; agentID: string; name: string; version: string; parserVersion: string; sourceRoots: string[]; sourceDescription: string; supportedAgentVersions: string[]; capabilities: Record<string, string> }
  detection: Detection
  health: { status: string; lastCollection?: string; compatibility: string; errors: string[]; files: number; bytesRead: number; imported: number; updated: number; duplicates: number }
  enabled: boolean
}
export interface Agent { id: string; name: string; detection: Detection; collector?: Collector; summary: Summary; today: Summary; allTime: Summary; lastSeen?: string; models: string[]; projects: string[] }
export interface Option { id: string; name: string }
export interface FilterOptions { agents: Option[]; models: Option[]; projects: Option[]; providers: Option[] }
export interface EventPage { events: UsageEvent[]; total: number; offset: number; limit: number }
export interface CustomAgent { id: string; name: string; executable?: string; processName?: string; logDirectory: string; dataDirectory?: string; mapping: Record<string, string>; inputIncludesCache: boolean; discoveryOnly?: boolean }
export interface Settings { language: 'system' | 'en' | 'zh-Hans'; dashboardTheme?: 'forest' | 'paper' | 'ocean' | 'mono'; dashboardAppearance?: 'system' | 'light' | 'dark'; menuBarMode: string; port: number; reconciliationSeconds: number; disabledCollectors: string[]; sourceOverrides: Record<string, string[]>; customAgents: CustomAgent[] }
export interface Status { schemaVersion: number; databasePath: string; collecting: boolean; timeZone: string; supportsNativeSettings: boolean }
