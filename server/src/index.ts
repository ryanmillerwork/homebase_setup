// Web socket with web clients
// Postgres listener
// Communication checker (pinging homebases)
// webserver

import { Pool, Client, QueryResult } from 'pg';     // MIT License
import { WebSocketServer, WebSocket } from 'ws';    // MIT License
import ping from 'ping';                            // MIT License
import { Socket } from 'net';                       // MIT License
import path from 'path';
import express, { Request, Response } from 'express';

// for webserver
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

pool.on('error', (err) => {
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
      msg?.msg_type === 'esscmd' && sendToDS(msg.ip, 2570, msg.msg); // Forward message to DS on relevant homebase
      msg?.msg_type === 'gitcmd' && sendToDS(msg.ip, 2573, msg.msg); // Forward message to DS on relevant homebase
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
    if (!lowercasedOptions.includes('test')) {
      cleanedAnimalOptions.unshift('test');
    }

    // Append 'animalName' only if its lowercase version is not already in lowercasedOptions
    if (!lowercasedOptions.includes(animalName.toLowerCase())) {
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

// Send a message to the dataserver on one of the homebases
function sendToDS(ipAddress: string, dsPort: number, message: string) {
  const dsSocket = new Socket();

  dsSocket.connect(dsPort, ipAddress, () => {

    console.log('sending: ', message)
    dsSocket.write(message);

    if (message.includes("ess::set_variant_args") || message.includes("ess::set_params")) {
      console.log('also sending reset cmd...');
      dsSocket.write('::ess::reload_variant');
    }
  });

  dsSocket.on('data', (data) => {
    const response = data.toString();
    console.log('Received from ds:', response);

    if (response.includes('TCL_ERROR')) {
      console.log('got an error, sending to client...')
      broadcastToWebSocketClients('TCL_ERROR', data.toString())

    } else if (message.includes('get_system_status')) {
      console.log("Message contains 'get_system_status'", ipAddress, message);

      // example message: {"system":"","protocol":"circles","variant":"single","state":"stopped","in_obs":"0"}
      // parsedObject = JSON.parse(message)

      try {
        updateStatus(ipAddress, JSON.parse(data.toString()));
      } catch (error) {
        console.error('Failed to update status:', error);
      }

  
    } else if (message.includes('get_subject')) {
      console.log("Message contains 'get_subject'", ipAddress, message);
      try {
        updateSubject(ipAddress, data.toString());
      } catch (error) {
        console.error('Failed to update subject:', error);
      }

    }
    dsSocket.end();
  });

  dsSocket.on('close', () => {
    console.log('DS connection closed');
  });

  dsSocket.on('error', (err) => {
    console.error('Error with DS:', err);
  });
}

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
    const devices = deviceResult.rows.map(row => row.address);

    // Fetch animalOptions from status where status_type is 'animalOptions'
    const statusResult = await pool.query<{ status_value: string }>(
      "SELECT status_value FROM server_status WHERE status_type = 'animalOptions';"
    );

    // Create a Set to ensure unique animal options
    const animalOptionsSet = new Set<string>();
    statusResult.rows.forEach(row => {
      row.status_value.split(',').forEach(option => animalOptionsSet.add(option.trim()));
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
    .catch(err => {
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
  notificationClient.on('error', (err) => {
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
    wss.clients.forEach((ws: WebSocket) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: eventType, data }));
      }
    });
  } catch (broadcastError) {
    console.error(`Error broadcasting ${eventType} to WebSocket clients:`, broadcastError);
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
        if (currentStatus && lastConnectionStatus[device] === false) {
          sendToDS(address, 2570, '::ess::get_system_status');
          sendToDS(address, 2570, '::ess::get_subject');
        }

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
startWebSocketServer();
startWebServer(webpage_path);