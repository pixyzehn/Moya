import Foundation
import Moya

// MARK: - Provider setup

private func JSONResponseDataFormatter(data: Data) -> Data {
    do {
        let dataAsJSON = try JSONSerialization.jsonObject(with: data, options: [])
        let prettyData = try JSONSerialization.data(withJSONObject: dataAsJSON, options: .prettyPrinted)
        return prettyData
    } catch {
        return data //fallback to original data if it cant be serialized
    }
}

let GitHubProvider = MoyaProvider<GitHub>(plugins: [NetworkLoggerPlugin(verbose: true, responseDataFormatter: JSONResponseDataFormatter)])


// MARK: - Provider support

private extension String {
    var URLEscapedString: String {
        return self.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!
    }
}

public enum GitHub {
    case zen
    case userProfile(String)
    case userRepositories(String)
}

extension GitHub: TargetType {
    public var baseURL: URL { return URL(string: "https://api.github.com")! }
    public var path: String {
        switch self {
        case .zen:
            return "/zen"
        case .userProfile(let name):
            return "/users/\(name.URLEscapedString)"
        case .userRepositories(let name):
            return "/users/\(name.URLEscapedString)/repos"
        }
    }
    public var method: Moya.Method {
        return .GET
    }
    public var parameters: [String: AnyObject]? {
        switch self {
        case .userRepositories(_):
            return ["sort": "pushed"]
        default:
            return nil
        }
    }

    public var sampleData: Data {
        switch self {
        case .zen:
            return "Half measures are as bad as nothing at all.".data(using: .utf8)!
        case .userProfile(let name):
            return "{\"login\": \"\(name)\", \"id\": 100}".data(using: .utf8)!
        case .userRepositories(_):
            return "[{\"name\": \"Repo Name\"}]".data(using: .utf8)!
        }
    }
}

public func url(route: TargetType) -> String {
    return try! route.baseURL.appendingPathComponent(route.path).absoluteString!
}
