import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';
import { createRequire } from 'module';
import express from 'express';
import cors from 'cors';
import axios from 'axios';
import dotenv from 'dotenv';
import swaggerJsdoc from 'swagger-jsdoc';
import swaggerUi from 'swagger-ui-express';
import { CostExplorerClient, GetCostAndUsageCommand } from '@aws-sdk/client-cost-explorer';
import { CloudFormationClient, ListStacksCommand } from '@aws-sdk/client-cloudformation';
import { ECSClient, ListClustersCommand, DescribeClustersCommand, ListServicesCommand, DescribeServicesCommand } from '@aws-sdk/client-ecs';
import { AutoScalingClient, DescribeAutoScalingGroupsCommand } from '@aws-sdk/client-auto-scaling';
import { ElasticLoadBalancingV2Client, DescribeLoadBalancersCommand, DescribeTargetGroupsCommand, DescribeTargetHealthCommand } from '@aws-sdk/client-elastic-load-balancing-v2';
import { CloudWatchLogsClient, DescribeLogGroupsCommand } from '@aws-sdk/client-cloudwatch-logs';
import { ECRClient, DescribeRepositoriesCommand } from '@aws-sdk/client-ecr';
import { S3Client, ListBucketsCommand } from '@aws-sdk/client-s3';
import { CloudFrontClient, ListDistributionsCommand } from '@aws-sdk/client-cloudfront';
import { Route53Client, ListHostedZonesCommand, ListResourceRecordSetsCommand } from '@aws-sdk/client-route-53';
import { ACMClient, ListCertificatesCommand } from '@aws-sdk/client-acm';
import { EC2Client, DescribeSecurityGroupsCommand } from '@aws-sdk/client-ec2';
import { fromIni } from '@aws-sdk/credential-providers';
import { SecretsManagerClient, GetSecretValueCommand, PutSecretValueCommand } from '@aws-sdk/client-secrets-manager';
const require = createRequire(import.meta.url);
const pkg = require('../package.json');

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const ENV_PATH = resolve(__dirname, '../.env');

// Load .env from the backend directory
dotenv.config({ path: ENV_PATH });

const app = express();
const PORT = process.env.PORT || 3001;
const API_VERSION = pkg.version || 'unknown';

const allowedOrigins = (process.env.CORS_ORIGINS || '*')
  .split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);
const allowAllOrigins = allowedOrigins.includes('*');
const corsMethods = (process.env.CORS_METHODS || 'GET,POST,PUT,PATCH,DELETE,OPTIONS')
  .split(',')
  .map((method) => method.trim().toUpperCase())
  .filter(Boolean);

const corsOptions = {
  origin: (origin, callback) => {
    if (!origin || allowAllOrigins || allowedOrigins.includes(origin)) {
      return callback(null, true);
    }
    return callback(new Error('Not allowed by CORS'));
  },
  methods: corsMethods,
  credentials: true,
};

// Mutable key — can be updated at runtime via /api/config/key
let apiKey = process.env.OPENAI_API_KEY || '';

// Mutable AWS credentials — can be updated at runtime via /api/aws/config/credentials
let awsAccessKeyId = process.env.AWS_ACCESS_KEY_ID || '';
let awsSecretAccessKey = process.env.AWS_SECRET_ACCESS_KEY || '';
let awsRegion = process.env.AWS_REGION || 'us-east-1';
const awsProfile = process.env.AWS_PROFILE || 'aws-cloudy';

let claudeApiKey = process.env.CLAUDE_API_KEY || process.env.ANTHROPIC_API_KEY || '';
let claudeOrgId = process.env.CLAUDE_ORG_ID || process.env.ANTHROPIC_ORG_ID || '';
const CLAUDE_API_VERSION = process.env.CLAUDE_API_VERSION || '2023-06-01';
const CLAUDE_USER_AGENT = process.env.CLAUDE_USER_AGENT || 'MarcosCostDashboard/1.0.0';
const CLAUDE_COST_ENDPOINT = 'https://api.anthropic.com/v1/organizations/cost_report';

const AWS_PROJECT_NAME = process.env.AWS_PROJECT_NAME || 'newsite';
const AWS_ROOT_DOMAIN = process.env.AWS_ROOT_DOMAIN || 'moneyclip.com.br';
const AWS_DOMAIN_SLUG = AWS_ROOT_DOMAIN.replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '');
const AWS_RESOURCE_PREFIX = process.env.AWS_RESOURCE_PREFIX || `${AWS_PROJECT_NAME}-${AWS_DOMAIN_SLUG}`;
const AWS_STACK_NAME = process.env.AWS_STACK_NAME || `${AWS_RESOURCE_PREFIX}-cloud-formation`;


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

