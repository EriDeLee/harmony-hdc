/**
 * 密钥持久化：把 RSA-3072 PEM 存入应用 Preferences，供下次连接复用。
 * 注意：这是本地调试工具，私钥以 PEM 存于应用沙箱 Preferences。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { HdcKeyPair, importPemPair } from './HdcCrypto';

const STORE_NAME: string = 'hdc_keys';
const KEY_PRIVATE: string = 'private_pem';
const KEY_PUBLIC: string = 'public_pem';

async function getStore(context: common.Context): Promise<preferences.Preferences> {
  return preferences.getPreferences(context, STORE_NAME);
}

/** 保存密钥对的 PEM。 */
export async function saveKeyPair(context: common.Context, keyPair: HdcKeyPair): Promise<void> {
  const store = await getStore(context);
  await store.put(KEY_PRIVATE, keyPair.privatePem);
  await store.put(KEY_PUBLIC, keyPair.publicPem);
  await store.flush();
}

/** 是否已存在持久化密钥。 */
export async function hasKeyPair(context: common.Context): Promise<boolean> {
  const store = await getStore(context);
  return store.has(KEY_PRIVATE);
}

/** 读取持久化密钥并恢复为 KeyPair；不存在返回 null。 */
export async function loadKeyPair(context: common.Context): Promise<HdcKeyPair | null> {
  const store = await getStore(context);
  const exists = await store.has(KEY_PRIVATE);
  if (!exists) {
    return null;
  }
  const privatePem = await store.get(KEY_PRIVATE, '') as string;
  const publicPem = await store.get(KEY_PUBLIC, '') as string;
  // 公钥也必须存在（convertPemKey 不会从私钥派生公钥）；任一为空视为无可用密钥，触发重新生成
  if (privatePem.length === 0 || publicPem.length === 0) {
    return null;
  }
  return importPemPair(privatePem, publicPem);
}

/** 删除持久化密钥。 */
export async function clearKeyPair(context: common.Context): Promise<void> {
  const store = await getStore(context);
  await store.delete(KEY_PRIVATE);
  await store.delete(KEY_PUBLIC);
  await store.flush();
}
