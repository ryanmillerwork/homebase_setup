// Websocket with homebase systems
// Websocket with web clients
// Postgres listener
// Communication checker (pinging homebases)
// web server

import { Pool, Client, QueryResult } from 'pg';     // MIT License
import { WebSocketServer, WebSocket } from 'ws';    // MIT License
import type { RawData } from 'ws';
import ping from 'ping';                            // MIT License
// import { Socket } from 'net';                       // Deprecated legacy TCP path (removed)
import path from 'path';
import express, { Request, Response } from 'express';

// for webserver
declare const process: any;

// Subscriptions to maintain with the homebase WS (edit here)
const HOMEBASE_SUBSCRIPTIONS = [
  // System-level
  'system/hostname',
  'system/hostaddr',
  'system/os',

  // ESS core identity and state
  'ess/subject',
  'ess/project',
  'ess/system',  
  'ess/protocol',
  'ess/variant',
  'ess/systems',
  'ess/protocols',
  'ess/variants',
  'ess/state',
  'ess/status',
  'ess/running',
  'ess/remote',
  'ess/name',
  'ess/ipaddr',
  'ess/rmt_host',
  'ess/rmt_connected',

  // Observation / session  
  'ess/obs_active',
  'ess/in_obs',
  'ess/obs_id',
  'ess/obs_total',
  'ess/obs_count',

  // Files and dirs
  'ess/data_dir',
  'ess/datafile',
  'ess/lastfile',
  'ess/system_path',
  'ess/executable',

  // Git
  'ess/git/status',
  'ess/git/branches',
  'ess/git/branch',
  'ess/git/tag',

  // Loading / progress
  'ess/loading_start_time',
  'ess/loading_progress',
  'ess/loading_operation_id',

  // Params / scripts / mappings
  'ess/variant_info',
  'ess/param_settings',
  'ess/params',

  // Misc runtime
  'ess/time',
  'ess/block_id',
  'ess/warningInfo',

  // Discovery helpers
  '@keys'
];

const DEFAULT_SUBSCRIBE_EVERY = 1;
// Empty means allow all HBs discovered from DB
const HOMEBASE_ALLOWED_IPS: string[] = [];
// Legacy TCP refresh is deprecated and disabled in index_ws.ts

const app = express();
const webpage_path = '/var/www/hb-webclient/spa'; // will serve index.html from this dir

// PostgreSQL database connection configuration
const dbConfig = {
  user: 'postgres',
  host: 'localhost',
  database: 'base',
  password: 'postgres',
  port: 5432, // Default PostgreSQL port
};

const pool = new Pool(dbConfig);
const client = new Client(dbConfig);

pool.on('error', (err: unknown) => {
  console.error('Unexpected error on idle PG client', err);
  // Decide how you want to handle this—likely just log it
  // The pool will internally remove the broken client and keep running
});

// Define types for our messages
interface SqlResponse {
  type: 'sql_table';
  result: Record<string, unknown>[];
}

interface ErrorResponse {
  type: 'error';
  message: string;
}

interface QueryRow {
  [key: string]: any;  // This matches the flexible structure of pg rows
}

// type WebSocketResponse = SqlResponse | ErrorResponse;


// Handle websocket communication with web clients
// Keeps them up to date on status, commstatus, and perfStats
// Also receives requests like start or stop and forwards them to the homebase
let wss: WebSocketServer; 

interface StatusChanges {
  host: string;
  status_source: string;
  status_type: string;
  status_value: string;
  sys_time?: string;
}

// Interface for the raw row structure from the database query for status, especially for images
interface DbQueryResultStatus {
  host: string;
  status_source: string;
  status_type: string;
  status_value: string;
  sys_time: Date | string | null; // server_time from DB, aliased to sys_time, can be Date object from pg driver
}

let statusData: StatusChanges[] = [];

interface RecentStatsChanges {
  status_type: string;
  host: string;
  subject: string;
  project: string;
  state_system: string;
  protocol: string;
  variant: string;
  aborts: number;
  pc: number;
  rt: number;
  trials: number;
  last_updated: string; 
}
let perfStatsData: RecentStatsChanges[] = [];

// -----------------------------
// Homebase WebSocket client (Step 1)
// -----------------------------

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (reason?: unknown) => void;
  timeoutId: ReturnType<typeof setTimeout>;
};

class HomebaseWS {
  private hostIp: string;
  private port: number;
  private path: string;
  private ws: WebSocket | null = null;
  private connecting = false;
  private reconnectAttempts = 0;
  private readonly maxBackoffMs = 30000;
  private readonly baseBackoffMs = 1000;
  private readonly requestMap: Map<string, PendingRequest> = new Map();
  private readonly isChunkedMessageKey = 'isChunkedMessage';
  private readonly chunkBuffers: Map<string, { chunks: string[]; total: number }> = new Map();
  private readonly maxChunkTotal = 2000; // safety guard against pathological chunk counts
  private firstDisconnectAtMs: number | null = null;
  private slowPhaseStartFailures: number | null = null;
  private consecutiveFailures = 0;
  private readonly fastRetryWindowMs = 5 * 60 * 1000; // 5 minutes
  private readonly fastRetryBaseMs = 2000;            // 2s
  private readonly fastRetryJitterMs = 1000;          // up to +1s
  private readonly slowBaseBackoffMs = 15000;         // 15s
  private readonly slowMaxBackoffMs = 120000;         // 2m
  private readonly slowJitterMs = 2000;               // up to +2s
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly connectTimeoutMs = 8000;
  private connectTimeoutHandle: ReturnType<typeof setTimeout> | null = null;
  private openedThisAttempt = false;
  private connectTimedOut = false;
  private lastErrorCode: string | null = null;
  private lastUrl: string = '';

  // Request queueing & in-flight limiting
  private readonly maxQueueSize = 200;
  private readonly maxInFlight = 8;
  private currentInFlight = 0;
  private evalQueue: Array<{ script: string; timeoutMs: number; resolve: (v: unknown)=>void; reject: (e?: unknown)=>void; enqueuedAt: number }>
    = [];

  // Heartbeat & staleness detection
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private heartbeatTimeoutHandle: ReturnType<typeof setTimeout> | null = null;
  private readonly heartbeatIntervalMs = 10000; // send ping every 10s
  private readonly heartbeatTimeoutMs = 5000;   // expect pong within 5s
  private readonly staleMs = 30000;             // force reconnect if no messages for 30s
  private lastMessageAt = 0;
  private staleCheckTimer: ReturnType<typeof setInterval> | null = null;
  private lastHeartbeatSentAt = 0;
  private lastValues: Map<string, string> = new Map();
  private pollJuicerTimer: ReturnType<typeof setInterval> | null = null;
  private refreshTimer: ReturnType<typeof setInterval> | null = null;

  constructor(hostIp: string, port = 2565, path = '/ws') {
    this.hostIp = hostIp;
    this.port = port;
    this.path = path;
  }

  

