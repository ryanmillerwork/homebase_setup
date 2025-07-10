import express, { Request, Response } from 'express';
import { Client } from 'pg';
import compression from 'compression';

const app = express();
const port = 3001;

app.use(compression()); 

/**
 * Helper function to add a filter condition for fields that may have comma-delimited multiple values.
 * It updates the conditions array and the values array, incrementing the placeholder index accordingly.
 */
function addFilterCondition(
  field: string,
  value: string | undefined,
  conditions: string[],
  values: any[],
  paramIndex: { index: number }
) {
  if (value) {
    // Split on commas and remove extra whitespace
    const items = value.split(',').map((s) => s.trim()).filter((s) => s.length > 0);
    if (items.length === 1) {
      conditions.push(`${field} = $${paramIndex.index}`);
      values.push(items[0]);
      paramIndex.index++;
    } else if (items.length > 1) {
      // Create placeholders for each value and use the IN clause
      const placeholders = items.map(() => `$${paramIndex.index++}`);
      conditions.push(`${field} IN (${placeholders.join(', ')})`);
      values.push(...items);
    }
  }
}

// GET endpoint to handle query requests
// Takes about 270 ms for 8900 rows 33 rows per ms
//             170 ms for 5600 rows 33 rows per ms
//              50 ms for 100 rows 2 rows per ms
// start_date=2025-02-18&end_date=2025-02-19&subject=sally
//   takes about 45 ms for 532 rows
// 6.441MB for 8902 rows = 723B/row, 723MB per million rows
app.get('/query', async (req: Request, res: Response) => {
  // Log each request with the current time and parameters
  const startTime = Date.now();
  console.log(`[${new Date().toLocaleString()}] Received request with params:`, req.query);

  try {
    // Extract required parameters from the query string
    const dbUser = req.query.user as string;
    const dbPass = req.query.pass as string;
    const table = req.query.table as string;
    const startDate = req.query.start_date as string;
    const endDate = req.query.end_date as string;
    const subject = req.query.subject as string;
    const project = req.query.project as string;
    const stateSystem = req.query.state_system as string;
    const protocol = req.query.protocol as string;
    const variant = req.query.variant as string;

    // Make sure theyre using one of the users designed for this purpose (i.e., not one of the superusers)
    const forbiddenUsers: string[] = ['postgres', 'lab', 'sym_user'];

    if (forbiddenUsers.indexOf(dbUser) !== -1) {
      return res.status(403).json({ error: "Invalid user" });
    }

    // Basic validation for the table name.
    // Since table names cannot be parameterized, we only allow alphanumeric characters and underscores.
    if (!table || !/^[a-zA-Z0-9_]+$/.test(table)) {
      res.status(400).json({ error: 'Invalid or missing table name.' });
      return;
    }

    // Begin building the SQL query
    let queryText = `SELECT * FROM ${table}`;
    const conditions: string[] = [];
    const values: any[] = [];
    // Use an object to allow pass-by-reference for the index counter.
    let paramIndex = { index: 1 };

    // Add date filters if provided (assuming "client_time" is the timestamp with time zone column)
    if (startDate) {
      conditions.push(`client_time >= $${paramIndex.index}`);
      values.push(startDate);
      paramIndex.index++;
    }

    if (endDate) {
      conditions.push(`client_time <= $${paramIndex.index}`);
      values.push(endDate);
      paramIndex.index++;
    }

    // Add filter conditions for multi-valued parameters
    addFilterCondition('subject', subject, conditions, values, paramIndex);
    addFilterCondition('project', project, conditions, values, paramIndex);
    addFilterCondition('state_system', stateSystem, conditions, values, paramIndex);
    addFilterCondition('protocol', protocol, conditions, values, paramIndex);
    addFilterCondition('variant', variant, conditions, values, paramIndex);

    // Append conditions to the query if any exist
    if (conditions.length > 0) {
      queryText += ' WHERE ' + conditions.join(' AND ');
    }

    // Set up the PostgreSQL client using user-supplied credentials.
    // Host, port, and database can be set via environment variables or hard-coded.
    const client = new Client({
      user: dbUser,
      password: dbPass,
      host: 'localhost',
      port: 5432,
      database: 'base',
    });

    // Connect to the database, execute the query, and then close the connection.
    await client.connect();
    const result = await client.query(queryText, values);
    await client.end();



    const rows = result.rows;
    
    // Check size in bytes *before* compression:
    const jsonString = JSON.stringify(rows);
    const sizeBytes = Buffer.byteLength(jsonString, 'utf-8');
    const maxBytes = 100 * 1024 * 1024; // 100 MB

    if (sizeBytes > maxBytes) {
      return res
        .status(413) // HTTP 413 Payload Too Large
        .json({ error: 'Result set exceeds 100MB limit. Use the /query-large endpoint instead.' });
    }

    // If below size limit, return JSON
    res.json(rows);







    // Return the rows as a JSON array
    // res.json(result.rows);
    const executionTime = Date.now() - startTime;
    console.log(`Number of rows returned: ${result.rows.length} (Execution time: ${executionTime} ms)`);

  } catch (error: any) {
    console.error('Error querying database:', error);
    // Enhanced error handling: check for known PostgreSQL error codes and provide more descriptive responses.
    if (error.code) {
      switch (error.code) {
        case '28P01':
          res.status(401).json({ error: 'User not authorized (authentication failure).' });
          break;
        case '3D000':
          res.status(500).json({ error: 'Database does not exist.' });
          break;
        case '42P01':
          res.status(400).json({ error: `Table '${req.query.table}' does not exist.` });
          break;
        default:
          res.status(500).json({ error: 'Database error: ' + error.message });
      }
    } else if (error.message && error.message.includes('connect')) {
      res.status(500).json({ error: 'Database connection error. Please check if the database is available.' });
    } else {
      res.status(500).json({ error: 'An error occurred: ' + error.message });
    }
  }
});

app.listen(port, () => {
  console.log(`Server is running on port ${port}`);
});
