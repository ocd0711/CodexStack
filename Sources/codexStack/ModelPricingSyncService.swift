import Foundation

extension NSNotification.Name {
    static let pricingUpdated = NSNotification.Name("CodexStackPricingUpdated")
}

struct LiteLLMPrice: Codable {
    let input_cost_per_token: Double?
    let output_cost_per_token: Double?
    let cache_read_input_token_cost: Double?
}

class ModelPricingSyncService {
    static let shared = ModelPricingSyncService()

    private let cacheURL: URL
    private(set) var syncedPrices: [String: CodexModelPricing] = [:]

    private var checkTask: Task<Void, Never>?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("codexStack")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
        self.cacheURL = appDir.appendingPathComponent("model_prices.json")
        loadCache()
        
        // Start a periodic background check
        checkTask = Task {
            while !Task.isCancelled {
                syncIfNeeded()
                // Check every hour to see if the interval has passed
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
    }
    
    deinit {
        checkTask?.cancel()
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let dict = try? JSONDecoder().decode([String: CodexModelPricing].self, from: data) else {
            return
        }
        self.syncedPrices = dict
    }

    func syncIfNeeded() {
        let interval = UserDefaults.standard.integer(forKey: "pricingSyncInterval")
        guard interval > 0 else { return }

        let lastSync = UserDefaults.standard.double(forKey: "pricingLastSync")
        let now = Date().timeIntervalSince1970
        if now - lastSync >= Double(interval) {
            Task {
                await syncPrices()
            }
        }
    }

    func syncPrices() async {
        guard let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            var newPrices: [String: CodexModelPricing] = [:]
            for (key, value) in json {
                guard key != "sample_spec", let info = value as? [String: Any] else { continue }
                
                let input = info["input_cost_per_token"] as? Double ?? 0
                let output = info["output_cost_per_token"] as? Double ?? 0
                let cachedInput = info["cache_read_input_token_cost"] as? Double ?? (input * 0.1)
                
                if input > 0 || output > 0 {
                    newPrices[key] = CodexModelPricing(
                        inputPerToken: input,
                        cachedInputPerToken: cachedInput,
                        outputPerToken: output
                    )
                }
            }
            
            if !newPrices.isEmpty {
                DispatchQueue.main.async {
                    self.syncedPrices = newPrices
                    if let encoded = try? JSONEncoder().encode(newPrices) {
                        try? encoded.write(to: self.cacheURL)
                    }
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pricingLastSync")
                    NotificationCenter.default.post(name: .pricingUpdated, object: nil)
                }
            }
        } catch {
            print("Failed to sync model prices: \(error)")
        }
    }
}
