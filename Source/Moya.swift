import Foundation
import Result

/// Closure to be executed when a request has completed.
public typealias Completion = (result: Result<Moya.Response, Moya.Error>) -> ()

/// Represents an HTTP method.
public enum Method: String {
    case GET, POST, PUT, DELETE, OPTIONS, HEAD, PATCH, TRACE, CONNECT
}

public enum StubBehavior {
    case never
    case immediate
    case delayed(seconds: TimeInterval)
}

/// Protocol to define the base URL, path, method, parameters and sample data for a target.
public protocol TargetType {
    var baseURL: URL { get }
    var path: String { get }
    var method: Moya.Method { get }
    var parameters: [String: AnyObject]? { get }
    var sampleData: Data { get }
}

public enum StructTarget: TargetType {
    case `struct`(TargetType)

    public init(_ target: TargetType) {
        self = StructTarget.struct(target)
    }

    public var path: String {
        return target.path
    }

    public var baseURL: URL {
        return target.baseURL
    }

    public var method: Moya.Method {
        return target.method
    }

    public var parameters: [String: AnyObject]? {
        return target.parameters
    }

    public var sampleData: Data {
        return target.sampleData
    }

    public var target: TargetType {
        switch self {
        case .struct(let t): return t
        }
    }
}

/// Protocol to define the opaque type returned from a request
public protocol Cancellable {
    func cancel()
}

/// Request provider class. Requests should be made through this class only.
public class MoyaProvider<Target: TargetType> {

    /// Closure that defines the endpoints for the provider.
    public typealias EndpointClosure = (Target) -> Endpoint<Target>

    /// Closure that decides if and what request should be performed
    public typealias RequestResultClosure = (Result<URLRequest, Moya.Error>) -> Void

    /// Closure that resolves an Endpoint into an RequestResult.
    public typealias RequestClosure = (Endpoint<Target>, RequestResultClosure) -> Void

    /// Closure that decides if/how a request should be stubbed.
    public typealias StubClosure = (Target) -> Moya.StubBehavior

    public let endpointClosure: EndpointClosure
    public let requestClosure: RequestClosure
    public let stubClosure: StubClosure
    public let manager: Manager

    /// A list of plugins
    /// e.g. for logging, network activity indicator or credentials
    public let plugins: [PluginType]

    public let trackInflights: Bool

    public private(set) var inflightRequests = Dictionary<Endpoint<Target>, [Moya.Completion]>()

    /// Initializes a provider.
    public init(endpointClosure: EndpointClosure = MoyaProvider.DefaultEndpointMapping,
        requestClosure: RequestClosure = MoyaProvider.DefaultRequestMapping,
        stubClosure: StubClosure = MoyaProvider.NeverStub,
        manager: Manager = MoyaProvider<Target>.DefaultAlamofireManager(),
        plugins: [PluginType] = [],
        trackInflights: Bool = false) {

            self.endpointClosure = endpointClosure
            self.requestClosure = requestClosure
            self.stubClosure = stubClosure
            self.manager = manager
            self.plugins = plugins
            self.trackInflights = trackInflights
    }

    /// Returns an Endpoint based on the token, method, and parameters by invoking the endpointsClosure.
    public func endpoint(_ token: Target) -> Endpoint<Target> {
        return endpointClosure(token)
    }

    /// Designated request-making method with queue option. Returns a Cancellable token to cancel the request later.
    public func request(_ target: Target, queue: DispatchQueue?, completion: Moya.Completion) -> Cancellable {
        let endpoint = self.endpoint(target)
        let stubBehavior = self.stubClosure(target)
        var cancellableToken = CancellableWrapper()

        if trackInflights {
            objc_sync_enter(self)
            var inflightCompletionBlocks = self.inflightRequests[endpoint]
            inflightCompletionBlocks?.append(completion)
            self.inflightRequests[endpoint] = inflightCompletionBlocks
            objc_sync_exit(self)

            if inflightCompletionBlocks != nil {
                return cancellableToken
            } else {
                objc_sync_enter(self)
                self.inflightRequests[endpoint] = [completion]
                objc_sync_exit(self)
            }
        }


        let performNetworking = { (requestResult: Result<URLRequest, Moya.Error>) in
            if cancellableToken.isCancelled { return }

            var request: URLRequest!

            switch requestResult {
            case .Success(let urlRequest):
                request = urlRequest
            case .Failure(let error):
                completion(result: .Failure(error))
                return
            }

            switch stubBehavior {
            case .never:
                cancellableToken.innerCancellable = self.sendRequest(target, request: request, queue: queue, completion: { result in

                    if self.trackInflights {
                        self.inflightRequests[endpoint]?.forEach({ $0(result: result) })

                        objc_sync_enter(self)
                        self.inflightRequests.removeValue(forKey: endpoint)
                        objc_sync_exit(self)
                    } else {
                        completion(result: result)
                    }
                })
            default:
                cancellableToken.innerCancellable = self.stubRequest(target, request: request, completion: { result in
                    if self.trackInflights {
                        self.inflightRequests[endpoint]?.forEach({ $0(result: result) })

                        objc_sync_enter(self)
                        self.inflightRequests.removeValue(forKey: endpoint)
                        objc_sync_exit(self)
                    } else {
                        completion(result: result)
                    }
                }, endpoint: endpoint, stubBehavior: stubBehavior)
            }
        }

        requestClosure(endpoint, performNetworking)

        return cancellableToken
    }

    /// Designated request-making method. Returns a Cancellable token to cancel the request later.
    public func request(_ target: Target, completion: Moya.Completion) -> Cancellable {
        return self.request(target, queue:nil, completion:completion)
    }