  connect(): void {
    if (this.connecting) {
      return;
    }
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) {
      return;
    }
    const url = `ws://${this.hostIp}:${this.port}${this.path}`;
    this.lastUrl = url;
    console.log(`[HBWS] Connecting to ${url}`);
    this.connecting = true;
    this.ws = new WebSocket(url);
    this.openedThisAttempt = false;
    this.connectTimedOut = false;
    this.lastErrorCode = null;

    // Connection attempt timeout to avoid hanging CONNECTING state
    if (this.connectTimeoutHandle) clearTimeout(this.connectTimeoutHandle);
    this.connectTimeoutHandle = setTimeout(() => {
      if (this.ws && this.ws.readyState === WebSocket.CONNECTING) {
        this.connectTimedOut = true;
        console.warn('[HBWS] Connect attempt timed out');
        try { this.ws.terminate(); } catch {}
      }
    }, this.connectTimeoutMs);

    this.ws.on('open', () => {
      console.log('[HBWS] Connected');
      this.connecting = false;
      if (this.connectTimeoutHandle) { clearTimeout(this.connectTimeoutHandle); this.connectTimeoutHandle = null; }
      this.openedThisAttempt = true;
      this.connectTimedOut = false;
      this.lastMessageAt = Date.now();
      this.reconnectAttempts = 0;
      this.firstDisconnectAtMs = null;
      this.slowPhaseStartFailures = null;
      this.consecutiveFailures = 0;
      this.startHeartbeat();
      this.simulateConnectivityUpsert(1);
      // Subscribe only to the datapoints we care about (from top-level list)
      HOMEBASE_SUBSCRIPTIONS.forEach((m) => this.subscribe(m, DEFAULT_SUBSCRIBE_EVERY));

      // Initial sync: touch all subscribed keys to seed values immediately
      HOMEBASE_SUBSCRIPTIONS.forEach((m) => this.touch(m));
      
    });

    this.ws.on('message', (data: RawData) => {
      this.lastMessageAt = Date.now();
      // If a heartbeat was outstanding, clear it
      if (this.heartbeatTimeoutHandle) {
        clearTimeout(this.heartbeatTimeoutHandle);
        this.heartbeatTimeoutHandle = null;
      }
      const text = typeof data === 'string' ? data : data.toString('utf-8');
      try {
        const msg = JSON.parse(text as string);
        // Chunked large message support (log-only for Step 1)
        if (msg && msg[this.isChunkedMessageKey]) {
          const messageId = String(msg.messageId || '');
          const chunkIndex = Number(msg.chunkIndex || 0);
          const totalChunks = Number(msg.totalChunks || 0);
          const chunkData = String(msg.data || '');
          if (!Number.isFinite(totalChunks) || totalChunks <= 0 || totalChunks > this.maxChunkTotal) {
            console.warn('[HBWS] Dropping chunked message with invalid totalChunks:', totalChunks);
            return;
          }
          if (!this.chunkBuffers.has(messageId)) {
            this.chunkBuffers.set(messageId, { chunks: new Array(totalChunks).fill(''), total: totalChunks });
          }
          const entry = this.chunkBuffers.get(messageId)!;
          entry.chunks[chunkIndex] = chunkData;
          const receivedCount = entry.chunks.filter((c) => c !== '').length;
          if (receivedCount === entry.total) {
            const joined = entry.chunks.join('');
            this.chunkBuffers.delete(messageId);
            try {
              const reconstructed = JSON.parse(joined);
              this.handleMessage(reconstructed);
            } catch (e) {
              console.error('[HBWS] Failed to parse reconstructed chunked message', e);
            }
          }
          return;
        }
        this.handleMessage(msg);
      } catch (e) {
        console.error('[HBWS] Failed to parse message from homebase:', e);
      }
    });

    this.ws.on('close', (code: number, reason: unknown) => {
      const reasonText = typeof reason === 'string' ? reason : '';
      if (this.openedThisAttempt) {
        console.warn(`[HBWS] Disconnected (code=${code}, reason=${reasonText || 'n/a'})`);
      } else if (this.connectTimedOut) {
        console.warn(`[HBWS] Connect failed to ${this.lastUrl} (timeout)`);
      } else if (this.lastErrorCode) {
        console.warn(`[HBWS] Connect failed to ${this.lastUrl} (${this.lastErrorCode})`);
      } else {
        console.warn(`[HBWS] Connect failed to ${this.lastUrl}`);
      }
      this.stopHeartbeat();
      this.simulateConnectivityUpsert(0);
      this.connecting = false;
      if (this.connectTimeoutHandle) { clearTimeout(this.connectTimeoutHandle); this.connectTimeoutHandle = null; }
      this.ws = null;
      this.scheduleReconnect();
    });

    this.ws.on('error', (err: unknown) => {
      // Capture error code for close handler context (suppress direct logging to avoid redundancy)
      const code = (err as any)?.code || (err as any)?.errno || null;
      this.lastErrorCode = code;
      // Error will also lead to close in most cases
    });

