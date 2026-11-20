import Foundation

/// 与 Android 被控端字节级兼容的协议定义。
/// 帧格式：4 字节大端长度(含 1 字节类型) + 1 字节类型 + 载荷
enum RCProtocol {
    static let port: UInt16 = 8899

    // 服务端 -> 客户端
    static let MSG_AUTH_REQUIRED: UInt8 = 1
    static let MSG_AUTH_OK: UInt8 = 2
    static let MSG_AUTH_DENIED: UInt8 = 3
    static let MSG_SCREEN_INFO: UInt8 = 4   // frameW,frameH,screenW,screenH (4 x Int32 大端)
    static let MSG_FRAME: UInt8 = 5         // JPEG bytes

    // 客户端 -> 服务端
    static let CMD_HELLO: UInt8 = 20        // "RC1"
    static let CMD_TAP: UInt8 = 21          // x,y (2 x Int32)
    static let CMD_SWIPE: UInt8 = 22        // x1,y1,x2,y2,duration (5 x Int32)
    static let CMD_KEY: UInt8 = 23          // keycode (Int32)
    static let CMD_TEXT: UInt8 = 24         // utf-8 bytes

    // 虚拟按键码
    static let KEY_HOME: Int32 = 1
    static let KEY_BACK: Int32 = 2
    static let KEY_RECENTS: Int32 = 3
    static let KEY_POWER: Int32 = 4
    static let KEY_VOL_UP: Int32 = 5
    static let KEY_VOL_DOWN: Int32 = 6
    static let KEY_SCREEN_OFF: Int32 = 7
    static let KEY_SCREEN_ON: Int32 = 8

    static let maxMessageLength = 20 * 1024 * 1024

    /// 组装一条完整消息：4字节长度 + 1字节类型 + 载荷
    static func pack(_ type: UInt8, _ payload: Data? = nil) -> Data {
        let body = payload ?? Data()
        let len = UInt32(1 + body.count)  // 长度含类型字节
        var out = Data()
        out.append(contentsOf: [
            UInt8((len >> 24) & 0xFF),
            UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8) & 0xFF),
            UInt8(len & 0xFF),
        ])
        out.append(type)
        out.append(body)
        return out
    }

    /// 把若干 Int32 编码为大端字节（对应 Java Protocol.ints()）
    static func ints(_ values: Int32...) -> Data {
        var out = Data()
        for v in values {
            let u = UInt32(bitPattern: v)
            out.append(contentsOf: [
                UInt8((u >> 24) & 0xFF),
                UInt8((u >> 16) & 0xFF),
                UInt8((u >> 8) & 0xFF),
                UInt8(u & 0xFF),
            ])
        }
        return out
    }
}

struct RCMessage {
    let type: UInt8
    let payload: Data
}

/// TCP 流式粘包/半包处理器：累积字节，按 4 字节长度前缀拆出完整消息
final class MessageDecoder {
    private var buffer = Data()

    /// 喂入新字节，返回本次解析出的所有完整消息
    func feed(_ chunk: Data) -> [RCMessage] {
        buffer.append(chunk)
        var messages: [RCMessage] = []
        while buffer.count >= 4 {
            let len = Int(readUInt32BE(buffer, 0))
            if len < 1 || len > RCProtocol.maxMessageLength {
                // 非法长度，丢弃缓冲重新同步，避免越界
                buffer.removeAll()
                break
            }
            let total = 4 + len
            if buffer.count < total { break }  // 半包，等待更多字节
            let body = buffer.subdata(in: 4..<total)
            messages.append(RCMessage(type: body[0], payload: body.subdata(in: 1..<body.count)))
            buffer.removeSubrange(0..<total)
        }
        return messages
    }

    func reset() { buffer.removeAll() }

    private func readUInt32BE(_ d: Data, _ at: Int) -> UInt32 {
        (UInt32(d[at]) << 24) | (UInt32(d[at + 1]) << 16) |
        (UInt32(d[at + 2]) << 8) | UInt32(d[at + 3])
    }
}

/// 从大端载荷读取第 index 个 Int32（对应 Java Protocol.getInt()）
func getInt32(_ data: Data, _ index: Int) -> Int32 {
    let o = index * 4
    let u = (UInt32(data[o]) << 24) | (UInt32(data[o + 1]) << 16) |
            (UInt32(data[o + 2]) << 8) | UInt32(data[o + 3])
    return Int32(bitPattern: u)
}
