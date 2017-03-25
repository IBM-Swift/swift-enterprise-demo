/**
 * Copyright IBM Corporation 2017
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Foundation
#if os(Linux)
    import Dispatch
#endif
import LoggerAPI
import Kitura
import KituraNet
import KituraWebSocket
import SwiftyJSON
import Configuration
import CloudFoundryEnv
import CloudFoundryConfig
import SwiftMetrics
import SwiftMetricsBluemix
import AlertNotifications
import CircuitBreaker

public class Controller {
    //
    enum DemoError: Swift.Error {
        case BadHostURL, InvalidPort
    }

    let configMgr: ConfigurationManager
    let router: Router
    let credentials: ServiceCredentials

    // Metrics variables
    var metrics: SwiftMetrics
    var monitor: SwiftMonitor
    var bluemixMetrics: SwiftMetricsBluemix
    var metricsDict: [String: Any]
    var currentMemoryUser: MemoryUser? = nil
    var autoScalingPolicy: AutoScalingPolicy? = nil

    // Current delay on JSON response.
    var jsonDelayTime: UInt32
    var jsonDispatchQueue: DispatchQueue

    // Circuit breaker.
    let breaker: CircuitBreaker<(URL, RouterResponse, () -> Void), Void, (RouterResponse, () -> Void)>
    var wsConnections: [String: WebSocketConnection]  = [:]
    var broadcastQueue: DispatchQueue
    var jsonEndpointHostURL: String?

    // Location of the cloud config file.
    let cloudConfigFile = "cloud_config.json"

    var port: Int {
        get { return configMgr.port }
    }

    var url: String {
        get { return configMgr.url }
    }

    init() throws {
        // App configuration.
        self.configMgr = ConfigurationManager()
        configMgr.load(file: "../../\(cloudConfigFile)")
        configMgr.load(file: cloudConfigFile, relativeFrom: .pwd)
        configMgr.load(.environmentVariables)
        self.metricsDict = [:]
        self.router = Router()
        if let endpointURL = configMgr["microservice-url"] as? String {
            self.jsonEndpointHostURL = endpointURL
        }

        // Credentials for the Alert Notifications SDK.
        let alertNotificationService = try configMgr.getAlertNotificationService(name: "SwiftEnterpriseDemo-Alert")
        self.credentials = ServiceCredentials(url: alertNotificationService.url, name: alertNotificationService.id, password: alertNotificationService.password)

        // Demo variables.
        self.jsonDelayTime = 0
        self.jsonDispatchQueue = DispatchQueue(label: "jsonResponseQueue")

        // Circuit breaker.
        self.breaker = CircuitBreaker(timeout: 10, maxFailures: 3, fallback: circuitTimeoutCallback, commandWrapper: circuitRequestWrapper)
        self.broadcastQueue = DispatchQueue(label: "circuitBroadcastQueue", qos: DispatchQoS.userInitiated)

        // SwiftMetrics configuration.
        self.metrics = try SwiftMetrics()
        self.monitor = self.metrics.monitor()
        self.bluemixMetrics = SwiftMetricsBluemix(swiftMetricsInstance: self.metrics)
        self.monitor.on(recordCPU)
        self.monitor.on(recordMem)

        // Router configuration.
        self.router.all("/", middleware: BodyParser())
        self.router.all("/", middleware: StickySession(withConfigMgr: self.configMgr))
        self.router.get("/", middleware: StaticFileServer(path: "./public"))
        self.router.get("/initData", handler: getInitDataHandler)
        self.router.get("/metrics", handler: getMetricsHandler)
        self.router.post("/memory", handler: requestMemoryHandler)
        self.router.post("/responseTime", handler: responseTimeHandler)
        self.router.get("/requestJSON", handler: requestJSONHandler)
        self.router.post("/throughput", handler: requestThroughputHandler)
        self.router.post("/changeEndpoint", handler: changeEndpointHandler)
        self.router.post("/changeEndpointState", handler: changeEndpointStateHandler)
        self.router.get("/invokeCircuit", handler: invokeCircuitHandler)
        self.router.get("/sync", handler: syncValuesHandler)
    }

    // Take CPU data and store it in our metrics dictionary.
    func recordCPU(cpu: CPUData) {
        metricsDict["cpuUsedByApplication"] = cpu.percentUsedByApplication * 100
        metricsDict["cpuUsedBySystem"] = cpu.percentUsedBySystem * 100
    }

    // Take memory data and store it in our metrics dictionary.
    func recordMem(mem: MemData) {
        metricsDict["totalRAMOnSystem"] = mem.totalRAMOnSystem
        metricsDict["totalRAMUsed"] = mem.totalRAMUsed
        metricsDict["totalRAMFree"] = mem.totalRAMFree
        metricsDict["applicationAddressSpaceSize"] = mem.applicationAddressSpaceSize
        metricsDict["applicationPrivateSize"] = mem.applicationPrivateSize
        metricsDict["applicationRAMUsed"] = mem.applicationRAMUsed
        
        // If auto-scaling memory limits haven't been set, set them now.
        if let policy = self.autoScalingPolicy, policy.totalSystemRAM == nil {
            policy.totalSystemRAM = metricsDict["totalRAMOnSystem"] as? Int
        }
    }

    // Obtain information about the current auto-scaling policy.
    func getAutoScalingPolicy() {
        guard configMgr.isLocal == false, let appID = configMgr.getApp()?.id else {
            Log.error("App is either running locally or an application ID could not be found. Cannot acquire auto-scaling policy information.")
            return
        }

        let autoScalingServices = configMgr.getServices(type: "Auto-Scaling")
        guard autoScalingServices.count > 0 else {
            Log.error("No auto-scaling service was found for this application.")
            return
        }

        guard let autoScalingService = AutoScalingService(withService: autoScalingServices[0]) else {
            Log.error("Could not obtain information for auto-scaling service.")
            return
        }

        let policyURLString = "\(autoScalingService.apiURL)/v1/autoscaler/apps/\(appID)/policy"
        guard let policyURL = URL(string: policyURLString) else {
            Log.error("Invalid URL. Could not acquire auto-scaling policy.")
            return
        }

        guard let oauthToken = configMgr["cf-oauth-token"] as? String else {
            Log.error("No oauth token provided. Cannot obtain auto-scaling policy.")
            return
        }

        networkRequest(url: policyURL, method: "GET", authorization: oauthToken) {
            restData, response, error in
            if let error = error {
                Log.error("Error retrieving auto-scaling policy: \(error.localizedDescription)")
                return
            }

            guard response == 200 else {
                if response == 404 {
                    Log.warning("No auto-scaling policy has been defined for this application.")
                    if let data = restData {
                        Log.warning("\(String(data: data, encoding: .utf8))")
                    }
                } else if response == 401 {
                    Log.error("Authorization is invalid.")
                    if let data = restData {
                        Log.warning("\(String(data: data, encoding: .utf8))")
                    }
                } else {
                    Log.error("Error obtaining auto-scaling policy. Status code: \(response)")
                    if let data = restData {
                        Log.warning("\(String(data: data, encoding: .utf8))")
                    }
                }
                return
            }

            guard let data = restData else {
                Log.error("No data returned for auto-scaling policy.")
                return
            }

            self.autoScalingPolicy = AutoScalingPolicy(data: data)
            Log.debug("\(self.autoScalingPolicy), \(self.autoScalingPolicy != nil)")
            if let appData = self.configMgr.getApp() {
                self.autoScalingPolicy?.totalSystemRAM = appData.limits.memory * 1_048_576
            }
        }
    }

    // Start regularly sending out information on the state of the circuit.
    func startCircuitBroadcast() {
        let broadcastWorkItem = {
            while true {
                broadcastCircuitStatus(breaker: self.breaker)
                sleep(10)
            }
        }
        self.broadcastQueue.async(execute: broadcastWorkItem)
    }

    public func getInitDataHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        var initDict: [String: Any] = [:]
        initDict["monitoringURL"] = "/swiftmetrics-dash"
        initDict["websocketURL"] = "ws://localhost:\(self.port)/circuit"

        if configMgr.isLocal == false, let appData = configMgr.getApp(), let appName = configMgr.name {
            var bluemixHostURL = "console.ng.bluemix.net"
            if configMgr.url.range(of: "stage1") != nil {
                bluemixHostURL = "console.stage1.ng.bluemix.net"
            }
            initDict["monitoringURL"] = "https://\(bluemixHostURL)/monitoring/index?dashboard=console.dashboard.page.appmonitoring1&nav=false&ace_config=%7B%22spaceGuid%22%3A%22\(appData.spaceId)%22%2C%22appGuid%22%3A%22\(appData.id)%22%2C%22bluemixUIVersion%22%3A%22Atlas%22%2C%22idealHeight%22%3A571%2C%22theme%22%3A%22bx--global-light-ui%22%2C%22appName%22%3A%22\(appName)%22%2C%22appRoutes%22%3A%22\(appData.uris[0])%22%7D&bluemixNav=true"
            initDict["websocketURL"] = "wss://\(appData.uris[0])/circuit"
            if let credDict = configMgr.getService(spec: ".*[Aa]uto-[Ss]caling.*")?.credentials, let autoScalingServiceID = credDict["service_id"] {
                initDict["autoScalingURL"] = "https://\(bluemixHostURL)/services/\(autoScalingServiceID)?ace_config=%7B%22spaceGuid%22%3A%22\(appData.spaceId)%22%2C%22appGuid%22%3A%22\(appData.id)%22%2C%22redirect%22%3A%22https%3A%2F%2F\(bluemixHostURL)%2Fapps%2F\(appData.id)%3FpaneId%3Dconnected-objects%22%2C%22bluemixUIVersion%22%3A%22v5%22%7D"
            }
            initDict["totalRAM"] = appData.limits.memory * 1_048_576
        } else if let totalRAM = metricsDict["totalRAMOnSystem"] {
            initDict["totalRAM"] = totalRAM
        }

        if let microserviceURL = self.jsonEndpointHostURL {
            initDict["microserviceURL"] = microserviceURL
        }

        if let initData = try? JSONSerialization.data(withJSONObject: initDict, options: []) {
            response.status(.OK).send(data: initData)
        } else {
            response.status(.internalServerError).send("Could not retrieve application data.")
        }
        next()
    }

    public func getMetricsHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        if let metricsData = try? JSONSerialization.data(withJSONObject: metricsDict, options: []) {
            response.status(.OK).send(data: metricsData)
        } else {
            response.status(.internalServerError).send("Could not retrieve metrics data.")
        }
        next()
    }

    public func requestMemoryHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        Log.info("Request for memory received.")
        guard let parsedBody = request.body else {
            Log.error("Bad request. Could not utilize memory.")
            response.status(.badRequest).send("Bad request. Could not utilize memory.")
            next()
            return
        }

        switch parsedBody {
        case .json(let memObject):
            guard memObject.type == .number else {
                fallthrough
            }

            if let memoryAmount = memObject.object as? Int {
                requestMemory(inBytes: memoryAmount, response: response, next: next)
            } else if let memoryNSAmount = memObject.object as? NSNumber {
                let memoryAmount = Int(memoryNSAmount)
                requestMemory(inBytes: memoryAmount, response: response, next: next)
            } else {
                fallthrough
            }
        default:
            Log.error("Bad value received. Could not utilize memory.")
            response.status(.badRequest).send("Bad request. Could not utilize memory.")
            next()
        }
    }

    public func requestMemory(inBytes memoryAmount: Int, response: RouterResponse, next: @escaping () -> Void) {
        self.currentMemoryUser = nil

        guard memoryAmount > 0 else {
            let _ = response.send(status: .OK)
            Log.info("Zero memory requested. Not creating new memory object.")
            next()
            return
        }

        self.currentMemoryUser = try? MemoryUser(usingBytes: memoryAmount)
        if self.currentMemoryUser == nil {
            let _ = response.status(.internalServerError).send("Could not obtain memory. Requested amount may exceed memory available.")
        } else {
            let _ = response.send(status: .OK)
            Log.info("New memory value: \(memoryAmount) bytes")
        }
        next()

        self.autoScalingPolicy?.checkPolicyTriggers(metric: .Memory, value: memoryAmount, configMgr: self.configMgr, usingCredentials: self.credentials)
    }

    public func responseTimeHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        Log.info("Request to increase delay received.")
        guard let parsedBody = request.body else {
            Log.error("Bad request. Could not change delay time.")
            response.status(.badRequest).send("Bad request. Could not change delay time.")
            next()
            return
        }

        switch parsedBody {
        case .json(let responseTimeObject):
            guard responseTimeObject.type == .number else {
                fallthrough
            }

            if let responseTime = responseTimeObject.object as? UInt32 {
                self.jsonDelayTime = responseTime
                let _ = response.send(status: .OK)
                Log.info("New response delay: \(responseTime) seconds")
                self.autoScalingPolicy?.checkPolicyTriggers(metric: .ResponseTime, value: Int(responseTime), configMgr: self.configMgr, usingCredentials: self.credentials)
            } else if let NSResponseTime = responseTimeObject.object as? NSNumber {
                let responseTime = Int(NSResponseTime)
                self.jsonDelayTime = UInt32(responseTime)
                let _ = response.send(status: .OK)
                Log.info("New response delay: \(responseTime) seconds")
                self.autoScalingPolicy?.checkPolicyTriggers(metric: .ResponseTime, value: responseTime, configMgr: self.configMgr, usingCredentials: self.credentials)
            } else {
                fallthrough
            }
        default:
            Log.error("Bad value received. Could not change delay time.")
            response.status(.badRequest).send("Bad request. Could not change delay time.")
        }
        next()
    }

    public func requestJSONHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        Log.info("Request for JSON endpoint received... about to sleep for \(self.jsonDelayTime) seconds.")
        sleep(self.jsonDelayTime)
        let responseDict = ["delay": Int(self.jsonDelayTime)]
        if let responseData = try? JSONSerialization.data(withJSONObject: responseDict, options: []) {
            response.status(.OK).send(data: responseData)
        } else {
            response.status(.internalServerError).send("Could not retrieve response data.")
        }
        next()
    }

    public func requestThroughputHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        Log.info("Request for increased throughput received.")
        guard let parsedBody = request.body else {
            Log.error("Bad throughput request.")
            response.status(.badRequest).send("Bad throughput request.")
            next()
            return
        }

        switch parsedBody {
        case .json(let throughputObject):
            guard throughputObject.type == .number else {
                fallthrough
            }

            if let throughput = throughputObject.object as? Int {
                self.autoScalingPolicy?.checkPolicyTriggers(metric: .Throughput, value: throughput, configMgr: self.configMgr, usingCredentials: self.credentials)
                Log.info("New throughput value: \(throughput) requests per second.")
                let _ = response.send(status: .OK)
            } else if let NSThroughput = throughputObject.object as? NSNumber {
                let throughput = Int(NSThroughput)
                self.autoScalingPolicy?.checkPolicyTriggers(metric: .Throughput, value: throughput, configMgr: self.configMgr, usingCredentials: self.credentials)
                Log.info("New throughput value: \(throughput) requests per second.")
                let _ = response.send(status: .OK)
            } else {
                fallthrough
            }
        default:
            Log.error("Bad value received for throughput request.")
            response.status(.badRequest).send("Bad value received for throughput request.")
        }
        next()
    }

    public func changeEndpointHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        guard let parsedBody = request.body else {
            Log.error("Bad request. Could not change endpoint.")
            response.status(.badRequest).send("Bad request. Could not change endpoint.")
            next()
            return
        }

        switch parsedBody {
        case .json(let endpointObject):
            guard endpointObject.type == .dictionary else {
                fallthrough
            }

            if let endpoint = endpointObject.object as? [String: Any], let formattedEndpoint = try? formatEndpoint(URL: endpoint) {
                self.jsonEndpointHostURL = formattedEndpoint
                let _ = response.status(.OK).send("\(formattedEndpoint)")
            } else {
                fallthrough
            }
        default:
            Log.error("Bad value received. Could not change endpoint.")
            response.status(.badRequest).send("Bad value received. Could not change endpoint.")
        }
        next()
    }

    func formatEndpoint(URL endpoint: [String: Any]) throws -> String {
        guard let hostURL = endpoint["host"] as? String, hostURL.characters.count > 8 else {
            Log.info("\(endpoint["host"])")
            throw DemoError.BadHostURL
        }

        // Remove trailing slashes.
        var urlCopy = hostURL
        var lastIndex = urlCopy.index(urlCopy.startIndex, offsetBy: urlCopy.characters.count-1)
        while urlCopy.characters.count > 1 && urlCopy[lastIndex] == "/" {
            urlCopy = urlCopy.substring(to: lastIndex)
            lastIndex = urlCopy.index(urlCopy.startIndex, offsetBy: urlCopy.characters.count-1)
        }

        // Ensure length again so our http check doesn't fail.
        guard urlCopy.characters.count > 8 else {
            throw DemoError.BadHostURL
        }

        // Ensure that the URL starts with http:// or https://
        let httpString = urlCopy.substring(to: urlCopy.index(urlCopy.startIndex, offsetBy: 7))
        let httpsString = urlCopy.substring(to: urlCopy.index(urlCopy.startIndex, offsetBy: 8))
        if httpString != "http://" && httpsString != "https://" {
            urlCopy = "http://\(urlCopy)"
        }

        return urlCopy
    }

    public func changeEndpointStateHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        guard let endpointHost = self.jsonEndpointHostURL, let starterURL = URL(string: "\(endpointHost)/jsonEndpointManager") else {
            response.status(.badRequest).send("Invalid microservice URL supplied.")
            next()
            return
        }

        guard let parsedBody = request.body else {
            Log.error("Bad request. Could not change endpoint.")
            response.status(.badRequest).send("Bad request. Could not change endpoint state.")
            next()
            return
        }

        switch parsedBody {
        case .json(let payloadObject):
            guard payloadObject.type == .dictionary else {
                fallthrough
            }

            if let payload = payloadObject.object as? [String: Any] {
                // For some reason on Linux I have to reassemble this dictionary into another dictionary
                // to get the boolean working right.
                var payloadString: String
                var delay = 0
                if let delayFromPayload = payload["delay"] as? Int {
                    delay = delayFromPayload
                } else if let delayFromPayload = payload["delay"] as? NSNumber {
                    delay = Int(delayFromPayload)
                }
                if let enabledBool = payload["enabled"] as? Bool {
                    payloadString = "{\"delay\":\(delay),\"enabled\":\(enabledBool)}"
                } else if let enabledInt = payload["enabled"] as? Int, enabledInt == 1 {
                    payloadString = "{\"delay\":\(delay),\"enabled\":true}"
                } else {
                    payloadString = "{\"delay\":\(delay),\"enabled\":false}"
                }
                let payloadData = payloadString.data(using: .utf8)

                networkRequest(url: starterURL, method: "POST", payload: payloadData) {
                    data, urlresponse, error in
                    guard error == nil else {
                        response.status(.internalServerError).send("Error changing endpoint settings.")
                        next()
                        return
                    }

                    guard let responseCode = urlresponse else {
                        response.status(.internalServerError).send("No response code received from server. Request status unknown.")
                        next()
                        return
                    }

                    guard responseCode == 200 else {
                        if let responseData = data, let statusCode = HTTPStatusCode(rawValue: responseCode), let dataString = String(data: responseData, encoding: .utf8) {
                            response.status(statusCode).send(dataString)
                        } else {
                            response.status(.internalServerError).send("Response from server was malformed.")
                        }
                        next()
                        return
                    }

                    let _ = response.send(status: .OK)
                    next()
                }
            } else {
                fallthrough
            }
        default:
            Log.error("Bad value received. Could not change endpoint state.")
            response.status(.badRequest).send("Bad value received. Could not change endpoint state.")
            next()
        }
    }

    public func invokeCircuitHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        guard let endpointURL = self.jsonEndpointHostURL, let starterURL = URL(string: "\(endpointURL)/json") else {
            response.status(.badRequest).send("Invalid URL supplied.")
            next()
            return
        }

        breaker.run(commandArgs: (url: starterURL, response: response, next: next), fallbackArgs: (response: response, next: next))
    }

    public func syncValuesHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        Log.info("Request to synchronize values received.")
        var valuesDict: [String: Int] = [:]
        if let memUser = self.currentMemoryUser {
            valuesDict["memoryValue"] = memUser.bytes
        } else {
            valuesDict["memoryValue"] = 0
        }
        valuesDict["responseTimeValue"] = Int(self.jsonDelayTime)

        if let valuesData = try? JSONSerialization.data(withJSONObject: valuesDict, options: []) {
            response.status(.OK).send(data: valuesData)
        } else {
            response.status(.internalServerError).send("Could not retrieve values for synchronization.")
        }
        next()
    }
}
