/**
 * 连接配置持久化（仅保存最近一次成功连接的 host/port，无历史，直接覆写）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const STORE_NAME: string = 'hdc_settings';
const KEY_HOST: string = 'last_host';
const KEY_PORT: string = 'last_port';

export interface ConnectionConfig {
  host: string;
  port: number;
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
