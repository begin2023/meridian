import Foundation

// IP 归属地在线查询:ipinfo.io(免费无鉴权),失败退回 freeipapi。
// 每次启动查一次;接口/IP 变化时由 NetModule 再次触发。结果缓存,
// 在拿到新结果前,弹窗展示 currentText。
final class GeoResolver {
    static let shared = GeoResolver()

    private(set) var currentText: String = "查询中…"
    /// 归属地服务返回的公网出口 IP;查询成功前为 nil。
    private(set) var publicIP: String?
    private var inFlight = false
    private var lastCompletedKey: String?

    /// 测试/调试用:直接注入展示文本。
    func setDebugText(_ text: String) {
        currentText = text
    }

    func lookupIfNeeded() {
        guard !inFlight else { return }
        inFlight = true
        fetchText { [weak self] text, publicIP in
            guard let self else { return }
            self.inFlight = false
            if let text {
                self.currentText = text
                self.publicIP = publicIP
                self.lastCompletedKey = text
            } else if self.lastCompletedKey == nil {
                self.currentText = "未获取"
            }
        }
    }

    private func fetchText(completion: @escaping (String?, String?) -> Void) {
        fetchJSON(from: URL(string: "https://ipinfo.io/json")) { dict in
            if let dict, let text = Self.describe(
                city: dict["city"] as? String,
                region: dict["region"] as? String,
                country: dict["country"] as? String,
                org: dict["org"] as? String
            ) {
                completion(text, dict["ip"] as? String)
                return
            }
            // 退路:freeipapi
            self.fetchJSON(from: URL(string: "https://freeipapi.com/api/json")) { dict in
                let text = dict.flatMap {
                    Self.describe(
                        city: $0["cityName"] as? String,
                        region: $0["regionName"] as? String,
                        country: $0["countryName"] as? String,
                        org: nil
                    )
                }
                completion(text, dict?["ipAddress"] as? String)
            }
        }
    }

    private func fetchJSON(from url: URL?, completion: @escaping ([String: Any]?) -> Void) {
        guard let url else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(dict) }
        }.resume()
    }

    private static func describe(city: String?, region: String?, country: String?, org: String?) -> String? {
        let place = [city, region, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard !place.isEmpty else { return nil }
        var text = place.joined(separator: " · ")
        if let org, !org.isEmpty {
            // 去掉 "AS4812 " 这类自治域前缀,保留运营商名
            let operatorName = org.split(separator: " ").dropFirst().joined(separator: " ")
            if !operatorName.isEmpty {
                text += " · \(operatorName)"
            }
        }
        return text
    }
}
