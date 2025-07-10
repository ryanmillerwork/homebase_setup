import express, { Request, Response } from "express";
import { Pool } from "pg";

const app = express();
app.use(express.json({ limit: "10mb" })); // Adjust the limit as needed

// Database configuration
const dbConfig = {
  user: "postgres",
  host: "localhost",
  database: "base",
  password: "postgres",
  port: 5432,
};

// Initialize PostgreSQL connection pool
const pool = new Pool(dbConfig);

// Listen for errors on idle clients so that they don't crash the process.
pool.on("error", (err, client) => {
  console.error("Unexpected error on idle PostgreSQL client:", err);
});

// Helper function to get a pool client with retry logic.
async function getPoolClientWithRetry(maxRetries = 3) {
  let attempts = 0;
  while (attempts < maxRetries) {
    try {
      const client = await pool.connect();
      return client;
    } catch (err) {
      attempts++;
      console.error(
        `Error acquiring client from pool. Retrying (${attempts}/${maxRetries})...`,
        err
      );
      // Wait 5 seconds before retrying
      await new Promise((resolve) => setTimeout(resolve, 5000));
    }
  }
  throw new Error("Unable to acquire client from pool after multiple attempts");
}

interface StatusChanges {
  host: string;
  status_source: string;
  status_type: string;
  status_value: string;
  sys_time?: string;
}

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

app.post("/upsert_status", async (req: Request, res: Response) => {
  const rows: StatusChanges[] = req.body.rows;
  console.log("Received upsert_status payload");

  if (!Array.isArray(rows)) {
    return res
      .status(400)
      .send({ error: 'Invalid payload: "rows" must be an array.' });
  }

  const skippedRows: StatusChanges[] = [];
  const MAX_RETRIES = 3;

  try {
    const client = await getPoolClientWithRetry();
    try {
      for (const row of rows) {
        const { host, status_source, status_type, status_value } = row;

        if (
          !host ||
          !status_source ||
          !status_type ||
          status_value === undefined ||
          status_value === null
        ) {
          console.warn("Skipping invalid row:", JSON.stringify(row, null, 2));
          skippedRows.push(row);
          continue;
        }

        let attempts = 0;
        while (attempts < MAX_RETRIES) {
          try {
            await client.query("BEGIN"); // Start a new transaction
            const insertQuery = `
              INSERT INTO server_status (host, status_source, status_type, status_value)
              VALUES ($1, $2, $3, $4)
              ON CONFLICT (host, status_source, status_type) DO UPDATE
              SET status_value = EXCLUDED.status_value,
                  server_time = CURRENT_TIMESTAMP;
            `;
            await client.query(insertQuery, [
              host,
              status_source,
              status_type,
              status_value,
            ]);
            await client.query("COMMIT"); // Commit the transaction
            break; // Exit retry loop on success
          } catch (err: any) {
            await client.query("ROLLBACK"); // Roll back the transaction on error
            if (err.code === "40P01") {
              // Deadlock detected
              attempts++;
              console.warn(
                `Deadlock detected. Retrying (${attempts}/${MAX_RETRIES})...`
              );
              await new Promise((resolve) => setTimeout(resolve, 100)); // Short delay before retry
            } else {
              // Add context for the failing row to the error object
              (err as any).context_host = host;
              (err as any).context_status_type = status_type;
              (err as any).context_status_value_length = (typeof status_value === 'string') ? status_value.length : 'N/A (not a string or unavailable)';
              throw err; // Re-throw non-deadlock errors
            }
          }
        }

        if (attempts === MAX_RETRIES) {
          console.error("Max retries reached for row:", row);
          skippedRows.push(row);
        }
      }

      res.send({
        success: true,
        message: `${rows.length - skippedRows.length} rows processed, ${skippedRows.length} rows skipped.`,
        skippedRows,
      });
    } catch (err: any) {
      // Construct additional error information if available from row processing
      let extraInfo = "";
      const contextHost = (err as any).context_host;
      const contextStatusType = (err as any).context_status_type;
      const contextStatusValueLength = (err as any).context_status_value_length;

      if (contextHost && contextStatusValueLength !== undefined) {
        let parts = [
          `Host: ${contextHost}`,
          contextStatusType ? `Status Type: ${contextStatusType}` : '',
          `Status Value Length: ${contextStatusValueLength} chars`
        ].filter(part => part !== '').join(', '); // Join with comma, filter empty parts
        extraInfo = ` (${parts})`;
      }

      console.error(
        `Error inserting/updating rows in server_status${extraInfo}:`, // Log with extra context
        err.message || err, // Original error message part
        err // Log the full error object for more details (e.g., error codes)
      );
      res
        .status(500)
        .send({ error: "Database error", details: err.message || err, code: err.code });
    } finally {
      client.release();
    }
  } catch (error) {
    console.error("Unexpected error:", error);
    res.status(500).send({ error: "Unexpected server error", details: error });
  }
});