function maskAwsKey(key) {
  if (!key || key.length < 8) return null;
  return key.slice(0, 4) + '...' + key.slice(-4);
}

function maskClaudeOrg(orgId) {
  if (!orgId) return null;
  if (orgId.length <= 8) return orgId;
  return `${orgId.slice(0, 4)}...${orgId.slice(-4)}`;
}

function claudeHeaders() {
  if (!claudeApiKey) {
    throw new Error('Claude Admin API key is not configured. Use the Settings panel to add your key.');
  }
  const headers = {
    'x-api-key': claudeApiKey,
    'anthropic-version': CLAUDE_API_VERSION,
    'user-agent': CLAUDE_USER_AGENT,
  };
  if (claudeOrgId) headers['anthropic-org-id'] = claudeOrgId;
  return headers;
}

const DAY_MS = 24 * 60 * 60 * 1000;

function parseDateInput(value) {
  if (!value || typeof value !== 'string') return null;
  const iso = `${value}T00:00:00Z`;
  const timestamp = Date.parse(iso);
  if (Number.isNaN(timestamp)) return null;
  return new Date(iso);
}

function toClaudeIso(dateStr, { end = false } = {}) {
  const base = parseDateInput(dateStr);
  if (!base) return null;
  if (end) base.setUTCDate(base.getUTCDate() + 1);
  return base.toISOString();
}

function resolveClaudeDateRange(startStr, endStr) {
  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);
  const defaultStart = new Date(today.getTime() - 30 * DAY_MS);

  const startDateObj = parseDateInput(startStr) || defaultStart;
  const endDateObj = parseDateInput(endStr) || today;

  if (startDateObj > endDateObj) {
    throw new Error('start_date must be on or before end_date.');
  }

  const startDate = startDateObj.toISOString().slice(0, 10);
  const endDate = endDateObj.toISOString().slice(0, 10);
  const startIso = toClaudeIso(startDate);
  const endIso = toClaudeIso(endDate, { end: true });

  return { startDate, endDate, startIso, endIso };
}

function isoToUnixSeconds(value) {
  const timestamp = Date.parse(value);
  if (Number.isNaN(timestamp)) return Math.floor(Date.now() / 1000);
  return Math.floor(timestamp / 1000);
}

function claudeAmountToCents(amount) {
  if (!amount) return 0;
  const numeric = Number(amount);
  if (Number.isNaN(numeric)) return 0;
  return Math.round(numeric);
}

function claudeParamsSerializer(params) {
  const search = new URLSearchParams();
  Object.entries(params).forEach(([key, value]) => {
    if (value === undefined || value === null || value === '') return;
    if (Array.isArray(value)) {
      value.forEach((entry) => {
        if (entry !== undefined && entry !== null && entry !== '') {
          search.append(key, entry);
        }
      });
    } else {
      search.append(key, value);
    }
  });
  return search.toString();
}

async function fetchClaudeCostBuckets(startIso, endIso) {
  const headers = claudeHeaders();
  const baseParams = {
    starting_at: startIso,
    ending_at: endIso,
    bucket_width: '1d',
    'group_by[]': ['description'],
  };

  const buckets = [];
  let pageToken;
  do {
    const response = await axios.get(CLAUDE_COST_ENDPOINT, {
      headers,
      params: { ...baseParams, page: pageToken || undefined },
      paramsSerializer: claudeParamsSerializer,
    });
    const payload = response.data || {};
    if (Array.isArray(payload.data)) {
      buckets.push(...payload.data);
    }
    pageToken = payload.has_more ? payload.next_page : null;
  } while (pageToken);

  return buckets;
}

function chunkArray(list, size = 10) {
  if (!Array.isArray(list) || size <= 0) return [];
  const chunks = [];
  for (let i = 0; i < list.length; i += size) {
    chunks.push(list.slice(i, i + size));
  }
  return chunks;
}

function getShortId(identifier = '') {
  if (!identifier) return '';
  if (identifier.includes('/')) return identifier.split('/').pop();
  if (identifier.includes(':')) return identifier.split(':').pop();
  return identifier;
}

