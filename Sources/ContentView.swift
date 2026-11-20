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
                // 按被控端屏幕比例锁定画面区域，避免 View 被压扁导致画面裁切/拉伸
                .aspectRatio(conn.screenW > 0 && conn.screenH > 0
                             ? CGFloat(conn.screenW) / CGFloat(conn.screenH)
                             : CGFloat(9) / CGFloat(19.5), contentMode: .fit)
                .layoutPriority(1)

                // 虚拟按键
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        keyButton("主页", .init(RCProtocol.KEY_HOME), "house")
                        keyButton("返回", .init(RCProtocol.KEY_BACK), "arrow.left")
                        keyButton("多任务", .init(RCProtocol.KEY_RECENTS), "square.stack")
                        keyButton("熄屏", .init(RCProtocol.KEY_SCREEN_OFF), "moon")
                        keyButton("亮屏", .init(RCProtocol.KEY_SCREEN_ON), "sun.max")
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
/// 用纯 SwiftUI Image + scaledToFit，杜绝 UIViewRepresentable 布局导致的画面裁切/拉伸
struct RemoteImageView: View {
    let image: UIImage
    let conn: RemoteConnection

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        // scaledToFit 实际绘制矩形
                        let vw = geo.size.width, vh = geo.size.height
                        let bw = image.size.width, bh = image.size.height
                        guard bw > 0, bh > 0 else { return }
                        let scale = min(vw / bw, vh / bh)
                        let drawW = bw * scale, drawH = bh * scale
                        let offsetX = (vw - drawW) / 2, offsetY = (vh - drawH) / 2
                        handleGesture(value, drawW: drawW, drawH: drawH,
                                      offsetX: offsetX, offsetY: offsetY)
                    }
            )
        }
    }

    /// View 坐标 -> scaledToFit 画面坐标 -> 被控端物理坐标
    private func handleGesture(_ value: DragGesture.Value,
                               drawW: CGFloat, drawH: CGFloat,
                               offsetX: CGFloat, offsetY: CGFloat) {
        guard drawW > 0, drawH > 0, conn.screenW > 0, conn.screenH > 0 else { return }

        func toRemote(_ p: CGPoint) -> (Int32, Int32) {
            var fx = (p.x - offsetX) / drawW
            var fy = (p.y - offsetY) / drawH
            fx = max(0, min(1, fx))
            fy = max(0, min(1, fy))
            return (Int32(fx * CGFloat(conn.screenW)), Int32(fy * CGFloat(conn.screenH)))
        }

        let start = value.startLocation
        let end = value.location
        let dx = end.x - start.x
        let dy = end.y - start.y

        if abs(dx) < 12 && abs(dy) < 12 {
            let p = toRemote(end)
            conn.tap(x: p.0, y: p.1)
        } else {
            let s = toRemote(start)
            let e = toRemote(end)
            let duration: Int32 = 300
            conn.swipe(x1: s.0, y1: s.1, x2: e.0, y2: e.1, duration: duration)
        }
    }
}