    // Log pongs specifically and clear heartbeat timeout
    (this.ws as any).on?.('pong', () => {
      const now = Date.now();
      this.lastMessageAt = now;
      if (this.heartbeatTimeoutHandle) {
        clearTimeout(this.heartbeatTimeoutHandle);
        this.heartbeatTimeoutHandle = null;
      }
    });
  }

  private handleMessage(msg: any): void {
    // Heartbeat replies may be plain pongs from ws lib, but if we get JSON we just proceed
    if (msg && msg.requestId && this.requestMap.has(msg.requestId)) {
      const pending = this.requestMap.get(msg.requestId)!;
      this.requestMap.delete(msg.requestId);
      this.currentInFlight = Math.max(0, this.currentInFlight - 1);
      this.tryDrainQueue();
      if (msg.status === 'ok') {
        pending.resolve(msg.result);
      } else {
        pending.reject(new Error(msg.error || 'Command failed'));
        // Forward as TCL_ERROR-equivalent to browser clients if available
        if (typeof msg.error === 'string') {
          this.safeBroadcast('TCL_ERROR', msg.error);
        }
      }
      return;
    }

    if (msg && msg.type === 'datapoint') {
      // Process datapoints (no noisy logs)
      this.processDatapointForLogging(String(msg.name || ''), String(msg.data ?? ''));
      return;
    }

    // Log subscription acks and other control messages (suppress noisy not-found touches)
    if (msg && (msg.status || msg.action)) {
      if (msg.status === 'error' && typeof msg.error === 'string' && msg.error.includes('Datapoint not found')) {
        return;
      }
      // Suppress control logs to reduce noise
      return;
    }

    // Unknown message type
    console.log('[HBWS] Message:', msg);
  }

  private processDatapointForLogging(name: string, value: string): void {
    const lowerName = name.toLowerCase();
    const host = this.hostIp;

    // Compute source/type per rules
    let status_source = '';
    let status_type = '';
    let status_value: string | number = value;

    if (lowerName === '@keys') {
      status_source = 'system';
      status_type = '@keys';
    } else if (lowerName.startsWith('ess/git/')) {
      status_source = 'git';
      status_type = name.slice('ess/git/'.length);
    } else if (lowerName === 'ess/obs_active') {
      status_source = 'ess';
      status_type = 'in_obs';
      status_value = Number(value) || 0;
    } else if (lowerName === 'ess/in_obs') {
      status_source = 'ess';
      status_type = 'in_obs';
      status_value = Number(value) || 0;
    } else {
      const slash = name.indexOf('/');
      if (slash > 0) {
        status_source = name.slice(0, slash);
        status_type = name.slice(slash + 1);
      } else {
        // Fallback: treat as system-scoped single token
        status_source = 'system';
        status_type = name;
      }
    }

    // Update cache; only proceed if changed
    const changed = this.updateLocalStatusAndBroadcast(host, status_source, status_type, status_value);
    if (!changed) return;

    // Print concise status log
    console.log(`[HBWS][STATUS] ${host} ${status_source}/${status_type}=${status_value}`);

    // Simulated DB upsert log
    this.logSimulatedUpsert(host, status_source, status_type, status_value);
  }

  private async logSimulatedUpsert(host: string, status_source: string, status_type: string, status_value: string | number): Promise<void> {
    const payload = {
      table: 'server_status',
      action: 'upsert',
      values: { host, status_source, status_type, status_value },
      server_time: 'NOW()',
      note: 'simulated - not executed by index_ws.ts'
    };
    console.log('[HBWS][SIMULATED-UPSERT]', JSON.stringify(payload));
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    // periodic ping
    this.heartbeatTimer = setInterval(() => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
      try {
        this.lastHeartbeatSentAt = Date.now();
        (this.ws as any).ping?.();
      } catch {}
      if (this.heartbeatTimeoutHandle) clearTimeout(this.heartbeatTimeoutHandle);
      this.heartbeatTimeoutHandle = setTimeout(() => {
        const now = Date.now();
        try { this.ws?.terminate(); } catch {}
      }, this.heartbeatTimeoutMs);
    }, this.heartbeatIntervalMs);

    // stale guard watchdog
    this.staleCheckTimer = setInterval(() => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
      const silentFor = Date.now() - this.lastMessageAt;
      if (silentFor > this.staleMs) {
        console.warn(`[HBWS] Stale connection detected (${silentFor}ms), forcing reconnect`);
        try { this.ws.terminate(); } catch {}
      }
    }, this.heartbeatIntervalMs);

    // periodic touch sweep once per minute to refresh possibly stale datapoints
    this.refreshTimer = setInterval(() => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
      HOMEBASE_SUBSCRIPTIONS.forEach((m) => {
        try { this.touch(m); } catch {}
      });
    }, 60000);

    // periodic juicer voltage poll every 10s
    this.pollJuicerTimer = setInterval(() => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
      const voltageScript = '[set ::ess::current(juicer)] get pump_voltage';
      this.eval(voltageScript, 5000)
        .then((result) => {
          let voltage: number | null = null;
          try {
            if (typeof result === 'string') {
              const trimmed = result.trim();
              if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
                const obj = JSON.parse(trimmed);
                if (obj && typeof obj === 'object' && 'pump_voltage' in obj) {
                  const v = (obj as any).pump_voltage;
                  const n = typeof v === 'number' ? v : parseFloat(String(v));
                  if (!isNaN(n)) voltage = n;
                }
              } else {
                const n = parseFloat(trimmed);
                if (!isNaN(n)) voltage = n;
              }
            } else if (typeof result === 'number') {
              voltage = result;
            } else if (result && typeof result === 'object' && 'pump_voltage' in (result as any)) {
              const v = (result as any).pump_voltage;
              const n = typeof v === 'number' ? v : parseFloat(String(v));
              if (!isNaN(n)) voltage = n;
            }
          } catch {}

          if (voltage !== null) {
            const changed = this.updateLocalStatusAndBroadcast(this.hostIp, 'system', '24v-v', voltage);
            if (changed) {
              console.log(`[HBWS][STATUS] ${this.hostIp} system/24v-v=${voltage}`);
              this.logSimulatedUpsert(this.hostIp, 'system', '24v-v', voltage);
            }
          }
        })
        .catch(() => {});

      // Also poll charging status
      const chargingScript = '[set ::ess::current(juicer)] get charging';
      this.eval(chargingScript, 5000)
        .then((result) => {
          // Temporary debug: log all raw charging results
          try { console.log(`[HBWS][CHARGING-POLL] ${this.hostIp} raw:`, result); } catch {}
          let chargingStr: string | null = null;
          try {
            if (typeof result === 'string') {
              const trimmed = result.trim();
              if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
                const obj = JSON.parse(trimmed);
                if (obj && typeof obj === 'object' && 'charging' in obj) {
                  const v: any = (obj as any).charging;
                  if (typeof v === 'boolean') chargingStr = v ? 'true' : 'false';
                  else if (typeof v === 'number') chargingStr = String(v);
                  else if (typeof v === 'string') chargingStr = v.toLowerCase();
                }
              } else if (trimmed.toLowerCase() === 'true' || trimmed.toLowerCase() === 'false') {
                chargingStr = trimmed.toLowerCase();
              } else {
                const n = parseFloat(trimmed);
                if (!isNaN(n)) chargingStr = String(n);
              }
            } else if (typeof result === 'boolean') {
              chargingStr = result ? 'true' : 'false';
            } else if (typeof result === 'number') {
              chargingStr = String(result);
            } else if (result && typeof result === 'object' && 'charging' in (result as any)) {
              const v: any = (result as any).charging;
              if (typeof v === 'boolean') chargingStr = v ? 'true' : 'false';
              else if (typeof v === 'number') chargingStr = String(v);
              else if (typeof v === 'string') chargingStr = v.toLowerCase();
            }
          } catch {}

          // Temporary debug: parsed value
          try { console.log(`[HBWS][CHARGING-PARSE] ${this.hostIp} parsed=`, chargingStr); } catch {}

          if (chargingStr !== null) {
            const changed = this.updateLocalStatusAndBroadcast(this.hostIp, 'system', 'charging', chargingStr);
            if (changed) {
              console.log(`[HBWS][STATUS] ${this.hostIp} system/charging=${chargingStr}`);
              this.logSimulatedUpsert(this.hostIp, 'system', 'charging', chargingStr);
            }
          }
        })
        .catch(() => {});
    }, 10000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) { clearInterval(this.heartbeatTimer); this.heartbeatTimer = null; }
    if (this.heartbeatTimeoutHandle) { clearTimeout(this.heartbeatTimeoutHandle); this.heartbeatTimeoutHandle = null; }
    if (this.staleCheckTimer) { clearInterval(this.staleCheckTimer); this.staleCheckTimer = null; }
    if (this.refreshTimer) { clearInterval(this.refreshTimer); this.refreshTimer = null; }
    if (this.pollJuicerTimer) { clearInterval(this.pollJuicerTimer); this.pollJuicerTimer = null; }
  }

  private simulateConnectivityUpsert(connected: 0 | 1): void {
    const host = this.hostIp;
    const status_source = 'ess';
    const status_type = 'connected';
    const changed = this.updateLocalStatusAndBroadcast(host, status_source, status_type, connected);
    if (changed) {
      console.log(`[HBWS][STATUS] ${host} ${status_source}/${status_type}=${connected}`);
      this.logSimulatedUpsert(host, status_source, status_type, connected);
    }
  }

  // Update in-memory statusData and broadcast only if value changed
  private updateLocalStatusAndBroadcast(
    host: string,
    status_source: string,
    status_type: string,
    status_value: string | number
  ): boolean {
    try {
      const newVal = typeof status_value === 'number' ? String(status_value) : status_value;
      const key = `${host}|${status_source}|${status_type}`;
      if (this.lastValues.get(key) === newVal) {
        return false;
      }
      this.lastValues.set(key, newVal);
      const idx = statusData.findIndex(
        (e) => e.host === host && e.status_type === status_type && e.status_source === status_source
      );
      const nowIso = new Date().toISOString();
      let changed = false;
      if (idx >= 0) {
        if (statusData[idx].status_value !== newVal) {
          statusData[idx] = {
            host,
            status_source,
            status_type,
            status_value: newVal,
            sys_time: nowIso
          };
          changed = true;
        }
      } else {
        statusData.push({ host, status_source, status_type, status_value: newVal, sys_time: nowIso });
        changed = true;
      }
      if (changed) {
        const payload: StatusChanges = {
          host,
          status_source,
          status_type,
          status_value: newVal,
          sys_time: nowIso
        };
        broadcastToWebSocketClients('status_changes', payload);
        return true;
      }
    } catch {}
    return false;
  }

  private scheduleReconnect(): void {
    this.reconnectAttempts += 1;
    this.consecutiveFailures += 1;
    const now = Date.now();
    if (this.firstDisconnectAtMs === null) {
      this.firstDisconnectAtMs = now;
    }
    const elapsed = now - this.firstDisconnectAtMs;

    let delay: number;
    if (elapsed < this.fastRetryWindowMs) {
      // Fast retry phase: frequent attempts (2-3s)
      const jitter = Math.floor(Math.random() * this.fastRetryJitterMs);
      delay = this.fastRetryBaseMs + jitter;
      console.log(`[HBWS] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts}, fast-retry phase)`);
    } else {
      // Slow backoff phase: exponential from 15s up to 2m
      if (this.slowPhaseStartFailures === null) {
        this.slowPhaseStartFailures = this.consecutiveFailures;
      }
      const slowFailures = Math.max(0, this.consecutiveFailures - this.slowPhaseStartFailures);
      const backoff = Math.min(this.slowMaxBackoffMs, this.slowBaseBackoffMs * Math.pow(2, slowFailures));
      const jitter = Math.floor(Math.random() * this.slowJitterMs);
      delay = backoff + jitter;
      console.log(`[HBWS] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts}, slow-backoff phase)`);
    }
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  private getOpenSocket(): WebSocket {
    try {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
        throw new Error('Homebase WebSocket not connected');
      }
      return this.ws;
    } catch (e) {
      throw e;
    }
  }

  private send(obj: Record<string, unknown>): void {
    const ws = this.getOpenSocket();
    ws.send(JSON.stringify(obj));
  }

  private genRequestId(): string {
    return `hbws-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  }

  eval(script: string, timeoutMs = 10000): Promise<unknown> {
    const attemptImmediate = () => {
      const requestId = this.genRequestId();
      return new Promise<unknown>((resolve, reject) => {
        try {
          this.getOpenSocket();
          const timeoutId = setTimeout(() => {
            if (this.requestMap.has(requestId)) {
              this.requestMap.delete(requestId);
              this.currentInFlight = Math.max(0, this.currentInFlight - 1);
              reject(new Error(`Request timed out: ${script}`));
              this.tryDrainQueue();
            }
          }, timeoutMs);
          this.requestMap.set(requestId, { resolve, reject, timeoutId });
          this.currentInFlight += 1;
          this.send({ cmd: 'eval', script, requestId });
        } catch (e) {
          reject(e);
        }
      });
    };

    // If socket open and we have capacity, send now
    if (this.ws && this.ws.readyState === WebSocket.OPEN && this.currentInFlight < this.maxInFlight) {
      return attemptImmediate();
    }

    // Otherwise queue the request to run after reconnect or when capacity frees
    return new Promise<unknown>((resolve, reject) => {
      if (this.evalQueue.length >= this.maxQueueSize) {
        reject(new Error('Request queue full'));
        return;
      }
      this.evalQueue.push({ script, timeoutMs, resolve, reject, enqueuedAt: Date.now() });
      this.tryDrainQueue();
    });
  }

  private tryDrainQueue(): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    while (this.currentInFlight < this.maxInFlight && this.evalQueue.length > 0) {
      const job = this.evalQueue.shift()!;
      // Reuse eval immediate logic
      const requestId = this.genRequestId();
      try {
        const timeoutId = setTimeout(() => {
          if (this.requestMap.has(requestId)) {
            this.requestMap.delete(requestId);
            this.currentInFlight = Math.max(0, this.currentInFlight - 1);
            job.reject(new Error(`Request timed out: ${job.script}`));
            this.tryDrainQueue();
          }
        }, job.timeoutMs);
        this.requestMap.set(requestId, { resolve: job.resolve, reject: job.reject, timeoutId });
        this.currentInFlight += 1;
        this.send({ cmd: 'eval', script: job.script, requestId });
      } catch (e) {
        job.reject(e);
      }
    }
  }

  subscribe(match: string, every: number = 1): void {
    try {
      this.send({ cmd: 'subscribe', match, every });
    } catch (e) {
      console.error('[HBWS] subscribe failed:', e);
    }
  }

  unsubscribe(match: string): void {
    try {
      this.send({ cmd: 'unsubscribe', match });
    } catch (e) {
      console.error('[HBWS] unsubscribe failed:', e);
    }
  }

  touch(name: string): void {
    try {
      this.send({ cmd: 'touch', name });
    } catch (e) {
      console.error('[HBWS] touch failed:', e);
    }
  }

  private safeBroadcast(eventType: string, data: any): void {
    try {
      if (!wss) return;
      wss.clients.forEach((wsClient: WebSocket) => {
        if (wsClient.readyState === WebSocket.OPEN) {
          wsClient.send(JSON.stringify({ type: eventType, data }));
        }
      });
    } catch (err) {
      console.error('[HBWS] safeBroadcast error:', err);
    }
  }
}

// -----------------------------
// Homebase Connection Registry
// -----------------------------
const homebaseConnections: Map<string, HomebaseWS> = new Map();

function getHomebaseWS(ip: string): HomebaseWS | null {
  if (HOMEBASE_ALLOWED_IPS.length > 0 && !HOMEBASE_ALLOWED_IPS.includes(ip)) {
    console.warn('[HBWS] Requested IP not allowed:', ip);
    return null;
  }
  if (!homebaseConnections.has(ip)) {
    const hb = new HomebaseWS(ip);
    homebaseConnections.set(ip, hb);
    hb.connect();
  }
  return homebaseConnections.get(ip)!;
}

async function startWebSocketServer() {
  await fetchCurrentStatus();
  await fetchCurrentCommStatus();
  await fetchCurrentPerfStats();

  wss = new WebSocketServer({ port: 8080 });

  wss.on('connection', (ws: WebSocket) => {
    console.log('New WebSocket connection established');

    // Send the current status and commstatus data to the newly connected client
    ws.send(JSON.stringify({ type: 'status', data: statusData }));
    ws.send(JSON.stringify({ type: 'commStatus', data: commStatus }));
    ws.send(JSON.stringify({ type: 'perfStats', data: perfStatsData }));

    ws.on('message', (message: string) => {
      let msg = JSON.parse(message);
      console.log('Received message from client:', msg);
      if (msg?.msg_type === 'esscmd') handleEssGitCommand('ess', msg.ip, msg.msg, ws);
      if (msg?.msg_type === 'gitcmd') handleEssGitCommand('git', msg.ip, msg.msg, ws);
      msg?.msg_type === 'AddDevice' && addDevice(msg.ip, msg.msg); // Forward message to DS on relevant homebase
      msg?.msg_type === 'Addsubject' && addAnimal(msg.msg); // Add animal to database
      msg?.msg_type === 'sql_query' && sqlQuery(msg.msg, ws); // Get resp from db
      msg?.msg_type === 'get_options' && getOptions(msg.msg, ws); // Get resp from db
    });

    ws.on('close', () => {
      console.log('WebSocket connection closed');
    });
  });
}

// Initial query to get current status of tasks on homebase systems
async function fetchCurrentStatus() {
  try {
    const result = await pool.query<StatusChanges>('SELECT * FROM server_status');  // Specify StatusChanges as the query result type
    statusData = result.rows;
  } catch (error) {
    console.error('Error fetching initial status data:', error);
  }
}

// Initial query to get current performance statistics
async function fetchCurrentPerfStats() {
  try {
    const result = await pool.query<RecentStatsChanges>('SELECT * FROM server_recent_stats');
    perfStatsData = result.rows;
  } catch (error) {
    console.error('Error fetching performance stats data:', error);
  }
}

// Add a new device which will be pinged and shown on web clients
async function addDevice(ipAddress: string, message: string){
  console.log('Sending new Device to DB:', message, ipAddress)
  // device and address should already be validated by the client before arriving here
  try {
    await pool.query(
      `INSERT INTO comm_status (device, address) VALUES ($1, $2)`,
      [message, ipAddress]
    );
  } catch (error) {
    console.error('Error updating comm_status table:', error);
  }
}

async function addAnimal(animalName: string) {
  console.log('adding animal to db:', animalName);
  try {
    const { devices, uniqueAnimalOptions } = await fetchUniqueAnimalOptions();
    console.log('Devices:', devices);
    console.log('Unique Animal Options:', uniqueAnimalOptions);

    // Filter out any empty strings from uniqueAnimalOptions
    let cleanedAnimalOptions = uniqueAnimalOptions.filter(option => option.trim() !== '');

    // Ensure 'test' is always the first option
    const lowercasedOptions = cleanedAnimalOptions.map(option => option.toLowerCase());
    if (lowercasedOptions.indexOf('test') === -1) {
      cleanedAnimalOptions.unshift('test');
    }

    // Append 'animalName' only if its lowercase version is not already in lowercasedOptions
    if (lowercasedOptions.indexOf(animalName.toLowerCase()) === -1) {
      cleanedAnimalOptions.push(animalName);
    }

    console.log('New Options:', cleanedAnimalOptions);

    // Call the upsert function with updated options
    upsertAnimals(devices, cleanedAnimalOptions);
  } catch (error) {
    console.error('Error calling fetchUniqueAnimalOptions:', error);
  }
}


async function sqlQuery(query: string, clientWs: WebSocket): Promise<void> {
  if (!validateQuery(query)) {
    console.error("Query rejected: Only SELECT queries are allowed.");
    clientWs.send(
      JSON.stringify({ 
        type: 'error', 
        message: 'Only SELECT queries are allowed.' 
      } as ErrorResponse)
    );
    return;
  }

  try {
    const result = await pool.query(query);
    console.log("Raw Query Result:", result.rows);

    // Convert the rows with proper type handling
    const convertedRows = result.rows.map((row: QueryRow) => {
      const convertedRow: Record<string, unknown> = {};
      
      // Use Object.keys() instead of Object.entries()
      Object.keys(row).forEach(key => {
        const value = row[key];

        // Skip null/undefined values
        if (value === null || value === undefined) {
          convertedRow[key] = value;
          return;
        }

        const strValue = String(value);

        // Handle dates
        if (isValidDate(value)) {
          convertedRow[key] = formatDate(value);
          return;
        }

        // Handle numbers and percentages
        if (!isNaN(parseFloat(strValue))) {
          convertedRow[key] = convertNumericValue(strValue);
          return;
        }

        // Keep other values as-is
        convertedRow[key] = value;
      });

      return convertedRow;
    });

    console.log("Converted Query Result:", convertedRows);

    const response: SqlResponse = {
      type: 'sql_table',
      result: convertedRows
    };

    clientWs.send(JSON.stringify(response));

  } catch (err) {
    console.error("Error executing SQL query:", err);
    const errorResponse: ErrorResponse = {
      type: 'error',
      message: 'Failed to execute SQL query.'
    };
    clientWs.send(JSON.stringify(errorResponse));
  }
}


// Helper function to check if a value might be a percentage
function isPercentage(value: string): boolean {
  return value.includes('%') || (
    !isNaN(parseFloat(value)) && 
    parseFloat(value) >= 0 && 
    parseFloat(value) <= 100
  );
}

// Helper function to check if a string is a valid date
function isValidDate(value: any): boolean {
  if (value instanceof Date) return !isNaN(value.getTime());
  
  // If it's a number or looks like a simple number, it's not a date
  if (typeof value === 'number' || !isNaN(Number(value))) return false;
  
  // Check if string contains date-like patterns (e.g., YYYY-MM-DD, has 'T' timestamp, etc.)
  if (typeof value === 'string') {
    // Must contain either a dash (YYYY-MM-DD) or 'T' (ISO timestamp)
    if (!value.includes('-') && !value.includes('T')) return false;
    
    const date = new Date(value);
    return !isNaN(date.getTime());
  }
  
  return false;
}

// Helper function to format date as YYYY-MM-DD
function formatDate(dateStr: string): string {
  const date = new Date(dateStr);
  return date.toISOString().split('T')[0];
}

// Helper function to safely convert numeric values
function convertNumericValue(value: string): number | string {
  // If it's clearly a percentage, preserve the decimal form
  if (isPercentage(value)) {
    const numValue = parseFloat(value.replace('%', ''));
    return numValue;
  }

  // Regular number conversion with additional safety checks
  const numValue = parseFloat(value);
  
  // Check if it's actually a number and not just "numeric-looking"
  if (!isNaN(numValue) && String(numValue) === value.trim()) {
    return numValue;
  }

  // If conversion isn't safe, return original value
  return value;
}


// function getOptions(query: string): boolean {
//   // Regex to check if the query starts with "SELECT" (case-insensitive)
//   return /^\s*SELECT/i.test(query);
// }

async function getOptions(query: string, clientWs: WebSocket): Promise<void> {
  if (!validateQuery(query)) {
    console.error("Query rejected: Only SELECT queries are allowed.");
    clientWs.send(
      JSON.stringify({ type: 'error', message: 'Only SELECT queries are allowed.' })
    );
    return;
  }

  try {
    const result = await pool.query(query);
    console.log("Query result:", result.rows);

    // Send the query result back to the requesting client
    clientWs.send(JSON.stringify({ type: 'listbox_options', result: result.rows }));
  } catch (err) {
    console.error("Error executing SQL query:", err);
    clientWs.send(
      JSON.stringify({ type: 'error', message: 'Failed to execute SQL query.' })
    );
  }
}

function validateQuery(query: string): boolean {
  // Remove any leading/trailing whitespace
  const trimmedQuery = query.trim();
  
  // Check if query starts with either SELECT or WITH
  const isValidStart = /^\s*(WITH|SELECT)/i.test(trimmedQuery);
  
  // Check for dangerous keywords that might indicate SQL injection attempts
  const hasDangerousKeywords = /\b(INSERT|UPDATE|DELETE|DROP|TRUNCATE|ALTER|GRANT|REVOKE|EXECUTE|CREATE)\b/i.test(trimmedQuery);
  
  // Check for multiple statements using semicolon
  const hasMultipleStatements = /;.+/i.test(trimmedQuery);
  
  return isValidStart && !hasDangerousKeywords && !hasMultipleStatements;
}

// function isSelectQuery(query: string): boolean {
//   // Regex to check if the query starts with "SELECT" (case-insensitive)
//   return /^\s*SELECT/i.test(query);
// }

async function upsertAnimals(devices: string[], uniqueAnimalOptions: string[]) {
  try {
    for (const device of devices) {
      // Convert uniqueAnimalOptions array to a comma-separated string
      const statusVal = uniqueAnimalOptions.join(',');

      // Upsert for each device
      await pool.query(
        `
        INSERT INTO server_status (host, status_source, status_type, status_value)
        VALUES ($1, 'ess', 'animalOptions', $2)
        ON CONFLICT (host, status_source, status_type) 
        DO UPDATE SET status_value = EXCLUDED.status_value;
        `,
        [device, statusVal]
      );
    }
    console.log('Upsert completed for all devices.');
  } catch (error) {
    console.error('Error upserting status for devices:', error);
    throw error; // Re-throw the error to handle it further up if needed
  }
}

// Legacy TCP DS client removed in favor of WebSocket-based control

// after requesting ess::get_system_status from a HB, update the database 
async function updateStatus(ipAddress: string, parsedObject: { [key: string]: string }) {
  try {
    // Get the correct device (hb) based on the IP address
    // const { rows } = await pool.query<CommStatus>('SELECT device FROM comm_status WHERE address = $1', [ipAddress]);
    // const device = rows[0]?.device;

    // if (!device) {
    //   console.error(`Device not found for IP address ${ipAddress}`);
    //   return;
    // }

    // Destructure parsed object values
    const { system = "", protocol = "", variant = "", state = "", in_obs = "" } = parsedObject;

    // Upsert for in_obs status
    await pool.query(
      `INSERT INTO server_status (host, status_source, status_type, status_value, server_time)
       VALUES ($1, 'ess', 'in_obs', $2, NOW())
       ON CONFLICT (host, status_source, status_type) DO UPDATE 
       SET status_value = $2, server_time = NOW();`,
      [ipAddress, in_obs]
    );

    // Upsert for running status based on state
    const runningStatus = state === 'stopped' ? 0 : 1;
    await pool.query(
      `INSERT INTO server_status (host, status_source, status_type, status_value, server_time)
       VALUES ($1, 'ess', 'running', $2, NOW())
       ON CONFLICT (host, status_source, status_type) DO UPDATE 
       SET status_value = $2, server_time = NOW();`,
      [ipAddress, runningStatus]
    );

    // Upsert for variant status based on system, protocol, and variant values
    const variantStatus = system === "" ? " : : " : `${system}:${protocol}:${variant}`;
    await pool.query(
      `INSERT INTO server_status (host, status_source, status_type, status_value, server_time)
       VALUES ($1, 'ess', 'variant', $2, NOW())
       ON CONFLICT (host, status_source, status_type) DO UPDATE 
       SET status_value = $2, server_time = NOW();`,
      [ipAddress, variantStatus]
    );

    console.log(`Status table updated for device ${ipAddress}`);
  } catch (error) {
    console.error('Error updating status:', error);
  }
}

// after requesting ess::get_subject from a HB, update the database 
async function updateSubject(ipAddress: string, subject: string) {
  try {
    // Get the correct device (hb) based on the IP address
    // const { rows } = await pool.query<CommStatus>('SELECT device FROM comm_status WHERE address = $1', [ipAddress]);
    // const device = rows[0]?.device;

    // if (!device) {
    //   console.error(`Device not found for IP address ${ipAddress}`);
    //   return;
    // }
    console.log(`Status table updating for device ${ipAddress}, subject ${subject}`);
    await pool.query(
      `INSERT INTO server_status (host, status_source, status_type, status_value, server_time)
       VALUES ($1, 'ess', 'animal', $2, NOW())
       ON CONFLICT (host, status_source, status_type) DO UPDATE 
       SET status_value = $2, server_time = NOW();`,
      [ipAddress, subject]
    );

    console.log(`Status table updated for device ${ipAddress}, subject ${subject}`);
  } catch (error) {
    console.error('Error updating status:', error);
  }
}

async function fetchUniqueAnimalOptions() {
  try {
    // Fetch all devices from comm_status
    const deviceResult = await pool.query<{ address: string }>("SELECT address FROM comm_status;");
    const devices = deviceResult.rows.map((row: { address: string }) => row.address);

    // Fetch animalOptions from status where status_type is 'animalOptions'
    const statusResult = await pool.query<{ status_value: string }>(
      "SELECT status_value FROM server_status WHERE status_type = 'animalOptions';"
    );

    // Create a Set to ensure unique animal options
    const animalOptionsSet = new Set<string>();
    statusResult.rows.forEach((row: { status_value: string }) => {
      row.status_value.split(',').forEach((option: string) => animalOptionsSet.add(option.trim()));
    });

    const uniqueAnimalOptions = Array.from(animalOptionsSet);

    // Return devices and uniqueAnimalOptions
    return { devices, uniqueAnimalOptions };
    
  } catch (error) {
    console.error('Error fetching unique animal options:', error);
    throw error; // Re-throw the error to handle it further up if needed
  }
}




//////////////////////////////////////////////
// Listen for changes on the postgres database
// update relevant status held here and notify
// web clients to also update their versions

interface NotificationMessage {
  channel: string;
  payload?: string;
}

function connectNotificationClient(): void {
  const notificationClient = new Client(dbConfig);

  // Attempt to connect.
  notificationClient
    .connect()
    .then(() => {
      console.log('Notification client connected.');
      // Register for the notification channels.
      return Promise.all([
        notificationClient.query("LISTEN status_changes"),
        notificationClient.query("LISTEN comm_status_changes"),
        notificationClient.query("LISTEN perf_stats_changes"),
        notificationClient.query("LISTEN new_image") // Listen for new_image notifications
      ]);
    })
    .then(() => {
      console.log('Notification client is listening for notifications.');
    })
    .catch((err: unknown) => {
      console.error('Error connecting notification client:', err);
      // Retry connection after 5 seconds.
      setTimeout(connectNotificationClient, 5000);
    });

  // Handle incoming notifications.
  notificationClient.on('notification', (msg: NotificationMessage) => {
    if (!msg.payload) return;
    let payload;
    try {
      payload = JSON.parse(msg.payload);
    } catch (error) {
      console.error('Failed to parse notification payload:', error);
      return;
    }

    // Dispatch to the appropriate handler.
    const handlers: Record<string, (data: any) => void> = {
      status_changes: handleStatusChanges,
      comm_status_changes: handleCommStatusChanges,
      perf_stats_changes: handleRecentStatsChanges,
      new_image: handleNewImage // Add handler for new_image
    };

    if (handlers[msg.channel]) {
      handlers[msg.channel](payload);
    }
  });

  // If the client errors out, close it and attempt a reconnection.
notificationClient.on('error', (err: unknown) => {
    console.error('Notification client error:', err);
    notificationClient.end()
      .then(() => {
        setTimeout(connectNotificationClient, 5000);
      })
      .catch(() => {
        setTimeout(connectNotificationClient, 5000);
      });
  });
}

// Start the notification client with reconnection enabled.
connectNotificationClient();


// client.connect();

// client.query("LISTEN status_changes");
// client.query("LISTEN comm_status_changes");
// client.query("LISTEN perf_stats_changes");

// interface NotificationMessage {
//   channel: string;
//   payload?: string;
// }

// client.on('notification', (msg: NotificationMessage) => {
//   if (!msg.payload) return;

//   let payload;
//   try {
//     payload = JSON.parse(msg.payload);
//   } catch (error) {
//     return console.error('Failed to parse notification payload:', error);
//   }

//   const handlers: Record<string, (data: any) => void> = {
//     status_changes: handleStatusChanges,
//     comm_status_changes: handleCommStatusChanges,
//     perf_stats_changes: handleRecentStatsChanges
//   };

//   handlers[msg.channel]?.(payload);
// });

// Generic function to handle notifications and update relevant data
function handleNotification<T extends object>(
  eventType: string,
  payload: T,
  dataStore: T[],
  findIndexCallback: (entry: T) => boolean,
  deleteOnZeroTrials: boolean = false
) {
  broadcastToWebSocketClients(eventType, payload);

  const index = dataStore.findIndex(findIndexCallback);

  // Type guard to check if payload has a 'trials' property and if deleteOnZeroTrials is enabled
  if (deleteOnZeroTrials && isRecentStatsChanges(payload) && payload.trials === 0) {
    if (index !== -1) {
      dataStore.splice(index, 1); // Remove the entry from the array
      console.log(`Removed entry for ${eventType} with trials=0:`, payload);
    }
  } else {
    // Update the entry if it exists, otherwise add it
    if (index !== -1) {
      dataStore[index] = payload; // Replace the entire entry
    } else {
      dataStore.push(payload); // Add new entry if not found
    }
  }
}


// Type guard to check if payload is of type RecentStatsChanges and has trials
function isRecentStatsChanges(payload: any): payload is RecentStatsChanges {
  return typeof payload === 'object' && 'trials' in payload && typeof payload.trials === 'number';
}

// Specific handlers using the generic function
function handleStatusChanges(payload: StatusChanges) {
  // console.log('status change: ', payload)
  handleNotification('status_changes', payload, statusData, (entry) =>
    entry.host === payload.host && entry.status_type === payload.status_type
  );
}

// handleNewImage is now called with an already parsed JSON object from the main notification handler
async function handleNewImage(parsedPayload: { host: string; status_type: string }) {
  try {
    // The payload is already parsed, directly destructure host and status_type
    const { host: queryHost, status_type: queryImageType } = parsedPayload;

    if (!queryHost || !queryImageType) {
      console.error(
        'Invalid new_image notification payload object. Missing host or status_type properties:',
        parsedPayload // Log the received object for debugging
      );
      return;
    }

    console.log(
      `Received new_image notification for host: ${queryHost}, type: ${queryImageType}. Fetching data...`
    );

    // Query the database for the actual image data using host and status_type
    const result = await pool.query<DbQueryResultStatus>(
      `SELECT host, status_source, status_type, status_value, server_time AS sys_time
       FROM server_status
       WHERE host = $1 AND status_type = $2
       ORDER BY server_time DESC
       LIMIT 1;`, // Fetch the most recent if multiple, though expecting one based on host/status_type uniqueness for images
      [queryHost, queryImageType]
    );

    if (result.rows.length > 0) {
      const dbRow = result.rows[0]; // dbRow is now of type DbQueryResultStatus
      
      const imageDataPayload: StatusChanges = { // Target type is still StatusChanges
        host: dbRow.host,
        status_source: dbRow.status_source,
        status_type: dbRow.status_type,
        status_value: dbRow.status_value, // Contains the large image data
        sys_time: dbRow.sys_time  // This is Date | string | null from DbQueryResultStatus
          ? (dbRow.sys_time instanceof Date ? dbRow.sys_time.toISOString() : String(dbRow.sys_time))
          : undefined,
      };
      
      console.log('Fetched image data, now handling as status_changes:', imageDataPayload.status_type, imageDataPayload.host);

      handleNotification(
        'status_changes',    // Use the existing event type for clients
        imageDataPayload,    // The fetched image data
        statusData,          // Store in the main statusData array
        (entry) =>           // Standard findIndexCallback
          entry.host === imageDataPayload.host &&
          entry.status_type === imageDataPayload.status_type,
        false                // deleteOnZeroTrials is false for images
      );
    } else {
      console.error(
        `Image data not found in server_status for host '${queryHost}', type '${queryImageType}'`
      );
    }
  } catch (error) {
    console.error('Error handling new_image notification:', error);
    if (error instanceof SyntaxError) {
      console.error(
        'Failed to parse new_image notification payload. Ensure it is valid JSON:',
        parsedPayload
      );
    }
  }
}

function handleCommStatusChanges(payload: CommStatus) {
  // console.log('notifying commStatus change', payload)
  handleNotification('comm_status_changes', payload, commStatus, (entry) =>
    entry.device === payload.device && entry.address === payload.address
  );
}

function handleRecentStatsChanges(payload: RecentStatsChanges) {
  // console.log('updated perf stats: ', payload)
  handleNotification('perf_stats_changes', payload, perfStatsData, (entry) =>
    entry.host === payload.host &&
    entry.status_type === payload.status_type &&
    entry.subject === payload.subject &&
    entry.state_system === payload.state_system &&
    entry.protocol === payload.protocol &&
    entry.variant === payload.variant,
    false // Enable delete on zero trials
  );
}

// Function to broadcast messages to all WebSocket clients
function broadcastToWebSocketClients(eventType: string, data: any) {
  try {
    if (!wss) return;
    wss.clients.forEach((ws: WebSocket) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: eventType, data }));
      }
    });
  } catch (broadcastError) {
    console.error(`Error broadcasting ${eventType} to WebSocket clients:`, broadcastError);
  }
}

// Handle ESS/Git commands from web clients via WS to homebase
function handleEssGitCommand(kind: 'ess' | 'git', ip: string, payload: string, clientWs: WebSocket) {
  try {
    const hb = getHomebaseWS(ip);
    if (!hb) {
      clientWs.send(JSON.stringify({ type: 'error', message: `HBWS not allowed or unavailable for ${ip}` }));
      return;
    }
    const script = kind === 'ess' ? payload : `send git {${payload}}`;
    hb.eval(script, 15000)
      .then((result) => {
        clientWs.send(JSON.stringify({ type: 'cmd_ok', kind, ip, result }));
      })
      .catch((err) => {
        const message = (err instanceof Error) ? err.message : String(err);
        clientWs.send(JSON.stringify({ type: 'cmd_error', kind, ip, error: message }));
        broadcastToWebSocketClients('TCL_ERROR', message);
      });
  } catch (e) {
    const message = (e instanceof Error) ? e.message : String(e);
    clientWs.send(JSON.stringify({ type: 'error', message }));
  }
}



/////////////////////////////////////////////////////////////
// Handle communication checks on each homebase system
// After pinging a device, update the DB to reflect the results
// Should be the average latency and proportion of success of last 100 pings
// If and only if the last ping was succesful, also update last_ping

interface CommStatus {
  device: string;
  address: string;
  ping_avg: number;
  ping_success: number;
  server_time: string;
  last_ping: string | null;
  hide_from: string | null;
}

let commStatus: CommStatus[] = [];
type PingResult = { success: boolean; time?: number };
const pingResults: Record<string, PingResult[]> = {};

/// this is running correctly i think
// Calculate average time and success rate
function calculatePingStats(pings: PingResult[]) {
  const successful = pings.filter(p => p.success && p.time !== undefined);
  const avgTime = successful.length ? Math.round(successful.reduce((sum, p) => sum + (p.time || 0), 0) / successful.length) : 0;
  const successRate = pings.length ? parseFloat((successful.length / pings.length).toFixed(2)) : 0;
  return { avgTime, successRate };
}

/// this is running correctly i think
// Fetch initial status data for clients
async function fetchCurrentCommStatus() {
  try {
    commStatus = (await pool.query<CommStatus>("SELECT * FROM comm_status WHERE hide_from != '*' ORDER BY device;")).rows;
  } catch (error) {
    console.error('Error fetching initial communication status:', error);
  }
}

/// this is running correctly i think
async function updateCommStatus(device: string, lastPingSuccessful: boolean) {
  const { avgTime, successRate } = calculatePingStats(pingResults[device]);
  try {
    await pool.query(
      `INSERT INTO comm_status (device, ping_avg, ping_success, last_ping, server_time)
       VALUES ($1, $2, $3, CURRENT_TIMESTAMP(3), CURRENT_TIMESTAMP(3))
       ON CONFLICT (device) DO UPDATE SET
         ping_avg = $2, 
         ping_success = $3, 
         last_ping = CASE WHEN $4 THEN CURRENT_TIMESTAMP(3) ELSE comm_status.last_ping END, 
         server_time = CURRENT_TIMESTAMP(3)`,
      [device, avgTime, successRate, lastPingSuccessful]
    );
  } catch (error) {
    console.error('Error updating comm_status table:', error);
  }
}

const lastConnectionStatus: Record<string, boolean> = {}; // Track last known status

/// this is running correctly i think
async function pingDevices() {
  try {
    // const devices: CommStatus[] = (await pool.query<CommStatus>("SELECT device, address FROM comm_status WHERE hide_from != '*' ORDER BY device;")).rows;
    const devices: CommStatus[] = (await pool.query<CommStatus>("SELECT device, address FROM comm_status;")).rows;

    await Promise.all(devices.map(async ({ device, address }) => {
      pingResults[device] ||= []; // Initialize if undefined

      try {
        const { alive, time } = await ping.promise.probe(address, { timeout: 0.5 });
        const currentStatus = alive;
        pingResults[device].push({ success: alive, time: alive && typeof time === 'number' ? time : undefined });

        // Check if the device has transitioned from no connection to connection
        // No legacy TCP refresh here; WS subscriptions handle state

        // Update the last known status
        lastConnectionStatus[device] = currentStatus;

      } catch (error) {
        console.error(`Error pinging device ${device}:`, error);
        pingResults[device].push({ success: false });
      }

      // Keep only the last 100 pings
      pingResults[device] = pingResults[device].slice(-100);

      await updateCommStatus(device, pingResults[device].slice(-1)[0].success);
    }));
  } catch (error) {
    console.error('Error fetching devices for pinging:', error);
  }
}

/// this is running correctly i think
const startWebServer = (staticPath: string): void => {
  const app = express();

  // Define index.html path based on the provided staticPath
  const indexFile = path.join(staticPath, 'index.html');
  // const PORT = parseInt(process.env.PORT || '3000', 10);

  // Serve static files from the specified path
  app.use(express.static(staticPath));

  // Serve index.html for all routes to support SPA routing
  app.get('*', (req: Request, res: Response) => {
    res.sendFile(indexFile);
  });

  // Start the server
  const WEB_PORT = process.env.WEB_PORT || '3000';
  app.listen(parseInt(WEB_PORT, 10), () => console.log(`Web server running on port ${WEB_PORT}`));
  };




pingDevices(); setInterval(pingDevices, 10000);
// startWebSocketServer(); // Temporarily disabled to avoid port conflict on 8080
// Initialize Homebase WebSocket clients for all known devices
// Initialize Homebase WebSocket clients for all known devices
(async () => {
  try {
    const devices: CommStatus[] = (await pool.query<CommStatus>("SELECT device, address FROM comm_status;" )).rows as any;
    devices.forEach(({ address }) => {
      getHomebaseWS(address);
    });
  } catch (e) {
    console.error('[HBWS] Failed to bootstrap HB WS clients from comm_status:', e);
  }
})();
// startWebServer(webpage_path); // Temporarily disabled to avoid port conflict during WS client testing