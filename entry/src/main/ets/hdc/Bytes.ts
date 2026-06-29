/**
 * 字节缓冲与编码工具。ArkTS 下统一用 Uint8Array 表示二进制。
 */
import { util } from '@kit.ArkTS';
import { buffer } from '@kit.ArkTS';

/** 可增长的字节写入缓冲。 */
export class ByteWriter {
  private chunks: Uint8Array[] = [];
  private length: number = 0;

  appendByte(value: number): void {
    this.append(new Uint8Array([value & 0xff]));
  }

  append(data: Uint8Array): void {
    this.chunks.push(data);
    this.length += data.length;
  }

  /** 写入 16 位大端。 */
  appendUint16BE(value: number): void {
    this.append(new Uint8Array([(value >>> 8) & 0xff, value & 0xff]));
  }

  /** 写入 32 位大端。 */
  appendUint32BE(value: number): void {
    this.append(new Uint8Array([
      (value >>> 24) & 0xff,
      (value >>> 16) & 0xff,
      (value >>> 8) & 0xff,
      value & 0xff
    ]));
  }

  size(): number {
    return this.length;
  }

  toUint8Array(): Uint8Array {
    const out = new Uint8Array(this.length);
    let offset = 0;
    for (const chunk of this.chunks) {
      out.set(chunk, offset);
      offset += chunk.length;
    }
    return out;
  }
}

/** 顺序读取字节缓冲。 */
export class ByteReader {
  private readonly data: Uint8Array;
  private pos: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  remaining(): number {
    return this.data.length - this.pos;
  }

  position(): number {
    return this.pos;
  }

  readByte(): number {
    if (this.pos >= this.data.length) {
      throw new Error('ByteReader: 读取越界');
    }
    const value = this.data[this.pos];
    this.pos += 1;
    return value;
  }

  readUint16BE(): number {
    const hi = this.readByte();
    const lo = this.readByte();
    return (hi << 8) | lo;
  }

  readUint32BE(): number {
    const b0 = this.readByte();
    const b1 = this.readByte();
    const b2 = this.readByte();
    const b3 = this.readByte();
    // 用无符号右移避免符号位问题
    return ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3) >>> 0;
  }

  readBytes(count: number): Uint8Array {
    if (this.pos + count > this.data.length) {
      throw new Error('ByteReader: 读取越界');
    }
    const slice = this.data.slice(this.pos, this.pos + count);
    this.pos += count;
    return slice;
  }
}

const textEncoder = new util.TextEncoder('utf-8');
const textDecoder = util.TextDecoder.create('utf-8');

/** UTF-8 字符串转字节。空串需特判：encodeInto('') 在部分实现返回 undefined。 */
export function utf8ToBytes(text: string): Uint8Array {
  if (text === undefined || text === null || text.length === 0) {
    return new Uint8Array(0);
  }
  return textEncoder.encodeInto(text);
}

/** 字节转 UTF-8 字符串（非法序列替换）。 */
export function bytesToUtf8(data: Uint8Array): string {
  return textDecoder.decodeToString(data);
}

/** 拼接多个字节数组。 */
export function concatBytes(parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const part of parts) {
    total += part.length;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/** Base64 编码。 */
export function bytesToBase64(data: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(data);
}

/** Base64 解码。 */
export function base64ToBytes(text: string): Uint8Array {
  const helper = new util.Base64Helper();
  return helper.decodeSync(text);
}

/** 十六进制（小写）用于日志。 */
export function bytesToHex(data: Uint8Array): string {
  return buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('hex');
}
