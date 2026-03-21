import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';
import { readFileSync, writeFileSync, existsSync } from 'fs';
import express from 'express';
import cors from 'cors';
import axios from 'axios';
import dotenv from 'dotenv';
import swaggerJsdoc from 'swagger-jsdoc';
import swaggerUi from 'swagger-ui-express';
import { CostExplorerClient, GetCostAndUsageCommand } from '@aws-sdk/client-cost-explorer';
import { fromIni, fromNodeProviderChain } from '@aws-sdk/credential-providers';
import { SecretsManagerClient, GetSecretValueCommand, PutSecretValueCommand } from '@aws-sdk/client-secrets-manager';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const ENV_PATH = resolve(__dirname, '../.env');

// Load .env from the backend directory
dotenv.config({ path: ENV_PATH });

const app = express();
const PORT = process.env.PORT || 3001;

const SECRETS_MANAGER_SECRET_NAME = 'sarrescost/backend/credentials';
const SECRETS_MANAGER_REGION = 'us-east-1';
const secretsClient = new SecretsManagerClient({
  region: SECRETS_MANAGER_REGION,
  credentials: fromNodeProviderChain({ profile: process.env.AWS_PROFILE || 'aws-cloudy' }),
});

// Mutable key — can be updated at runtime via /api/config/key
let apiKey = process.env.OPENAI_API_KEY || '';

// Mutable AWS credentials — can be updated at runtime via /api/aws/config/credentials
let awsAccessKeyId = process.env.AWS_ACCESS_KEY_ID || '';
let awsSecretAccessKey = process.env.AWS_SECRET_ACCESS_KEY || '';
let awsRegion = process.env.AWS_REGION || 'us-east-1';
const awsProfile = process.env.AWS_PROFILE || 'aws-cloudy';

// ── Helpers ──────────────────────────────────────────────────────────────────