async function fetchAwsServiceInventory() {
  const awsConfig = getAwsClientConfig();
  const results = await Promise.allSettled([
    scanCfnStacks(awsConfig),
    scanEcsResources(awsConfig),
    scanAsgGroups(awsConfig),
    scanLoadBalancers(awsConfig),
    scanTargetGroups(awsConfig),
    scanLogGroups(awsConfig),
    scanEcrRepos(awsConfig),
    scanS3Buckets(awsConfig),
    scanCloudfrontDistributions(awsConfig),
    scanRoute53Aliases(awsConfig),
    scanAcmCertificates(awsConfig),
    scanWebSecurityGroups(awsConfig),
  ]);
  return results.flatMap((r) => (r.status === 'fulfilled' ? r.value : []));
}

async function scanCfnStacks(awsConfig) {
  const client = new CloudFormationClient(awsConfig);
  const items = [];
  let nextToken;
  do {
    const resp = await client.send(new ListStacksCommand({
      StackStatusFilter: ['CREATE_COMPLETE', 'UPDATE_COMPLETE', 'UPDATE_ROLLBACK_COMPLETE', 'ROLLBACK_COMPLETE', 'CREATE_ROLLBACK_COMPLETE'],
      NextToken: nextToken,
    }));
    for (const stack of resp.StackSummaries || []) {
      items.push({ serviceType: 'CFN', component: `CloudFormation stack (${stack.StackName})`, status: stack.StackStatus });
    }
    nextToken = resp.NextToken;
  } while (nextToken);
  return items;
}

async function scanEcsResources(awsConfig) {
  const client = new ECSClient(awsConfig);
  const clusterArns = [];
  let nextToken;
  do {
    const resp = await client.send(new ListClustersCommand({ nextToken }));
    clusterArns.push(...(resp.clusterArns || []));
    nextToken = resp.nextToken;
  } while (nextToken);
  if (!clusterArns.length) return [];

  const items = [];
  const clustersResp = await client.send(new DescribeClustersCommand({ clusters: clusterArns }));
  for (const cluster of clustersResp.clusters || []) {
    items.push({ serviceType: 'ECS', component: `ECS cluster (${cluster.clusterName})`, status: cluster.status || 'UNKNOWN' });
    const serviceArns = [];
    let svcToken;
    do {
      const svcResp = await client.send(new ListServicesCommand({ cluster: cluster.clusterArn, nextToken: svcToken }));
      serviceArns.push(...(svcResp.serviceArns || []));
      svcToken = svcResp.nextToken;
    } while (svcToken);
    for (const chunk of chunkArray(serviceArns, 10)) {
      const svcDesc = await client.send(new DescribeServicesCommand({ cluster: cluster.clusterArn, services: chunk }));
      for (const svc of svcDesc.services || []) {
        items.push({ serviceType: 'ECS', component: `ECS service (${svc.serviceName})`, status: svc.status || 'UNKNOWN' });
      }
    }
  }
  return items;
}

async function scanAsgGroups(awsConfig) {
  const client = new AutoScalingClient(awsConfig);
  const items = [];
  let nextToken;
  do {
    const resp = await client.send(new DescribeAutoScalingGroupsCommand({ NextToken: nextToken }));
    for (const group of resp.AutoScalingGroups || []) {
      const desired = group.DesiredCapacity ?? 0;
      const inService = (group.Instances || []).filter((i) => i.LifecycleState === 'InService').length;
      items.push({ serviceType: 'ASG', component: `ECS AutoScaling (${group.AutoScalingGroupName})`, status: `${inService}/${desired}` });
    }
    nextToken = resp.NextToken;
  } while (nextToken);
  return items;
}

async function scanLoadBalancers(awsConfig) {
  const client = new ElasticLoadBalancingV2Client(awsConfig);
  const items = [];
  let marker;
  do {
    const resp = await client.send(new DescribeLoadBalancersCommand({ Marker: marker }));
    for (const lb of resp.LoadBalancers || []) {
      items.push({ serviceType: 'ALB', component: `Application Load Balancer (${lb.LoadBalancerName})`, status: lb.State?.Code || 'UNKNOWN' });
    }
    marker = resp.NextMarker;
  } while (marker);
  return items;
}

