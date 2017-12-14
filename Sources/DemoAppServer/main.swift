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

import Kitura
import KituraWebSocket
import LoggerAPI
import HeliumLogger
import SwiftMetricsDash

// Set logger and log level
HeliumLogger.use(LoggerMessageType.info)

// Create controller (which does basically everything).
let controller = try Controller()

// Initialize the WebSocket class.
WebSocket.register(service: CircuitWSService(), onPath: "circuit")

// Get auto-scaling policy.
controller.getAutoScalingPolicy()

// Activate the Swift Metrics dashboard.
let _ = try SwiftMetricsDash(swiftMetricsInstance: controller.metrics, endpoint: controller.router)

// Add an HTTP server and connect it to the router
Kitura.addHTTPServer(onPort: controller.port, with: controller.router)

// Start broadcasting the state of the CircuitBreaker.
controller.startCircuitBroadcast()

// Start the Kitura runloop (this call never returns)
Kitura.run()
