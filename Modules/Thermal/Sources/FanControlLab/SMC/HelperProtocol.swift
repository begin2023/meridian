import Foundation

/// 应用 ↔ 特权助手的 XPC 协议。
/// 放在共享核心库里，主应用（远程代理）与助手（导出对象）使用同一份声明。
/// 助手以 root 运行，负责 SMC keyinfo 与写入；读无需助手。
@objc protocol FanControlHelperProtocol {
    /// 连通性检查。返回助手版本。
    func ping(withReply reply: @escaping (String) -> Void)

    /// root 专属的 keyinfo。result: 0 成功；size/type 仅成功时有效。
    func keyInfo(_ key: String, withReply reply: @escaping (Int32, Int, String) -> Void)

    /// 写入键值（原始字节）。助手内部先读回校验尺寸，防止类型错写。
    func writeKey(_ key: String, data: Data, declaredSize: Int, withReply reply: @escaping (Int32) -> Void)
}