async function scanTargetGroups(awsConfig) {
  const client = new ElasticLoadBalancingV2Client(awsConfig);
  const items = [];
  let marker;
  do {
    const resp = await client.send(new DescribeTargetGroupsCommand({ Marker: marker }));
    for (const tg of resp.TargetGroups || []) {
      try {
        const health = await client.send(new DescribeTargetHealthCommand({ TargetGroupArn: tg.TargetGroupArn }));
        const descs = health.TargetHealthDescriptions || [];
        const total = descs.length;
        const healthy = descs.filter((d) => d.TargetHealth?.State === 'healthy').length;
        const status = !total ? 'empty' : healthy === total ? 'healthy' : `${healthy}/${total} healthy`;
        items.push({ serviceType: 'ALB', component: `ALB target group (${tg.TargetGroupName})`, status });
      } catch {
        items.push({ serviceType: 'ALB', component: `ALB target group (${tg.TargetGroupName})`, status: 'UNKNOWN' });
      }
    }
    marker = resp.NextMarker;
  } while (marker);
  return items;
}

async function scanLogGroups(awsConfig) {
  const client = new CloudWatchLogsClient(awsConfig);
  const items = [];
  let nextToken;
  do {
    const resp = await client.send(new DescribeLogGroupsCommand({ nextToken }));
    for (const group of resp.logGroups || []) {
      items.push({ serviceType: 'CWL', component: `CloudWatch Logs (${group.logGroupName})`, status: 'EXISTS' });
    }
    nextToken = resp.nextToken;
  } while (nextToken);
  return items;
}

async function scanEcrRepos(awsConfig) {
  const client = new ECRClient(awsConfig);
  const items = [];
  let nextToken;
  do {
    const resp = await client.send(new DescribeRepositoriesCommand({ nextToken }));
    for (const repo of resp.repositories || []) {
      items.push({ serviceType: 'ECR', component: `ECR repository (${repo.repositoryName})`, status: 'AVAILABLE' });
    }
    nextToken = resp.nextToken;
  } while (nextToken);
  return items;
}

async function scanS3Buckets(awsConfig) {
  const client = new S3Client(awsConfig);
  const resp = await client.send(new ListBucketsCommand({}));
  return (resp.Buckets || []).map((b) => ({
    serviceType: 'S3',
    component: `Frontend bucket (s3://${b.Name})`,
    status: 'AVAILABLE',
  }));
}

async function scanCloudfrontDistributions(awsConfig) {
  const client = new CloudFrontClient({ ...awsConfig, region: 'us-east-1' });
  const items = [];
  let marker;
  do {
    const resp = await client.send(new ListDistributionsCommand({ Marker: marker }));
    const list = resp.DistributionList;
    for (const dist of list?.Items || []) {
      const alias = dist.Aliases?.Items?.[0] || dist.DomainName || dist.Id;
      items.push({ serviceType: 'CFD', component: `CloudFront (${alias})`, status: dist.Status || 'UNKNOWN' });
    }
    marker = list?.IsTruncated ? list.NextMarker : undefined;
  } while (marker);
  return items;
}

async function scanRoute53Aliases(awsConfig) {
  const client = new Route53Client({ ...awsConfig, region: 'us-east-1' });
  const zones = [];
  let marker;
  do {
    const resp = await client.send(new ListHostedZonesCommand({ Marker: marker }));
    zones.push(...(resp.HostedZones || []));
    marker = resp.IsTruncated ? resp.NextMarker : undefined;
  } while (marker);

  const items = [];
  for (const zone of zones) {
    let rrMarker;
    do {
      const resp = await client.send(new ListResourceRecordSetsCommand({ HostedZoneId: zone.Id, StartRecordIdentifier: rrMarker }));
      for (const rr of resp.ResourceRecordSets || []) {
        if (rr.AliasTarget) {
          const domain = rr.Name.replace(/\.$/, '');
          items.push({ serviceType: 'R53', component: `Route 53 alias (${domain})`, status: 'ALIAS_SET' });
        }
      }
      rrMarker = resp.IsTruncated ? resp.NextRecordIdentifier : undefined;
    } while (rrMarker);
  }
  return items;
}

async function scanAcmCertificates(awsConfig) {
  const client = new ACMClient(awsConfig);
  const items = [];
  let nextToken;
  do {
    const resp = await client.send(new ListCertificatesCommand({ NextToken: nextToken }));
    for (const cert of resp.CertificateSummaryList || []) {
      items.push({
        serviceType: 'ACM',
        component: `ACM certificate (${cert.DomainName || getShortId(cert.CertificateArn)})`,
        status: cert.Status || 'UNKNOWN',
      });
    }
    nextToken = resp.NextToken;
  } while (nextToken);
  return items;
}

