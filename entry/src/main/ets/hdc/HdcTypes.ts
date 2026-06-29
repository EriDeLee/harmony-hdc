/**
 * HDC 3.x 协议常量与类型定义。
 * 来源：hdc-reverse-engineer/hdc_wireless_report.md 与 hdc_wireless_connect.py。
 */

// 帧头标识与协议版本（PayloadHead）
export const PACKET_FLAG: string = 'HW';
export const PROTOCOL_VER: number = 1;
export const PAYLOAD_VCODE: number = 9;

// HDC 命令字（commandFlag），数值来自 developtools_hdc_standard/src/common/define_plus.h
export const CMD_KERNEL_HANDSHAKE: number = 1;
export const CMD_KERNEL_CHANNEL_CLOSE: number = 2;
export const CMD_KERNEL_ECHO: number = 9;
export const CMD_KERNEL_ECHO_RAW: number = 10; // shell 输出回传命令字
export const CMD_UNITY_EXECUTE: number = 1001;
export const CMD_SHELL_INIT: number = 2000;
export const CMD_SHELL_DATA: number = 2001;

// 认证类型（SessionHandShake.authType）
export const AUTH_NONE: number = 0;
export const AUTH_TOKEN: number = 1;
export const AUTH_SIGNATURE: number = 2;
export const AUTH_PUBLICKEY: number = 3;
export const AUTH_OK: number = 4;
export const AUTH_FAIL: number = 5;
export const AUTH_ENCRYPT: number = 6;

// 握手 banner 与默认版本串（注意：3.2.0d 需联调/逆向核对 magic 后缀）
export const HANDSHAKE_BANNER: string = 'OHOS HDC';
export const DEFAULT_VERSION: string = 'Ver: 3.0.0b7fdbc1aa8c5fefaa';

/** 解析后的 SessionHandShake。 */
export interface HandShake {
  banner: string;
  authType: number;
  sessionId: number;
  connectKey: string;
  buf: Uint8Array;
  version: string;
}

/** 解析后的一帧 HDC 报文。 */
export interface HdcFrame {
  protocolVer: number;
  protectFields: Map<number, number | Uint8Array>;
  channelId: number;
  commandFlag: number;
  payload: Uint8Array;
}
