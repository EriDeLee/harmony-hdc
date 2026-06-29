/**
 * 密钥持久化：把 RSA-3072 PEM 存入应用 Preferences，供下次连接复用。
 * 注意：这是本地调试工具，私钥以 PEM 存于应用沙箱 Preferences。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HdcKeyPair, importPemPair } from './HdcCrypto';

const STORE_NAME: string = 'hdc_keys';
const KEY_PRIVATE: string = 'private_pem';
const KEY_PUBLIC: string = 'public_pem';

async function getStore(context: common.Context): Promise<preferences.Preferences> {
  try {
    return await preferences.getPreferences(context, STORE_NAME);
  } catch (err) {
    throw new Error(`打开 Preferences(${STORE_NAME}) 失败: ${(err as BusinessError).message}`);
  }
}

/** 保存密钥对的 PEM。 */
export async function saveKeyPair(context: common.Context, keyPair: HdcKeyPair): Promise<void> {
  const store = await getStore(context);
  try {
    await store.put(KEY_PRIVATE, keyPair.privatePem);
    await store.put(KEY_PUBLIC, keyPair.publicPem);
    await store.flush();
  } catch (err) {
    throw new Error(`保存密钥失败: ${(err as BusinessError).message}`);
  }
}

/** 是否已存在持久化密钥。 */
export async function hasKeyPair(context: common.Context): Promise<boolean> {
  const store = await getStore(context);
  try {
    return await store.has(KEY_PRIVATE);
  } catch (err) {
    throw new Error(`查询密钥失败: ${(err as BusinessError).message}`);
  }
}

/** 读取持久化密钥并恢复为 KeyPair；不存在返回 null。 */
export async function loadKeyPair(context: common.Context): Promise<HdcKeyPair | null> {
  const store = await getStore(context);
  let privatePem: string;
  let publicPem: string;
  try {
    const exists = await store.has(KEY_PRIVATE);
    if (!exists) {
      return null;
    }
    privatePem = await store.get(KEY_PRIVATE, '') as string;
    publicPem = await store.get(KEY_PUBLIC, '') as string;
  } catch (err) {
    throw new Error(`读取密钥失败: ${(err as BusinessError).message}`);
  }
  // 公钥也必须存在（convertPemKey 不会从私钥派生公钥）；任一为空视为无可用密钥，触发重新生成
  if (privatePem.length === 0 || publicPem.length === 0) {
    return null;
  }
  return importPemPair(privatePem, publicPem);
}

/** 删除持久化密钥。 */
export async function clearKeyPair(context: common.Context): Promise<void> {
  const store = await getStore(context);
  try {
    await store.delete(KEY_PRIVATE);
    await store.delete(KEY_PUBLIC);
    await store.flush();
  } catch (err) {
    throw new Error(`删除密钥失败: ${(err as BusinessError).message}`);
  }
}
