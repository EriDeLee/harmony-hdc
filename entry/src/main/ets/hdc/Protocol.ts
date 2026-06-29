/**
 * HDC 3.x 协议编解码：varint、protobuf-like message、TLV、PayloadHead 帧、SessionHandShake。
 * 逐字节对应 hdc_wireless_connect.py 的实现。
 */
import { ByteReader, ByteWriter, bytesToUtf8, concatBytes, utf8ToBytes } from './Bytes';
import {
  CMD_KERNEL_HANDSHAKE,
  HANDSHAKE_BANNER,
  HandShake,
  HdcFrame,
  PACKET_FLAG,
  PAYLOAD_VCODE,
  PROTOCOL_VER
} from './HdcTypes';

const PACKET_FLAG_BYTES: Uint8Array = utf8ToBytes(PACKET_FLAG);

// ---------- varint ----------

export function encodeVarint(value: number): Uint8Array {
  if (value < 0) {
    throw new Error('varint 不能为负');
  }
  const out = new ByteWriter();
  let v = value >>> 0;
  // value 最大为 uint32（sessionId），用无符号 32 位运算
  while (true) {
    const byte = v & 0x7f;
    v = v >>> 7;
    if (v !== 0) {
      out.appendByte(byte | 0x80);
    } else {
      out.appendByte(byte);
      break;
    }
  }
  return out.toUint8Array();
}

export interface VarintResult {
  value: number;
  pos: number;
}

export function decodeVarint(data: Uint8Array, start: number): VarintResult {
  let value = 0;
  let shift = 0;
  let pos = start;
  while (pos < data.length) {
    const byte = data[pos];
    pos += 1;
    value += (byte & 0x7f) * Math.pow(2, shift);
    if ((byte & 0x80) === 0) {
      return { value, pos };
    }
    shift += 7;
    if (shift > 70) {
      throw new Error('varint 过长');
    }
  }
  throw new Error('varint 截断');
}

// ---------- protobuf-like message ----------

function fieldVarint(tag: number, value: number): Uint8Array {
  return concatBytes([encodeVarint((tag << 3) | 0), encodeVarint(value)]);
}

function fieldBytes(tag: number, value: Uint8Array): Uint8Array {
  return concatBytes([encodeVarint((tag << 3) | 2), encodeVarint(value.length), value]);
}

function fieldString(tag: number, value: string): Uint8Array {
  return fieldBytes(tag, utf8ToBytes(value));
}

/** 解析 protobuf-like 报文，返回 tag -> (varint 数值 | length-delimited 字节)。 */
export function parseMessage(data: Uint8Array): Map<number, number | Uint8Array> {
  const result = new Map<number, number | Uint8Array>();
  let pos = 0;
  while (pos < data.length) {
    const key = decodeVarint(data, pos);
    pos = key.pos;
    const tag = Math.floor(key.value / 8);
    const wireType = key.value & 7;
    if (wireType === 0) {
      const v = decodeVarint(data, pos);
      pos = v.pos;
      result.set(tag, v.value);
    } else if (wireType === 2) {
      const len = decodeVarint(data, pos);
      pos = len.pos;
      const slice = data.slice(len.pos, len.pos + len.value);
      pos = len.pos + len.value;
      result.set(tag, slice);
    } else {
      break; // 不支持的 wire type
    }
  }
  return result;
}

// ---------- TLV（定长 16 字节头） ----------

function pad16(value: Uint8Array): Uint8Array {
  if (value.length >= 16) {
    return value;
  }
  const out = new Uint8Array(16);
  out.fill(0x20); // 空格补齐
  out.set(value, 0);
  return out;
}

export function tlvAppend(buf: Uint8Array, key: string, value: string): Uint8Array {
  const valueBytes = utf8ToBytes(value);
  return concatBytes([
    buf,
    pad16(utf8ToBytes(key)),
    pad16(utf8ToBytes(`${valueBytes.length}`)),
    valueBytes
  ]);
}

/** 解析 TLV buffer，返回 key -> 原始字节值。 */
export function tlvParse(data: Uint8Array): Map<string, Uint8Array> {
  const result = new Map<string, Uint8Array>();
  let pos = 0;
  while (pos + 32 <= data.length) {
    const key = bytesToUtf8(data.slice(pos, pos + 16)).replace(/ +$/g, '').replace(/ +/g, ' ').trim();
    pos += 16;
    const rawLen = bytesToUtf8(data.slice(pos, pos + 16)).trim();
    pos += 16;
    const size = Number.parseInt(rawLen, 10);
    if (!Number.isFinite(size) || size < 0) {
      break;
    }
    if (pos + size > data.length) {
      break;
    }
    result.set(key, data.slice(pos, pos + size));
    pos += size;
  }
  return result;
}

