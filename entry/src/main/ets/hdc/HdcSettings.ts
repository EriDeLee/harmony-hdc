/**
 * 连接配置持久化（仅保存最近一次成功连接的 host/port，无历史，直接覆写）。
 */
import { preferences } from '@kit.ArkData';
import type { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';

const STORE_NAME: string = 'hdc_settings';
const KEY_HOST: string = 'last_host';
const KEY_PORT: string = 'last_port';
const KEY_BUNDLE_SYS: string = 'bundle_system_map';

export interface ConnectionConfig {
  host: string;
  port: number;
}

interface CacheRow {
  n: string;
  s: boolean;
}

async function getStore(context: common.Context): Promise<preferences.Preferences> {
  try {
    return await preferences.getPreferences(context, STORE_NAME);
  } catch (err) {
    throw new Error(`打开 Preferences(${STORE_NAME}) 失败: ${(err as BusinessError).message}`);
  }
}

/** 保存最近一次成功连接的 host/port（覆写）。 */
export async function saveConnection(context: common.Context, host: string, port: number): Promise<void> {
  const store = await getStore(context);
  try {
    await store.put(KEY_HOST, host);
    await store.put(KEY_PORT, port);
    await store.flush();
  } catch (err) {
    throw new Error(`保存连接配置失败: ${(err as BusinessError).message}`);
  }
}

/** 读取上次成功连接的 host/port；无记录返回 null。 */
export async function loadConnection(context: common.Context): Promise<ConnectionConfig | null> {
  const store = await getStore(context);
  let host: string;
  let port: number;
  try {
    const exists = await store.has(KEY_HOST);
    if (!exists) {
      return null;
    }
    host = await store.get(KEY_HOST, '') as string;
    port = await store.get(KEY_PORT, 0) as number;
  } catch (err) {
    throw new Error(`读取连接配置失败: ${(err as BusinessError).message}`);
  }
  if (host.length === 0 || port <= 0) {
    return null;
  }
  return { host, port };
}

/** 读取“包名→是否系统应用”的分类缓存；无记录返回空 Map。 */
export async function loadBundleSystemMap(context: common.Context): Promise<Map<string, boolean>> {
  const map = new Map<string, boolean>();
  try {
    const store = await getStore(context);
    const text = await store.get(KEY_BUNDLE_SYS, '') as string;
    if (text.length === 0) {
      return map;
    }
    const rows = JSON.parse(text) as CacheRow[];
    for (const row of rows) {
      map.set(row.n, row.s);
    }
  } catch (err) {
    // 缓存损坏时返回空，重新分类即可
  }
  return map;
}

/** 持久化“包名→是否系统应用”的分类缓存（覆写）。 */
export async function saveBundleSystemMap(context: common.Context, map: Map<string, boolean>): Promise<void> {
  const rows: CacheRow[] = [];
  map.forEach((value: boolean, key: string) => {
    rows.push({ n: key, s: value });
  });
  try {
    const store = await getStore(context);
    await store.put(KEY_BUNDLE_SYS, JSON.stringify(rows));
    await store.flush();
  } catch (err) {
    throw new Error(`保存应用分类缓存失败: ${(err as BusinessError).message}`);
  }
}