    /// When overriding this method, take care to `notifyPluginsOfImpendingStub` and to perform the stub using the `createStubFunction` method.
    /// Note: this was previously in an extension, however it must be in the original class declaration to allow subclasses to override.
    internal func stubRequest(_ target: Target, request: URLRequest, completion: Moya.Completion, endpoint: Endpoint<Target>, stubBehavior: Moya.StubBehavior) -> CancellableToken {
        let cancellableToken = CancellableToken { }
        notifyPluginsOfImpendingStub(request, target: target)
        let plugins = self.plugins
        let stub: () -> () = createStubFunction(cancellableToken, forTarget: target, withCompletion: completion, endpoint: endpoint, plugins: plugins)
        switch stubBehavior {
        case .immediate:
            stub()
        case .delayed(let delay):
            let killTimeOffset = Int64(CDouble(delay) * CDouble(NSEC_PER_SEC))
            let killTime = DispatchTime.now() + Double(killTimeOffset) / Double(NSEC_PER_SEC)
            DispatchQueue.main.after(when: killTime) {
                stub()
            }
        case .never:
            fatalError("Method called to stub request when stubbing is disabled.")
        }

        return cancellableToken
    }
}

/// Mark: Defaults

public extension MoyaProvider {

    // These functions are default mappings to MoyaProvider's properties: endpoints, requests, manager, etc.

    public final class func DefaultEndpointMapping(_ target: Target) -> Endpoint<Target> {
        let url = try! target.baseURL.appendingPathComponent(target.path).absoluteString
        return Endpoint(url: url!, sampleResponseClosure: {.networkResponse(200, target.sampleData)}, method: target.method, parameters: target.parameters)
    }

    public final class func DefaultRequestMapping(_ endpoint: Endpoint<Target>, closure: RequestResultClosure) {
        return closure(.Success(endpoint.urlRequest))
    }

    public final class func DefaultAlamofireManager() -> Manager {
        let configuration = URLSessionConfiguration.default()
        configuration.httpAdditionalHeaders = Manager.defaultHTTPHeaders

        let manager = Manager(configuration: configuration)
        manager.startRequestsImmediately = false
        return manager
    }
}

/// Mark: Stubbing

public extension MoyaProvider {

    // Swift won't let us put the StubBehavior enum inside the provider class, so we'll
    // at least add some class functions to allow easy access to common stubbing closures.

    public final class func NeverStub(_: Target) -> Moya.StubBehavior {
        return .never
    }

    public final class func ImmediatelyStub(_: Target) -> Moya.StubBehavior {
        return .immediate
    }

    public final class func DelayedStub(_ seconds: TimeInterval) -> (Target) -> Moya.StubBehavior {
        return { _ in return .delayed(seconds: seconds) }
    }
}

internal extension MoyaProvider {

    func sendRequest(_ target: Target, request: URLRequest, queue: DispatchQueue?, completion: Moya.Completion) -> CancellableToken {
        let alamoRequest = manager.request(request)
        let plugins = self.plugins

        // Give plugins the chance to alter the outgoing request
      plugins.forEach { $0.willSendRequest(alamoRequest, target: target) }

        // Perform the actual request
        alamoRequest.response(queue: queue) { (_, response: HTTPURLResponse?, data: Data?, error: NSError?) -> () in
            let result = convertResponseToResult(response, data: data, error: error)
            // Inform all plugins about the response
            plugins.forEach { $0.didReceiveResponse(result, target: target) }
            completion(result: result)
        }

        alamoRequest.resume()

        return CancellableToken(request: alamoRequest)
    }

    /// Creates a function which, when called, executes the appropriate stubbing behavior for the given parameters.
    internal final func createStubFunction(_ token: CancellableToken, forTarget target: Target, withCompletion completion: Moya.Completion, endpoint: Endpoint<Target>, plugins: [PluginType]) -> (() -> ()) {
        return {
            if token.canceled {
                let error = Moya.Error.underlying(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil))
                plugins.forEach { $0.didReceiveResponse(.Failure(error), target: target) }
                completion(result: .Failure(error))
                return
            }

            switch endpoint.sampleResponseClosure() {
            case .networkResponse(let statusCode, let data):
                let response = Moya.Response(statusCode: statusCode, data: data, response: nil)
                plugins.forEach { $0.didReceiveResponse(.Success(response), target: target) }
                completion(result: .Success(response))
            case .networkError(let error):
                let error = Moya.Error.underlying(error)
                plugins.forEach { $0.didReceiveResponse(.Failure(error), target: target) }
                completion(result: .Failure(error))
            }
        }
    }

    /// Notify all plugins that a stub is about to be performed. You must call this if overriding `stubRequest`.
    internal final func notifyPluginsOfImpendingStub(_ request: URLRequest, target: Target) {
        let alamoRequest = manager.request(request)
        plugins.forEach { $0.willSendRequest(alamoRequest, target: target) }
    }
}

public func convertResponseToResult(_ response: HTTPURLResponse?, data: Data?, error: NSError?) ->
    Result<Moya.Response, Moya.Error> {
    switch (response, data, error) {
    case let (.some(response), .some(data), .none):
        let response = Moya.Response(statusCode: response.statusCode, data: data, response: response)
        return .Success(response)
    case let (_, _, .some(error)):
        let error = Moya.Error.underlying(error)
        return .Failure(error)
    default:
        let error = Moya.Error.underlying(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: nil))
        return .Failure(error)
    }
}

internal struct CancellableWrapper: Cancellable {
    internal var innerCancellable: CancellableToken? = nil

    private var isCancelled = false

    internal func cancel() {
        innerCancellable?.cancel()
    }
}
