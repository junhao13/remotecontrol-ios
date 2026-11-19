import Foundation
import Network
import UIKit

/// 连接状态
enum ConnState: String {
    case idle = "未连接"
    case connecting = "正在连接…"
    case waitingAuth = "已握手，等待被控端授权…"
    case connected = "已连接"
    case failed = "连接失败"
}

/// 控制端 TCP 连接：基于 Network.framework，原生支持 IPv4/IPv6
final class RemoteConnection: ObservableObject {
    @Published var state: ConnState = .idle
    @Published var statusText: String = "输入被控端地址后点「连接」"
    @Published var screenImage: UIImage?
    @Published var screenW: Int32 = 0
    @Published var screenH: Int32 = 0

    private var connection: NWConnection?
    private let decoder = MessageDecoder()
    private let netQueue = DispatchQueue(label: "com.remotecontrol.net", qos: .userInitiated)
    private var frameW: Int32 = 0
    private var frameH: Int32 = 0

    // 画面节流：接收线程只缓存"最新一帧的原始字节"，绝不在接收线程解码，
    // 否则每帧 UIImage(data:) 同步解码会堵死 socket 读取，导致 TCP 发送队列堆积旧帧。
    // 定时器到点才解码并渲染最新一帧，中间堆积的旧帧被覆盖直接丢弃。
    private let frameLock = NSLock()
    private var pendingData: Data?
    private var frameTimer: DispatchSourceTimer?

    /// 是否处于已连接可发指令状态
    var isConnected: Bool { state == .connected }

    func connect(host: String, port: UInt16 = RCProtocol.port) {
        disconnect()
        startFrameTicker()
        publishState(.connecting, "正在连接 \(host):\(port) …")

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: port)!)
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                self.publishState(.connecting, "TCP 已建立，发送握手…")
                self.sendHello()
                self.startReceiving()
            case .waiting(let err):
                self.publishState(.connecting, "网络等待：\(err.localizedDescription)")
            case .failed(let err):
                self.publishState(.failed, "连接失败：\(err.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: netQueue)
    }

    func disconnect() {
        decoder.reset()
        connection?.cancel()
        connection = nil
        stopFrameTicker()
        frameW = 0; frameH = 0
        screenW = 0; screenH = 0
        frameLock.lock(); pendingData = nil; frameLock.unlock()
        DispatchQueue.main.async {
            self.screenImage = nil
            self.state = .idle
            self.statusText = "输入被控端地址后点「连接」"
        }
    }

    /// 帧投递定时器：每 50ms 只解码渲染"当前最新的一帧"。
    /// 关键：解码放到这里做，绝不放接收线程；这样接收线程能全速排空 TCP 队列，
    /// 队列里堆积的旧帧在读进来时就被后来帧覆盖丢弃，不会逐帧显示。
    private func startFrameTicker() {
        stopFrameTicker()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.frameLock.lock()
            let data = self.pendingData
            self.pendingData = nil
            self.frameLock.unlock()
            // 只解码这 50ms 窗口内的最新一帧；解码开销只在主线程发生一次
            if let data = data, let img = UIImage(data: data) {
                self.screenImage = img
            }
        }
        timer.resume()
        frameTimer = timer
    }

    private func stopFrameTicker() {
        frameTimer?.cancel()
        frameTimer = nil
    }

    private func publishState(_ s: ConnState, _ text: String) {
        DispatchQueue.main.async {
            self.state = s
            self.statusText = text
        }
    }

    private func sendHello() {
        let data = RCProtocol.pack(RCProtocol.CMD_HELLO, "RC1".data(using: .utf8))
        sendRaw(data)
    }

    private func sendRaw(_ data: Data) {
        guard let conn = connection else { return }
        conn.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[RC] send error: \(error)")
            }
        })
    }

    private func startReceiving() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let data = content, !data.isEmpty {
                let msgs = self.decoder.feed(data)
                for msg in msgs { self.handleMessage(msg) }
            }
            if isComplete || error != nil {
                if let error = error {
                    self.publishState(.failed, "连接断开：\(error.localizedDescription)")
                } else if self.state != .idle {
                    self.publishState(.failed, "连接已被对方关闭")
                }
                return
            }
            self.startReceiving()  // 继续下一轮接收
        }
    }

    private func handleMessage(_ msg: RCMessage) {
        switch msg.type {
        case RCProtocol.MSG_AUTH_OK:
            publishState(.waitingAuth, "已授权，等待屏幕信息…")

        case RCProtocol.MSG_AUTH_DENIED:
            publishState(.failed, "对方拒绝了连接")
            disconnect()

        case RCProtocol.MSG_SCREEN_INFO:
            guard msg.payload.count >= 16 else { return }
            frameW = getInt32(msg.payload, 0)
            frameH = getInt32(msg.payload, 1)
            screenW = getInt32(msg.payload, 2)
            screenH = getInt32(msg.payload, 3)
            publishState(.connected,
                         "已连接：\(screenW)x\(screenH)  帧 \(frameW)x\(frameH)")

        case RCProtocol.MSG_FRAME:
            // 接收线程只做一次 Data 持有（几乎零开销），绝不解码。
            // 快速排空 TCP 队列：旧帧读到后直接被下一帧覆盖，只留最新一帧给定时器解码。
            frameLock.lock()
            pendingData = msg.payload
            frameLock.unlock()

        default:
            break
        }
    }

    // MARK: - 控制指令

    func tap(x: Int32, y: Int32) {
        guard isConnected else { return }
        sendRaw(RCProtocol.pack(RCProtocol.CMD_TAP, RCProtocol.ints(x, y)))
    }

    func swipe(x1: Int32, y1: Int32, x2: Int32, y2: Int32, duration: Int32) {
        guard isConnected else { return }
        sendRaw(RCProtocol.pack(RCProtocol.CMD_SWIPE,
                                RCProtocol.ints(x1, y1, x2, y2, duration)))
    }

    func key(_ code: Int32) {
        guard isConnected else { return }
        sendRaw(RCProtocol.pack(RCProtocol.CMD_KEY, RCProtocol.ints(code)))
    }

    func text(_ str: String) {
        guard isConnected else { return }
        sendRaw(RCProtocol.pack(RCProtocol.CMD_TEXT, str.data(using: .utf8)))
    }

    deinit {
        stopFrameTicker()
        connection?.cancel()
    }
}
