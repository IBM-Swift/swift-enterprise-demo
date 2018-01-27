/**
 * Copyright IBM Corporation 2018
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
import Kitura
import KituraNet
import CircuitBreaker

enum CircuitError: Swift.Error {
    case BadURL
}

func circuitTimeoutCallback(_ err: BreakerError, _ fallbackArgs: (response: RouterResponse, next: () -> Void)) {
    let response: RouterResponse = fallbackArgs.0
    let next: () -> Void = fallbackArgs.1
    switch err {
    case BreakerError.timeout:
        response.status(.expectationFailed).send("Request timed out.")
        break
    case BreakerError.fastFail:
        response.status(.expectationFailed).send("Request failed fast.")
        break
    default: break
    }
    next()
}

func circuitRequestWrapper(invocation: Invocation<(URL, RouterResponse, () -> Void), (RouterResponse, () -> Void)>) {
    let url: URL = invocation.commandArgs.0
    let response: RouterResponse = invocation.commandArgs.1
    let next: () -> Void = invocation.commandArgs.2
    let callback = { (restData: Data?, statusCode: Int?, error: Swift.Error?) -> Void in
        defer {
            next()
        }
        
        guard error == nil, let data = restData else {
            response.status(.internalServerError).send("Could not parse server response.")
            invocation.notifyFailure(error: BreakerError(reason: error?.localizedDescription))
            return
        }
        
        if statusCode == 200 {
            let _ = response.status(.OK).send(data: data)
            invocation.notifySuccess()
        } else {
            let _ = response.send(status: .expectationFailed)
            invocation.notifyFailure(error: BreakerError(reason: error?.localizedDescription))
        }
    }
    networkRequest(url: url, method: "GET", callback: callback)
}

func broadcastCircuitStatus(breaker: CircuitBreaker<(URL, RouterResponse, () -> Void), (RouterResponse, () -> Void)>) {
    let state = breaker.breakerState
    for (_, connection) in controller.wsConnections {
        switch state {
        case .open:
            connection.send(message: "open")
        case .halfopen:
            connection.send(message: "half-open")
        case .closed:
            connection.send(message: "closed")
        }
    }
}