app.post("/upsert_recent_stats", async (req: Request, res: Response) => {
  const rows: RecentStatsChanges[] = req.body.rows;
  console.log("Received upsert_recent_stats payload");

  if (!Array.isArray(rows)) {
    return res
      .status(400)
      .send({ error: 'Invalid payload: "rows" must be an array.' });
  }

  if (rows.length === 0) {
    return res.status(400).send({ error: "Payload contains no rows." });
  }

  const skippedRows: RecentStatsChanges[] = [];
  const processedHosts: Set<string> = new Set();

  try {
    const client = await getPoolClientWithRetry();
    try {
      await client.query("BEGIN");

      const insertQuery = `
        INSERT INTO server_recent_stats (
          status_type, host, subject, project, state_system,
          protocol, variant, aborts, pc, rt, trials, last_updated
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, COALESCE($12, CURRENT_TIMESTAMP))
        ON CONFLICT (status_type, host, subject, project, state_system, protocol, variant)
        DO UPDATE SET 
          aborts = EXCLUDED.aborts,
          pc = EXCLUDED.pc,
          rt = EXCLUDED.rt,
          trials = EXCLUDED.trials,
          last_updated = COALESCE(EXCLUDED.last_updated, CURRENT_TIMESTAMP);
      `;

      // Collect host-specific keys for deletion
      const keysByHost: Record<string, string[]> = {};

      for (const row of rows) {
        const {
          status_type,
          host,
          subject,
          project,
          state_system,
          protocol,
          variant,
          aborts,
          pc,
          rt,
          trials,
          last_updated,
        } = row;

        // Validate required fields
        if (
          !status_type ||
          !host ||
          !subject ||
          !project ||
          !state_system ||
          !protocol ||
          !variant ||
          aborts === undefined ||
          pc === undefined ||
          rt === undefined ||
          trials === undefined
        ) {
          console.warn("Skipping invalid recent_stats row");
          skippedRows.push(row);
          continue;
        }

        // Add to keys for deletion
        if (!keysByHost[host]) {
          keysByHost[host] = [];
        }
        keysByHost[host].push(
          `(${client.escapeLiteral(status_type)}, ${client.escapeLiteral(
            subject
          )}, ${client.escapeLiteral(project)}, ${client.escapeLiteral(
            state_system
          )}, ${client.escapeLiteral(protocol)}, ${client.escapeLiteral(
            variant
          )})`
        );

        // Perform the database query
        await client.query(insertQuery, [
          status_type,
          host,
          subject,
          project,
          state_system,
          protocol,
          variant,
          aborts,
          pc,
          rt,
          trials,
          last_updated || null,
        ]);
      }

      // Perform deletions for each host
      for (const [host, keys] of Object.entries(keysByHost)) {
        const deleteQuery = `
          DELETE FROM server_recent_stats
          WHERE host = $1
            AND (status_type, subject, project, state_system, protocol, variant)
                NOT IN (${keys.join(", ")});
        `;
        await client.query(deleteQuery, [host]);
      }

      await client.query("COMMIT");

      res.send({
        success: true,
        message: `${rows.length - skippedRows.length} rows processed, ${skippedRows.length} rows skipped.`,
        skippedRows,
      });
    } catch (err: any) {
      await client.query("ROLLBACK");
      console.error(
        "Error inserting/updating rows in server_recent_stats:",
        err.message || err
      );
      res
        .status(500)
        .send({ error: "Database error", details: err.message || err });
    } finally {
      client.release();
    }
  } catch (error) {
    console.error("Unexpected error:", error);
    res.status(500).send({ error: "Unexpected server error", details: error });
  }
});

