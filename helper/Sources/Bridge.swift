import Foundation

/// Newline-delimited JSON over a localhost TCP socket. Godot listens; we connect.
final class Bridge {
    private let port: Int
    private var fd: Int32 = -1
    private let writeQueue = DispatchQueue(label: "filo.bridge.write")
    var onLine: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    init(port: Int) {
        self.port = port
    }

    func connect(attempts: Int = 60, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for _ in 0..<attempts {
                if tryConnect() {
                    DispatchQueue.main.async { completion(true) }
                    readLoop()
                    return
                }
                usleep(250_000)
            }
            DispatchQueue.main.async { completion(false) }
        }
    }

    private func tryConnect() -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            close(s)
            return false
        }
        var one: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        return true
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 10) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    DispatchQueue.main.async { self.onLine?(obj) }
                }
            }
        }
        DispatchQueue.main.async { self.onDisconnect?() }
    }

    func send(_ obj: [String: Any]) {
        writeQueue.async { [self] in
            guard fd >= 0, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            var payload = data
            payload.append(10)
            payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, base + offset, raw.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
        }
    }
}
