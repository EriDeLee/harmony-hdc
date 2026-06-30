/**
 * HDC 认证所需的 RSA-3072 密钥与签名能力。
 * - 生成 / 导入（PEM）RSA-3072 密钥对
 * - 导出公钥 PEM（X.509 SubjectPublicKeyInfo，与 openssl `pkey -pubout` 一致）
 * - 对 token 做 RSA-PSS / SHA512 / saltlen=digest 签名，输出 base64
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { bytesToBase64 } from './Bytes';

/** 把 DER 字节封装成 PEM 文本。 */
function wrapPem(label: string, der: Uint8Array): string {
  const b64 = bytesToBase64(der);
  const lines: string[] = [];
  for (let i = 0; i < b64.length; i += 64) {
    lines.push(b64.slice(i, i + 64));
  }
  return `-----BEGIN ${label}-----\n${lines.join('\n')}\n-----END ${label}-----\n`;
}

const RSA_ALG: string = 'RSA3072';
// 签名算法串：RSA-PSS，摘要 SHA512，MGF1 用 SHA512
const SIGN_ALG: string = 'RSA3072|PSS|SHA512|MGF1_SHA512';
// SHA512 摘要长度 64 字节，对应 openssl rsa_pss_saltlen:digest
const PSS_SALT_LEN: number = 64;

/** 应用内持有的密钥对（含 PEM 形式，便于持久化）。 */
export class HdcKeyPair {
  readonly keyPair: cryptoFramework.KeyPair;
  readonly privatePem: string;
  readonly publicPem: string;

  constructor(keyPair: cryptoFramework.KeyPair, privatePem: string, publicPem: string) {
    this.keyPair = keyPair;
    this.privatePem = privatePem;
    this.publicPem = publicPem;
  }
}

function requirePem(pem: string | undefined | null, label: string): string {
  if (pem === undefined || pem === null || pem.length === 0) {
    throw new Error(`${label} PEM 为空（getEncodedPem 返回无效值）`);
  }
  return pem;
}

// 公钥用最稳定的 getEncoded()（默认返回 X509 SubjectPublicKeyInfo DER）+ 手动 PEM 封装。
// getEncodedPem('X509') 在部分设备返回空、getEncodedDer('X509') 在部分设备抛错，故都不用。
function encodePublicPem(pubKey: cryptoFramework.PubKey): string {
  let der: cryptoFramework.DataBlob;
  try {
    der = pubKey.getEncoded();
  } catch (err) {
    throw new Error(`导出公钥 DER 失败: ${(err as BusinessError).message}`);
  }
  return wrapPem('PUBLIC KEY', der.data);
}

/** 新生成一对 RSA-3072 密钥。 */
export async function generateKeyPair(): Promise<HdcKeyPair> {
  try {
    const generator = cryptoFramework.createAsyKeyGenerator(RSA_ALG);
    const keyPair = await generator.generateKeyPair();
    const privatePem = requirePem(keyPair.priKey.getEncodedPem('PKCS8'), '私钥');
    const publicPem = requirePem(encodePublicPem(keyPair.pubKey), '公钥');
    return new HdcKeyPair(keyPair, privatePem, publicPem);
  } catch (err) {
    throw new Error(`生成 RSA-3072 密钥对失败: ${(err as BusinessError).message}`);
  }
}

/**
 * 从已保存的 PEM（私钥+公钥）恢复密钥对。
 * 注意：cryptoFramework.convertPemKey 不会从私钥派生公钥，必须同时提供公钥 PEM。
 */
export async function importPemPair(privatePem: string, publicPem: string): Promise<HdcKeyPair> {
  try {
    const generator = cryptoFramework.createAsyKeyGenerator(RSA_ALG);
    const keyPair = await generator.convertPemKey(publicPem, privatePem);
    return new HdcKeyPair(keyPair, privatePem, publicPem);
  } catch (err) {
    throw new Error(`从 PEM 恢复密钥对失败: ${(err as BusinessError).message}`);
  }
}

/** 对 token 做 RSA-PSS/SHA512 签名，返回 base64 字符串对应的字节。 */
export async function signToken(keyPair: HdcKeyPair, token: Uint8Array): Promise<string> {
  try {
    const sign = cryptoFramework.createSign(SIGN_ALG);
    await sign.init(keyPair.keyPair.priKey);
    sign.setSignSpec(cryptoFramework.SignSpecItem.PSS_SALT_LEN_NUM, PSS_SALT_LEN);
    const tokenBlob: cryptoFramework.DataBlob = { data: token };
    const result = await sign.sign(tokenBlob);
    return bytesToBase64(result.data);
  } catch (err) {
    throw new Error(`token 签名失败: ${(err as BusinessError).message}`);
  }
}