async function scanWebSecurityGroups(awsConfig) {
  const client = new EC2Client(awsConfig);
  const items = [];
  let nextToken;
  do {
    const resp = await client.send(new DescribeSecurityGroupsCommand({
      Filters: [{ Name: 'ip-permission.from-port', Values: ['443', '80'] }],
      NextToken: nextToken,
    }));
    for (const group of resp.SecurityGroups || []) {
      const httpsRule = (group.IpPermissions || []).some(
        (perm) => perm.IpProtocol === 'tcp' && (perm.FromPort ?? 0) <= 443 && (perm.ToPort ?? 0) >= 443,
      );
      items.push({
        serviceType: 'SG',
        component: `ALB security group (${group.GroupId})`,
        status: httpsRule ? 'HTTPS_ENABLED' : 'NO_HTTPS_RULE',
      });
    }
    nextToken = resp.NextToken;
  } while (nextToken);
  return items;
}

const credentialsSecretId = process.env.CREDENTIALS_SECRET_ID || 'sarrescost/backend/credentials';
const secretsClientRegion = process.env.AWS_REGION || 'us-east-1';
const secretsClient = credentialsSecretId ? new SecretsManagerClient({ region: secretsClientRegion }) : null;

function applyCredentials(payload = {}) {
  if (payload.openaiApiKey !== undefined) apiKey = payload.openaiApiKey;
  if (payload.awsAccessKeyId !== undefined) awsAccessKeyId = payload.awsAccessKeyId;
  if (payload.awsSecretAccessKey !== undefined) awsSecretAccessKey = payload.awsSecretAccessKey;
  if (payload.awsRegion) awsRegion = payload.awsRegion;
  if (payload.claudeApiKey !== undefined) claudeApiKey = payload.claudeApiKey;
  if (payload.claudeOrgId !== undefined) claudeOrgId = payload.claudeOrgId;
}

function extractSecretString(data) {
  if (data.SecretString) return data.SecretString;
  if (data.SecretBinary) return Buffer.from(data.SecretBinary, 'base64').toString('utf8');
  return '{}';
}

async function loadCredentialsFromSecret() {
  if (!secretsClient || !credentialsSecretId) return;
  try {
    const response = await secretsClient.send(new GetSecretValueCommand({ SecretId: credentialsSecretId }));
    const parsed = JSON.parse(extractSecretString(response) || '{}');
    applyCredentials(parsed);
  } catch (err) {
    console.warn('[secrets] Unable to load credentials:', err.message);
  }
}

async function persistCredentialsToSecret(updates = {}) {
  if (!secretsClient || !credentialsSecretId) {
    throw new Error('Secrets Manager is not configured for this service.');
  }
  const next = {
    openaiApiKey: updates.openaiApiKey ?? apiKey,
    awsAccessKeyId: updates.awsAccessKeyId ?? awsAccessKeyId,
    awsSecretAccessKey: updates.awsSecretAccessKey ?? awsSecretAccessKey,
    awsRegion: updates.awsRegion ?? awsRegion,
    claudeApiKey: updates.claudeApiKey ?? claudeApiKey,
    claudeOrgId: updates.claudeOrgId ?? claudeOrgId,
  };
  await secretsClient.send(new PutSecretValueCommand({
    SecretId: credentialsSecretId,
    SecretString: JSON.stringify(next),
  }));
  applyCredentials(next);
}

function awsCredentials() {
  if (awsAccessKeyId && awsSecretAccessKey) {
    return { accessKeyId: awsAccessKeyId, secretAccessKey: awsSecretAccessKey };
  }
  return null;
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
    servers: [{ url: `http://localhost:${PORT}` }],
  },
  apis: [__filename],
});

// ── Middleware ────────────────────────────────────────────────────────────────

app.use(cors(corsOptions));
app.use(express.json());
app.use('/api-docs', swaggerUi.serve, swaggerUi.setup(swaggerSpec));

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
app.post('/api/config/key', async (req, res) => {
  const { key } = req.body;
  if (!key || typeof key !== 'string' || !key.trim()) {
    return res.status(400).json({ error: 'key is required' });
  }
  const trimmed = key.trim();
  try {
    await persistCredentialsToSecret({ openaiApiKey: trimmed });
  } catch (err) {
    console.error('[config] Failed to store OpenAI key in Secrets Manager:', err.message);
    return res.status(500).json({ error: 'Unable to store key. Please try again.' });
  }
  res.json({ ok: true, keyPreview: maskKey(trimmed) });
});

