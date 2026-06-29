/**
 * 连接配置持久化（仅保存最近一次成功连接的 host/port，无历史，直接覆写）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'hdc_settings';
const KEY_HOST: string = 'last_host';
const KEY_PORT: string = 'last_port';

export interface ConnectionConfig {
  host: string;
  port: number;
}

async function getStore(context: common.Context): Promise<preferences.Preferences> {
  return preferences.getPreferences(context, STORE_NAME);
}

/** 保存最近一次成功连接的 host/port（覆写）。 */
export async function saveConnection(context: common.Context, host: string, port: number): Promise<void> {
  const store = await getStore(context);
  await store.put(KEY_HOST, host);
  await store.put(KEY_PORT, port);
  await store.flush();
}

/** 读取上次成功连接的 host/port；无记录返回 null。 */
export async function loadConnection(context: common.Context): Promise<ConnectionConfig | null> {
  const store = await getStore(context);
  const exists = await store.has(KEY_HOST);
  if (!exists) {
    return null;
  }
  const host = await store.get(KEY_HOST, '') as string;
  const port = await store.get(KEY_PORT, 0) as number;
  if (host.length === 0 || port <= 0) {
    return null;
  }
  return { host, port };
}
