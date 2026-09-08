import Redis, { RedisOptions } from 'ioredis';
import { env } from './environment';
import { logger } from '@shared/utils/logger';

const REDIS_RETRY_STRATEGY = (times: number): number | null => {
  if (times > 10) {
    logger.error('Redis: Maximum reconnection attempts exceeded. Giving up.');
    return null;
  }
  const delay = Math.min(times * 100, 3000);
  logger.warn(`Redis: Reconnecting in ${delay}ms (attempt ${times})`);
  return delay;
};

function buildRedisOptions(withPrefix = true): RedisOptions {
  const isTls = env.REDIS_URL.startsWith('rediss://');
  return {
    keyPrefix: withPrefix ? env.REDIS_KEY_PREFIX : undefined,
    retryStrategy: REDIS_RETRY_STRATEGY,
    maxRetriesPerRequest: null,
    lazyConnect: true,
    enableReadyCheck: false,
    connectTimeout: 20000,
    tls: isTls ? { rejectUnauthorized: false } : undefined,
  };
}

// ─────────────────────────────────────────────
// Redis Instances
// ─────────────────────────────────────────────

let sharedClient: Redis | null = null;
let queueClient: Redis | null = null;

function getOrCreateClient(): Redis {
  if (!sharedClient) {
    sharedClient = new Redis(env.REDIS_URL, buildRedisOptions(true));
    sharedClient.on('connect', () => logger.info(`Redis connected`));
    sharedClient.on('ready', () => logger.info(`Redis ready`));
    sharedClient.on('error', (err: Error) => logger.error(`Redis error: ${err.message}`));
  }
  return sharedClient;
}

export function getCacheClient(): Redis {
  return getOrCreateClient();
}

export function getSessionClient(): Redis {
  return getOrCreateClient();
}

export function getLockClient(): Redis {
  return getOrCreateClient();
}

export function getQueueClient(): Redis {
  if (!queueClient) {
    queueClient = new Redis(env.REDIS_URL, buildRedisOptions(false));
    queueClient.on('error', (err: Error) => logger.error(`BullMQ Redis error: ${err.message}`));
  }
  return queueClient;
}

// ─────────────────────────────────────────────
// Connect Redis
// ─────────────────────────────────────────────

export async function connectRedis(): Promise<void> {
  const client = getOrCreateClient();
  try {
    if (client.status === 'wait') {
      await client.connect();
    }
    await client.ping();
    logger.info(`✅ Redis connected successfully`);
  } catch (error) {
    const err = error as Error;
    logger.warn(`Redis initial ping warning: ${err.message}`);
  }
}

export async function disconnectRedis(): Promise<void> {
  if (sharedClient) {
    await sharedClient.quit();
    sharedClient = null;
    logger.info('Redis connection closed');
  }
}

// ─────────────────────────────────────────────
// Health Check
// ─────────────────────────────────────────────

export async function checkRedisHealth(): Promise<{
  healthy: boolean;
  latencyMs: number;
}> {
  const start = Date.now();
  try {
    await getCacheClient().ping();
    return { healthy: true, latencyMs: Date.now() - start };
  } catch {
    return { healthy: false, latencyMs: Date.now() - start };
  }
}

// ─────────────────────────────────────────────
// Cache Utilities
// ─────────────────────────────────────────────

export class CacheService {
  private client: Redis;
  private defaultTTL: number;

  constructor(client: Redis, defaultTTLSeconds = 300) {
    this.client = client;
    this.defaultTTL = defaultTTLSeconds;
  }

  async get<T>(key: string): Promise<T | null> {
    const value = await this.client.get(key);
    if (!value) return null;
    try {
      return JSON.parse(value) as T;
    } catch {
      return null;
    }
  }

  async set<T>(key: string, value: T, ttlSeconds?: number): Promise<void> {
    const ttl = ttlSeconds ?? this.defaultTTL;
    await this.client.setex(key, ttl, JSON.stringify(value));
  }

  async del(key: string): Promise<void> {
    await this.client.del(key);
  }

  async delPattern(pattern: string): Promise<void> {
    const keys = await this.client.keys(pattern);
    if (keys.length > 0) {
      await this.client.del(...keys);
    }
  }

  async exists(key: string): Promise<boolean> {
    const result = await this.client.exists(key);
    return result === 1;
  }

  async ttl(key: string): Promise<number> {
    return this.client.ttl(key);
  }

  async increment(key: string, by = 1): Promise<number> {
    return this.client.incrby(key, by);
  }

  async setNX(key: string, value: string, ttlMs: number): Promise<boolean> {
    const result = await this.client.set(key, value, 'PX', ttlMs, 'NX');
    return result === 'OK';
  }
}