// ── Claude config routes ─────────────────────────────────────────────────────

app.get('/api/claude/config/status', (_req, res) => {
  res.json({
    hasKey: Boolean(claudeApiKey),
    keyPreview: maskKey(claudeApiKey),
    hasOrgId: Boolean(claudeOrgId),
    orgPreview: maskClaudeOrg(claudeOrgId),
  });
});

app.post('/api/claude/config/key', async (req, res) => {
  const { key, orgId } = req.body || {};
  if (!key || typeof key !== 'string' || !key.trim()) {
    return res.status(400).json({ error: 'key is required' });
  }
  if (orgId !== undefined && orgId !== null && typeof orgId !== 'string') {
    return res.status(400).json({ error: 'orgId must be a string if provided' });
  }
  const updates = {
    claudeApiKey: key.trim(),
    claudeOrgId: orgId?.trim() || '',
  };
  try {
    await persistCredentialsToSecret(updates);
  } catch (err) {
    console.error('[claude config] Failed to store Claude credentials:', err.message);
    return res.status(500).json({ error: 'Unable to store Claude credentials. Please try again.' });
  }
  res.json({
    ok: true,
    keyPreview: maskKey(claudeApiKey),
    orgPreview: claudeOrgId ? maskClaudeOrg(claudeOrgId) : null,
  });
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
app.post('/api/aws/config/credentials', async (req, res) => {
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
  const next = {
    awsAccessKeyId: accessKeyId.trim(),
    awsSecretAccessKey: secretAccessKey.trim(),
    awsRegion: region.trim(),
  };
  try {
    await persistCredentialsToSecret(next);
  } catch (err) {
    console.error('[aws config] Failed to store credentials in Secrets Manager:', err.message);
    return res.status(500).json({ error: 'Unable to store AWS credentials. Please try again.' });
  }
  res.json({ ok: true, accessKeyPreview: maskAwsKey(next.awsAccessKeyId), region: next.awsRegion });
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

app.get('/api/aws/services', async (_req, res, next) => {
  try {
    const items = await fetchAwsServiceInventory();
    res.json({ items });
  } catch (err) {
    if (err.message && err.message.includes('CloudFormation stack')) {
      return res.status(400).json({ error: err.message });
    }
    next(err);
  }
});

// ── Claude routes ───────────────────────────────────────────────────────────

app.get('/api/claude/costs', async (req, res, next) => {
  try {
    if (!claudeApiKey) {
      return res.status(400).json({ error: 'Claude Admin API key is not configured. Use the Settings modal to add your key.' });
    }
    const { startIso, endIso } = resolveClaudeDateRange(req.query.start_date, req.query.end_date);
    const buckets = await fetchClaudeCostBuckets(startIso, endIso);

    let totalCents = 0;
    const daily_costs = buckets.map((bucket) => {
      const timestamp = isoToUnixSeconds(bucket.starting_at);
      const line_items = (bucket.results || []).map((item) => {
        const cost = claudeAmountToCents(item.amount);
        totalCents += cost;
        return {
          name: item.description || item.model || item.cost_type || 'Unknown',
          cost,
          currency: item.currency || 'USD',
          model: item.model || null,
          cost_type: item.cost_type || null,
          workspace_id: item.workspace_id || null,
        };
      }).filter((entry) => entry.cost > 0);
      return { timestamp, line_items };
    }).filter((day) => day.line_items.length > 0);

    res.json({ total_cost: totalCents, daily_costs });
  } catch (err) {
    if (err.message === 'start_date must be on or before end_date.') {
      return res.status(400).json({ error: err.message });
    }
    if (err.response) {
      const status = err.response.status || 502;
      const message = err.response.data?.error?.message
        || err.response.data?.error
        || err.response.data?.message
        || 'Claude API error';
      return res.status(status).json({ error: message });
    }
    next(err);
  }
});

// ── Health check ─────────────────────────────────────────────────────────────

app.get('/health', (_req, res) => {
  res.json({ ok: true, version: API_VERSION, timestamp: Date.now() });
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

function bootstrap() {
  loadCredentialsFromSecret();
  app.listen(PORT, () => {
    console.log(`Backend running at http://localhost:${PORT}`);
    if (!apiKey) console.warn('WARNING: No API key set. Open the dashboard and use Settings to configure your key.');
  });
}

bootstrap();