// ---------- PayloadProtect ----------

function serializePayloadProtect(channelId: number, commandFlag: number): Uint8Array {
  return concatBytes([
    fieldVarint(1, channelId),
    fieldVarint(2, commandFlag),
    fieldVarint(3, 0),
    fieldVarint(4, PAYLOAD_VCODE)
  ]);
}

// ---------- SessionHandShake ----------

export interface HandShakeOptions {
  authType: number;
  sessionId: number;
  connectKey: string;
  buf: Uint8Array;
  version: string;
  includeVersion: boolean;
}

export function serializeHandShake(opts: HandShakeOptions): Uint8Array {
  const parts: Uint8Array[] = [
    fieldString(1, HANDSHAKE_BANNER),
    fieldVarint(2, opts.authType),
    fieldVarint(3, opts.sessionId),
    fieldString(4, opts.connectKey),
    fieldBytes(5, opts.buf)
  ];
  if (opts.includeVersion) {
    parts.push(fieldString(6, opts.version));
  }
  return concatBytes(parts);
}

// ---------- 帧组包/解包 ----------

/** 组一帧完整 HDC 报文：PayloadHead + PayloadProtect + Payload。 */
export function buildFrame(payload: Uint8Array, channelId: number, commandFlag: number): Uint8Array {
  const protect = serializePayloadProtect(channelId, commandFlag);
  const writer = new ByteWriter();
  writer.append(PACKET_FLAG_BYTES);
  writer.appendByte(0);
  writer.appendByte(0);
  writer.appendByte(PROTOCOL_VER);
  writer.appendUint16BE(protect.length);
  writer.appendUint32BE(payload.length);
  writer.append(protect);
  writer.append(payload);
  return writer.toUint8Array();
}

export interface ParseFrameResult {
  frame: HdcFrame;
  consumed: number;
}

/**
 * 尝试从流缓冲解析一帧；不足一帧返回 null。
 * @throws 帧头非法时抛出。
 */
export function tryParseFrame(data: Uint8Array): ParseFrameResult | null {
  if (data.length < 11) {
    return null;
  }
  if (data[0] !== PACKET_FLAG_BYTES[0] || data[1] !== PACKET_FLAG_BYTES[1]) {
    throw new Error(`非法 HDC 帧头: ${data[0]},${data[1]}`);
  }
  const reader = new ByteReader(data);
  reader.readBytes(4); // flag(2) + reserve(2)
  const protocolVer = reader.readByte();
  const protectSize = reader.readUint16BE();
  const dataSize = reader.readUint32BE();
  const total = 11 + protectSize + dataSize;
  if (data.length < total) {
    return null; // 帧未收全
  }
  const protect = reader.readBytes(protectSize);
  const payload = reader.readBytes(dataSize);
  const protectFields = parseMessage(protect);
  const channelRaw = protectFields.get(1);
  const cmdRaw = protectFields.get(2);
  const channelId = typeof channelRaw === 'number' ? channelRaw : 0;
  const commandFlag = typeof cmdRaw === 'number' ? cmdRaw : 0;
  const frame: HdcFrame = { protocolVer, protectFields, channelId, commandFlag, payload };
  return { frame, consumed: total };
}

/** 把一帧的 payload 解析为 SessionHandShake（仅握手帧适用）。 */
export function parseHandShake(payload: Uint8Array): HandShake {
  const fields = parseMessage(payload);
  const banner = fieldToString(fields.get(1));
  const authType = fieldToNumber(fields.get(2));
  const sessionId = fieldToNumber(fields.get(3));
  const connectKey = fieldToString(fields.get(4));
  const bufRaw = fields.get(5);
  const buf = bufRaw instanceof Uint8Array ? bufRaw : new Uint8Array(0);
  const version = fieldToString(fields.get(6));
  return { banner, authType, sessionId, connectKey, buf, version };
}

function fieldToString(value: number | Uint8Array | undefined): string {
  if (value instanceof Uint8Array) {
    return bytesToUtf8(value);
  }
  if (typeof value === 'number') {
    return `${value}`;
  }
  return '';
}

function fieldToNumber(value: number | Uint8Array | undefined): number {
  if (typeof value === 'number') {
    return value;
  }
  return 0;
}

/** 组初始握手 buf（authtype + supportfeatures）。 */
export function buildInitialBuf(advertiseEncryptTcp: boolean): Uint8Array {
  const features = advertiseEncryptTcp ? 'heartbeat,encrypt_tcp' : 'heartbeat';
  let buf = new Uint8Array(0);
  buf = tlvAppend(buf, 'authtype', '1');
  buf = tlvAppend(buf, 'supportfeatures', features);
  return buf;
}

export { CMD_KERNEL_HANDSHAKE };