function openaiHeaders() {
  if (!apiKey) throw new Error('OPENAI_API_KEY is not configured. Use the Settings panel to add your key.');
  return { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' };
}

function dateToUnix(dateStr) {
  return Math.floor(new Date(dateStr).getTime() / 1000);
}

function maskKey(key) {
  if (!key || key.length < 10) return null;
  return key.slice(0, 14) + '...' + key.slice(-4);
}

function persistKeyToEnv(key) {
  let contents = existsSync(ENV_PATH) ? readFileSync(ENV_PATH, 'utf8') : '';
  if (/^OPENAI_API_KEY=.*/m.test(contents)) {
    contents = contents.replace(/^OPENAI_API_KEY=.*/m, `OPENAI_API_KEY=${key}`);
  } else {
    contents = contents.trimEnd() + `\nOPENAI_API_KEY=${key}\n`;
  }
  writeFileSync(ENV_PATH, contents, 'utf8');
}

function persistAwsToEnv(accessKeyId, secretAccessKey, region) {
  let contents = existsSync(ENV_PATH) ? readFileSync(ENV_PATH, 'utf8') : '';
  const replacements = { AWS_ACCESS_KEY_ID: accessKeyId, AWS_SECRET_ACCESS_KEY: secretAccessKey, AWS_REGION: region };
  for (const [k, v] of Object.entries(replacements)) {
    if (new RegExp(`^${k}=.*`, 'm').test(contents)) {
      contents = contents.replace(new RegExp(`^${k}=.*`, 'm'), `${k}=${v}`);
    } else {
      contents = contents.trimEnd() + `\n${k}=${v}\n`;
    }
  }
  writeFileSync(ENV_PATH, contents, 'utf8');
}

function maskAwsKey(key) {
  if (!key || key.length < 8) return null;
  return key.slice(0, 4) + '...' + key.slice(-4);
}

function awsCredentials() {
  if (awsAccessKeyId && awsSecretAccessKey) {
    return { accessKeyId: awsAccessKeyId, secretAccessKey: awsSecretAccessKey };
  }
  return null;
}

async function loadFromSecretsManager() {
  try {
    const res = await secretsClient.send(new GetSecretValueCommand({ SecretId: SECRETS_MANAGER_SECRET_NAME }));
    const secret = JSON.parse(res.SecretString || '{}');
    if (secret.openaiApiKey) apiKey = secret.openaiApiKey;
    if (secret.awsAccessKeyId) awsAccessKeyId = secret.awsAccessKeyId;
    if (secret.awsSecretAccessKey) awsSecretAccessKey = secret.awsSecretAccessKey;
    if (secret.awsRegion) awsRegion = secret.awsRegion;
    console.log('[secrets] Loaded credentials from Secrets Manager.');
  } catch (err) {
    console.warn('[secrets] Could not load from Secrets Manager, using .env fallback:', err.message);
  }
}

async function persistToSecretsManager() {
  const payload = JSON.stringify({
    openaiApiKey: apiKey,
    awsAccessKeyId,
    awsSecretAccessKey,
    awsRegion,
  });
  try {
    await secretsClient.send(new PutSecretValueCommand({
      SecretId: SECRETS_MANAGER_SECRET_NAME,
      SecretString: payload,
    }));
  } catch (err) {
    console.warn('[secrets] Could not persist to Secrets Manager:', err.message);
  }
}

function getAwsClientConfig() {
  const creds = awsCredentials();
  if (creds) {
    return { region: awsRegion, credentials: creds };
  }
  return { region: awsRegion, credentials: fromIni({ profile: awsProfile }) };
}

async function fetchAllCostPages(startTime, endTime) {
  const results = [];
  let afterCursor = undefined;
  do {
    const params = { start_time: startTime, end_time: endTime, bucket_width: '1d', group_by: 'line_item', limit: 180 };
    if (afterCursor) params.page = afterCursor;
    const resp = await axios.get('https://api.openai.com/v1/organization/costs', { headers: openaiHeaders(), params });
    results.push(...(resp.data.data || []));
    afterCursor = resp.data.has_more ? resp.data.next_page : null;
  } while (afterCursor);
  return results;
}

function transformCosts(buckets) {
  let totalCents = 0;
  const daily_costs = buckets.map((bucket) => {
    const line_items = (bucket.results || []).map((r) => {
      const costCents = Math.round((r.amount?.value || 0) * 100);
      totalCents += costCents;
      return { name: r.line_item || 'Unknown', cost: costCents };
    });
    return { timestamp: bucket.start_time, line_items };
  });
  return { total_usage: totalCents, daily_costs };
}

// ── Swagger ───────────────────────────────────────────────────────────────────

const swaggerSpec = swaggerJsdoc({
  definition: {
    openapi: '3.0.0',
    info: {
      title: 'Marcos OpenAI Dashboard API',
      version: '1.0.0',
      description: 'Backend API for the Marcos OpenAI usage dashboard',
    },
    servers: [],
  },
  apis: [__filename],
});

// ── Middleware ────────────────────────────────────────────────────────────────

app.use(cors({ origin: true, methods: ['GET', 'POST'] }));
app.use(express.json());

app.get('/api-docs.json', (req, res) => {
  const proto = req.headers['x-forwarded-proto'] || req.protocol;
  const host = req.headers['x-forwarded-host'] || req.get('host');
  res.json({ ...swaggerSpec, servers: [{ url: `${proto}://${host}` }] });
});

app.use('/api-docs', swaggerUi.serve, swaggerUi.setup(null, { swaggerUrl: '/api-docs.json' }));

// ── Config routes ─────────────────────────────────────────────────────────────

/**
 * @swagger
 * /api/config/status:
 *   get:
 *     summary: Get API key status
 *     description: Returns whether an OpenAI Admin API key is configured and a masked preview.
 *     tags: [Config]
 *     responses:
 *       200:
 *         description: Key status
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 hasKey:
 *                   type: boolean
 *                 keyPreview:
 *                   type: string
 *                   nullable: true
 *                   example: sk-admin-abc...wxyz
 */
app.get('/api/config/status', (_req, res) => {
  res.json({ hasKey: Boolean(apiKey), keyPreview: maskKey(apiKey) });
});

/**
 * @swagger
 * /api/config/key:
 *   post:
 *     summary: Set or update the OpenAI API key
 *     description: Updates the key in memory immediately and persists it to backend/.env.
 *     tags: [Config]
 *     requestBody:
 *       required: true
 *       content:
 *         application/json:
 *           schema:
 *             type: object
 *             required: [key]
 *             properties:
 *               key:
 *                 type: string
 *                 example: sk-admin-...
 *     responses:
 *       200:
 *         description: Key saved
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 ok:
 *                   type: boolean
 *                 keyPreview:
 *                   type: string
 *       400:
 *         description: Missing or invalid key
 */
app.post('/api/config/key', (req, res) => {
  const { key } = req.body;
  if (!key || typeof key !== 'string' || !key.trim()) {
    return res.status(400).json({ error: 'key is required' });
  }
  const trimmed = key.trim();
  apiKey = trimmed;
  try { persistKeyToEnv(trimmed); } catch (err) {
    console.warn('[config] Could not persist key to .env:', err.message);
  }
  persistToSecretsManager();
  res.json({ ok: true, keyPreview: maskKey(trimmed) });
});

// ── Data routes ───────────────────────────────────────────────────────────────

/**
 * @swagger
 * /api/costs:
 *   get:
 *     summary: Get usage costs
 *     description: Returns daily cost breakdown and total usage for a date range, sourced from /v1/organization/costs.
 *     tags: [Usage]
 *     parameters:
 *       - in: query
 *         name: start_date
 *         schema:
 *           type: string
 *           format: date
 *           example: "2026-02-01"
 *         description: Start date (YYYY-MM-DD). Defaults to 30 days ago.
 *       - in: query
 *         name: end_date
 *         schema:
 *           type: string
 *           format: date
 *           example: "2026-03-01"
 *         description: End date (YYYY-MM-DD). Defaults to today.
 *     responses:
 *       200:
 *         description: Cost data
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 total_usage:
 *                   type: integer
 *                   description: Total cost in cents
 *                 daily_costs:
 *                   type: array
 *                   items:
 *                     type: object
 *                     properties:
 *                       timestamp:
 *                         type: integer
 *                       line_items:
 *                         type: array
 *                         items:
 *                           type: object
 *                           properties:
 *                             name:
 *                               type: string
 *                             cost:
 *                               type: integer
 *                               description: Cost in cents
 */
app.get('/api/costs', async (req, res, next) => {
  try {
    const { start_date, end_date } = req.query;
    const startTime = start_date ? dateToUnix(start_date) : dateToUnix(new Date(Date.now() - 30 * 86400 * 1000).toISOString().slice(0, 10));
    const endTime = end_date ? dateToUnix(end_date) + 86400 : Math.floor(Date.now() / 1000);
    const buckets = await fetchAllCostPages(startTime, endTime);
    res.json(transformCosts(buckets));
  } catch (err) { next(err); }
});

/**
 * @swagger
 * /api/account:
 *   get:
 *     summary: Get organization user info
 *     description: Returns the name and email of the first user in the org from /v1/organization/users.
 *     tags: [Account]
 *     responses:
 *       200:
 *         description: Account info
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 name:
 *                   type: string
 *                   nullable: true
 *                 email:
 *                   type: string
 *                   nullable: true
 */
app.get('/api/account', async (req, res) => {
  try {
    const response = await axios.get('https://api.openai.com/v1/organization/users?limit=1', { headers: openaiHeaders() });
    const first = response.data.data?.[0];
    res.json({ name: first?.name || null, email: first?.email || null });
  } catch (err) {
    console.error('[/api/account] error:', err.response?.data || err.message);
    res.json({ name: null, email: null });
  }
});

/**
 * @swagger
 * /api/subscription:
 *   get:
 *     summary: Get billing subscription info
 *     description: Attempts to fetch plan/limit info from the legacy billing API. Returns defaults if unavailable.
 *     tags: [Account]
 *     responses:
 *       200:
 *         description: Subscription info
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 plan:
 *                   type: object
 *                   properties:
 *                     title:
 *                       type: string
 *                 hard_limit_usd:
 *                   type: number
 *                   nullable: true
 *                 soft_limit_usd:
 *                   type: number
 *                   nullable: true
 */
app.get('/api/subscription', async (req, res) => {
  try {
    const response = await axios.get('https://api.openai.com/v1/dashboard/billing/subscription', { headers: openaiHeaders() });
    res.json(response.data);
  } catch {
    res.json({ plan: { title: 'Pay-as-you-go' }, hard_limit_usd: null, soft_limit_usd: null });
  }
});

// ── AWS config routes ─────────────────────────────────────────────────────────

/**
 * @swagger
 * /api/aws/config/status:
 *   get:
 *     summary: Get AWS credential status
 *     description: Returns whether AWS credentials are stored, a masked preview, region, profile fallback, and credential source.
 *     tags: [Config]
 *     responses:
 *       200:
 *         description: AWS credential status
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 hasCredentials:
 *                   type: boolean
 *                 accessKeyPreview:
 *                   type: string
 *                   nullable: true
 *                   example: AKIA...ABCD
 *                 region:
 *                   type: string
 *                   example: us-east-1
 *                 profile:
 *                   type: string
 *                   nullable: true
 *                   example: aws-cloudy
 *                 source:
 *                   type: string
 *                   enum: [env, profile]
 */
app.get('/api/aws/config/status', (_req, res) => {
  const hasCredentials = Boolean(awsAccessKeyId && awsSecretAccessKey);
  res.json({
    hasCredentials,
    accessKeyPreview: maskAwsKey(awsAccessKeyId),
    region: awsRegion,
    profile: hasCredentials ? null : awsProfile,
    source: hasCredentials ? 'env' : 'profile',
  });
});

/**
 * @swagger
 * /api/aws/config/credentials:
 *   post:
 *     summary: Set or update AWS credentials
 *     description: Validates and persists AWS credentials to backend/.env and updates in-memory values.
 *     tags: [Config]
 *     requestBody:
 *       required: true
 *       content:
 *         application/json:
 *           schema:
 *             type: object
 *             required: [accessKeyId, secretAccessKey, region]
 *             properties:
 *               accessKeyId:
 *                 type: string
 *                 example: AKIAIOSFODNN7EXAMPLE
 *               secretAccessKey:
 *                 type: string
 *               region:
 *                 type: string
 *                 example: us-east-1
 *     responses:
 *       200:
 *         description: Credentials saved
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 ok:
 *                   type: boolean
 *                 accessKeyPreview:
 *                   type: string
 *                 region:
 *                   type: string
 *       400:
 *         description: Missing or invalid credentials
 */
app.post('/api/aws/config/credentials', (req, res) => {
  const { accessKeyId, secretAccessKey, region } = req.body;
  if (!accessKeyId || typeof accessKeyId !== 'string' || !accessKeyId.trim()) {
    return res.status(400).json({ error: 'accessKeyId is required' });
  }
  if (!secretAccessKey || typeof secretAccessKey !== 'string' || !secretAccessKey.trim()) {
    return res.status(400).json({ error: 'secretAccessKey is required' });
  }
  if (!region || typeof region !== 'string' || !region.trim()) {
    return res.status(400).json({ error: 'region is required' });
  }
  awsAccessKeyId = accessKeyId.trim();
  awsSecretAccessKey = secretAccessKey.trim();
  awsRegion = region.trim();
  try { persistAwsToEnv(awsAccessKeyId, awsSecretAccessKey, awsRegion); } catch (err) {
    console.warn('[aws config] Could not persist credentials to .env:', err.message);
  }
  persistToSecretsManager();
  res.json({ ok: true, accessKeyPreview: maskAwsKey(awsAccessKeyId), region: awsRegion });
});

// ── AWS routes ────────────────────────────────────────────────────────────────

/**
 * @swagger
 * /api/aws/costs:
 *   get:
 *     summary: Get AWS costs
 *     description: Returns daily AWS cost breakdown by service using Cost Explorer.
 *     tags: [AWS]
 *     parameters:
 *       - in: query
 *         name: start_date
 *         schema:
 *           type: string
 *           format: date
 *           example: "2026-02-01"
 *       - in: query
 *         name: end_date
 *         schema:
 *           type: string
 *           format: date
 *           example: "2026-03-01"
 *     responses:
 *       200:
 *         description: AWS cost data
 */
app.get('/api/aws/costs', async (req, res, next) => {
  try {
    const { start_date, end_date } = req.query;
    const today = new Date().toISOString().slice(0, 10);
    const thirtyDaysAgo = new Date(Date.now() - 30 * 86400 * 1000).toISOString().slice(0, 10);
    const start = start_date || thirtyDaysAgo;
    const end = end_date || today;

    const client = new CostExplorerClient(getAwsClientConfig());

    const command = new GetCostAndUsageCommand({
      TimePeriod: { Start: start, End: end },
      Granularity: 'DAILY',
      Metrics: ['UnblendedCost'],
      GroupBy: [{ Type: 'DIMENSION', Key: 'SERVICE' }],
    });

    const response = await client.send(command);

    let totalCents = 0;
    const daily_costs = (response.ResultsByTime || []).map((day) => {
      const services = (day.Groups || []).map((g) => {
        const usd = parseFloat(g.Metrics.UnblendedCost.Amount || '0');
        const cents = Math.round(usd * 100);
        totalCents += cents;
        return { name: g.Keys[0], cost: cents };
      }).filter((s) => s.cost > 0);
      return { date: day.TimePeriod.Start, services };
    });

    res.json({ total_cost: totalCents, daily_costs });
  } catch (err) { next(err); }
});

// ── Error handling ────────────────────────────────────────────────────────────

app.use((_req, res) => res.status(404).json({ error: 'Route not found' }));

app.use((err, _req, res, _next) => {
  console.error('[Error]', err.message);
  if (err.response) {
    const { status, data } = err.response;
    return res.status(status).json({ error: data?.error?.message || 'OpenAI API error', details: data });
  }
  res.status(500).json({ error: err.message || 'Internal server error' });
});

loadFromSecretsManager().then(() => {
  app.listen(PORT, () => {
    console.log(`Backend running at http://localhost:${PORT}`);
    if (!apiKey) console.warn('WARNING: No API key set. Open the dashboard and use Settings to configure your key.');
  });
});
