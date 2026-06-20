import { Pool, QueryResultRow } from "pg";

// Create a connection pool for PostgreSQL
const pool = new Pool({
  host: process.env.POSTGRES_HOST || "localhost",
  port: parseInt(process.env.POSTGRES_PORT || "5432"),
  database: process.env.POSTGRES_DB || "bngc",
  user: process.env.POSTGRES_USER || "bngc",
  password: process.env.POSTGRES_PASSWORD || "bngc",
});

/**
 * Execute a raw SQL query
 */
export async function query<T extends QueryResultRow = QueryResultRow>(
  text: string,
  params?: unknown[],
): Promise<T[]> {
  const result = await pool.query<T>(text, params);
  return result.rows;
}

/**
 * Execute a raw SQL query and return a single row
 */
export async function queryOne<T extends QueryResultRow = QueryResultRow>(
  text: string,
  params?: unknown[],
): Promise<T | null> {
  const rows = await query<T>(text, params);
  return rows[0] || null;
}

/**
 * Get the pool for transactions or advanced usage
 */
export function getPool() {
  return pool;
}

export default pool;