app.post("/process_outbox_trial", async (req: Request, res: Response) => {
  const rows = req.body.rows;
  console.log("Received process_outbox_trial payload");

  if (!Array.isArray(rows)) {
    return res
      .status(400)
      .send({ error: 'Invalid payload: "rows" must be an array.' });
  }

  const skippedRows: any[] = [];
  const processedRows: any[] = [];

  try {
    const client = await getPoolClientWithRetry();
    try {
      await client.query("BEGIN");

      const insertQuery = `
        INSERT INTO server_trial (
          base_trial_id, host, block_id, trial_id, project, state_system,
          protocol, variant, version, subject, status, rt, trialinfo, client_time
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
        ON CONFLICT DO NOTHING;
      `;

      for (const row of rows) {
        const {
          base_trial_id,
          host,
          block_id,
          trial_id,
          project,
          state_system,
          protocol,
          variant,
          version,
          subject,
          status,
          rt,
          trialinfo,
          sys_time, // Use sys_time from the client
        } = row;

        // Validate required fields
        if (
          base_trial_id === null ||
          base_trial_id === undefined ||
          !host ||
          block_id === null ||
          block_id === undefined ||
          trial_id === null ||
          trial_id === undefined ||
          !project ||
          !state_system ||
          !protocol ||
          !variant ||
          !version ||
          !subject ||
          sys_time === undefined
        ) {
          console.warn(
            "Skipping invalid row (required fields missing):",
            JSON.stringify(row, null, 2)
          );
          skippedRows.push(row);
          continue;
        }

        if (typeof trialinfo !== "object") {
          console.warn(
            "Skipping invalid row (trialinfo not an object):",
            JSON.stringify(row, null, 2)
          );
          skippedRows.push(row);
          continue;
        }

        // Convert trialinfo to JSON string
        const trialinfoJSON = JSON.stringify(trialinfo);

        // Use sys_time from the client mapped to client_time for insertion
        await client.query(insertQuery, [
          base_trial_id,
          host,
          block_id,
          trial_id,
          project,
          state_system,
          protocol,
          variant,
          version,
          subject,
          status,
          rt,
          trialinfoJSON,
          sys_time,
        ]);

        processedRows.push(row);
      }

      await client.query("COMMIT");
      res.send({
        success: true,
        message: `${processedRows.length} rows processed, ${skippedRows.length} rows skipped.`,
        processedRows,
        skippedRows,
      });
    } catch (err: unknown) {
      await client.query("ROLLBACK");
      const errorMessage = err instanceof Error ? err.message : String(err);
      console.error("Error inserting/updating rows in server_trial:", errorMessage);
      res.status(500).send({ error: "Database error", details: errorMessage });
    } finally {
      client.release();
    }
  } catch (err: unknown) {
    const errorMessage = err instanceof Error ? err.message : String(err);
    console.error("Unexpected error:", errorMessage);
    res.status(500).send({ error: "Unexpected server error", details: errorMessage });
  }
});

