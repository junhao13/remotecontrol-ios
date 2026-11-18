import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var conn = RemoteConnection()
    @State private var host: String = UserDefaults.standard.string(forKey: "rc_host") ?? ""
    @State private var inputText: String = ""

    private let defaultsKey = "rc_host"

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                // 地址输入 + 连接/断开
                HStack(spacing: 8) {
                    TextField("被控端 IPv6 或 IPv4", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .font(.system(size: 14))

                    Button(action: toggleConnect) {
                        Text(conn.isConnected ? "断开" : "连接")
                            .frame(minWidth: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty && !conn.isConnected)
                }
                .padding(.horizontal)

                // 状态
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(conn.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal)

                // 远程画面（可触摸：点击=点击，拖动=滑动）
                ZStack {
                    Color.black.cornerRadius(8)
                    if let image = conn.screenImage {
                        RemoteImageView(image: image, conn: conn)
                            .cornerRadius(8)
                            .clipped()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 36))
                                .foregroundColor(.gray)
                            Text("连接后显示被控端画面\n单击=点击  拖动=滑动")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(.horizontal)
                .layoutPriority(1)

                // 虚拟按键
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        keyButton("主页", .init(RCProtocol.KEY_HOME), "house")
                        keyButton("返回", .init(RCProtocol.KEY_BACK), "arrow.left")
                        keyButton("多任务", .init(RCProtocol.KEY_RECENTS), "square.stack")
                        keyButton("电源", .init(RCProtocol.KEY_POWER), "power")
                        keyButton("音量+", .init(RCProtocol.KEY_VOL_UP), "speaker.wave.2")
                        keyButton("音量−", .init(RCProtocol.KEY_VOL_DOWN), "speaker.wave.1")
                    }
                    .padding(.horizontal)
                }
                .frame(height: 44)

                // 文字发送
                HStack(spacing: 8) {
                    TextField("输入要发送的文字…", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14))
                    Button("发送文字") {
                        let t = inputText.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { conn.text(t); inputText = "" }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!conn.isConnected || inputText.isEmpty)
                }
                .padding(.horizontal)
            }
            .padding(.top, 8)
            .navigationTitle("互控助手")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true  // 保持屏幕常亮
            }
        }
        .navigationViewStyle(.stack)
    }

    private var statusColor: Color {
        switch conn.state {
        case .connected: return .green
        case .connecting, .waitingAuth: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private func toggleConnect() {
        if conn.isConnected {
            conn.disconnect()
        } else {
            let h = host.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty else { return }
            UserDefaults.standard.set(h, forKey: defaultsKey)  // 记住地址，下次自动填入
            conn.connect(host: h)
        }
    }

    private func keyButton(_ title: String, _ code: Int32, _ icon: String) -> some View {
        Button(action: { conn.key(code) }) {
            Label(title, systemImage: icon)
                .font(.caption)
                .frame(height: 34)
        }
        .buttonStyle(.bordered)
        .disabled(!conn.isConnected)
    }
}

/// 显示 JPEG 帧并把触摸坐标映射为被控端物理坐标
struct RemoteImageView: UIViewRepresentable {
    let image: UIImage
    let conn: RemoteConnection

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = true
        iv.clipsToBounds = true
        iv.backgroundColor = .black

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        tap.require(toFail: pan)
        iv.addGestureRecognizer(tap)
        iv.addGestureRecognizer(pan)
        return iv
    }

    func updateUIView(_ iv: UIImageView, context: Context) {
        iv.image = image
        context.coordinator.conn = conn
        context.coordinator.imageSize = image.size
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var conn: RemoteConnection?
        var imageSize: CGSize = .zero
        private var panStart: CGPoint = .zero
        private var panStartTime: TimeInterval = 0

        /// 把 View 坐标 -> 画面坐标 -> 被控端物理坐标（对应 Android toRemote()）
        private func toRemote(_ point: CGPoint, in view: UIView) -> (Int32, Int32)? {
            let vw = view.bounds.width, vh = view.bounds.height
            let bw = imageSize.width, bh = imageSize.height
            guard vw > 0, vh > 0, bw > 0, bh > 0,
                  let conn = conn, conn.screenW > 0, conn.screenH > 0 else { return nil }

            // scaleAspectFit：等比缩放并居中
            let scale = min(vw / bw, vh / bh)
            let drawW = bw * scale
            let drawH = bh * scale
            let offsetX = (vw - drawW) / 2
            let offsetY = (vh - drawH) / 2

            var fx = (point.x - offsetX) / drawW
            var fy = (point.y - offsetY) / drawH
            fx = max(0, min(1, fx))
            fy = max(0, min(1, fy))
            return (Int32(fx * Float(conn.screenW)), Int32(fy * Float(conn.screenH)))
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view, let p = toRemote(g.location(in: view), in: view) else { return }
            conn?.tap(x: p.0, y: p.1)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            switch g.state {
            case .began:
                panStart = g.location(in: view)
                panStartTime = Date().timeIntervalSince1970
            case .ended:
                let endPoint = g.location(in: view)
                guard let s = toRemote(panStart, in: view),
                      let e = toRemote(endPoint, in: view) else { return }
                let dx = endPoint.x - panStart.x
                let dy = endPoint.y - panStart.y
                let elapsed = (Date().timeIntervalSince1970 - panStartTime) * 1000
                if abs(dx) < 12 && abs(dy) < 12 && elapsed < 600 {
                    conn?.tap(x: e.0, y: e.1)
                } else {
                    let duration = Int32(max(100, min(1500, elapsed)))
                    conn?.swipe(x1: s.0, y1: s.1, x2: e.0, y2: e.1, duration: duration)
                }
            default:
                break
            }
        }
    }
}