app.post("/process_outbox_inference", async (req: Request, res: Response) => {
  const rows = req.body.rows;
  console.log("Received process_outbox_inference payload");

  if (!Array.isArray(rows)) {
    return res
      .status(400)
      .send({ error: 'Invalid payload: "rows" must be an array.' });
  }

  if (rows.length === 0) {
    return res.status(200).send({ success: true, message: "No rows to process.", processedRows: [], skippedRows: [] });
  }

  const skippedRows: any[] = [];
  const processedRows: any[] = [];

  let client;
  try {
    client = await getPoolClientWithRetry();
    try {
      await client.query("BEGIN");

      const insertQuery = `
        INSERT INTO server_inference (
          infer_id, meta_file, model_file, host, infer_label, manual_label,
          input_data, mime_type, client_time, confidence, server_trial_id, trial_time
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12);
      `;
      // Note: Removed ON CONFLICT clause. If infer_id needs to be unique, 
      // a UNIQUE constraint must be added to the 'infer_id' column in the database schema.

      for (let i = 0; i < rows.length; i++) {
        const row = rows[i];
        const savepointName = `savepoint_row_${i}`;
        
        const {
          infer_id,
          meta_file,
          model_file,
          host,
          infer_label,
          manual_label,
          input_data, // Expected to be Base64 string if present
          mime_type,
          client_time,
          confidence,
          server_trial_id,
          trial_time,
        } = row;

        // Basic validation for required fields
        if (
          infer_id === undefined || infer_id === null ||
          !host || 
          client_time === undefined || client_time === null
        ) {
          console.warn(
            `Skipping invalid inference row (pre-check: required fields missing or invalid), row index ${i}:`,
            JSON.stringify(row, null, 2)
          );
          skippedRows.push({index: i, rowData: row, error: "Pre-check validation failed"});
          continue;
        }

        let inputDataBuffer: Buffer | null = null;
        if (input_data && typeof input_data === 'string') {
          try {
            inputDataBuffer = Buffer.from(input_data, 'base64');
          } catch (bufferError) {
            console.warn(
              `Skipping invalid inference row (input_data base64 decoding error), row index ${i}:`,
              JSON.stringify(row, null, 2),
              bufferError
            );
            skippedRows.push({index: i, rowData: row, error: "Base64 decoding error", details: bufferError});
            continue;
          }
        } else if (input_data && typeof input_data !== 'string') {
             console.warn(
              `Skipping invalid inference row (input_data is not a string), row index ${i}:`,
              JSON.stringify(row, null, 2)
            );
            skippedRows.push({index: i, rowData: row, error: "input_data not a string"});
            continue;
        }


        try {
            await client.query(`SAVEPOINT ${savepointName}`);
            await client.query(insertQuery, [
              infer_id,
              meta_file,
              model_file,
              host,
              infer_label,
              manual_label,
              inputDataBuffer, 
              mime_type,
              client_time, 
              confidence,
              server_trial_id,
              trial_time,
            ]);
            processedRows.push(row);
        } catch (queryError: any) {
            await client.query(`ROLLBACK TO SAVEPOINT ${savepointName}`);
            console.error(
              `Error inserting row (rolled back to ${savepointName}), row index ${i}, skipping row:`,
              JSON.stringify(row, null, 2),
              queryError.message || queryError,
              queryError.code ? `SQLState: ${queryError.code}` : ''
            );
            skippedRows.push({index: i, rowData: row, error: queryError.message, sqlState: queryError.code});
        }
      }

      await client.query("COMMIT");
      res.send({
        success: true,
        message: `${processedRows.length} rows processed into server_inference, ${skippedRows.length} rows skipped.`,
        processedRowsCount: processedRows.length,
        skippedRowsCount: skippedRows.length,
        processedRows,
        skippedRows,
      });
    } catch (err: unknown) {
      if (client) { // Ensure client exists before trying to rollback
        await client.query("ROLLBACK");
      }
      const errorMessage = err instanceof Error ? err.message : String(err);
      console.error("Error processing /process_outbox_inference payload:", errorMessage, err);
      res.status(500).send({ error: "Database error during inference processing", details: errorMessage });
    } finally {
      if (client) {
        client.release();
      }
    }
  } catch (err: unknown) {
    const errorMessage = err instanceof Error ? err.message : String(err);
    console.error("Unexpected error in /process_outbox_inference:", errorMessage, err);
    res.status(500).send({ error: "Unexpected server error during inference processing", details: errorMessage });
  }
});

// app.listen(3030, () => {
//   console.log("Server is running on port 3030");
// });

const API_PORT = '3030';
app.listen(parseInt(API_PORT, 10), () => console.log(`API server running on port ${API_PORT}`));

